import Foundation

public enum WhisperTranscriptionError: Error, LocalizedError {
    case pythonMissing
    case scriptMissing
    case emptyResult
    case invalidResult(String)
    case backendUnavailable(modelName: String, backendName: String)
    case modelCacheIncomplete(modelName: String)
    case modelResourceUnavailable(modelName: String, reason: String)
    case transcriptionFailed(modelName: String)

    public var errorDescription: String? {
        switch self {
        case .pythonMissing:
            return "The local transcription Python environment was not found. Run script/setup_transcription_backend.sh."
        case .scriptMissing:
            return "The local transcription bridge script is missing from the app bundle."
        case .emptyResult:
            return "Local transcription finished without transcript text."
        case .invalidResult(let reason):
            return "Local transcription returned an invalid result: \(reason)"
        case .backendUnavailable(let modelName, let backendName):
            return "Tare cannot use \(modelName) yet because the \(backendName) backend is missing. Repair Tare's local backend, then choose Retry."
        case .modelCacheIncomplete(let modelName):
            return "Tare found \(modelName) in the local cache, but its files are incomplete or incompatible. Open Models to remove it or choose another model."
        case .modelResourceUnavailable(let modelName, let reason):
            return "Tare cannot run \(modelName) on this Mac. \(reason)"
        case .transcriptionFailed(let modelName):
            return "Tare could not transcribe this file with \(modelName). Check that the local model is available, then choose Retry."
        }
    }
}

public final class WhisperTranscriptionService {
    private let runner: ProcessRunner
    private let pythonURL: URL
    private let scriptURL: URL
    private let decoder = JSONDecoder()

    public init(
        runner: ProcessRunner = ProcessRunner(),
        pythonURL: URL? = nil,
        scriptURL: URL? = nil
    ) throws {
        self.runner = runner

        guard let resolvedPythonURL = pythonURL ?? Self.resolvePythonURL() else {
            throw WhisperTranscriptionError.pythonMissing
        }

        guard let resolvedScriptURL = scriptURL ?? Self.resolveScriptURL() else {
            throw WhisperTranscriptionError.scriptMissing
        }

        self.pythonURL = resolvedPythonURL
        self.scriptURL = resolvedScriptURL
    }

    public func transcribe(
        audioURL: URL,
        sourceName: String,
        localeIdentifier: String,
        modelIdentifier: String,
        chunkSeconds: Int = 0,
        chunkWorkerCount: Int = 1,
        wordTimestamps: Bool = false
    ) async throws -> Transcript {
        let resultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Tare", isDirectory: true)
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")

        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var arguments = [
            scriptURL.path,
            "--audio", audioURL.path,
            "--output", resultURL.path,
            "--model", modelIdentifier
        ]

        if let languageCode = Self.languageCode(from: localeIdentifier) {
            arguments.append(contentsOf: ["--language", languageCode])
        }

        if chunkSeconds > 0 {
            arguments.append(contentsOf: ["--chunk-seconds", String(chunkSeconds)])
        }

        if chunkWorkerCount > 1 {
            arguments.append(contentsOf: ["--chunk-workers", String(chunkWorkerCount)])
        }

        if wordTimestamps {
            arguments.append("--word-timestamps")
        }

        do {
            _ = try await runner.run(
                executableURL: pythonURL,
                arguments: arguments,
                environment: Self.transcriptionEnvironment(),
                forwardOutput: true
            )
        } catch {
            throw Self.userFacingError(error, modelIdentifier: modelIdentifier)
        }

        let data = try Data(contentsOf: resultURL)
        let payload: WhisperTranscriptPayload

        do {
            payload = try decoder.decode(WhisperTranscriptPayload.self, from: data)
        } catch {
            throw WhisperTranscriptionError.invalidResult(error.localizedDescription)
        }

        let fullText = payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fullText.isEmpty else {
            throw WhisperTranscriptionError.emptyResult
        }

        let segments = payload.segments.enumerated().map { offset, segment -> TranscriptSegment in
            let words = segment.words.enumerated().map { wordOffset, word in
                TranscriptWord(
                    index: wordOffset + 1,
                    startTime: word.start,
                    duration: max(word.end - word.start, 0.05),
                    text: word.word.trimmingCharacters(in: .whitespacesAndNewlines),
                    probability: word.probability
                )
            }

            return TranscriptSegment(
                index: offset + 1,
                startTime: segment.start,
                duration: max(segment.end - segment.start, 0.2),
                text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines),
                speaker: segment.speaker,
                words: words.filter { !$0.text.isEmpty }
            )
        }

        return Transcript(
            sourceName: sourceName,
            localeIdentifier: payload.language ?? localeIdentifier,
            fullText: fullText,
            segments: segments
        )
    }

    public static func resolvePythonURL() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["TARE_PYTHON"], FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        if let applicationSupportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            let installedPython = applicationSupportDirectory
                .appendingPathComponent("Tare/.venv/bin/python")
            if FileManager.default.isExecutableFile(atPath: installedPython.path) {
                return installedPython
            }
        }

        if let bundledPython = Bundle.main.resourceURL?.appendingPathComponent(".venv/bin/python"),
           FileManager.default.isExecutableFile(atPath: bundledPython.path) {
            return bundledPython
        }

        return candidateRootURLs()
            .map { $0.appendingPathComponent(".venv/bin/python") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func userFacingError(_ error: Error, modelIdentifier: String) -> WhisperTranscriptionError {
        let modelName = WhisperModelPreset.preset(for: modelIdentifier)?.displayName ?? modelIdentifier
        let backendName: String
        if WhisperModelPreset.isCanary(modelIdentifier) {
            backendName = "Canary-Qwen MLX"
        } else {
            switch WhisperModelPreset.preset(for: modelIdentifier)?.backend {
            case .mlxAudio:
                backendName = "MLX-Audio"
            case .canary:
                backendName = "Canary-Qwen MLX"
            case .mlxVoxtral:
                backendName = "Voxtral MLX"
            case .parakeet:
                backendName = "Parakeet"
            case .moss:
                backendName = "MOSS"
            case .geminiTranscribe:
                backendName = "Gemini 3.5 Transcribe"
            default:
                backendName = "MLX Whisper"
            }
        }

        if case let ProcessRunnerError.nonZeroExit(_, _, stderr) = error {
            let normalized = stderr.lowercased()
            if normalized.contains("dependencies are missing") || normalized.contains("modulenotfounderror") {
                return .backendUnavailable(modelName: modelName, backendName: backendName)
            }
            if normalized.contains("config not found") || normalized.contains("file not found") ||
                normalized.contains("cache is incomplete") || normalized.contains("weights are missing") ||
                normalized.contains("local hugging face cache") {
                return .modelCacheIncomplete(modelName: modelName)
            }
            if normalized.contains("maximum allowed buffer size") ||
                normalized.contains("metal buffer") ||
                normalized.contains("unified memory") {
                return .modelResourceUnavailable(
                    modelName: modelName,
                    reason: "Its full-precision load exceeds this Mac's Metal memory limit. Choose Parakeet v3 or Qwen3-ASR 1.7B 6-bit."
                )
            }
        }

        return .transcriptionFailed(modelName: modelName)
    }

    public static func resolveScriptURL() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["TARE_SCRIPT"], FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        let bundleResourceURL = Bundle.main.resourceURL?.appendingPathComponent("mlx_transcribe.py")
        if let bundleResourceURL, FileManager.default.fileExists(atPath: bundleResourceURL.path) {
            return bundleResourceURL
        }

        return candidateRootURLs()
            .map { $0.appendingPathComponent("script/mlx_transcribe.py") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func candidateRootURLs() -> [URL] {
        var urls: [URL] = []
        let currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        urls.append(currentDirectoryURL)

        let bundleURL = Bundle.main.bundleURL
        urls.append(bundleURL.deletingLastPathComponent().deletingLastPathComponent())
        urls.append(bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())

        var seenPaths = Set<String>()
        return urls.filter { url in
            let path = url.standardizedFileURL.path
            guard !seenPaths.contains(path) else { return false }
            seenPaths.insert(path)
            return true
        }
    }

    public static func transcriptionEnvironment(
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        let fallbackPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        var environment = [
            "PYTHONUNBUFFERED": "1",
            "PYTHONDONTWRITEBYTECODE": "1",
            "PATH": fallbackPath
        ]

        if let existingPath = processEnvironment["PATH"], !existingPath.isEmpty {
            environment["PATH"] = "\(fallbackPath):\(existingPath)"
        }

        return environment
    }

    public static func languageCode(from identifier: String) -> String? {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lowered = trimmed.lowercased()
        if ["auto", "detect", "auto-detect", "automatic"].contains(lowered) {
            return nil
        }

        if let languageCode = Locale(identifier: trimmed).language.languageCode?.identifier {
            return languageCode
        }

        return lowered
            .split(whereSeparator: { $0 == "_" || $0 == "-" })
            .first
            .map(String.init)
    }
}

private struct WhisperTranscriptPayload: Decodable {
    var text: String
    var segments: [WhisperSegmentPayload]
    var language: String?
}

private struct WhisperSegmentPayload: Decodable {
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    var speaker: String?
    var words: [WhisperWordPayload] = []

    private enum CodingKeys: String, CodingKey {
        case start
        case end
        case text
        case speaker
        case words
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        start = try container.decode(TimeInterval.self, forKey: .start)
        end = try container.decode(TimeInterval.self, forKey: .end)
        text = try container.decode(String.self, forKey: .text)
        speaker = try container.decodeIfPresent(String.self, forKey: .speaker)
        words = try container.decodeIfPresent([WhisperWordPayload].self, forKey: .words) ?? []
    }
}

private struct WhisperWordPayload: Decodable {
    var word: String
    var start: TimeInterval
    var end: TimeInterval
    var probability: Double?
}
