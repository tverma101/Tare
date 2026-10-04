import AppKit
import SwiftUI
import TranscriberCore

/// Plain-language descriptions of the transcription choices, shared by the main
/// window and Settings so both say the same thing.
enum ModelChoice {
    /// One short phrase that says what a model is for. The catalog `detail` lines
    /// describe how a model is built; this says why someone would pick it.
    static func tagline(for preset: WhisperModelPreset) -> String {
        switch preset.id {
        case WhisperModelPreset.parakeetV3.id:
            return "Fastest · recommended"
        case WhisperModelPreset.qwen3ASR6Bit.id:
            return "Compact · accurate"
        case WhisperModelPreset.voxtralMini8BitDense.id:
            return "Most accurate on 16 GB"
        case WhisperModelPreset.highestAccuracyMultilingual.id:
            return "Accurate · slower"
        case WhisperModelPreset.mossDiarize.id:
            return "Labels who is speaking"
        case WhisperModelPreset.gemini35Transcribe.id:
            return "Cloud · sends audio to Google"
        default:
            return preset.detail
        }
    }

    static func menuTitle(for preset: WhisperModelPreset) -> String {
        "\(preset.displayName) — \(tagline(for: preset))"
    }

    /// The text the closed model menu shows.
    @MainActor
    static func currentTitle(_ store: TranscriptionStore) -> String {
        guard let preset = WhisperModelPreset.preset(for: store.effectiveSelectedModelIdentifier) else {
            return store.modelIdentifier.isEmpty ? "Choose a model" : store.modelIdentifier
        }
        return preset.displayName
    }
}

/// A folder as a person names it: its own name, never its path.
enum FolderName {
    static func display(_ url: URL) -> String {
        let name = FileManager.default.displayName(atPath: url.path)
        return PastTranscriptScanner.folderDisplayName(name)
    }
}

/// A problem with the current setup, in words, with the place to fix it.
struct SetupIssue: Equatable {
    enum Severity { case error, warning, info }

    let severity: Severity
    let message: String
    let fixLabel: String?
    let fixTab: SettingsTab?
}

extension TranscriptionStore {
    /// True when no local model is installed and cloud is not selected: the one
    /// situation where the app cannot do anything until the user sets something up.
    var needsModelSetup: Bool {
        didFinishModelScan
            && !isRefreshingModels
            && installedModelPresets.isEmpty
            && !isUsingGeminiTranscription
    }

    var queuedJobCount: Int {
        jobs.filter { $0.status == .queued || $0.status == .failed || $0.status == .cancelled }.count
    }

    /// Why Start is unavailable, when the reason is something the user can fix
    /// right here. Nil when Start is enabled or when the queue simply has nothing
    /// left to do (the finished batch summary says that).
    var startBlockedReason: String? {
        guard !isRunning, !isPreparingModel, !jobs.isEmpty else { return nil }
        if isScanning || isOrganizing {
            return "Waiting for the library task to finish."
        }
        if !isUsableFormatSelection(selectedFormats) {
            return "Choose at least one transcript file under Output files."
        }
        return nil
    }

    /// The most important thing wrong with the current model and language choice.
    var setupIssue: SetupIssue? {
        if let error = modelSelectionErrorMessage {
            return SetupIssue(severity: .error, message: error, fixLabel: "Open Models", fixTab: .models)
        }

        guard let preset = WhisperModelPreset.preset(for: effectiveSelectedModelIdentifier) else {
            return nil
        }

        if preset.isCloud {
            if geminiUsableAPIKeyCount == 0 {
                return SetupIssue(
                    severity: .warning,
                    message: "Cloud transcription needs a Gemini API key.",
                    fixLabel: "Add a Key",
                    fixTab: .cloud
                )
            }
            return nil
        }

        if didFinishModelScan, !isRefreshingModels, modelStatus(for: preset)?.isUsable != true {
            return SetupIssue(
                severity: .warning,
                message: "\(preset.displayName) is not installed on this Mac.",
                fixLabel: "Choose a Model",
                fixTab: .models
            )
        }

        if !preset.isMultilingual {
            let code = WhisperTranscriptionService.languageCode(from: localeIdentifier)
            if code != "en" {
                return SetupIssue(
                    severity: .warning,
                    message: code == nil
                        ? "\(preset.displayName) only understands English, so Auto Detect is limited to English."
                        : "\(preset.displayName) only understands English.",
                    fixLabel: nil,
                    fixTab: nil
                )
            }
        }

        return nil
    }

    /// "Plain Transcript, SRT" or "4 file types".
    var outputFormatSummary: String {
        let chosen = ExportFormat.visibleManualFormats.filter { selectedFormats.contains($0) }
        switch chosen.count {
        case 0: return "None selected"
        case 1, 2: return chosen.map(\.displayName).joined(separator: ", ")
        default: return "\(chosen.count) file types"
        }
    }

    /// The folder transcripts go into, before a batch runs, by name. People
    /// recognise a folder by its name, not by where it sits on disk.
    var outputFolderName: String {
        FolderName.display(outputDirectory)
    }

    /// Where the last batch actually wrote its files.
    var lastBatchFolderName: String {
        FolderName.display(currentOutputDirectory)
    }
}

extension TranscriptionStore {
    var failedJobCount: Int {
        jobs.filter { $0.status == .failed }.count
    }

    /// True once a batch has run and nothing is left waiting.
    var hasFinishedBatch: Bool {
        !isRunning && !isPreparingModel && !jobs.isEmpty
            && queuedJobCount == 0 && jobs.contains { $0.status.isTerminal }
    }

    /// Opens a produced file in its default app.
    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func retryFailedJobs() {
        for job in jobs where job.status == .failed {
            requeue(job.id)
        }
    }
}
