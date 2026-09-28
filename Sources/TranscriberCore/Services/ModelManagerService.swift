import Foundation

public struct ModelStatus: Codable, Hashable, Sendable {
    public let modelIdentifier: String
    public let isAvailable: Bool
    public let isUsable: Bool
    public let issueMessage: String?
    public let sizeBytes: Int64
    public let cachePath: String?

    public init(
        modelIdentifier: String,
        isAvailable: Bool,
        isUsable: Bool = true,
        issueMessage: String? = nil,
        sizeBytes: Int64,
        cachePath: String?
    ) {
        self.modelIdentifier = modelIdentifier
        self.isAvailable = isAvailable
        self.isUsable = isUsable
        self.issueMessage = issueMessage
        self.sizeBytes = sizeBytes
        self.cachePath = cachePath
    }

    private enum CodingKeys: String, CodingKey {
        case modelIdentifier
        case isAvailable
        case isUsable
        case issueMessage
        case sizeBytes
        case cachePath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modelIdentifier = try container.decode(String.self, forKey: .modelIdentifier)
        // A dev checkout and an installed app can load different model scripts,
        // so a field the loaded script omits falls back instead of failing the
        // whole decode and blanking the Models tab.
        isAvailable = try container.decodeIfPresent(Bool.self, forKey: .isAvailable) ?? false
        isUsable = try container.decodeIfPresent(Bool.self, forKey: .isUsable) ?? isAvailable
        issueMessage = try container.decodeIfPresent(String.self, forKey: .issueMessage)
        sizeBytes = try container.decodeIfPresent(Int64.self, forKey: .sizeBytes) ?? 0
        cachePath = try container.decodeIfPresent(String.self, forKey: .cachePath)
    }

    public var sizeDescription: String {
        guard sizeBytes > 0 else { return "Size unavailable" }
        return ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

public enum ModelManagerError: Error, LocalizedError {
    case pythonMissing
    case scriptMissing
    case unsupportedModel(String)
    case invalidResult
    case cacheInspectionFailed
    case operationFailed(modelName: String, action: String, detail: String?)

    public var errorDescription: String? {
        switch self {
        case .pythonMissing:
            return "The local Python environment was not found. Run script/setup_transcription_backend.sh."
        case .scriptMissing:
            return "The model manager script is missing from the app bundle."
        case .unsupportedModel(let identifier):
            return "Model is not in Tare's managed catalog: \(identifier)"
        case .invalidResult:
            return "The model manager returned an invalid status. Its script may be an older version than this build of Tare."
        case .cacheInspectionFailed:
            return "Tare could not inspect the local model cache. Check the local Python backend, then choose Refresh again."
        case .operationFailed(let modelName, let action, let detail):
            let sentence: String
            if action == "remove" {
                sentence = "Tare could not remove \(modelName) from the local cache. Nothing was changed; choose Remove again to retry."
            } else {
                sentence = "Tare could not download \(modelName). Check your internet connection and choose Download again. Existing cache files are safe."
            }
            guard let detail, !detail.isEmpty else { return sentence }
            return "\(sentence) \(detail)"
        }
    }
}

/// Turns model-manager stderr into one short, actionable cause.
///
/// Nothing is forwarded verbatim. A Python traceback can carry absolute paths,
/// and a backend can echo the environment it was handed, so a recognised cause
/// becomes fixed wording and anything unrecognised is dropped rather than shown.
private enum ModelManagerFailure {
    case outOfDiskSpace
    case gatedRepository
    case unauthorized
    case missingRepository
    case connectionFailed
    case unusableCache

    var detail: String {
        switch self {
        case .outOfDiskSpace:
            return "The model manager ran out of disk space. Free space in your Hugging Face cache, then try again."
        case .gatedRepository:
            return "This model is gated on Hugging Face. Accept its licence on the model page for the signed-in account, then try again."
        case .unauthorized:
            return "Hugging Face refused the request as unauthorized. Sign in again with huggingface-cli login, then try again."
        case .missingRepository:
            return "Hugging Face could not find this model. It may have been renamed, made private, or removed."
        case .connectionFailed:
            return "The connection to Hugging Face failed. Check the network, VPN, or proxy, then try again."
        case .unusableCache:
            return "The cached files for this model are incomplete or unreadable. Choose Re-download, or remove the entry and download it again."
        }
    }

    static func detail(for error: Error) -> String? {
        guard case let ProcessRunnerError.nonZeroExit(_, _, stderr) = error else { return nil }
        return detail(forStderr: stderr)
    }

    static func detail(forStderr stderr: String) -> String? {
        let line = lastReportableLine(in: stderr)
        guard !line.isEmpty else { return nil }

        let lowered = line.lowercased()
        if lowered.contains("no space left on device") || lowered.contains("errno 28")
            || lowered.contains("disk quota exceeded") || lowered.contains("disk full") {
            return ModelManagerFailure.outOfDiskSpace.detail
        }
        if lowered.contains("gated") || lowered.contains("accept the licence")
            || lowered.contains("accept the license") || lowered.contains("request access") {
            return ModelManagerFailure.gatedRepository.detail
        }
        if lowered.contains("401") || lowered.contains("403") || lowered.contains("unauthorized")
            || lowered.contains("unauthorised") || lowered.contains("invalid token")
            || lowered.contains("token is required") || lowered.contains("bad credentials") {
            return ModelManagerFailure.unauthorized.detail
        }
        if lowered.contains("404") || lowered.contains("repositorynotfound")
            || lowered.contains("does not exist") {
            return ModelManagerFailure.missingRepository.detail
        }
        if lowered.contains("ssl") || lowered.contains("certificate") || lowered.contains("proxy")
            || lowered.contains("connection") || lowered.contains("timed out")
            || lowered.contains("max retries") || lowered.contains("name or service not known") {
            return ModelManagerFailure.connectionFailed.detail
        }
        if lowered.contains("safetensor") || lowered.contains("incomplete")
            || lowered.contains("corrupt") || lowered.contains("checksum")
            || lowered.contains("unreadable") {
            return ModelManagerFailure.unusableCache.detail
        }
        return nil
    }

    /// The one stderr line that carries the cause.
    ///
    /// A Python traceback is read from its last line and its `File "..."` frames
    /// are skipped, because a frame is a local path. `manage_models.py` marks
    /// the cause itself, so a marked line wins over an unmarked trailing one.
    private static func lastReportableLine(in stderr: String) -> String {
        var trailing = ""
        for rawLine in stderr.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("Traceback (most recent call last)") { continue }
            if line.hasPrefix("File \"") || line.hasPrefix("During handling")
                || line.hasPrefix("The above exception") {
                continue
            }
            if let range = line.range(of: "model management failed:") {
                return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            trailing = line
        }
        return trailing
    }
}

public final class ModelManagerService {
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

        guard let resolvedPythonURL = pythonURL ?? WhisperTranscriptionService.resolvePythonURL() else {
            throw ModelManagerError.pythonMissing
        }
        guard let resolvedScriptURL = scriptURL ?? Self.resolveScriptURL() else {
            throw ModelManagerError.scriptMissing
        }

        self.pythonURL = resolvedPythonURL
        self.scriptURL = resolvedScriptURL
    }

    public func status(for modelIdentifier: String) async throws -> ModelStatus {
        try await run(action: "status", modelIdentifier: modelIdentifier)
    }

    public func localModels() async throws -> [ModelStatus] {
        var environment = WhisperTranscriptionService.transcriptionEnvironment()
        environment["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"

        let result: ProcessResult
        do {
            result = try await runner.run(
                executableURL: pythonURL,
                arguments: [scriptURL.path, "--action", "inventory"],
                environment: environment,
                forwardOutput: false
            )
        } catch {
            throw ModelManagerError.cacheInspectionFailed
        }

        guard let data = result.stdout.data(using: .utf8) else {
            throw ModelManagerError.invalidResult
        }

        do {
            return try decoder.decode([ModelStatus].self, from: data)
        } catch {
            throw ModelManagerError.invalidResult
        }
    }

    public func download(modelIdentifier: String) async throws -> ModelStatus {
        try await run(action: "download", modelIdentifier: modelIdentifier)
    }

    public func remove(modelIdentifier: String) async throws -> ModelStatus {
        try await run(action: "remove", modelIdentifier: modelIdentifier)
    }

    private func run(action: String, modelIdentifier: String) async throws -> ModelStatus {
        let normalized = WhisperModelPreset.normalizedIdentifier(modelIdentifier)
        guard let preset = WhisperModelPreset.preset(for: normalized), preset.isLocal else {
            throw ModelManagerError.unsupportedModel(modelIdentifier)
        }

        var environment = WhisperTranscriptionService.transcriptionEnvironment()
        environment["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"

        let result: ProcessResult
        do {
            result = try await runner.run(
                executableURL: pythonURL,
                arguments: [
                    scriptURL.path,
                    "--action", action,
                    "--model", normalized
                ],
                environment: environment,
                forwardOutput: false
            )
        } catch {
            let modelName = preset.displayName
            throw ModelManagerError.operationFailed(
                modelName: modelName,
                action: action,
                detail: ModelManagerFailure.detail(for: error)
            )
        }

        guard let data = result.stdout.data(using: .utf8) else {
            throw ModelManagerError.invalidResult
        }

        do {
            return try decoder.decode(ModelStatus.self, from: data)
        } catch {
            throw ModelManagerError.invalidResult
        }
    }

    private static func resolveScriptURL() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["TARE_MODEL_SCRIPT"], FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        let bundleResourceURL = Bundle.main.resourceURL?.appendingPathComponent("manage_models.py")
        if let bundleResourceURL, FileManager.default.fileExists(atPath: bundleResourceURL.path) {
            return bundleResourceURL
        }

        let bundleURL = Bundle.main.bundleURL
        let roots = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            bundleURL.deletingLastPathComponent().deletingLastPathComponent(),
            bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        ]
        var seenPaths = Set<String>()
        for root in roots {
            let path = root.standardizedFileURL.path
            guard seenPaths.insert(path).inserted else { continue }
            let candidate = root.appendingPathComponent("script/manage_models.py")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
    }
}
