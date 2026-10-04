import AppKit
import Combine
import Foundation
import TranscriberCore
import UniformTypeIdentifiers

@MainActor
final class TranscriptionStore: ObservableObject {
    @Published var jobs: [TranscriptionJob] = []
    @Published var selectedJobID: TranscriptionJob.ID?
    @Published var isFileImporterPresented = false
    @Published var outputDirectory: URL {
        didSet {
            UserDefaults.standard.set(outputDirectory.path, forKey: Self.outputDirectoryDefaultsKey)
            // A previous failure described a folder the user has now replaced.
            if outputDirectoryError != nil {
                outputDirectoryError = Self.ensureDirectory(outputDirectory)
            }
        }
    }
    @Published var createBatchFolder: Bool {
        didSet {
            UserDefaults.standard.set(createBatchFolder, forKey: Self.createBatchFolderDefaultsKey)
        }
    }
    @Published var smartTranscriptNamingEnabled: Bool {
        didSet {
            UserDefaults.standard.set(smartTranscriptNamingEnabled, forKey: Self.smartTranscriptNamingDefaultsKey)
        }
    }
    @Published var attachCaptionedVideoToSource: Bool {
        didSet {
            UserDefaults.standard.set(attachCaptionedVideoToSource, forKey: Self.attachCaptionedVideoToSourceDefaultsKey)
        }
    }
    /// Whether finished files offer an in-app transcript view. Off, a batch just
    /// runs and then says where everything was saved.
    @Published var showTranscriptPreview: Bool = UserDefaults.standard.object(forKey: "showTranscriptPreview") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showTranscriptPreview, forKey: "showTranscriptPreview")
        }
    }
    /// Which page the single window is showing.
    @Published var page: AppPage = .transcribe
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
            // An empty string normalizes to a real preset, which snapped the
            // field back mid-edit and made a custom ID impossible to type from
            // scratch. Leave it blank; Start normalizes before use.
            guard !modelIdentifier.isEmpty else { return }
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
    /// The last saved key Gemini rejected during a cloud job, by label only.
    @Published private(set) var geminiCredentialFailureMessage: String?
    @Published var selectedFormats: Set<ExportFormat> = [.text] {
        didSet {
            Self.saveSelectedFormats(selectedFormats)
        }
    }
    /// What a finished batch did, so the status line can report the result
    /// instead of resetting to an undifferentiated "Ready".
    enum BatchOutcome: Equatable {
        case running
        case finished(completed: Int, failed: Int, cancelled: Int, notice: String?)

        var statusMessage: String {
            switch self {
            case .running:
                return "Working…"
            case let .finished(completed, failed, cancelled, notice):
                var summary: String
                if failed == 0 && cancelled == 0 {
                    summary = completed == 1 ? "Completed 1 job" : "Completed \(completed) jobs"
                } else {
                    var parts: [String] = []
                    if completed > 0 { parts.append("\(completed) completed") }
                    if failed > 0 { parts.append("\(failed) failed") }
                    if cancelled > 0 { parts.append("\(cancelled) cancelled") }
                    summary = parts.joined(separator: ", ")
                }
                // A key that had to be failed over to is worth keeping, since
                // the per-chunk phase string overwrites it moments later.
                guard let notice, !notice.isEmpty else { return summary }
                return "\(summary) · \(notice)"
            }
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
    /// True once the first inventory of the local model cache has finished, so an
    /// empty list can be told apart from one that has not loaded yet.
    @Published private(set) var didFinishModelScan = false
    @Published var modelOperation: String?
    @Published var modelOperationModelID: String?
    @Published var modelErrorMessage: String?
    /// Raised by pressing Start on the Transcribe tab. It is rendered inline
    /// there rather than in the Models tab alert, so the reason a batch refused
    /// to start is visible where the user pressed the button.
    @Published var modelSelectionErrorMessage: String?
    @Published var cloudErrorMessage: String?
    /// Set when the configured output root cannot be created or written.
    @Published private(set) var outputDirectoryError: String?
    @Published private(set) var freeLLMAPIKeyConfigured = false
    @Published private(set) var freeLLMAPIStatusMessage = "Optional: use the local FreeLLMAPI app for compact transcript names."

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
    private let freeLLMAPIKeyStore = FreeLLMAPIKeyStore()
    private let transcriptNamingService = TranscriptNamingService()
    private var runTask: Task<Void, Never>?
    private var modelPreparationTask: Task<Void, Never>?
    private var batchOutcome: BatchOutcome?
    private var batchJobIDs: Set<TranscriptionJob.ID> = []
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
    private static let smartTranscriptNamingDefaultsKey = "smartTranscriptNaming"
    private static let freeLLMAPIKeyConfiguredDefaultsKey = "freeLLMAPIKeyConfigured"
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
            if let failure = Self.ensureDirectory(outputRoot) {
                outputDirectoryError = failure
            }
        } else if let savedPath = UserDefaults.standard.string(forKey: Self.outputDirectoryDefaultsKey),
                  !savedPath.isEmpty {
            let outputRoot = URL(fileURLWithPath: savedPath, isDirectory: true)
            outputDirectory = outputRoot
            if let failure = Self.ensureDirectory(outputRoot) {
                outputDirectoryError = failure
            }
        } else {
            let outputRoot = OutputFolderPlanner.defaultRootDirectory()
            outputDirectory = outputRoot
            if let failure = Self.ensureDirectory(outputRoot) {
                outputDirectoryError = failure
            }
        }

        if let rawCreateBatchFolder = environment["TARE_CREATE_BATCH_FOLDER"] {
            createBatchFolder = rawCreateBatchFolder != "0"
        } else if UserDefaults.standard.object(forKey: Self.createBatchFolderDefaultsKey) != nil {
            createBatchFolder = UserDefaults.standard.bool(forKey: Self.createBatchFolderDefaultsKey)
        } else {
            createBatchFolder = true
        }

        if let rawSmartNaming = environment["TARE_SMART_NAMING"] {
            smartTranscriptNamingEnabled = rawSmartNaming != "0"
        } else if UserDefaults.standard.object(forKey: Self.smartTranscriptNamingDefaultsKey) != nil {
            smartTranscriptNamingEnabled = UserDefaults.standard.bool(forKey: Self.smartTranscriptNamingDefaultsKey)
        } else {
            smartTranscriptNamingEnabled = true
        }

        freeLLMAPIKeyConfigured = UserDefaults.standard.bool(forKey: Self.freeLLMAPIKeyConfiguredDefaultsKey)

        if let rawAttach = environment["TARE_ATTACH_CAPTIONED_VIDEO"] {
            attachCaptionedVideoToSource = rawAttach != "0"
        } else if UserDefaults.standard.object(forKey: Self.attachCaptionedVideoToSourceDefaultsKey) != nil {
            attachCaptionedVideoToSource = UserDefaults.standard.bool(forKey: Self.attachCaptionedVideoToSourceDefaultsKey)
        } else {
            attachCaptionedVideoToSource = true
        }

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

    /// The job the user is inspecting.
    ///
    /// Returns nil when nothing is selected. It used to fall back to the first
    /// job, so the detail pane could show a file the sidebar did not highlight
    /// and that Remove was therefore disabled for.
    var selectedJob: TranscriptionJob? {
        guard let selectedJobID else { return nil }
        return jobs.first { $0.id == selectedJobID }
    }

    /// The job the running batch is working on right now.
    ///
    /// Deliberately separate from `selectedJobID`, which is the user's
    /// inspection target: the batch used to overwrite it, so clicking another
    /// job mid-run made the detail pane contradict what was really happening.
    @Published private(set) var activeJobID: TranscriptionJob.ID?

    var activeJob: TranscriptionJob? {
        guard let activeJobID else { return nil }
        return jobs.first { $0.id == activeJobID }
    }

    var mkvJobCount: Int {
        jobs.filter { Self.isMKV($0.sourceURL) }.count
    }

    /// The queued MKV files that organizing would rename and move on disk.
    var mkvSourceURLs: [URL] {
        jobs.filter { Self.isMKV($0.sourceURL) }.map(\.sourceURL)
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
            && isUsableFormatSelection(selectedFormats)
            && jobs.contains { $0.status == .queued || $0.status == .failed || $0.status == .cancelled }
    }

    /// Which jobs the queue shows. A forty-file batch is unreadable without one.
    enum QueueFilter: String, CaseIterable, Identifiable {
        case all
        case active
        case queued
        case completed
        case failed

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .all: return "All"
            case .active: return "Active"
            case .queued: return "Queued"
            case .completed: return "Done"
            case .failed: return "Failed"
            }
        }

        func matches(_ job: TranscriptionJob) -> Bool {
            switch self {
            case .all:
                return true
            case .active:
                // Work that has not finished yet, which is every queued
                // file as well as the one running.
                return !job.status.isTerminal
            case .queued:
                return job.status == .queued
            case .completed:
                return job.status == .completed
            case .failed:
                return job.status == .failed || job.status == .cancelled
            }
        }
    }

    @Published var queueFilter: QueueFilter = .all {
        didSet {
            guard queueFilter != oldValue else { return }
            reconcileSelectionWithFilter()
        }
    }

    /// Keeps the selection pointing at a row the user can actually see.
    ///
    /// The table is filtered but the selection is not, so switching filter could
    /// leave a job selected that is no longer on screen — and `Remove` is bound
    /// to the selection, which would let the user delete an invisible job.
    private func reconcileSelectionWithFilter() {
        guard let selectedJobID else { return }
        guard !visibleJobs.contains(where: { $0.id == selectedJobID }) else { return }
        self.selectedJobID = visibleJobs.first?.id
    }

    /// Runs after any status change, since a job leaving the current filter is
    /// just as able to strand the selection as changing the filter is.
    private func reconcileSelectionAfterStatusChange() {
        guard selectedJobID != nil else { return }
        reconcileSelectionWithFilter()
    }

    func count(for filter: QueueFilter) -> Int {
        jobs.filter { filter.matches($0) }.count
    }

    var visibleJobs: [TranscriptionJob] {
        jobs.filter { queueFilter.matches($0) }
    }

    var completedCount: Int {
        jobs.filter { $0.status == .completed }.count
    }

    /// Whole-batch progress, so the status strip has something honest to show.
    /// Whole-batch progress, so the status strip has something honest to show.
    var batchProgress: Double {
        guard batchTotalCount > 0 else { return 0 }
        return min(1, Double(batchCompletedCount) / Double(batchTotalCount))
    }

    /// "3 of 12" for the running batch, empty when nothing is running.
    var batchCounterText: String? {
        guard batchTotalCount > 0 else { return nil }
        return "\(batchCompletedCount) of \(batchTotalCount)"
    }

    private var batchTotalCount: Int { batchJobIDs.count }

    private var batchCompletedCount: Int {
        jobs.filter { batchJobIDs.contains($0.id) && $0.status.isTerminal }.count
    }

    func presentFilePicker() {
        isFileImporterPresented = true
    }

    func handleFileImporterResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            addFiles(urls)
        case .failure(let error):
            guard (error as? CocoaError)?.code != .userCancelled else { return }
            statusMessage = "Could not add files: \(error.localizedDescription)"
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

        presentOpenPanel(panel) { [weak self] panel in
            guard let url = panel.url else { return }
            guard FileManager.default.isWritableFile(atPath: url.path) else {
                self?.statusMessage = "\(url.lastPathComponent) is not writable. Choose another output folder."
                return
            }
            self?.outputDirectory = url
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

        presentOpenPanel(panel) { [weak self] panel in
            guard let url = panel.url else { return }
            self?.libraryDirectory = url
        }
    }

    func presentScanRootPicker() {
        let panel = NSOpenPanel()
        panel.title = "Add MKV Search Folder"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false

        presentOpenPanel(panel) { [weak self] panel in
            guard let self else { return }
            let existing = Set(self.scanRoots.map { $0.standardizedFileURL.path })
            let additions = panel.urls
                .map(\.standardizedFileURL)
                .filter { !existing.contains($0.path) }
            self.scanRoots.append(contentsOf: additions)
        }
    }

    private func presentOpenPanel(_ panel: NSOpenPanel, onSelection: @escaping (NSOpenPanel) -> Void) {
        let completionHandler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            onSelection(panel)
        }

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: completionHandler)
        } else {
            panel.begin(completionHandler: completionHandler)
        }
    }

    func removeScanRoot(_ url: URL) {
        let target = url.standardizedFileURL.path
        scanRoots.removeAll { $0.standardizedFileURL.path == target }
    }

    func addFiles(_ urls: [URL]) {
        let existing = Set(jobs.map { $0.sourceURL.standardizedFileURL })
        let candidates = SupportedMedia.preferredMacCompatibleURLs(from: urls)
        let supported = candidates.filter { !existing.contains($0) }

        guard !supported.isEmpty else {
            statusMessage = candidates.isEmpty
                ? "No supported audio or video in that selection"
                : "Already in the queue"
            return
        }

        let newJobs = supported.map { TranscriptionJob(sourceURL: $0) }
        jobs.append(contentsOf: newJobs)
        selectedJobID = selectedJobID ?? newJobs.first?.id
        let addedCount = newJobs.count

        var notes: [String] = ["\(addedCount) file\(addedCount == 1 ? "" : "s") added"]
        if candidates.count < Set(urls.map(\.standardizedFileURL)).count {
            notes.append("unsupported skipped")
        }
        if isRunning {
            notes.append("will wait for the next Start")
        }
        let addMessage = notes.joined(separator: "; ")
        statusMessage = addMessage
        resolveLinkedTranscripts(for: newJobs.map(\.id), addedCount: addedCount, pendingMessage: addMessage)
    }

    /// Discovers existing transcript links off the main actor.
    ///
    /// The lookup reads and decodes JSON beside each source, so doing it inline
    /// froze the window for every file added.
    private func resolveLinkedTranscripts(
        for ids: [TranscriptionJob.ID],
        addedCount: Int,
        pendingMessage: String
    ) {
        let sourcesByID = Dictionary(
            uniqueKeysWithValues: ids.compactMap { id in
                jobs.first(where: { $0.id == id }).map { (id, $0.sourceURL) }
            }
        )
        guard !sourcesByID.isEmpty else { return }

        Task { [weak self] in
            let sources = Array(sourcesByID.values)
            let metadataBySource = await Task.detached(priority: .userInitiated) {
                TranscriptLinker().existingLinks(for: sources)
            }.value

            let linkedByID = sourcesByID.reduce(into: [TranscriptionJob.ID: URL]()) { result, entry in
                if let transcriptURL = metadataBySource[entry.value]?.primaryTranscriptURL {
                    result[entry.key] = transcriptURL
                }
            }

            guard let self, !linkedByID.isEmpty else { return }
            for (id, transcriptURL) in linkedByID {
                self.updateJob(id) { $0.linkedTranscriptURL = transcriptURL }
            }
            // A caller such as the MKV scan reports its own result immediately
            // after adding files, so only claim the status line if it is still ours.
            guard self.statusMessage == pendingMessage else { return }
            let linkedCount = linkedByID.count
            self.statusMessage = "\(addedCount) file\(addedCount == 1 ? "" : "s") added; \(linkedCount) linked transcript\(linkedCount == 1 ? "" : "s") found"
        }
    }

    /// Collects every dropped file and imports them in one pass.
    ///
    /// Adding them one at a time reordered the queue by load-completion order
    /// and re-ran the transcript-link lookup per file.
    func addDroppedProviders(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else {
            statusMessage = "Only audio and video files can be added"
            return false
        }

        let group = DispatchGroup()
        // A reference box rather than a captured `var`, which is a Swift 6
        // concurrency error and is published safely by the group's own edge.
        let collected = LockedURLBox()

        for provider in fileProviders {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }

                let url: URL?
                if let itemURL = item as? URL {
                    url = itemURL
                } else if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = nil
                }

                guard let url else { return }
                collected.append(url)
            }
        }

        group.notify(queue: .main) { [weak self] in
            // Hop through a MainActor task rather than calling a @MainActor
            // method directly from a non-isolated block.
            let dropped = collected.urls
            Task { @MainActor in
                self?.addFiles(dropped)
            }
        }

        return true
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

    /// Set by any caller that wants to organize; the confirmation dialog is
    /// presented once at the top level so no entry point can skip it.
    @Published var isConfirmingOrganize = false

    func requestOrganizeConfirmation() {
        isConfirmingOrganize = true
    }

    func confirmOrganize() async {
        isConfirmingOrganize = false
        await cleanAndOrganizeMKVs()
    }

    func cleanAndOrganizeMKVs() async {
        await cleanAndOrganizeMKVs(startAfter: false)
    }

    func cleanOrganizeAndStartMKVs() async {
        await cleanAndOrganizeMKVs(startAfter: true)
    }

    func removeSelectedJob() {
        guard let selectedJobID else { return }
        removeJob(selectedJobID)
    }

    func removeJob(_ id: TranscriptionJob.ID) {
        let previousIndex = jobs.firstIndex { $0.id == id }
        jobs.removeAll { $0.id == id }

        guard selectedJobID == id else { return }
        // Keep the selection where it was in the list rather than jumping to the
        // top, which is disorienting in a long queue.
        if let previousIndex, previousIndex < jobs.count {
            self.selectedJobID = jobs[previousIndex].id
        } else {
            self.selectedJobID = jobs.first?.id
        }
    }

    func clearCompleted() {
        let previousIndex = selectedJobID.flatMap { id in jobs.firstIndex { $0.id == id } }
        jobs.removeAll { $0.status == .completed }

        guard let selectedJobID else { return }
        if jobs.contains(where: { $0.id == selectedJobID }) { return }
        if let previousIndex, previousIndex < jobs.count {
            self.selectedJobID = jobs[previousIndex].id
        } else {
            self.selectedJobID = jobs.first?.id
        }
    }

    func retrySelectedJob() {
        guard let id = selectedJobID else { return }
        requeue(id)
    }

    /// Returns a finished job to the queue.
    ///
    /// A running batch already snapshotted its work list, so the job cannot
    /// join the batch in flight. Say so rather than leaving it looking stalled.
    func requeue(_ id: TranscriptionJob.ID) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        guard job.status == .failed || job.status == .cancelled else { return }

        updateJob(id) { job in
            job.status = .queued
            job.progress = 0
            job.chunkProgress = nil
            job.errorMessage = nil
            job.outputURLs = []
            job.transcript = nil
            job.startedAt = nil
            job.completedAt = nil
        }

        statusMessage = isRunning
            ? "\(job.displayName) requeued — it will run when you press Start again"
            : "\(job.displayName) requeued — press Start to run"
    }

    func revealOutputDirectory() {
        let directory = currentOutputDirectory
        if let failure = Self.ensureDirectory(directory) {
            outputDirectoryError = failure
            statusMessage = "Could not open the output folder"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
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
            modelSelectionErrorMessage = nil
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
                await reportCloudPlan()
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
            modelSelectionErrorMessage = ModelManagerError.pythonMissing.localizedDescription
            return
        }

        do {
            let status = try await modelManager.status(for: modelIdentifier)
            modelStatuses[modelIdentifier] = status

            guard status.isUsable else {
                statusMessage = "\(preset.displayName) is not ready on this Mac"
                modelSelectionErrorMessage = status.issueMessage ?? "The cached model cannot run on this Mac. Choose another available model."
                return
            }
        } catch is CancellationError {
            statusMessage = "Model check cancelled"
            return
        } catch {
            statusMessage = "Could not verify \(preset.displayName)"
            modelSelectionErrorMessage = error.localizedDescription
            return
        }

        startBatch(effectiveModelIdentifier: modelIdentifier)
    }

    /// Measures the queued sources before a cloud batch starts.
    ///
    /// Duration used to be measured only after a full audio extraction, so for a
    /// long recording the user watched a spinner with no idea of the chunk count
    /// or size until uploads were already under way. This is advisory: the
    /// authoritative checks still run in the service, because a container can
    /// report no duration while the extracted audio has one.
    private func reportCloudPlan() async {
        let sourceURLs = jobs
            .filter { $0.status == .queued || $0.status == .failed || $0.status == .cancelled }
            .map(\.sourceURL)
        guard let audioExtractor, let firstSource = sourceURLs.first else { return }

        do {
            let duration = try await audioExtractor.duration(of: firstSource)
            let plan = GeminiAudioChunkPlanner.plan(
                duration: duration,
                options: geminiTranscriptionOptions
            )
            let fileCount = max(sourceURLs.count, 1)
            statusMessage = sourceURLs.count == 1
                ? "Cloud plan: \(plan.summaryDescription)"
                : "Cloud plan for \(fileCount) files, first is \(Self.formatDuration(duration)) · \(plan.summaryDescription)"
        } catch {
            // Advisory only. A source whose duration cannot be read is still
            // handled by the service, which fails with an actionable message.
            statusMessage = "Starting cloud batch; Tare will measure each file as it runs"
        }
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(total)s"
    }

    private func startBatch(
        effectiveModelIdentifier: String,
        geminiCredentials: [GeminiAPIKeyCredential]? = nil
    ) {

        // Cleared per batch as well as per job: the notice is rendered on the
        // Cloud tab for as long as it is set, and a batch that never reads its
        // credentials would otherwise leave the last one on screen.
        geminiCredentialFailureMessage = nil

        // Checked before anything is created and before isRunning is set: a
        // refusal after that point would leave the flag stuck, because
        // runBatch's defer is the only thing that clears it.
        guard isUsableFormatSelection(selectedFormats) else {
            statusMessage = "Choose at least one transcript file format"
            return
        }

        let queuedSourceURLs = jobs
            .filter { $0.status == .queued || $0.status == .failed || $0.status == .cancelled }
            .map(\.sourceURL)

        let exportDirectory: URL
        // Tracked separately so the failure path can name the folder that
        // actually failed rather than defaulting to the root.
        var attemptedDirectory = outputDirectory
        do {
            if createBatchFolder {
                exportDirectory = try OutputFolderPlanner.createBatchDirectory(
                    rootDirectory: outputDirectory,
                    sourceURLs: queuedSourceURLs
                )
            } else {
                exportDirectory = outputDirectory
            }
            attemptedDirectory = exportDirectory
            try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        } catch {
            statusMessage = "Could not create output folder"
            outputDirectoryError = Self.ensureDirectory(attemptedDirectory)
                ?? "Tare could not prepare \(attemptedDirectory.path): \(error.localizedDescription)"
            return
        }

        outputDirectoryError = nil

        lastOutputDirectory = exportDirectory
        isRunning = true
        statusMessage = "Saving to \(exportDirectory.lastPathComponent)"

        let requestedFormats = selectedFormats.intersection(ExportFormat.sidecarFormats)

        let configuration = TranscriptionConfiguration(
            outputDirectory: exportDirectory,
            localeIdentifier: localeIdentifier,
            modelIdentifier: effectiveModelIdentifier,
            formats: requestedFormats,
            attachCaptionedVideoToSource: attachCaptionedVideoToSource,
            chunkSeconds: WhisperModelPreset.isGeminiTranscribe(effectiveModelIdentifier) || WhisperModelPreset.usesLongFormInference(effectiveModelIdentifier)
                ? 0
                : Self.automaticChunkSeconds,
            chunkWorkerCount: Self.automaticWorkerCount,
            geminiOptions: geminiTranscriptionOptions,
            smartNamingEnabled: smartTranscriptNamingEnabled
        )

        runTask = Task { [weak self] in
            await self?.runBatch(
                configuration: configuration,
                geminiCredentials: geminiCredentials
            )
        }
    }

    /// Creates a directory, returning a user-facing reason when it cannot be
    /// created. A launch-time failure here used to surface much later as a
    /// four-word message at Start, with the path shown in Settings as if valid.
    private static func ensureDirectory(_ url: URL) -> String? {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return nil
        } catch {
            return "Tare could not prepare \(url.path): \(error.localizedDescription)"
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

    func saveFreeLLMAPIKey(_ rawKey: String) {
        let keyStore = freeLLMAPIKeyStore
        Task { @MainActor [weak self] in
            do {
                try await Self.performKeychainWork {
                    try keyStore.save(rawKey)
                }
                guard let self else { return }
                self.freeLLMAPIKeyConfigured = true
                UserDefaults.standard.set(true, forKey: Self.freeLLMAPIKeyConfiguredDefaultsKey)
                self.freeLLMAPIStatusMessage = "FreeLLMAPI key saved in macOS Keychain. Tare will call it only while an export is running."
            } catch {
                self?.freeLLMAPIStatusMessage = error.localizedDescription
            }
        }
    }

    func removeFreeLLMAPIKey() {
        let keyStore = freeLLMAPIKeyStore
        Task { @MainActor [weak self] in
            do {
                try await Self.performKeychainWork {
                    try keyStore.delete()
                }
                guard let self else { return }
                self.freeLLMAPIKeyConfigured = false
                UserDefaults.standard.set(false, forKey: Self.freeLLMAPIKeyConfiguredDefaultsKey)
                self.freeLLMAPIStatusMessage = "FreeLLMAPI naming disabled until a key is saved."
            } catch {
                self?.freeLLMAPIStatusMessage = error.localizedDescription
            }
        }
    }

    func refreshFreeLLMAPIStatus() async {
        // Do not touch the Keychain while the Settings view or app is opening.
        // The non-secret preference is enough for UI state; the secret is read
        // once, off the main actor, only when a batch actually starts.
        freeLLMAPIKeyConfigured = UserDefaults.standard.bool(forKey: Self.freeLLMAPIKeyConfiguredDefaultsKey)
        if freeLLMAPIKeyConfigured {
            freeLLMAPIStatusMessage = "Ready for on-demand compact naming. FreeLLMAPI must already be open; Tare never starts a server."
        } else {
            freeLLMAPIStatusMessage = "Optional: save a FreeLLMAPI unified key to name transcripts from their contents."
        }
    }

    func openFreeLLMAPI() {
        let appURL = URL(fileURLWithPath: "/Applications/FreeLLMAPI.app")
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            freeLLMAPIStatusMessage = "FreeLLMAPI.app was not found in /Applications."
            return
        }
        NSWorkspace.shared.open(appURL)
        freeLLMAPIStatusMessage = "FreeLLMAPI opened. Tare will use it only during the next export."
    }

    private func readFreeLLMAPIKey() async -> String? {
        if let environmentKey = ProcessInfo.processInfo.environment["TARE_FREELLM_API_KEY"],
           !environmentKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return environmentKey
        }

        let keyStore = freeLLMAPIKeyStore
        return try? await Self.performKeychainWork {
            try keyStore.load()
        }
    }

    private static func performKeychainWork<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await Task.detached(priority: .userInitiated, operation: operation).value
    }

    /// Every saved key, enabled or not.
    var geminiAPIKeyCount: Int {
        geminiAPIKeyRecords.count
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

    /// The preset the user actually selected.
    func isActiveModel(_ preset: WhisperModelPreset) -> Bool {
        modelIdentifier == preset.id
    }

    /// Every preset that must stay on disk for the current selection to run.
    ///
    /// An English language setting resolves the multilingual Whisper base, small
    /// and tiny models to their `.en` counterparts, so a second model becomes
    /// load-bearing even though the user never picked it. It is protected from
    /// removal, but it is not the selection.
    func isRequiredModel(_ preset: WhisperModelPreset) -> Bool {
        if isActiveModel(preset) { return true }
        let languageCode = WhisperTranscriptionService.languageCode(from: localeIdentifier)
        let effectiveIdentifier = WhisperModelPreset.optimizedIdentifier(
            modelIdentifier,
            languageCode: languageCode
        )
        return effectiveIdentifier == preset.id
    }

    func selectModel(_ preset: WhisperModelPreset) {
        modelIdentifier = preset.id
        statusMessage = "Selected \(preset.displayName)"
    }

    func refreshModelStatuses() async {
        // A second concurrent inventory would race the first and could publish a
        // stale snapshot over a download that finished in the meantime.
        guard !isRefreshingModels else { return }
        guard let modelManager else {
            modelErrorMessage = ModelManagerError.pythonMissing.localizedDescription
            return
        }

        isRefreshingModels = true
        defer {
            isRefreshingModels = false
            didFinishModelScan = true
        }

        do {
            let knownModelIDs = Set(WhisperModelPreset.local.map(\.id))
            let inventory = try await modelManager.localModels()
            let localStatuses = inventory
                .filter { knownModelIDs.contains($0.modelIdentifier) && $0.isAvailable }

            // A status that omitted isAvailable or sizeBytes now decodes to
            // unavailable, so an out-of-date model script looks like an empty
            // cache. Say so instead of reporting nothing to download.
            if localStatuses.isEmpty,
               inventory.contains(where: { knownModelIDs.contains($0.modelIdentifier) }) {
                modelErrorMessage = "Tare's model script did not report a usable status. It may be older than this build; reinstall the backend with script/setup_transcription_backend.sh."
                return
            }

            // Merge rather than replace: an entry this scan did not observe may
            // already reflect a completed download or removal.
            var merged = modelStatuses
            for status in localStatuses {
                merged[status.modelIdentifier] = status
            }
            let scannedIDs = Set(localStatuses.map(\.modelIdentifier))
            for identifier in modelStatuses.keys
            where !scannedIDs.contains(identifier) && identifier != modelOperationModelID {
                merged.removeValue(forKey: identifier)
            }
            modelStatuses = merged

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

    func removeModel(_ preset: WhisperModelPreset) async {
        guard !isRequiredModel(preset) else {
            modelErrorMessage = "Tare cannot remove \(preset.id == modelIdentifier ? "the active model" : "a model the current language setting needs"). Select another model first."
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
        // Set here as well as per job, so an early return — a credential read
        // that throws, say — cannot leave the previous batch's notice showing.
        geminiCredentialFailureMessage = nil

        defer {
            isRunning = false
            runTask = nil
            activeJobID = nil
            if batchOutcome == .running {
                // Count only what this batch ran, so a queue that already held
                // failures does not get reported as this run's outcome.
                let ran = jobs.filter { batchJobIDs.contains($0.id) }
                batchOutcome = .finished(
                    completed: ran.filter { $0.status == .completed }.count,
                    failed: ran.filter { $0.status == .failed }.count,
                    cancelled: ran.filter { $0.status == .cancelled }.count,
                    notice: geminiCredentialFailureMessage
                )
            }
            batchJobIDs = []
            if let outcome = batchOutcome {
                batchOutcome = nil
                statusMessage = outcome.statusMessage
            }
        }

        let jobIDs = jobs
            .filter { $0.status == .queued || $0.status == .failed || $0.status == .cancelled }
            .map(\.id)
        batchJobIDs = Set(jobIDs)
        batchOutcome = .running

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
                        job.chunkProgress = nil
                        job.errorMessage = GeminiTranscriptionService.redactingCredentialsInProviderText(error.localizedDescription)
                        job.completedAt = Date()
                    }
                }
                return
            }
        } else {
            batchGeminiCredentials = nil
        }

        let namingAPIKey = configuration.smartNamingEnabled ? await readFreeLLMAPIKey() : nil


        for (index, id) in jobIDs.enumerated() {
            if Task.isCancelled {
                markQueuedJobsCancelled(in: jobIDs)
                return
            }

            do {
                updateJob(id) { job in
                    job.status = .extractingAudio
                    job.progress = 0.08
                    job.chunkProgress = nil
                    job.errorMessage = nil
                    job.outputURLs = []
                    job.transcript = nil
                    job.startedAt = Date()
                    job.completedAt = nil
                }

                guard let sourceURL = jobs.first(where: { $0.id == id })?.sourceURL else {
                    continue
                }

                let jobName = sourceURL.deletingPathExtension().lastPathComponent
                activeJobID = id
                geminiCredentialFailureMessage = nil
                statusMessage = "[\(index + 1) of \(jobIDs.count)] \(jobName) — Extracting audio"

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
                        configuration: configuration,
                        namingAPIKey: namingAPIKey
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
                    job.chunkProgress = nil
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
                                if let failure = progress.credentialFailure {
                                    self.geminiCredentialFailureMessage =
                                        "\(failure.label) failed: \(failure.reason)"
                                }
                                self.statusMessage = progress.phase
                                self.updateJob(id) { job in
                                    let fraction = Double(progress.completedChunks) / Double(max(progress.totalChunks, 1))
                                    job.progress = min(0.86, 0.2 + fraction * 0.66)
                                    job.chunkProgress = ChunkProgress(
                                        completed: progress.completedChunks,
                                        total: progress.totalChunks
                                    )
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
                    statusMessage = "[\(index + 1) of \(jobIDs.count)] \(jobName) — Transcribing"
                    transcript = try await whisperService.transcribe(
                        audioURL: audioURL,
                        sourceName: sourceURL.lastPathComponent,
                        localeIdentifier: configuration.localeIdentifier,
                        modelIdentifier: configuration.modelIdentifier,
                        chunkSeconds: configuration.chunkSeconds,
                        chunkWorkerCount: configuration.chunkWorkerCount,
                        wordTimestamps: configuration.requiresWordTimestamps,
                        progress: { [weak self] update in
                            Task { @MainActor [weak self] in
                                guard let self else { return }
                                self.statusMessage = "[\(index + 1) of \(jobIDs.count)] \(jobName) — \(update.phase)"
                                guard update.totalChunks > 0 else { return }
                                self.updateJob(id) { job in
                                    job.progress = min(0.86, 0.2 + update.fraction * 0.66)
                                    job.chunkProgress = ChunkProgress(
                                        completed: update.completedChunks,
                                        total: update.totalChunks
                                    )
                                }
                            }
                        }
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
                    configuration: configuration,
                    namingAPIKey: namingAPIKey
                )

                updateJob(id) { job in
                    job.status = .completed
                    job.progress = 1
                    job.chunkProgress = nil
                    job.outputURLs = outputURLs
                    job.errorMessage = nil
                    job.completedAt = Date()
                }
            } catch is CancellationError {
                updateJob(id) { job in
                    job.status = .cancelled
                    job.chunkProgress = nil
                    job.errorMessage = "Cancelled"
                    job.completedAt = Date()
                }
                markQueuedJobsCancelled(in: jobIDs)
                return
            } catch {
                // Tearing down a subprocess surfaces as a non-zero exit rather
                // than a CancellationError, so a user-initiated cancel would
                // otherwise be reported as a failure with a raw exit code.
                guard !Task.isCancelled else {
                    updateJob(id) { job in
                        job.status = .cancelled
                        job.chunkProgress = nil
                        job.errorMessage = "Cancelled"
                        job.completedAt = Date()
                    }
                    markQueuedJobsCancelled(in: jobIDs)
                    return
                }
                updateJob(id) { job in
                    job.status = .failed
                    job.chunkProgress = nil
                    job.errorMessage = GeminiTranscriptionService.redactingCredentialsInProviderText(error.localizedDescription)
                    job.completedAt = Date()
                }
            }
        }
    }

    private func exportOutputs(
        _ transcript: Transcript,
        sourceURL: URL,
        configuration: TranscriptionConfiguration,
        namingAPIKey: String?
    ) async throws -> [URL] {
        try Task.checkCancellation()

        let fallbackNaming = TranscriptNamingService.deterministicSuggestion(for: sourceURL)
        let naming: TranscriptNamingSuggestion
        if configuration.smartNamingEnabled, let namingAPIKey,
           let suggestion = await transcriptNamingService.suggestName(
               for: transcript,
               sourceURL: sourceURL,
               apiKey: namingAPIKey
           ) {
            naming = suggestion
        } else {
            naming = fallbackNaming
        }

        let transcriptDirectory = try OutputFolderPlanner.createTranscriptDirectory(
            rootDirectory: configuration.outputDirectory,
            title: naming.folderName
        )
        let baseName = OutputFolderPlanner.sanitizedBaseName(naming.title)
        var outputURLs: [URL] = []
        let exportFormats = configuration.formats.intersection(ExportFormat.sidecarFormats)

        if !exportFormats.isEmpty {
            outputURLs.append(
                contentsOf: try await exporter.export(
                    transcript,
                    sourceURL: sourceURL,
                    to: transcriptDirectory,
                    formats: exportFormats,
                    baseName: baseName
                )
            )
        }

        let manifestURL = transcriptLinker.manifestURL(
            for: sourceURL,
            outputDirectory: transcriptDirectory,
            baseName: baseName
        )
        var linkMetadata = transcriptLinker.metadata(
            for: transcript,
            sourceURL: sourceURL,
            transcriptURLs: outputURLs,
            manifestURL: manifestURL,
            modelIdentifier: configuration.modelIdentifier,
            displayName: naming.title,
            folderName: naming.folderName,
            namingProvider: naming.provider,
            namingModelIdentifier: naming.modelIdentifier,
            namingStrategy: naming.strategy,
            transcriptDirectoryURL: transcriptDirectory
        )

        if configuration.attachCaptionedVideoToSource,
           SupportedMedia.videoExtensions.contains(sourceURL.pathExtension.lowercased()),
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

        linkMetadata.transcriptPaths = outputURLs.map { $0.standardizedFileURL.path }
        outputURLs.append(try transcriptLinker.write(linkMetadata))

        return outputURLs
    }

    private func updateJob(_ id: TranscriptionJob.ID, mutate: (inout TranscriptionJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else {
            return
        }

        mutate(&jobs[index])
        reconcileSelectionAfterStatusChange()
    }

    /// Marks the jobs this batch was going to run as cancelled.
    ///
    /// Only the snapshot is touched, so a file added after the batch started is
    /// left queued rather than reported as cancelled when it never ran.
    private func markQueuedJobsCancelled(in batchIDs: [TranscriptionJob.ID]) {
        let batchIDSet = Set(batchIDs)
        for id in jobs.filter({ !$0.status.isTerminal && batchIDSet.contains($0.id) }).map(\.id) {
            updateJob(id) { job in
                job.status = .cancelled
                job.chunkProgress = nil
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
        let sidecars = formats.intersection(ExportFormat.sidecarFormats)
        return sidecars.isEmpty ? [.text] : sidecars
    }
}

/// Thread-safe accumulator for URLs arriving from asynchronous item providers.
private final class LockedURLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    func append(_ url: URL) {
        lock.lock()
        storage.append(url)
        lock.unlock()
    }

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
