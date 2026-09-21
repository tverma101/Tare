import Foundation

public struct TranscriptNamingSuggestion: Codable, Hashable, Sendable {
    public let title: String
    public let folderName: String
    public let provider: String
    public let modelIdentifier: String
    public let strategy: String

    public init(
        title: String,
        folderName: String,
        provider: String,
        modelIdentifier: String,
        strategy: String
    ) {
        self.title = title
        self.folderName = folderName
        self.provider = provider
        self.modelIdentifier = modelIdentifier
        self.strategy = strategy
    }
}

public enum TranscriptNamingError: Error, LocalizedError, Sendable {
    case invalidResponse
    case providerUnavailable
    case requestFailed(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "FreeLLMAPI returned a name that Tare could not use."
        case .providerUnavailable:
            return "FreeLLMAPI is not running or did not accept the request."
        case .requestFailed(let status):
            return "FreeLLMAPI returned HTTP \(status) while naming the transcript."
        }
    }
}

/// The local FreeLLMAPI desktop app is an optional, on-demand collaborator.
/// Tare never launches it, embeds it, or keeps a replacement server alive.
public final class TranscriptNamingService {
    public struct Configuration: Hashable, Sendable {
        public var baseURL: URL
        public var preferredModel: String?
        public var timeout: TimeInterval

        public init(
            baseURL: URL = Configuration.defaultBaseURL,
            preferredModel: String? = nil,
            timeout: TimeInterval = 6
        ) {
            self.baseURL = baseURL
            self.preferredModel = preferredModel
            self.timeout = timeout
        }

        public static let defaultBaseURL = URL(string: "http://127.0.0.1:31415/v1")!

        public static func discovered(
            environment: [String: String] = ProcessInfo.processInfo.environment,
            fileManager: FileManager = .default
        ) -> Configuration {
            if let rawURL = environment["TARE_FREELLM_URL"],
               let url = URL(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)),
               url.scheme != nil,
               url.host != nil {
                let trimmedPath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let normalizedURL: URL
                if trimmedPath.hasSuffix("v1") {
                    normalizedURL = url
                } else {
                    normalizedURL = url.appendingPathComponent("v1", isDirectory: true)
                }
                return Configuration(
                    baseURL: normalizedURL,
                    preferredModel: environment["TARE_FREELLM_MODEL"],
                    timeout: 6
                )
            }

            let supportRoot = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            let configURL = supportRoot?
                .appendingPathComponent("FreeLLMAPI", isDirectory: true)
                .appendingPathComponent("config.json")
            if let configURL,
               let data = try? Data(contentsOf: configURL),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let port = object["port"] as? Int,
               (1...65535).contains(port),
               let baseURL = URL(string: "http://127.0.0.1:\(port)/v1") {
                return Configuration(
                    baseURL: baseURL,
                    preferredModel: environment["TARE_FREELLM_MODEL"],
                    timeout: 6
                )
            }

            return Configuration(
                baseURL: Configuration.defaultBaseURL,
                preferredModel: environment["TARE_FREELLM_MODEL"],
                timeout: 6
            )
        }
    }

    /// These are quality-first aliases from the FreeLLMAPI catalog. The order
    /// favors broad language/instruction-following quality, then fast free-tier
    /// fallbacks. The live /v1/models response is authoritative for availability.
    public static let benchmarkPreferredModelIDs = [
        "gemini-3.6-flash",
        "gpt-oss-120b",
        "nemotron-3-ultra-550b",
        "deepseek-v4-flash",
        "gemini-3.5-flash",
        "gemini-3.5-flash-lite",
        "auto"
    ]

    private let configuration: Configuration
    private let session: URLSession

    public init(
        configuration: Configuration = .discovered(),
        session: URLSession? = nil
    ) {
        self.configuration = configuration
        if let session {
            self.session = session
        } else {
            let sessionConfiguration = URLSessionConfiguration.ephemeral
            sessionConfiguration.waitsForConnectivity = false
            sessionConfiguration.timeoutIntervalForRequest = configuration.timeout
            sessionConfiguration.timeoutIntervalForResource = configuration.timeout
            sessionConfiguration.urlCache = nil
            self.session = URLSession(configuration: sessionConfiguration)
        }
    }

    public var baseURL: URL { configuration.baseURL }

    /// Returns nil on any provider failure so naming can never turn a
    /// successful transcription into a failed export.
    public func suggestName(
        for transcript: Transcript,
        sourceURL: URL,
        apiKey: String?
    ) async -> TranscriptNamingSuggestion? {
        let resolvedKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ProcessInfo.processInfo.environment["TARE_FREELLM_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let resolvedKey, !resolvedKey.isEmpty else { return nil }

        let candidates = await modelCandidates(apiKey: resolvedKey)
        for model in candidates.prefix(2) {
            do {
                let data = try await requestCompletion(
                    model: model,
                    transcript: transcript,
                    sourceURL: sourceURL,
                    apiKey: resolvedKey
                )
                if let suggestion = Self.parseSuggestion(
                    from: data,
                    sourceURL: sourceURL,
                    modelIdentifier: model
                ) {
                    return suggestion
                }
            } catch {
                // The next ranked/free candidate or the deterministic fallback
                // keeps the export path reliable when a provider is cooling down.
                continue
            }
        }

        return nil
    }

    public static func deterministicSuggestion(for sourceURL: URL) -> TranscriptNamingSuggestion {
        let rawName = sourceURL.deletingPathExtension().lastPathComponent
        let cleaned = OutputFolderPlanner.cleanSourceTitle(rawName)
            .replacingOccurrences(
                of: #"(?i)\b(recording|transcript|audio|video|lecture)\b"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = normalizedName(cleaned, fallback: "Transcript", maxLength: 80)
        return TranscriptNamingSuggestion(
            title: title,
            folderName: normalizedName(title, fallback: "Transcript", maxLength: 80),
            provider: "local",
            modelIdentifier: "deterministic-filename",
            strategy: "filename-fallback"
        )
    }

    /// Public for focused smoke tests and for callers that already have a
    /// decoded OpenAI-compatible response body.
    public static func parseSuggestion(
        from data: Data,
        sourceURL: URL,
        modelIdentifier: String
    ) -> TranscriptNamingSuggestion? {
        guard let response = try? JSONDecoder().decode(ChatCompletionResponse.self, from: data),
              let content = response.choices.first?.message.content else {
            return nil
        }

        let jsonText: String
        if let start = content.firstIndex(of: "{"),
           let end = content.lastIndex(of: "}"),
           start <= end {
            jsonText = String(content[start...end])
        } else {
            return nil
        }

        guard let jsonData = jsonText.data(using: .utf8),
              let payload = try? JSONDecoder().decode(NamePayload.self, from: jsonData) else {
            return nil
        }

        let title = normalizedName(payload.title, fallback: "", maxLength: 80)
        let folder = normalizedName(payload.folder ?? payload.folderName ?? title, fallback: "", maxLength: 80)
        guard isUsableName(title), isUsableName(folder) else { return nil }

        return TranscriptNamingSuggestion(
            title: title,
            folderName: folder,
            provider: "FreeLLMAPI",
            modelIdentifier: response.model?.isEmpty == false
                ? (response.model ?? modelIdentifier)
                : modelIdentifier,
            strategy: "benchmark-ranked-llm"
        )
    }

    private func modelCandidates(apiKey: String) async -> [String] {
        if let preferredModel = configuration.preferredModel?.trimmingCharacters(in: .whitespacesAndNewlines),
           !preferredModel.isEmpty {
            return [preferredModel]
        }

        guard let modelsURL = endpoint(path: "models") else {
            return ["auto"]
        }

        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = min(configuration.timeout, 4)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        guard let (data, response) = try? await session.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode),
              let listing = try? JSONDecoder().decode(ModelListing.self, from: data) else {
            return ["auto"]
        }

        let available = Set(listing.data.map { $0.id.lowercased() })
        let ranked = Self.benchmarkPreferredModelIDs.filter { available.contains($0.lowercased()) }
        return ranked.isEmpty ? ["auto"] : ranked
    }

    private func requestCompletion(
        model: String,
        transcript: Transcript,
        sourceURL: URL,
        apiKey: String
    ) async throws -> Data {
        guard let url = endpoint(path: "chat/completions") else {
            throw TranscriptNamingError.providerUnavailable
        }

        let body = ChatCompletionRequest(
            model: model,
            messages: [
                .init(role: "system", content: "You create concise, accurate names for transcript files. Never invent a course, person, date, or location that is not supported by the transcript."),
                .init(role: "user", content: prompt(transcript: transcript, sourceURL: sourceURL))
            ],
            temperature: 0.1,
            max_tokens: 256
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptNamingError.providerUnavailable
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw TranscriptNamingError.requestFailed(httpResponse.statusCode)
        }
        return data
    }

    private func endpoint(path: String) -> URL? {
        configuration.baseURL.appendingPathComponent(path)
    }

    private func prompt(transcript: Transcript, sourceURL: URL) -> String {
        let excerpt = Self.transcriptExcerpt(transcript.fullText)
        return """
        Return only one JSON object with exactly these keys:
        {"title":"compact human-readable title","folder":"compact folder name"}

        Rules:
        - title: 3-80 characters, 2-8 meaningful words when possible.
        - folder: 3-80 characters, suitable as one macOS folder name.
        - Prefer the actual subject, course, meeting, or event named in the transcript.
        - Keep useful proper nouns and course numbers; remove filler such as Recording, Transcript, Audio, Campus, and date-only suffixes unless they disambiguate the subject.
        - Do not include file extensions, slashes, colons, quotes, emojis, or a made-up date.
        - If the transcript is too noisy, use the strongest supported subject words and keep the result short.

        Source filename: \(sourceURL.lastPathComponent)

        Transcript excerpt:
        \(excerpt)
        """
    }

    private static func transcriptExcerpt(_ text: String) -> String {
        let normalized = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard normalized.count > 8_000 else { return normalized }
        let prefix = String(normalized.prefix(6_000))
        let suffix = String(normalized.suffix(2_000))
        return prefix + " … [middle omitted] … " + suffix
    }

    private static func normalizedName(_ raw: String?, fallback: String, maxLength: Int) -> String {
        guard let raw else { return fallback }
        let replaced = raw
            .replacingOccurrences(of: #"[/:\\*?\"<>|]"#, with: " - ", options: .regularExpression)
            .replacingOccurrences(of: #"[\r\n\t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !replaced.isEmpty else { return fallback }
        if replaced.count <= maxLength { return replaced }

        let clipped = String(replaced.prefix(maxLength))
        if let boundary = clipped.lastIndex(of: " "), boundary > clipped.startIndex {
            return String(clipped[..<boundary]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return clipped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isUsableName(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= 3 else { return false }
        let generic = Set(["audio", "recording", "transcript", "untitled", "unknown", "video", "notes"])
        return !generic.contains(normalized.lowercased())
    }
}

private struct ModelListing: Decodable {
    var data: [ModelListingEntry]
}

private struct ModelListingEntry: Decodable {
    var id: String
}

private struct ChatCompletionRequest: Encodable {
    struct Message: Encodable {
        var role: String
        var content: String
    }

    var model: String
    var messages: [Message]
    var temperature: Double
    var max_tokens: Int
}

private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            var content: String?
        }

        var message: Message
    }

    var model: String?
    var choices: [Choice]
}

private struct NamePayload: Decodable {
    var title: String?
    var folder: String?
    var folderName: String?
}
