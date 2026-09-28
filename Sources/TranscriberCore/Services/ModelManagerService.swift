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
        isAvailable = try container.decode(Bool.self, forKey: .isAvailable)
        isUsable = try container.decodeIfPresent(Bool.self, forKey: .isUsable) ?? isAvailable
        issueMessage = try container.decodeIfPresent(String.self, forKey: .issueMessage)
        sizeBytes = try container.decode(Int64.self, forKey: .sizeBytes)
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
    case operationFailed(modelName: String, action: String)

    public var errorDescription: String? {
        switch self {
        case .pythonMissing:
            return "The local Python environment was not found. Run script/setup_transcription_backend.sh."
        case .scriptMissing:
            return "The model manager script is missing from the app bundle."
        case .unsupportedModel(let identifier):
            return "Model is not in Tare's managed catalog: \(identifier)"
        case .invalidResult:
            return "The model manager returned an invalid status."
        case .cacheInspectionFailed:
            return "Tare could not inspect the local model cache. Check the local Python backend, then choose Refresh again."
        case .operationFailed(let modelName, let action):
            if action == "remove" {
                return "Tare could not remove \(modelName) from the local cache. Nothing was changed; choose Remove again to retry."
            }
            return "Tare could not download \(modelName). Check your internet connection and choose Download again. Existing cache files are safe."
        }
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
            throw ModelManagerError.operationFailed(modelName: modelName, action: action)
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
