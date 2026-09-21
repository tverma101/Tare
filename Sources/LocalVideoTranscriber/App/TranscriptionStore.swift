import AppKit
import Combine
import Foundation
import TranscriberCore
import UniformTypeIdentifiers

@MainActor
final class TranscriptionStore: ObservableObject {
    @Published var jobs: [TranscriptionJob] = []
    @Published var selectedJobID: TranscriptionJob.ID?
    @Published var outputDirectory: URL {
        didSet {
            UserDefaults.standard.set(outputDirectory.path, forKey: Self.outputDirectoryDefaultsKey)
        }
    }
    @Published var createBatchFolder: Bool {
        didSet {
            UserDefaults.standard.set(createBatchFolder, forKey: Self.createBatchFolderDefaultsKey)
        }
    }
    @Published var attachCaptionedVideoToSource: Bool {
        didSet {
            UserDefaults.standard.set(attachCaptionedVideoToSource, forKey: Self.attachCaptionedVideoToSourceDefaultsKey)
        }
    }
    @Published var libraryDirectory: URL {
        didSet {
            UserDefaults.standard.set(libraryDirectory.path, forKey: Self.libraryDirectoryDefaultsKey)
        }
    }
    @Published var scanRoots: [URL] {
        didSet {
            Self.saveScanRoots(scanRoots)
        }
    }
    @Published var autoScanOnLaunch: Bool {
        didSet {
            UserDefaults.standard.set(autoScanOnLaunch, forKey: Self.autoScanOnLaunchDefaultsKey)
        }
    }
    @Published var autoProcessDiscoveredMKVs: Bool {
        didSet {
            UserDefaults.standard.set(autoProcessDiscoveredMKVs, forKey: Self.autoProcessDiscoveredMKVsDefaultsKey)
        }
    }
    @Published var lastOutputDirectory: URL?
    @Published var localeIdentifier: String {
        didSet {
            UserDefaults.standard.set(localeIdentifier, forKey: Self.localeIdentifierDefaultsKey)
        }
    }
    @Published var modelIdentifier: String {
        didSet {
            let normalizedIdentifier = Self.normalizedModelIdentifier(modelIdentifier)
            if normalizedIdentifier != modelIdentifier {
                modelIdentifier = normalizedIdentifier
                return
            }
            UserDefaults.standard.set(modelIdentifier, forKey: Self.modelIdentifierDefaultsKey)
            guard modelIdentifier != oldValue, !isRunning, !isPreparingModel else { return }
            shouldSelectFirstLocalModel = false
            shouldRecoverUnavailableSavedModel = false
            if let preset = WhisperModelPreset.preset(for: modelIdentifier) {
                statusMessage = "Selected \(preset.displayName)"
            } else if !modelIdentifier.isEmpty {
                statusMessage = "Custom model selected"
            }
        }
    }
    @Published var geminiMode: GeminiTranscriptionMode = .verbatim {
        didSet {
            UserDefaults.standard.set(geminiMode.rawValue, forKey: Self.geminiModeDefaultsKey)
            if geminiMode == .smart {
                geminiWordTimestamps = false
                geminiSpeakerDiarization = false
            }
        }
    }
    @Published var geminiWordTimestamps = false {
        didSet { UserDefaults.standard.set(geminiWordTimestamps, forKey: Self.geminiWordTimestampsDefaultsKey) }
    }
    @Published var geminiSpeakerDiarization = false {
        didSet { UserDefaults.standard.set(geminiSpeakerDiarization, forKey: Self.geminiSpeakerDiarizationDefaultsKey) }
    }
    @Published var geminiCustomVocabularyText = "" {
        didSet { UserDefaults.standard.set(geminiCustomVocabularyText, forKey: Self.geminiVocabularyDefaultsKey) }
    }
    @Published private(set) var geminiAPIKeyRecords: [GeminiAPIKeyRecord] = []
    @Published private(set) var isVerifyingGeminiKeys = false
    @Published private(set) var geminiVerificationMessage: String?
    @Published private(set) var geminiVerifiedCredentialIDs: Set<UUID> = []
    @Published var selectedFormats: Set<ExportFormat> = [.text] {
        didSet {
            Self.saveSelectedFormats(selectedFormats)
        }
    }
    @Published var isRunning = false
    @Published var isPreparingModel = false
    @Published var isScanning = false
    @Published var isOrganizing = false
    @Published var dropIsTargeted = false
    @Published var statusMessage = "Ready"
    @Published var modelStatuses: [String: ModelStatus] = [:]
    @Published var isRefreshingModels = false
    @Published var modelOperation: String?
    @Published var modelOperationModelID: String?
    @Published var modelErrorMessage: String?
    @Published var cloudErrorMessage: String?

    private let audioExtractor: FFmpegAudioExtractor?
    private let whisperService: WhisperTranscriptionService?
    private let exporter = TranscriptExporter()
    private let transcriptLinker = TranscriptLinker()
    private let captionedVideoExporter = CaptionedVideoExporter()
    private let audioLyricsEmbedder = AudioLyricsEmbedder()
    private let mkvDiscoveryService = MKVDiscoveryService()
    private let filenameCleanerService = FilenameCleanerService()
    private let mediaLibraryOrganizer = MediaLibraryOrganizer()
    private let modelManager: ModelManagerService?
    private let geminiAPIKeyStore = GeminiAPIKeyStore()
    private let geminiTranscriptionService = GeminiTranscriptionService()
    private var runTask: Task<Void, Never>?
    private var modelPreparationTask: Task<Void, Never>?
    private var shouldAutoStart = false
    private var shouldSelectFirstLocalModel = false
    private var shouldRecoverUnavailableSavedModel = false
    private var didStartLaunchWork = false
    private var openFilesObserver: NSObjectProtocol?

    private static let outputDirectoryDefaultsKey = "outputDirectoryPath"
    private static let libraryDirectoryDefaultsKey = "libraryDirectoryPath"
    private static let scanRootsDefaultsKey = "mkvScanRootPaths"
    private static let autoScanOnLaunchDefaultsKey = "autoScanOnLaunch"
    private static let autoProcessDiscoveredMKVsDefaultsKey = "autoProcessDiscoveredMKVs"
    private static let createBatchFolderDefaultsKey = "createBatchFolder"
    private static let attachCaptionedVideoToSourceDefaultsKey = "attachCaptionedVideoToSource"
    private static let localeIdentifierDefaultsKey = "localeIdentifier"
    private static let modelIdentifierDefaultsKey = "modelIdentifier"
    private static let selectedFormatsDefaultsKey = "selectedFormats"
    private static let selectedFormatsCSVDefaultsKey = "selectedFormatsCSV"
    private static let geminiModeDefaultsKey = "geminiTranscriptionMode"
    private static let geminiWordTimestampsDefaultsKey = "geminiWordTimestamps"
    private static let geminiSpeakerDiarizationDefaultsKey = "geminiSpeakerDiarization"
    private static let geminiVocabularyDefaultsKey = "geminiCustomVocabulary"

    init() {
        let environment = ProcessInfo.processInfo.environment
        if let outputPath = environment["TARE_OUTPUT_DIR"], !outputPath.isEmpty {
            let outputRoot = URL(fileURLWithPath: outputPath, isDirectory: true)
            outputDirectory = outputRoot
            try? FileManager.default.createDirectory(
                at: outputRoot,
                withIntermediateDirectories: true
            )
        } else if let savedPath = UserDefaults.standard.string(forKey: Self.outputDirectoryDefaultsKey),
                  !savedPath.isEmpty {
            let outputRoot = URL(fileURLWithPath: savedPath, isDirectory: true)
            outputDirectory = outputRoot
            try? FileManager.default.createDirectory(
                at: outputRoot,
                withIntermediateDirectories: true
            )
        } else {
            let outputRoot = OutputFolderPlanner.defaultRootDirectory()
            outputDirectory = outputRoot
            try? FileManager.default.createDirectory(
                at: outputRoot,
                withIntermediateDirectories: true
            )
        }

        if let rawCreateBatchFolder = environment["TARE_CREATE_BATCH_FOLDER"] {
            createBatchFolder = rawCreateBatchFolder != "0"
        } else if UserDefaults.standard.object(forKey: Self.createBatchFolderDefaultsKey) != nil {
            createBatchFolder = UserDefaults.standard.bool(forKey: Self.createBatchFolderDefaultsKey)
        } else {
            createBatchFolder = true
        }

        attachCaptionedVideoToSource = true

        if let libraryPath = environment["TARE_LIBRARY_DIR"], !libraryPath.isEmpty {
            libraryDirectory = URL(fileURLWithPath: libraryPath, isDirectory: true)
        } else if let savedPath = UserDefaults.standard.string(forKey: Self.libraryDirectoryDefaultsKey),
                  !savedPath.isEmpty {
            libraryDirectory = URL(fileURLWithPath: savedPath, isDirectory: true)
        } else {
            libraryDirectory = OutputFolderPlanner.defaultLibraryDirectory()
        }

        if let rawScanRoots = environment["TARE_SCAN_ROOTS"], !rawScanRoots.isEmpty {
            scanRoots = Self.scanRoots(from: rawScanRoots)
        } else {
            scanRoots = Self.savedScanRoots()
        }

        if UserDefaults.standard.object(forKey: Self.autoScanOnLaunchDefaultsKey) != nil {
            autoScanOnLaunch = UserDefaults.standard.bool(forKey: Self.autoScanOnLaunchDefaultsKey)
        } else {
            autoScanOnLaunch = true
        }

        if UserDefaults.standard.object(forKey: Self.autoProcessDiscoveredMKVsDefaultsKey) != nil {
            autoProcessDiscoveredMKVs = UserDefaults.standard.bool(forKey: Self.autoProcessDiscoveredMKVsDefaultsKey)
        } else {
            autoProcessDiscoveredMKVs = false
        }

        lastOutputDirectory = nil
        if let language = environment["TARE_LANGUAGE"], !language.isEmpty {
            localeIdentifier = language
        } else if let locale = environment["TARE_LOCALE"], !locale.isEmpty {
            localeIdentifier = locale
        } else if let savedLocale = UserDefaults.standard.string(forKey: Self.localeIdentifierDefaultsKey),
                  !savedLocale.isEmpty {
            localeIdentifier = savedLocale
        } else {
            localeIdentifier = WhisperLanguagePreset.auto.id
        }

        if let model = environment["TARE_MODEL"], !model.isEmpty {
            modelIdentifier = Self.normalizedModelIdentifier(model)
        } else if let savedModel = UserDefaults.standard.string(forKey: Self.modelIdentifierDefaultsKey),
                  !savedModel.isEmpty {
            let normalizedSavedModel = Self.normalizedModelIdentifier(savedModel)
            let selectedModelIdentifier = normalizedSavedModel == WhisperModelPreset.balancedMultilingual.id
                ? WhisperModelPreset.fastMultilingual.id
                : normalizedSavedModel
            modelIdentifier = selectedModelIdentifier
            shouldRecoverUnavailableSavedModel = WhisperModelPreset.preset(for: selectedModelIdentifier)?.isLocal == true
        } else {
            modelIdentifier = WhisperModelPreset.fastMultilingual.id
            shouldSelectFirstLocalModel = true
        }

        geminiWordTimestamps = UserDefaults.standard.bool(forKey: Self.geminiWordTimestampsDefaultsKey)
        geminiSpeakerDiarization = UserDefaults.standard.bool(forKey: Self.geminiSpeakerDiarizationDefaultsKey)
        geminiCustomVocabularyText = UserDefaults.standard.string(forKey: Self.geminiVocabularyDefaultsKey) ?? ""
        let savedGeminiMode = UserDefaults.standard.string(forKey: Self.geminiModeDefaultsKey)
            .flatMap(GeminiTranscriptionMode.init(rawValue:)) ?? .verbatim
        geminiMode = savedGeminiMode
        if savedGeminiMode == .smart {
            geminiWordTimestamps = false
            geminiSpeakerDiarization = false
        }
        if let rawFormats = environment["TARE_FORMATS"], !rawFormats.isEmpty {
            selectedFormats = Self.exportFormats(fromCSV: rawFormats)
        } else if let savedFormats = UserDefaults.standard.array(forKey: Self.selectedFormatsDefaultsKey) as? [String],
                  !savedFormats.isEmpty {
            selectedFormats = Self.exportFormats(fromRawValues: savedFormats)
        } else if let savedFormatsCSV = UserDefaults.standard.string(forKey: Self.selectedFormatsCSVDefaultsKey),
                  !savedFormatsCSV.isEmpty {
            selectedFormats = Self.exportFormats(fromCSV: savedFormatsCSV)
        }

        audioExtractor = try? FFmpegAudioExtractor()
        whisperService = try? WhisperTranscriptionService()
        modelManager = try? ModelManagerService()

        // Persist the normalized/migrated cloud settings after all stored
        // dependencies are initialized so an older preference with an invalid
        // mode or incompatible annotations cannot reappear on the next restart.
        UserDefaults.standard.set(geminiMode.rawValue, forKey: Self.geminiModeDefaultsKey)
        UserDefaults.standard.set(geminiWordTimestamps, forKey: Self.geminiWordTimestampsDefaultsKey)
        UserDefaults.standard.set(geminiSpeakerDiarization, forKey: Self.geminiSpeakerDiarizationDefaultsKey)
        UserDefaults.standard.set(geminiCustomVocabularyText, forKey: Self.geminiVocabularyDefaultsKey)
        do {
            geminiAPIKeyRecords = try geminiAPIKeyStore.loadRecords()
        } catch {
            geminiAPIKeyRecords = []
            cloudErrorMessage = error.localizedDescription
        }
        Self.saveSelectedFormats(selectedFormats)

        if let inputList = environment["TARE_INPUTS"], !inputList.isEmpty {
            let urls = inputList
                .split(separator: "\n")
                .map { URL(fileURLWithPath: String($0)) }
            let preferred = SupportedMedia.preferredMacCompatibleURLs(from: urls)
            jobs = preferred.map { TranscriptionJob(sourceURL: $0) }
            selectedJobID = jobs.first?.id
        }

        shouldAutoStart = environment["TARE_AUTOSTART"] == "1"

        if audioExtractor == nil {
            statusMessage = "ffmpeg backend missing"
        } else if whisperService == nil,
                  WhisperModelPreset.preset(for: modelIdentifier)?.isCloud != true {
            statusMessage = "MLX Whisper backend missing"
        }

        openFilesObserver = NotificationCenter.default.addObserver(
            forName: .tareOpenFiles,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let urls = notification.userInfo?["urls"] as? [URL] else { return }
            Task { @MainActor in
                self?.addFiles(urls)
            }
        }

        let pendingURLs = PendingOpenFiles.shared.drain()
        if !pendingURLs.isEmpty {
            addFiles(pendingURLs)
        }

        Task { @MainActor [weak self] in
            await self?.refreshModelStatuses()
        }
    }

    deinit {
        if let openFilesObserver {
            NotificationCenter.default.removeObserver(openFilesObserver)
        }
    }

    var selectedJob: TranscriptionJob? {
        guard let selectedJobID else { return jobs.first }
        return jobs.first { $0.id == selectedJobID }
    }

    var mkvJobCount: Int {
        jobs.filter { Self.isMKV($0.sourceURL) }.count
    }

    var canScanForMKVs: Bool {
        !isRunning && !isScanning && !isOrganizing && !scanRoots.isEmpty
    }

    var canCleanAndOrganizeMKVs: Bool {
        !isRunning && !isScanning && !isOrganizing && mkvJobCount > 0
    }

    var canStart: Bool {
        !isRunning
            && !isPreparingModel
            && !isScanning
            && !isOrganizing
            && !jobs.isEmpty
            && jobs.contains { $0.status == .queued || $0.status == .failed || $0.status == .cancelled }
    }

    var completedCount: Int {
        jobs.filter { $0.status == .completed }.count
    }

    var failedCount: Int {
        jobs.filter { $0.status == .failed }.count
    }

    func presentFilePicker() {
        let panel = NSOpenPanel()
        panel.title = "Add Video or Audio"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = SupportedMedia.contentTypes

        if panel.runModal() == .OK {
            addFiles(panel.urls)
        }
    }

    func presentOutputDirectoryPicker() {
        let panel = NSOpenPanel()
        panel.title = "Choose Output Folder"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = outputDirectory

        if panel.runModal() == .OK, let url = panel.url {
            outputDirectory = url
        }
    }

    func presentLibraryDirectoryPicker() {
        let panel = NSOpenPanel()
        panel.title = "Choose MKV Library Folder"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = libraryDirectory

        if panel.runModal() == .OK, let url = panel.url {
            libraryDirectory = url
        }
    }

    func presentScanRootPicker() {
        let panel = NSOpenPanel()
        panel.title = "Add MKV Search Folder"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false

        if panel.runModal() == .OK {
            let existing = Set(scanRoots.map { $0.standardizedFileURL.path })
            let additions = panel.urls
                .map(\.standardizedFileURL)
                .filter { !existing.contains($0.path) }
            scanRoots.append(contentsOf: additions)
        }
    }

    func removeScanRoot(_ url: URL) {
        let target = url.standardizedFileURL.path
        scanRoots.removeAll { $0.standardizedFileURL.path == target }
    }

    func addFiles(_ urls: [URL]) {
        let existing = Set(jobs.map { $0.sourceURL.standardizedFileURL })
        let supported = SupportedMedia.preferredMacCompatibleURLs(from: urls)
            .filter { !existing.contains($0) }

        guard !supported.isEmpty else {
            statusMessage = "No supported new files"
            return
        }

        let newJobs = supported.map { sourceURL -> TranscriptionJob in
            var job = TranscriptionJob(sourceURL: sourceURL)
            job.linkedTranscriptURL = transcriptLinker.existingLink(for: sourceURL)?.primaryTranscriptURL
            return job
        }
        jobs.append(contentsOf: newJobs)
        selectedJobID = selectedJobID ?? newJobs.first?.id
        let linkedCount = newJobs.filter { $0.linkedTranscriptURL != nil }.count
        if linkedCount > 0 {
            statusMessage = "\(newJobs.count) file\(newJobs.count == 1 ? "" : "s") added; \(linkedCount) linked transcript\(linkedCount == 1 ? "" : "s") found"
        } else {
            statusMessage = "\(newJobs.count) file\(newJobs.count == 1 ? "" : "s") added"
        }
    }

    func addDroppedProviders(_ providers: [NSItemProvider]) -> Bool {
        var handled = false

        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            handled = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, _ in
                let url: URL?

                if let itemURL = item as? URL {
                    url = itemURL
                } else if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = nil
                }

                guard let url else { return }

                Task { @MainActor [weak self] in
                    self?.addFiles([url])
                }
            }
        }

        return handled
    }

    func scanForMKVs(autoProcess: Bool = false) async {
        guard canScanForMKVs else {
            return
        }

        isScanning = true
        statusMessage = "Finding MKV files"

        let discovered = await mkvDiscoveryService.discover(in: scanRoots)
        let existingCount = jobs.count
        addFiles(discovered)
        let addedCount = jobs.count - existingCount

        isScanning = false
        if addedCount == 0 {
            statusMessage = discovered.isEmpty ? "No MKV files found" : "No new MKV files"
        } else {
            statusMessage = "Found \(addedCount) MKV file\(addedCount == 1 ? "" : "s")"
        }

        if autoProcess, addedCount > 0 {
            await cleanOrganizeAndStartMKVs()
        }
    }

    func cleanAndOrganizeMKVs() async {
        await cleanAndOrganizeMKVs(startAfter: false)
    }

    func cleanOrganizeAndStartMKVs() async {
        await cleanAndOrganizeMKVs(startAfter: true)
    }

    func removeSelectedJob() {
        guard let selectedJobID else { return }
        jobs.removeAll { $0.id == selectedJobID }
        self.selectedJobID = jobs.first?.id
    }

    func clearCompleted() {
        jobs.removeAll { $0.status == .completed }
        if let selectedJobID, jobs.allSatisfy({ $0.id != selectedJobID }) {
            self.selectedJobID = jobs.first?.id
        }
    }

    func retrySelectedJob() {
        guard let id = selectedJobID else { return }
        updateJob(id) { job in
            job.status = .queued
            job.progress = 0
            job.errorMessage = nil
            job.outputURLs = []
            job.startedAt = nil
            job.completedAt = nil
        }
    }

    func revealOutputDirectory() {
        let directory = currentOutputDirectory
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func toggleFormat(_ format: ExportFormat) {
        if selectedFormats.contains(format) {
            selectedFormats.remove(format)
        } else {
            selectedFormats.insert(format)
        }
    }

    var savesTextTranscript: Bool {
        selectedFormats.contains(.text)
    }

    func setTextTranscriptEnabled(_ isEnabled: Bool) {
        if isEnabled {
            selectedFormats.insert(.text)
        } else {
            selectedFormats.remove(.text)
        }
    }

    var savesTimestampedTranscript: Bool {
        selectedFormats.contains(.timestampedText)
    }

    func setTimestampedTranscriptEnabled(_ isEnabled: Bool) {
        if isEnabled {
            selectedFormats.insert(.timestampedText)
        } else {
            selectedFormats.remove(.timestampedText)
        }
    }

    private func cleanAndOrganizeMKVs(startAfter: Bool) async {
        guard canCleanAndOrganizeMKVs else {
            return
        }

        let targetIDs = jobs
            .filter { Self.isMKV($0.sourceURL) }
            .map(\.id)

        guard !targetIDs.isEmpty else {
            statusMessage = "No MKV files to organize"
            return
        }

        isOrganizing = true
        statusMessage = "Cleaning MKV names"

        let sourceURLs = targetIDs.compactMap { id in
            jobs.first { $0.id == id }?.sourceURL
        }

        var cleanResults: [FilenameCleanResult] = []
        var cleanerUnavailable = false
        do {
            cleanResults = try await filenameCleanerService.clean(urls: sourceURLs)
        } catch FilenameCleanerError.cleanerMissing {
            cleanerUnavailable = true
        } catch {
            isOrganizing = false
            statusMessage = "Name cleanup failed: \(error.localizedDescription)"
            return
        }

        let cleanResultByPath = Dictionary(uniqueKeysWithValues: cleanResults.map { ($0.path, $0) })
        var renamedCount = cleanResults.filter(\.renamed).count
        var movedCount = 0

        do {
            for id in targetIDs {
                guard let currentURL = jobs.first(where: { $0.id == id })?.sourceURL else {
                    continue
                }

                let cleanedURL = cleanResultByPath[currentURL.path]?.targetURL ?? currentURL
                let organization = try await mediaLibraryOrganizer.organize(
                    sourceURL: cleanedURL,
                    libraryRoot: libraryDirectory
                )
                if organization.moved {
                    movedCount += 1
                }
                if cleanedURL.path != currentURL.path, cleanResultByPath[currentURL.path] == nil {
                    renamedCount += 1
                }

                updateJob(id) { job in
                    job.sourceURL = organization.destinationURL
                    if job.status == .failed || job.status == .cancelled {
                        job.status = .queued
                        job.progress = 0
                        job.errorMessage = nil
                        job.outputURLs = []
                        job.startedAt = nil
                        job.completedAt = nil
                    }
                }
            }
        } catch {
            isOrganizing = false
            statusMessage = "Organize failed: \(error.localizedDescription)"
            return
        }

        isOrganizing = false
        let cleanPrefix = cleanerUnavailable ? "Cleaner missing; " : "\(renamedCount) renamed, "
        statusMessage = "\(cleanPrefix)\(movedCount) moved"

        if startAfter {
            startBatch()
        }
    }

    func startBatch() {
        guard canStart else { return }
        guard audioExtractor != nil else {
            statusMessage = "ffmpeg was not found"
            return
        }
        let languageCode = WhisperTranscriptionService.languageCode(from: localeIdentifier)
        let effectiveModelIdentifier = WhisperModelPreset.optimizedIdentifier(modelIdentifier, languageCode: languageCode)
        let usesCloudModel = WhisperModelPreset.isGeminiTranscribe(effectiveModelIdentifier)

        guard usesCloudModel || whisperService != nil else {
            statusMessage = "Run script/setup_transcription_backend.sh"
            return
        }

        let selectedModelIdentifier = modelIdentifier

        // Managed models must pass a fresh cache check before any output folder is
        // created or a transcription task is started. The launch-time inventory
        // is not trusted here because it may still be loading, or the cache may
        // have changed outside this process.
        if WhisperModelPreset.preset(for: effectiveModelIdentifier) != nil {
            isPreparingModel = true
            modelErrorMessage = nil
            statusMessage = "Checking model availability…"
            modelPreparationTask = Task { @MainActor [weak self] in
                await self?.preflightAndStartBatch(
                    modelIdentifier: effectiveModelIdentifier,
                    selectedModelIdentifier: selectedModelIdentifier,
                    languageCode: languageCode
                )
            }
            return
        }

        startBatch(effectiveModelIdentifier: effectiveModelIdentifier)
    }

    private func preflightAndStartBatch(
        modelIdentifier: String,
        selectedModelIdentifier: String,
        languageCode: String?
    ) async {
        defer {
            isPreparingModel = false
            modelPreparationTask = nil
        }

        guard self.modelIdentifier == selectedModelIdentifier,
              WhisperTranscriptionService.languageCode(from: localeIdentifier) == languageCode else {
            statusMessage = "Model or language changed; press Start again"
            return
        }

        guard let preset = WhisperModelPreset.preset(for: modelIdentifier) else {
            startBatch(effectiveModelIdentifier: modelIdentifier)
            return
        }

        if preset.isCloud {
            do {
                _ = try geminiTranscriptionOptions.validated()
                let credentials = try await readGeminiCredentials()
                guard !credentials.isEmpty else {
                    throw GeminiTranscriptionError.apiKeysMissing
                }

                isVerifyingGeminiKeys = true
                statusMessage = "Verifying Gemini 3.5 Transcribe access…"
                defer { isVerifyingGeminiKeys = false }

                let verification = await geminiTranscriptionService.verifyTranscribeModelAccess(
                    credentials: credentials
                )
                geminiVerificationMessage = verification.message
                if let credentialID = verification.verifiedCredentialID {
                    geminiVerifiedCredentialIDs.insert(credentialID)
                    recordGeminiCredentialUse(credentialID)
                }
                guard verification.isAvailable else {
                    cloudErrorMessage = verification.message
                    statusMessage = "Cloud model verification failed"
                    modelErrorMessage = nil
                    return
                }
                cloudErrorMessage = nil
                startBatch(
                    effectiveModelIdentifier: modelIdentifier,
                    geminiCredentials: credentials
                )
            } catch {
                statusMessage = "Cloud transcription is not ready"
                modelErrorMessage = nil
                cloudErrorMessage = error.localizedDescription
                geminiVerificationMessage = error.localizedDescription
                return
            }
            return
        }

        guard let modelManager else {
            statusMessage = "Could not verify \(preset.displayName). Repair the model backend in Models."
            modelErrorMessage = ModelManagerError.pythonMissing.localizedDescription
            return
        }

        do {
            let status = try await modelManager.status(for: modelIdentifier)
            modelStatuses[modelIdentifier] = status

            guard status.isUsable else {
                statusMessage = "\(preset.displayName) is not ready on this Mac"
                modelErrorMessage = status.issueMessage ?? "The cached model cannot run on this Mac. Choose another available model."
                return
            }
        } catch is CancellationError {
            statusMessage = "Model check cancelled"
            return
        } catch {
            statusMessage = "Could not verify \(preset.displayName)"
            modelErrorMessage = error.localizedDescription
            return
        }

        startBatch(effectiveModelIdentifier: modelIdentifier)
    }

    private func startBatch(
        effectiveModelIdentifier: String,
        geminiCredentials: [GeminiAPIKeyCredential]? = nil
    ) {

        let queuedSourceURLs = jobs
            .filter { $0.status == .queued || $0.status == .failed || $0.status == .cancelled }
            .map(\.sourceURL)

        let exportDirectory: URL
        do {
            if createBatchFolder {
                exportDirectory = try OutputFolderPlanner.createBatchDirectory(
                    rootDirectory: outputDirectory,
                    sourceURLs: queuedSourceURLs
                )
            } else {
                exportDirectory = outputDirectory
                try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
            }
        } catch {
            statusMessage = "Could not create output folder"
            return
        }

        lastOutputDirectory = exportDirectory
        isRunning = true
        statusMessage = "Saving to \(exportDirectory.lastPathComponent)"

        let configuration = TranscriptionConfiguration(
            outputDirectory: exportDirectory,
            localeIdentifier: localeIdentifier,
            modelIdentifier: effectiveModelIdentifier,
            formats: selectedFormats.intersection(Self.textSidecarFormats),
            attachCaptionedVideoToSource: true,
            chunkSeconds: WhisperModelPreset.isGeminiTranscribe(effectiveModelIdentifier) || WhisperModelPreset.usesLongFormInference(effectiveModelIdentifier)
                ? 0
                : Self.automaticChunkSeconds,
            chunkWorkerCount: Self.automaticWorkerCount,
            geminiOptions: geminiTranscriptionOptions
        )

        runTask = Task { [weak self] in
            await self?.runBatch(
                configuration: configuration,
                geminiCredentials: geminiCredentials
            )
        }
    }

    func modelStatus(for preset: WhisperModelPreset) -> ModelStatus? {
        modelStatuses[preset.id]
    }

    var installedModelPresets: [WhisperModelPreset] {
        WhisperModelPreset.local.filter { modelStatuses[$0.id]?.isUsable == true }
    }

    var downloadableModelPresets: [WhisperModelPreset] {
        WhisperModelPreset.local.filter { modelStatuses[$0.id]?.isUsable != true }
    }

    var effectiveSelectedModelIdentifier: String {
        WhisperModelPreset.optimizedIdentifier(
            modelIdentifier,
            languageCode: WhisperTranscriptionService.languageCode(from: localeIdentifier)
        )
    }

    var effectiveSelectedModelStatus: ModelStatus? {
        modelStatuses[effectiveSelectedModelIdentifier]
    }

    var currentOutputDirectory: URL {
        lastOutputDirectory ?? outputDirectory
    }

    var isUsingGeminiTranscription: Bool {
        WhisperModelPreset.isGeminiTranscribe(effectiveSelectedModelIdentifier)
    }

    var geminiTranscriptionOptions: GeminiTranscriptionOptions {
        GeminiTranscriptionOptions(
            mode: geminiMode,
            wordTimestamps: geminiWordTimestamps,
            speakerDiarization: geminiSpeakerDiarization,
            customVocabulary: GeminiTranscriptionOptions.vocabularyTerms(from: geminiCustomVocabularyText)
        )
    }

    var geminiOptionsValidationMessage: String? {
        do {
            _ = try geminiTranscriptionOptions.validated()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func readGeminiCredentials() async throws -> [GeminiAPIKeyCredential] {
        let keyStore = geminiAPIKeyStore
        return try await Self.performKeychainWork {
            try keyStore.activeCredentials()
        }
    }

    private static func performKeychainWork<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await Task.detached(priority: .userInitiated, operation: operation).value
    }

    var geminiAPIKeyCount: Int {
        geminiAPIKeyRecords.filter(\.isEnabled).count
    }

    /// This is deliberately metadata-only. Reading Keychain secrets from a
    /// SwiftUI body caused a Security prompt on every view refresh. Actual
    /// secret reads happen once when Verify or Start is pressed.
    var geminiUsableAPIKeyCount: Int {
        geminiAPIKeyRecords.filter(\.isEnabled).count
    }

    func useGeminiTranscription() {
        modelIdentifier = WhisperModelPreset.gemini35Transcribe.id
        statusMessage = "Selected Gemini 3.5 Transcribe"
    }

    func setGeminiMode(_ mode: GeminiTranscriptionMode) {
        geminiMode = mode
    }

    func addGeminiAPIKey(label: String, apiKey: String) {
        let keyStore = geminiAPIKeyStore
        Task { @MainActor [weak self] in
            do {
                let record = try await Self.performKeychainWork {
                    try keyStore.add(label: label, apiKey: apiKey)
                }
                guard let self else { return }
                self.geminiAPIKeyRecords = try keyStore.loadRecords()
                self.cloudErrorMessage = nil
                self.geminiVerificationMessage = "API key saved. Verifying model access…"
                await self.verifyGeminiAPIKey(record)
            } catch {
                self?.cloudErrorMessage = error.localizedDescription
            }
        }
    }

    func verifyGeminiAPIKeys() {
        Task { [weak self] in
            await self?.verifyAllEnabledGeminiAPIKeys()
        }
    }

    func verifyGeminiAPIKey(_ record: GeminiAPIKeyRecord) async {
        guard record.isEnabled else {
            geminiVerificationMessage = "Enable the key before verifying model access."
            return
        }

        let credential: GeminiAPIKeyCredential
        do {
            guard let match = try await readGeminiCredentials().first(where: { $0.id == record.id }) else {
                geminiVerificationMessage = GeminiAPIKeyStoreError.missingSecret.localizedDescription
                cloudErrorMessage = geminiVerificationMessage
                return
            }
            credential = match
        } catch {
            geminiVerificationMessage = error.localizedDescription
            cloudErrorMessage = error.localizedDescription
            return
        }

        isVerifyingGeminiKeys = true
        defer { isVerifyingGeminiKeys = false }
        do {
            let result = try await geminiTranscriptionService.verifyTranscribeModelAccess(apiKey: credential.apiKey)
            geminiVerificationMessage = result.message
            if result.isAvailable {
                geminiVerifiedCredentialIDs.insert(record.id)
                cloudErrorMessage = nil
                recordGeminiCredentialUse(record.id)
            } else {
                geminiVerifiedCredentialIDs.remove(record.id)
                cloudErrorMessage = result.message
            }
        } catch {
            geminiVerifiedCredentialIDs.remove(record.id)
            geminiVerificationMessage = error.localizedDescription
            cloudErrorMessage = error.localizedDescription
        }
    }

    private func verifyAllEnabledGeminiAPIKeys() async {
        let credentials: [GeminiAPIKeyCredential]
        do {
            credentials = try await readGeminiCredentials()
        } catch {
            geminiVerificationMessage = error.localizedDescription
            cloudErrorMessage = error.localizedDescription
            return
        }
        guard !credentials.isEmpty else {
            geminiVerificationMessage = GeminiTranscriptionError.apiKeysMissing.localizedDescription
            cloudErrorMessage = geminiVerificationMessage
            return
        }

        isVerifyingGeminiKeys = true
        statusMessage = "Verifying Gemini 3.5 Transcribe access…"
        defer { isVerifyingGeminiKeys = false }

        let verification = await geminiTranscriptionService.verifyTranscribeModelAccess(
            credentials: credentials
        )
        geminiVerificationMessage = verification.message
        if let credentialID = verification.verifiedCredentialID {
            geminiVerifiedCredentialIDs.insert(credentialID)
            recordGeminiCredentialUse(credentialID)
        }
        if verification.isAvailable {
            cloudErrorMessage = nil
            statusMessage = "Gemini 3.5 Transcribe verified"
        } else {
            cloudErrorMessage = verification.message
            statusMessage = "Cloud model verification failed"
        }
    }

    func removeGeminiAPIKey(_ record: GeminiAPIKeyRecord) {
        let keyStore = geminiAPIKeyStore
        Task { @MainActor [weak self] in
            do {
                try await Self.performKeychainWork {
                    try keyStore.delete(record)
                }
                guard let self else { return }
                self.geminiAPIKeyRecords = try keyStore.loadRecords()
                self.geminiVerifiedCredentialIDs.remove(record.id)
            } catch {
                self?.cloudErrorMessage = error.localizedDescription
            }
        }
    }

    func setGeminiAPIKeyEnabled(_ isEnabled: Bool, record: GeminiAPIKeyRecord) {
        let keyStore = geminiAPIKeyStore
        Task { @MainActor [weak self] in
            do {
                try await Self.performKeychainWork {
                    try keyStore.setEnabled(isEnabled, for: record)
                }
                guard let self else { return }
                self.geminiAPIKeyRecords = try keyStore.loadRecords()
                if !isEnabled {
                    self.geminiVerifiedCredentialIDs.remove(record.id)
                }
            } catch {
                self?.cloudErrorMessage = error.localizedDescription
            }
        }
    }

    func moveGeminiAPIKeys(fromOffsets: IndexSet, toOffset: Int) {
        let keyStore = geminiAPIKeyStore
        Task { @MainActor [weak self] in
            do {
                try await Self.performKeychainWork {
                    try keyStore.move(fromOffsets: fromOffsets, toOffset: toOffset)
                }
                self?.geminiAPIKeyRecords = try keyStore.loadRecords()
            } catch {
                self?.cloudErrorMessage = error.localizedDescription
            }
        }
    }

    private func recordGeminiCredentialUse(_ id: UUID) {
        geminiAPIKeyStore.markUsed(id)
        if let records = try? geminiAPIKeyStore.loadRecords() {
            geminiAPIKeyRecords = records
        }
    }

    func isActiveModel(_ preset: WhisperModelPreset) -> Bool {
        let languageCode = WhisperTranscriptionService.languageCode(from: localeIdentifier)
        let effectiveIdentifier = WhisperModelPreset.optimizedIdentifier(
            modelIdentifier,
            languageCode: languageCode
        )
        return modelIdentifier == preset.id || effectiveIdentifier == preset.id
    }

    func selectModel(_ preset: WhisperModelPreset) {
        modelIdentifier = preset.id
        statusMessage = "Selected \(preset.displayName)"
    }

    func refreshModelStatuses() async {
        guard let modelManager else {
            modelErrorMessage = ModelManagerError.pythonMissing.localizedDescription
            return
        }

        isRefreshingModels = true
        defer { isRefreshingModels = false }

        do {
            let knownModelIDs = Set(WhisperModelPreset.local.map(\.id))
            let localStatuses = try await modelManager.localModels()
                .filter { knownModelIDs.contains($0.modelIdentifier) && $0.isAvailable }
            modelStatuses = Dictionary(uniqueKeysWithValues: localStatuses.map { ($0.modelIdentifier, $0) })

            if shouldSelectFirstLocalModel,
               let firstLocalPreset = Self.localModelSelectionOrder.first(where: { modelStatuses[$0.id]?.isUsable == true }) {
                modelIdentifier = firstLocalPreset.id
                statusMessage = "Using local \(firstLocalPreset.displayName)"
                shouldSelectFirstLocalModel = false
            } else if shouldRecoverUnavailableSavedModel {
                shouldRecoverUnavailableSavedModel = false
                let selectedModelIsUsable = modelStatuses[modelIdentifier]?.isUsable == true
                let effectiveModelIsUsable = modelStatuses[effectiveSelectedModelIdentifier]?.isUsable == true
                if !selectedModelIsUsable,
                   !effectiveModelIsUsable,
                   let firstLocalPreset = Self.localModelSelectionOrder.first(where: { modelStatuses[$0.id]?.isUsable == true }) {
                    let unavailablePreset = WhisperModelPreset.preset(for: modelIdentifier)
                    modelIdentifier = firstLocalPreset.id
                    if let unavailablePreset {
                        statusMessage = "\(unavailablePreset.displayName) is not runnable here; using local \(firstLocalPreset.displayName)"
                    } else {
                        statusMessage = "Using local \(firstLocalPreset.displayName)"
                    }
                }
            }
        } catch {
            modelErrorMessage = error.localizedDescription
        }
    }

    private static let localModelSelectionOrder: [WhisperModelPreset] = [
        .fastMultilingual,
        .fastestMultilingual,
        .parakeetV3,
        .qwen3ASR6Bit,
        .voxtralMini8BitDense,
        .fastTurboMultilingual,
        .balancedMultilingual,
        .mossDiarize,
        .canaryQwen,
        .voxtralMini,
        .cohereTranscribe,
        .qwen3ASR8Bit,
        .qwen3ASRBF16,
        .voxtralSmall,
        .distilledLargeMultilingual,
        .highestAccuracyMultilingual,
        .accurateMultilingual,
        .fastestEnglish,
        .fastEnglish,
        .balancedEnglish,
        .accurateEnglish,
    ]

    func downloadModel(_ preset: WhisperModelPreset) async {
        await performModelOperation("Downloading \(preset.displayName)", preset: preset) { modelManager in
            try await modelManager.download(modelIdentifier: preset.id)
        }
    }

    func installModel(_ preset: WhisperModelPreset) async {
        await performModelOperation("Installing \(preset.displayName)", preset: preset) { modelManager in
            try await modelManager.install(modelIdentifier: preset.id)
        }
        if modelErrorMessage == nil, modelOperation == nil {
            selectModel(preset)
        }
    }

    func removeModel(_ preset: WhisperModelPreset) async {
        guard !isActiveModel(preset) else {
            modelErrorMessage = "Tare cannot remove the active model. Install or select another model first."
            return
        }

        guard modelStatus(for: preset)?.isAvailable == true else {
            modelErrorMessage = "\(preset.displayName) is not downloaded."
            return
        }

        await performModelOperation("Removing \(preset.displayName)", preset: preset) { modelManager in
            try await modelManager.remove(modelIdentifier: preset.id)
        }
    }

    private func performModelOperation(
        _ message: String,
        preset: WhisperModelPreset,
        operation: (ModelManagerService) async throws -> ModelStatus
    ) async {
        guard modelOperation == nil else { return }
        guard let modelManager else {
            modelErrorMessage = ModelManagerError.pythonMissing.localizedDescription
            return
        }

        modelErrorMessage = nil
        modelOperation = message
        modelOperationModelID = preset.id
        defer {
            modelOperation = nil
            modelOperationModelID = nil
        }

        do {
            modelStatuses[preset.id] = try await operation(modelManager)
        } catch {
            modelErrorMessage = error.localizedDescription
        }
    }

    func startLaunchWorkIfNeeded() {
        guard !didStartLaunchWork else { return }
        didStartLaunchWork = true
        startRequestedBatchIfNeeded()
    }

    private func startRequestedBatchIfNeeded() {
        guard shouldAutoStart else { return }
        shouldAutoStart = false
        startBatch()
    }

    func cancelBatch() {
        modelPreparationTask?.cancel()
        runTask?.cancel()
        statusMessage = isPreparingModel ? "Cancelling model check" : "Cancelling"
    }

    private func runBatch(
        configuration: TranscriptionConfiguration,
        geminiCredentials: [GeminiAPIKeyCredential]? = nil
    ) async {
        defer {
            isRunning = false
            runTask = nil
            statusMessage = "Ready"
        }

        let jobIDs = jobs
            .filter { $0.status == .queued || $0.status == .failed || $0.status == .cancelled }
            .map(\.id)

        let batchGeminiCredentials: [GeminiAPIKeyCredential]?
        if WhisperModelPreset.isGeminiTranscribe(configuration.modelIdentifier) {
            do {
                if let geminiCredentials {
                    batchGeminiCredentials = geminiCredentials
                } else {
                    batchGeminiCredentials = try await readGeminiCredentials()
                }
            } catch {
                for id in jobIDs {
                    updateJob(id) { job in
                        job.status = .failed
                        job.errorMessage = error.localizedDescription
                        job.completedAt = Date()
                    }
                }
                return
            }
        } else {
            batchGeminiCredentials = nil
        }

        for id in jobIDs {
            if Task.isCancelled {
                markQueuedJobsCancelled()
                return
            }

            selectedJobID = id

            do {
                updateJob(id) { job in
                    job.status = .extractingAudio
                    job.progress = 0.08
                    job.errorMessage = nil
                    job.outputURLs = []
                    job.transcript = nil
                    job.startedAt = Date()
                    job.completedAt = nil
                }

                guard let sourceURL = jobs.first(where: { $0.id == id })?.sourceURL else {
                    continue
                }

                guard let audioExtractor else {
                    throw WhisperTranscriptionError.pythonMissing
                }

                let audioLevel = try await audioExtractor.measureAudioLevel(of: sourceURL)

                if audioLevel.isEffectivelySilent {
                    let transcript = Self.silentTranscript(
                        sourceURL: sourceURL,
                        localeIdentifier: configuration.localeIdentifier,
                        audioLevel: audioLevel
                    )

                    updateJob(id) { job in
                        job.status = .exporting
                        job.progress = 0.9
                        job.transcript = transcript
                    }

                    let outputURLs = try await exportOutputs(
                        transcript,
                        sourceURL: sourceURL,
                        configuration: configuration
                    )

                    updateJob(id) { job in
                        job.status = .completed
                        job.progress = 1
                        job.outputURLs = outputURLs
                        job.errorMessage = nil
                        job.completedAt = Date()
                    }
                    continue
                }

                let usesGemini = WhisperModelPreset.isGeminiTranscribe(configuration.modelIdentifier)
                let audioURL = try await audioExtractor.extractAudio(
                    from: sourceURL,
                    preserveSourceQuality: usesGemini
                )
                defer { try? FileManager.default.removeItem(at: audioURL) }

                try Task.checkCancellation()

                updateJob(id) { job in
                    job.status = .transcribing
                    job.progress = 0.2
                }

                let transcript: Transcript
                if WhisperModelPreset.isGeminiTranscribe(configuration.modelIdentifier) {
                    let credentials = batchGeminiCredentials ?? []
                    guard !credentials.isEmpty else {
                        throw GeminiTranscriptionError.apiKeysMissing
                    }
                    transcript = try await geminiTranscriptionService.transcribe(
                        audioURL: audioURL,
                        sourceName: sourceURL.lastPathComponent,
                        localeIdentifier: configuration.localeIdentifier,
                        credentials: credentials,
                        options: configuration.geminiOptions,
                        audioExtractor: audioExtractor,
                        progress: { [weak self] progress in
                            Task { @MainActor [weak self] in
                                guard let self else { return }
                                self.statusMessage = progress.phase
                                self.updateJob(id) { job in
                                    let fraction = Double(progress.completedChunks) / Double(max(progress.totalChunks, 1))
                                    job.progress = min(0.86, 0.2 + fraction * 0.66)
                                }
                            }
                        },
                        onCredentialUsed: { [weak self] id in
                            Task { @MainActor [weak self] in
                                self?.recordGeminiCredentialUse(id)
                            }
                        }
                    )
                } else {
                    guard let whisperService else {
                        throw WhisperTranscriptionError.pythonMissing
                    }
                    transcript = try await whisperService.transcribe(
                        audioURL: audioURL,
                        sourceName: sourceURL.lastPathComponent,
                        localeIdentifier: configuration.localeIdentifier,
                        modelIdentifier: configuration.modelIdentifier,
                        chunkSeconds: configuration.chunkSeconds,
                        chunkWorkerCount: configuration.chunkWorkerCount,
                        wordTimestamps: configuration.requiresWordTimestamps
                    )
                }

                try Task.checkCancellation()

                let finalTranscript = Transcript(
                    sourceName: sourceURL.lastPathComponent,
                    createdAt: transcript.createdAt,
                    localeIdentifier: transcript.localeIdentifier,
                    fullText: transcript.fullText,
                    segments: transcript.segments
                )

                updateJob(id) { job in
                    job.status = .exporting
                    job.progress = 0.9
                    job.transcript = finalTranscript
                }

                let outputURLs = try await exportOutputs(
                    finalTranscript,
                    sourceURL: sourceURL,
                    configuration: configuration
                )

                updateJob(id) { job in
                    job.status = .completed
                    job.progress = 1
                    job.outputURLs = outputURLs
                    job.errorMessage = nil
                    job.completedAt = Date()
                }
            } catch is CancellationError {
                updateJob(id) { job in
                    job.status = .cancelled
                    job.errorMessage = "Cancelled"
                    job.completedAt = Date()
                }
                markQueuedJobsCancelled()
                return
            } catch {
                updateJob(id) { job in
                    job.status = .failed
                    job.errorMessage = error.localizedDescription
                    job.completedAt = Date()
                }
            }
        }
    }

    private func exportOutputs(
        _ transcript: Transcript,
        sourceURL: URL,
        configuration: TranscriptionConfiguration
    ) async throws -> [URL] {
        var outputURLs: [URL] = []
        let exportFormats = configuration.formats.intersection(Self.textSidecarFormats)

        if !exportFormats.isEmpty {
            outputURLs.append(
                contentsOf: try await exporter.export(
                    transcript,
                    sourceURL: sourceURL,
                    to: configuration.outputDirectory,
                    formats: exportFormats
                )
            )
        }

        let manifestURL = transcriptLinker.manifestURL(
            for: sourceURL,
            outputDirectory: configuration.outputDirectory
        )
        let linkMetadata = transcriptLinker.metadata(
            for: transcript,
            sourceURL: sourceURL,
            transcriptURLs: outputURLs,
            manifestURL: manifestURL,
            modelIdentifier: configuration.modelIdentifier
        )

        if SupportedMedia.videoExtensions.contains(sourceURL.pathExtension.lowercased()),
           !transcript.segments.isEmpty {
            let attachedVideo = try await captionedVideoExporter.attachToSource(
                sourceURL: sourceURL,
                captions: exporter.srtDocument(for: transcript),
                localeIdentifier: transcript.localeIdentifier
            )
            outputURLs.append(attachedVideo.outputURL)
            if let backupURL = attachedVideo.backupURL {
                outputURLs.append(backupURL)
            }
        }

        if AudioLyricsEmbedder.canAttachLyrics(to: sourceURL) {
            let attachedAudio = try await audioLyricsEmbedder.attachToSource(
                sourceURL: sourceURL,
                lyrics: exporter.appleMusicLyricsDocument(for: transcript),
                linkMetadata: linkMetadata
            )
            outputURLs.append(attachedAudio.outputURL)
            outputURLs.append(attachedAudio.backupURL)
        }

        outputURLs.append(try transcriptLinker.write(linkMetadata))

        return outputURLs
    }

    private func updateJob(_ id: TranscriptionJob.ID, mutate: (inout TranscriptionJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else {
            return
        }

        mutate(&jobs[index])
    }

    private func markQueuedJobsCancelled() {
        for id in jobs.filter({ !$0.status.isTerminal }).map(\.id) {
            updateJob(id) { job in
                job.status = .cancelled
                job.errorMessage = "Cancelled"
                job.completedAt = Date()
            }
        }
    }

    private static func silentTranscript(
        sourceURL: URL,
        localeIdentifier: String,
        audioLevel: AudioLevelReport
    ) -> Transcript {
        let maxVolumeText = audioLevel.maxVolumeDB.map { String(format: "%.1f dB", $0) } ?? "unknown"
        return Transcript(
            sourceName: sourceURL.lastPathComponent,
            localeIdentifier: localeIdentifier,
            fullText: "No audible speech detected. Maximum audio level: \(maxVolumeText).",
            segments: []
        )
    }

    private static func normalizedModelIdentifier(_ identifier: String) -> String {
        WhisperModelPreset.normalizedIdentifier(identifier)
    }

    private static var automaticChunkSeconds: Int {
        if let rawValue = ProcessInfo.processInfo.environment["TARE_CHUNK_SECONDS"],
           let value = Int(rawValue) {
            return clampedChunkSeconds(value)
        }
        return 600
    }

    private static var automaticWorkerCount: Int {
        if let rawValue = ProcessInfo.processInfo.environment["TARE_CHUNK_WORKERS"],
           let value = Int(rawValue) {
            return clampedWorkerCount(value)
        }
        return 1
    }

    private static func clampedWorkerCount(_ value: Int) -> Int {
        if ProcessInfo.processInfo.environment["TARE_ALLOW_PARALLEL_MLX"] != "1" {
            return 1
        }
        return min(max(value, 1), min(2, max(1, ProcessInfo.processInfo.activeProcessorCount / 2)))
    }

    private static func clampedChunkSeconds(_ value: Int) -> Int {
        if value <= 0 {
            return 0
        }
        return min(max(value, 60), 900)
    }

    private static func isMKV(_ url: URL) -> Bool {
        url.pathExtension.caseInsensitiveCompare("mkv") == .orderedSame
    }

    private static func savedScanRoots(fileManager: FileManager = .default) -> [URL] {
        if let paths = UserDefaults.standard.array(forKey: scanRootsDefaultsKey) as? [String],
           !paths.isEmpty {
            return uniqueScanRoots(paths.map { URL(fileURLWithPath: $0, isDirectory: true) })
        }

        return defaultScanRoots(fileManager: fileManager)
    }

    private static func defaultScanRoots(fileManager: FileManager = .default) -> [URL] {
        let directoryKinds: [FileManager.SearchPathDirectory] = [
            .downloadsDirectory,
            .moviesDirectory,
            .desktopDirectory,
            .documentDirectory
        ]

        let roots = directoryKinds.compactMap {
            fileManager.urls(for: $0, in: .userDomainMask).first
        }
        return uniqueScanRoots(roots)
    }

    private static func scanRoots(from rawValue: String) -> [URL] {
        let paths = rawValue
            .split { character in
                character == "\n" || character == ":"
            }
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let roots = paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
        return uniqueScanRoots(roots)
    }

    private static func saveScanRoots(_ roots: [URL]) {
        let paths = uniqueScanRoots(roots).map(\.path)
        UserDefaults.standard.set(paths, forKey: scanRootsDefaultsKey)
    }

    private static func uniqueScanRoots(_ roots: [URL]) -> [URL] {
        var seen = Set<String>()
        return roots
            .map(\.standardizedFileURL)
            .filter { url in
                seen.insert(url.path).inserted
            }
    }

    private static func saveSelectedFormats(_ formats: Set<ExportFormat>) {
        let rawValues = ExportFormat.allCases
            .filter { formats.contains($0) }
            .map(\.rawValue)
        UserDefaults.standard.set(rawValues, forKey: selectedFormatsDefaultsKey)
        UserDefaults.standard.set(rawValues.joined(separator: ","), forKey: selectedFormatsCSVDefaultsKey)
    }

    private static func exportFormats(fromCSV rawValue: String) -> Set<ExportFormat> {
        exportFormats(
            fromRawValues: rawValue
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        )
    }

    private static func exportFormats(fromRawValues rawValues: [String]) -> Set<ExportFormat> {
        let formats = Set(rawValues.compactMap(ExportFormat.init(rawValue:)))
        guard !formats.isEmpty else {
            return [.text]
        }
        let textFormats = formats.intersection(textSidecarFormats)
        return textFormats.isEmpty ? [.text] : textFormats
    }

    private static let textSidecarFormats: Set<ExportFormat> = [.text, .timestampedText]
}
