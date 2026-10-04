import Foundation

public enum GeminiTranscriptionMode: String, Codable, CaseIterable, Hashable, Sendable {
    case smart
    case verbatim

    public var displayName: String {
        switch self {
        case .smart:
            return "Smart transcription"
        case .verbatim:
            return "Verbatim transcription (Google default)"
        }
    }
}

public enum GeminiTranscriptionOptionsError: Error, LocalizedError, Hashable, Sendable {
    case smartModeDoesNotSupportAnnotations
    case vocabularyDoesNotSupportAnnotations
    case vocabularyLimitExceeded(Int)

    public var errorDescription: String? {
        switch self {
        case .smartModeDoesNotSupportAnnotations:
            return "Smart transcription cannot be combined with word timestamps or speaker labels. Choose Verbatim or turn those options off."
        case .vocabularyDoesNotSupportAnnotations:
            return "Custom vocabulary cannot be combined with word timestamps or speaker labels. Remove the vocabulary or turn those options off."
        case .vocabularyLimitExceeded(let count):
            return "Custom vocabulary has \(count) terms. Google allows at most 1,000 terms per request."
        }
    }
}

public struct GeminiTranscriptionOptions: Codable, Hashable, Sendable {
    public var mode: GeminiTranscriptionMode
    public var wordTimestamps: Bool
    public var speakerDiarization: Bool
    public var customVocabulary: [String]

    public static let `default` = GeminiTranscriptionOptions()

    public init(
        mode: GeminiTranscriptionMode = .verbatim,
        wordTimestamps: Bool = false,
        speakerDiarization: Bool = false,
        customVocabulary: [String] = []
    ) {
        self.mode = mode
        self.wordTimestamps = wordTimestamps
        self.speakerDiarization = speakerDiarization
        self.customVocabulary = Self.normalizedVocabulary(customVocabulary)
    }

    public var usesAnnotatedOutput: Bool {
        wordTimestamps || speakerDiarization
    }

    public var safeChunkSeconds: Int {
        usesAnnotatedOutput
            ? GeminiTranscriptionLimits.safeAnnotatedChunkSeconds
            : GeminiTranscriptionLimits.safePlainChunkSeconds
    }

    public func validated() throws -> GeminiTranscriptionOptions {
        var normalized = self
        normalized.customVocabulary = Self.normalizedVocabulary(customVocabulary)

        if normalized.customVocabulary.count > GeminiTranscriptionLimits.maximumVocabularyTerms {
            throw GeminiTranscriptionOptionsError.vocabularyLimitExceeded(normalized.customVocabulary.count)
        }

        if normalized.mode == .smart, normalized.usesAnnotatedOutput {
            throw GeminiTranscriptionOptionsError.smartModeDoesNotSupportAnnotations
        }

        if !normalized.customVocabulary.isEmpty, normalized.usesAnnotatedOutput {
            throw GeminiTranscriptionOptionsError.vocabularyDoesNotSupportAnnotations
        }

        return normalized
    }

    public static func normalizedVocabulary(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { rawValue in
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            let key = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard seen.insert(key).inserted else { return nil }
            return value
        }
    }

    public static func vocabularyTerms(from text: String) -> [String] {
        normalizedVocabulary(
            text.components(separatedBy: CharacterSet.newlines.union(CharacterSet(charactersIn: ",;")))
        )
    }
}

public enum GeminiTranscriptionLimits {
    /// Official Gemini 3.5 Transcribe / pricing estimate (ai.google.dev pricing page).
    /// General multimodal audio docs still mention 32 tok/s; the dedicated
    /// transcription product pricing footnote uses 25 tok/s.
    public static let audioTokensPerSecond = 25
    public static let documentedPlainChunkSeconds = 60 * 60
    public static let documentedAnnotatedChunkSeconds = 30 * 60
    // Google documents one hour, but on 2026-10-04 a ~34-minute plain request
    // came back 2xx with no transcript (a ~30.5-minute one succeeded), so plain
    // requests are held to the same 28 minutes as annotated ones.
    public static let safePlainChunkSeconds = 28 * 60
    public static let safeAnnotatedChunkSeconds = 28 * 60
    public static let maximumVocabularyTerms = 1_000
    public static let maximumFileBytes: Int64 = 2 * 1024 * 1024 * 1024
    public static let boundaryContextOverlapSeconds: TimeInterval = 1.5
}

public struct GeminiAudioChunk: Hashable, Sendable {
    public let index: Int
    public let startTime: TimeInterval
    public let endTime: TimeInterval

    public init(index: Int, startTime: TimeInterval, endTime: TimeInterval) {
        self.index = index
        self.startTime = max(0, startTime)
        self.endTime = max(self.startTime, endTime)
    }

    public var duration: TimeInterval {
        max(0, endTime - startTime)
    }
}

public struct GeminiTranscriptionPlan: Hashable, Sendable {
    public let duration: TimeInterval
    public let chunks: [GeminiAudioChunk]
    public let safeChunkSeconds: Int
    public let estimatedInputTokens: Int64

    public init(
        duration: TimeInterval,
        chunks: [GeminiAudioChunk],
        safeChunkSeconds: Int,
        estimatedInputTokens: Int64
    ) {
        self.duration = duration
        self.chunks = chunks
        self.safeChunkSeconds = safeChunkSeconds
        self.estimatedInputTokens = estimatedInputTokens
    }

    public var isChunked: Bool {
        chunks.count > 1
    }

    public var summaryDescription: String {
        let tokenText = Self.formattedTokenCount(estimatedInputTokens)
        if isChunked {
            return "\(chunks.count) safe chunks · ~\(tokenText) estimated audio tokens"
        }
        return "1 request · ~\(tokenText) estimated audio tokens"
    }

    public static func formattedTokenCount(_ value: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

public enum GeminiAudioChunkPlanner {
    public static func plan(
        duration: TimeInterval,
        options: GeminiTranscriptionOptions,
        safeBoundaries: [TimeInterval] = []
    ) -> GeminiTranscriptionPlan {
        let normalizedDuration = max(0.2, duration.isFinite ? duration : 0.2)
        let maximumChunkDuration = TimeInterval(options.safeChunkSeconds)
        let rawEstimatedTokens = max(
            0,
            normalizedDuration * Double(GeminiTranscriptionLimits.audioTokensPerSecond)
        )
        let estimatedTokens = rawEstimatedTokens >= Double(Int64.max)
            ? Int64.max
            : Int64(rawEstimatedTokens.rounded(.up))

        guard normalizedDuration > maximumChunkDuration else {
            return GeminiTranscriptionPlan(
                duration: normalizedDuration,
                chunks: [GeminiAudioChunk(index: 1, startTime: 0, endTime: normalizedDuration)],
                safeChunkSeconds: options.safeChunkSeconds,
                estimatedInputTokens: estimatedTokens
            )
        }

        // Leave a small amount of context on both sides of each interior boundary
        // so a word or sentence is not lost when a recording has no detected pause.
        // The core spans are shortened first, keeping the uploaded chunks under the
        // provider's request limit even after overlap is added.
        let minimumChunkDuration = 0.5
        let overlap = GeminiTranscriptionLimits.boundaryContextOverlapSeconds
        let maximumCoreDuration = max(minimumChunkDuration, maximumChunkDuration - (overlap * 2))
        let chunkCount = max(2, Int(ceil(normalizedDuration / maximumCoreDuration)))
        var starts: [TimeInterval] = [0]
        let sortedBoundaries = Array(Set(safeBoundaries.filter { value in
            value.isFinite && value > minimumChunkDuration && value < normalizedDuration - minimumChunkDuration
        })).sorted()

        for part in 1..<chunkCount {
            let remainingChunkCount = chunkCount - part
            let idealCut = normalizedDuration * Double(part) / Double(chunkCount)
            let lowerBound = max(
                starts.last! + minimumChunkDuration,
                normalizedDuration - Double(remainingChunkCount) * maximumCoreDuration
            )
            let upperBound = min(
                starts.last! + maximumCoreDuration,
                normalizedDuration - Double(remainingChunkCount) * minimumChunkDuration
            )
            let boundedIdeal = min(max(idealCut, lowerBound), upperBound)
            let safeCut = sortedBoundaries
                .filter { $0 >= lowerBound && $0 <= upperBound }
                .min { abs($0 - boundedIdeal) < abs($1 - boundedIdeal) }
            starts.append(safeCut ?? boundedIdeal)
        }
        starts.append(normalizedDuration)

        let corePairs = Array(zip(starts.dropLast(), starts.dropFirst()))
        var chunks: [GeminiAudioChunk] = []
        chunks.reserveCapacity(corePairs.count)
        for (offset, pair) in corePairs.enumerated() {
            let coreStart = pair.0
            let coreEnd = pair.1
            guard coreEnd - coreStart >= minimumChunkDuration else { continue }
            let isFirst = offset == 0
            let isLast = offset == corePairs.count - 1
            let start = isFirst ? coreStart : max(0, coreStart - overlap)
            let end = isLast ? coreEnd : min(normalizedDuration, coreEnd + overlap)
            // Defensive clamp: overlap must never push a chunk past the safe
            // unary request limit used for planning.
            let clampedEnd = min(end, start + maximumChunkDuration)
            chunks.append(
                GeminiAudioChunk(
                    index: chunks.count + 1,
                    startTime: start,
                    endTime: max(start + minimumChunkDuration, clampedEnd)
                )
            )
        }

        if chunks.isEmpty {
            chunks = [GeminiAudioChunk(index: 1, startTime: 0, endTime: normalizedDuration)]
        }

        // Ensure full timeline coverage even if a compactMap-style drop occurred.
        if let last = chunks.last, last.endTime + 0.001 < normalizedDuration {
            let start = max(0, normalizedDuration - maximumChunkDuration)
            chunks.append(
                GeminiAudioChunk(
                    index: chunks.count + 1,
                    startTime: start,
                    endTime: normalizedDuration
                )
            )
        }

        return GeminiTranscriptionPlan(
            duration: normalizedDuration,
            chunks: chunks,
            safeChunkSeconds: options.safeChunkSeconds,
            estimatedInputTokens: estimatedTokens
        )
    }
}
