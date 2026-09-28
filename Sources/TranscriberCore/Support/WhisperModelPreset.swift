import Foundation

public enum WhisperModelBackend: String, Hashable, Sendable {
    case mlxWhisper
    case mlxAudio
    case canary
    case mlxVoxtral
    case parakeet
    case moss
    case geminiTranscribe
}

public struct WhisperModelPreset: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let detail: String
    public let isMultilingual: Bool
    public let backend: WhisperModelBackend
    public let supportsWordTimestamps: Bool

    /// Published download size. `nil` means the catalog has no trustworthy
    /// number, so the UI stays silent rather than showing a placeholder.
    public let downloadSizeDescription: String?

    /// Set only when the preset cannot run on common Apple Silicon memory.
    public let memoryRequirementNote: String?

    public var isCloud: Bool {
        backend == .geminiTranscribe
    }

    public var isLocal: Bool {
        !isCloud
    }

    public init(
        id: String,
        displayName: String,
        detail: String,
        isMultilingual: Bool,
        backend: WhisperModelBackend = .mlxWhisper,
        supportsWordTimestamps: Bool = true,
        downloadSizeDescription: String? = nil,
        memoryRequirementNote: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.detail = detail
        self.isMultilingual = isMultilingual
        self.backend = backend
        self.supportsWordTimestamps = supportsWordTimestamps
        self.downloadSizeDescription = downloadSizeDescription
        self.memoryRequirementNote = memoryRequirementNote
    }

    public static let canaryQwen = WhisperModelPreset(
        id: "speechllms/canary-speechlm-mlx",
        displayName: "Canary-Qwen 2.5B BF16/full",
        detail: "NVIDIA Canary MLX port · full precision + Qwen3-1.7B base",
        isMultilingual: true,
        backend: .canary,
        supportsWordTimestamps: false,
        downloadSizeDescription: "9.2 GB total",
        memoryRequirementNote: "Needs ~13.3 GiB in one Metal buffer, so it cannot run on a 16 GB Mac."
    )

    public static let gemini35Transcribe = WhisperModelPreset(
        id: "gemini-3.5-transcribe",
        displayName: "Gemini 3.5 Transcribe · Cloud",
        detail: "Google Gemini API · automatic language detection · safe long-recording chunking",
        isMultilingual: true,
        backend: .geminiTranscribe,
        supportsWordTimestamps: true
    )

    public static let voxtralMini8BitDense = WhisperModelPreset(
        id: "MarkusKaemmerer/Voxtral-Mini-3B-2507-8bit-dense-encoder",
        displayName: "Voxtral Mini 3B 8-bit",
        detail: "~7.7 GB peak · 16 GB Mac ready",
        isMultilingual: true,
        backend: .mlxVoxtral,
        supportsWordTimestamps: false,
        downloadSizeDescription: "6.0 GB"
    )

    public static let voxtralSmall = WhisperModelPreset(
        id: "VincentGOURBIN/voxtral-small-4bit-mixed",
        displayName: "Voxtral Small 24B Q3/IQ3",
        detail: "Mixed 4-bit MLX build · 24B parameters",
        isMultilingual: true,
        backend: .mlxAudio,
        supportsWordTimestamps: false,
        downloadSizeDescription: "14.9 GB",
        memoryRequirementNote: "Too large to run on a 16 GB Mac."
    )

    public static let cohereTranscribe = WhisperModelPreset(
        id: "aufklarer/Cohere-Transcribe-2B-MLX-FP16",
        displayName: "Cohere Transcribe 2B BF16",
        detail: "Full-precision MLX · 14 languages",
        isMultilingual: true,
        backend: .mlxAudio,
        supportsWordTimestamps: false,
        downloadSizeDescription: "4.1 GB"
    )

    public static let qwen3ASRBF16 = WhisperModelPreset(
        id: "mlx-community/Qwen3-ASR-1.7B-bf16",
        displayName: "Qwen3-ASR 1.7B BF16",
        detail: "Full-precision MLX · accuracy reference",
        isMultilingual: true,
        backend: .mlxAudio,
        supportsWordTimestamps: false,
        downloadSizeDescription: "4.1 GB"
    )

    public static let qwen3ASR6Bit = WhisperModelPreset(
        id: "mlx-community/Qwen3-ASR-1.7B-6bit",
        displayName: "Qwen3-ASR 1.7B 6-bit",
        detail: "Compact accuracy-focused choice",
        isMultilingual: true,
        backend: .mlxAudio,
        supportsWordTimestamps: false,
        downloadSizeDescription: "2.0 GB"
    )

    public static let qwen3ASR8Bit = WhisperModelPreset(
        id: "mlx-community/Qwen3-ASR-1.7B-8bit",
        displayName: "Qwen3-ASR 1.7B 8-bit",
        detail: "Quantized MLX · lower memory",
        isMultilingual: true,
        backend: .mlxAudio,
        supportsWordTimestamps: false,
        downloadSizeDescription: "2.5 GB"
    )

    public static let voxtralMini = WhisperModelPreset(
        id: "mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit",
        displayName: "Voxtral Mini 4B",
        detail: "Realtime MLX · 4-bit · 13 languages",
        isMultilingual: true,
        backend: .mlxAudio,
        supportsWordTimestamps: false,
        downloadSizeDescription: "3.1 GB"
    )

    public static let fastestMultilingual = WhisperModelPreset(
        id: "mlx-community/whisper-tiny",
        displayName: "Fastest Multilingual",
        detail: "Tiny local MLX",
        isMultilingual: true,
        downloadSizeDescription: "74 MB"
    )

    public static let fastMultilingual = WhisperModelPreset(
        id: "mlx-community/whisper-base-mlx",
        displayName: "Fast Multilingual",
        detail: "Base local MLX",
        isMultilingual: true,
        downloadSizeDescription: "144 MB"
    )

    public static let fastTurboMultilingual = WhisperModelPreset(
        id: "mlx-community/whisper-large-v3-turbo",
        displayName: "Fast Turbo Multilingual",
        detail: "Large v3 Turbo local MLX",
        isMultilingual: true,
        downloadSizeDescription: "1.6 GB"
    )

    public static let mossDiarize = WhisperModelPreset(
        id: "OpenMOSS-Team/MOSS-Transcribe-Diarize",
        displayName: "MOSS-Diarize 0.9B",
        detail: "Speaker-aware long-form local",
        isMultilingual: true,
        backend: .moss,
        supportsWordTimestamps: false,
        downloadSizeDescription: "1.8 GB"
    )

    public static let parakeetV3 = WhisperModelPreset(
        id: "mlx-community/parakeet-tdt-0.6b-v3",
        displayName: "Parakeet v3",
        detail: "Fast multilingual MLX · lowest memory",
        isMultilingual: true,
        backend: .parakeet,
        downloadSizeDescription: "2.5 GB"
    )

    public static let distilledLargeMultilingual = WhisperModelPreset(
        id: "mlx-community/distil-whisper-large-v3",
        displayName: "Distilled Large Multilingual",
        detail: "Distil Large v3 local MLX",
        isMultilingual: true,
        downloadSizeDescription: "1.5 GB"
    )

    public static let highestAccuracyMultilingual = WhisperModelPreset(
        id: "mlx-community/whisper-large-v3-mlx",
        displayName: "Whisper Large v3",
        detail: "Large v3 local MLX",
        isMultilingual: true,
        downloadSizeDescription: "3.1 GB"
    )

    public static let accurateMultilingual = WhisperModelPreset(
        id: "mlx-community/whisper-medium-mlx-4bit",
        displayName: "Accurate Multilingual",
        detail: "Medium 4-bit",
        isMultilingual: true,
        downloadSizeDescription: "512 MB"
    )

    public static let balancedMultilingual = WhisperModelPreset(
        id: "mlx-community/whisper-small-mlx",
        displayName: "Balanced Multilingual",
        detail: "Small",
        isMultilingual: true,
        downloadSizeDescription: "481 MB"
    )

    public static let accurateEnglish = WhisperModelPreset(
        id: "mlx-community/whisper-medium.en-mlx",
        displayName: "Accurate English",
        detail: "Medium English",
        isMultilingual: false,
        downloadSizeDescription: "1.5 GB"
    )

    public static let fastEnglish = WhisperModelPreset(
        id: "mlx-community/whisper-base.en-mlx",
        displayName: "Fast English",
        detail: "Base English",
        isMultilingual: false,
        downloadSizeDescription: "144 MB"
    )

    public static let balancedEnglish = WhisperModelPreset(
        id: "mlx-community/whisper-small.en-mlx",
        displayName: "Balanced English",
        detail: "Small English",
        isMultilingual: false,
        downloadSizeDescription: "481 MB"
    )

    public static let fastestEnglish = WhisperModelPreset(
        id: "mlx-community/whisper-tiny.en-mlx",
        displayName: "Fastest English",
        detail: "Tiny English",
        isMultilingual: false,
        downloadSizeDescription: "74 MB"
    )

    public static let all: [WhisperModelPreset] = [
        .parakeetV3,
        .qwen3ASR6Bit,
        .voxtralMini8BitDense,
        .canaryQwen,
        .voxtralSmall,
        .cohereTranscribe,
        .qwen3ASRBF16,
        .qwen3ASR8Bit,
        .voxtralMini,
        .highestAccuracyMultilingual,
        .fastestMultilingual,
        .fastMultilingual,
        .fastTurboMultilingual,
        .mossDiarize,
        .distilledLargeMultilingual,
        .balancedMultilingual,
        .accurateMultilingual,
        .fastestEnglish,
        .fastEnglish,
        .balancedEnglish,
        .accurateEnglish,
        .gemini35Transcribe,
    ]

    public static var local: [WhisperModelPreset] {
        all.filter(\.isLocal)
    }

    public static var cloud: [WhisperModelPreset] {
        all.filter(\.isCloud)
    }

    public static func preset(for identifier: String) -> WhisperModelPreset? {
        let normalized = normalizedIdentifier(identifier)
        return all.first { $0.id == normalized }
    }

    public static func normalizedIdentifier(_ identifier: String) -> String {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed.lowercased() {
        case "":
            return fastMultilingual.id
        case "gemini-3.5-transcribe",
            "gemini_3.5_transcribe",
            "gemini_3_5_transcribe",
            "google/gemini-3.5-transcribe",
            "models/gemini-3.5-transcribe":
            return gemini35Transcribe.id
        case "mlx-community/whisper-large-v3-turbo-4bit",
            "mlx-community/whisper-large-v3-turbo-8bit",
            "mlx-community/whisper-large-v3-turbo-fp16",
            "mlx-community/whisper-large-v3-turbo-asr-4bit",
            "mlx-community/whisper-large-v3-turbo-asr-fp16":
            return fastTurboMultilingual.id
        default:
            return trimmed
        }
    }

    public static func optimizedIdentifier(_ identifier: String, languageCode: String?) -> String {
        let normalized = normalizedIdentifier(identifier)
        guard languageCode == "en" else {
            return normalized
        }

        switch normalized {
        case fastestMultilingual.id, fastMultilingual.id, balancedMultilingual.id:
            return fastEnglish.id
        default:
            return normalized
        }
    }

    public static func isMossDiarize(_ identifier: String) -> Bool {
        normalizedIdentifier(identifier) == mossDiarize.id
    }

    public static func isParakeetV3(_ identifier: String) -> Bool {
        normalizedIdentifier(identifier) == parakeetV3.id
    }

    public static func isCanary(_ identifier: String) -> Bool {
        normalizedIdentifier(identifier) == canaryQwen.id
    }

    public static func isGeminiTranscribe(_ identifier: String) -> Bool {
        normalizedIdentifier(identifier) == gemini35Transcribe.id
    }

    public static func isVoxtral(_ identifier: String) -> Bool {
        normalizedIdentifier(identifier) == voxtralMini8BitDense.id
    }

    public static func usesMLXAudio(_ identifier: String) -> Bool {
        preset(for: normalizedIdentifier(identifier))?.backend == .mlxAudio
    }

    public static func usesLongFormInference(_ identifier: String) -> Bool {
        isMossDiarize(identifier) || isParakeetV3(identifier) || isCanary(identifier) || usesMLXAudio(identifier) || isVoxtral(identifier)
    }
}
