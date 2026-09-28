import Foundation

public enum ExportFormat: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case text
    case timestampedText
    case srt
    case vtt
    case json
    case wordTimings
    case appleMusicLyrics
    case appleMusicTTML
    case captionedVideo

    public var id: String { rawValue }

    /// The sidecar files Tare offers as a checkbox.
    ///
    /// `captionedVideo` is excluded because it produces or replaces media rather
    /// than a sidecar file, and is governed by the separate
    /// "embed subtitles into video sources" setting.
    public static var visibleManualFormats: [ExportFormat] {
        [.text, .timestampedText, .srt, .vtt, .json, .wordTimings, .appleMusicLyrics, .appleMusicTTML]
    }

    /// Every format written as a file beside the transcript manifest.
    public static let sidecarFormats: Set<ExportFormat> = Set(visibleManualFormats)

    /// Formats whose output is meaningless without word-level alignment.
    public var needsWordTimestamps: Bool {
        requiresWordTimestamps
    }

    public var displayName: String {
        switch self {
        case .text:
            return "Plain Transcript"
        case .timestampedText:
            return "Timestamped Transcript"
        case .srt:
            return "SRT"
        case .vtt:
            return "VTT"
        case .json:
            return "JSON"
        case .wordTimings:
            return "Word Timings"
        case .appleMusicLyrics:
            return "Apple Music Lyrics"
        case .appleMusicTTML:
            return "Apple Music TTML"
        case .captionedVideo:
            return "Captioned Video"
        }
    }

    public var fileExtension: String {
        switch self {
        case .text, .timestampedText:
            return "txt"
        case .srt:
            return "srt"
        case .vtt:
            return "vtt"
        case .json:
            return "json"
        case .wordTimings:
            return "csv"
        case .appleMusicLyrics:
            return "txt"
        case .appleMusicTTML:
            return "ttml"
        case .captionedVideo:
            return "mp4"
        }
    }

    public var requiresWordTimestamps: Bool {
        switch self {
        case .wordTimings, .appleMusicTTML:
            return true
        case .text, .timestampedText, .srt, .vtt, .json, .appleMusicLyrics, .captionedVideo:
            return false
        }
    }
}

/// Keeps a batch from reporting success while writing nothing.
///
/// The Export panel lets every format be unchecked, which would otherwise leave
/// a completed job whose only artifact is the link manifest.
public func isUsableFormatSelection(_ formats: Set<ExportFormat>) -> Bool {
    !formats.intersection(ExportFormat.sidecarFormats).isEmpty
}

public struct TranscriptionConfiguration: Hashable {
    public var outputDirectory: URL
    public var localeIdentifier: String
    public var modelIdentifier: String
    public var formats: Set<ExportFormat>
    public var attachCaptionedVideoToSource: Bool
    public var chunkSeconds: Int
    public var chunkWorkerCount: Int
    public var geminiOptions: GeminiTranscriptionOptions
    public var smartNamingEnabled: Bool

    public init(
        outputDirectory: URL,
        localeIdentifier: String,
        modelIdentifier: String = WhisperModelPreset.fastMultilingual.id,
        formats: Set<ExportFormat> = [.text],
        attachCaptionedVideoToSource: Bool = true,
        chunkSeconds: Int = 600,
        chunkWorkerCount: Int = 1,
        geminiOptions: GeminiTranscriptionOptions = .default,
        smartNamingEnabled: Bool = true
    ) {
        self.outputDirectory = outputDirectory
        self.localeIdentifier = localeIdentifier
        self.modelIdentifier = modelIdentifier
        self.formats = formats
        self.attachCaptionedVideoToSource = attachCaptionedVideoToSource
        self.chunkSeconds = chunkSeconds
        self.chunkWorkerCount = chunkWorkerCount
        self.geminiOptions = geminiOptions
        self.smartNamingEnabled = smartNamingEnabled
    }

    public var requiresWordTimestamps: Bool {
        // Auto-embedded media needs timed transcript data even when text is the only manual export.
        true
    }
}
