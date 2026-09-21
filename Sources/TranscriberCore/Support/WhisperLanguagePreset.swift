import Foundation

public struct WhisperLanguagePreset: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }

    public static let auto = WhisperLanguagePreset(id: "auto", displayName: "Auto Detect")

    public static let all: [WhisperLanguagePreset] = [
        .auto,
        WhisperLanguagePreset(id: "en", displayName: "English"),
        WhisperLanguagePreset(id: "es", displayName: "Spanish"),
        WhisperLanguagePreset(id: "fr", displayName: "French"),
        WhisperLanguagePreset(id: "de", displayName: "German"),
        WhisperLanguagePreset(id: "hi", displayName: "Hindi"),
        WhisperLanguagePreset(id: "zh", displayName: "Chinese"),
        WhisperLanguagePreset(id: "ja", displayName: "Japanese"),
        WhisperLanguagePreset(id: "ko", displayName: "Korean"),
        WhisperLanguagePreset(id: "pt", displayName: "Portuguese"),
        WhisperLanguagePreset(id: "ru", displayName: "Russian"),
        WhisperLanguagePreset(id: "ar", displayName: "Arabic")
    ]

    public static func preset(for identifier: String) -> WhisperLanguagePreset? {
        all.first { $0.id == identifier }
    }
}
