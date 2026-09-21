import Foundation

public enum FilenameCleanerError: Error, LocalizedError {
    case cleanerMissing
    case pythonMissing
    case invalidJSON(String)

    public var errorDescription: String? {
        switch self {
        case .cleanerMissing:
            return "Name Clean helper was not found."
        case .pythonMissing:
            return "python3 was not found."
        case .invalidJSON(let message):
            return "Name Clean returned unreadable JSON: \(message)"
        }
    }
}

public struct FilenameCleanResult: Decodable, Hashable, Sendable {
    public var path: String
    public var oldName: String
    public var newName: String
    public var targetPath: String
    public var changed: Bool
    public var renamed: Bool
    public var reason: String
    public var category: String
    public var confidence: Double
    public var elapsedSeconds: Double

    public var originalURL: URL {
        URL(fileURLWithPath: path)
    }

    public var targetURL: URL {
        URL(fileURLWithPath: targetPath)
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case oldName = "old_name"
        case newName = "new_name"
        case targetPath = "target_path"
        case changed
        case renamed
        case reason
        case category
        case confidence
        case elapsedSeconds = "elapsed_seconds"
    }
}

public final class FilenameCleanerService {
    private let cleanerURL: URL?
    private let runner: ProcessRunner

    public init(
        cleanerURL: URL? = FilenameCleanerService.defaultCleanerURL(),
        runner: ProcessRunner = ProcessRunner()
    ) {
        self.cleanerURL = cleanerURL
        self.runner = runner
    }

    public static func defaultCleanerURL(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        var candidates: [String] = []
        if let override = environment["TARE_CLEANER"], !override.isEmpty {
            candidates.append(override)
        }

        candidates.append(contentsOf: [
            "~/Library/Application Support/NameClean/clean-name-cli.py",
            "~/Experiemnts/NameCleanApp/clean-name-cli.py",
            "~/Name Clean/NameCleanApp/clean-name-cli.py"
        ])

        return candidates
            .map(expandedURL)
            .first { fileManager.fileExists(atPath: $0.path) }
    }

    public static func decodeResults(from json: String) throws -> [FilenameCleanResult] {
        guard let data = json.data(using: .utf8) else {
            throw FilenameCleanerError.invalidJSON("stdout was not UTF-8")
        }

        do {
            return try JSONDecoder().decode([FilenameCleanResult].self, from: data)
        } catch {
            throw FilenameCleanerError.invalidJSON(error.localizedDescription)
        }
    }

    public func clean(urls: [URL]) async throws -> [FilenameCleanResult] {
        guard let cleanerURL else {
            throw FilenameCleanerError.cleanerMissing
        }

        guard let pythonURL = Self.python3URL() else {
            throw FilenameCleanerError.pythonMissing
        }

        let arguments = [cleanerURL.path, "--json", "--progress", "--no-table-of-contents"] + urls.map(\.path)
        let result = try await runner.run(
            executableURL: pythonURL,
            arguments: arguments
        )
        return try Self.decodeResults(from: result.stdout)
    }

    private static func python3URL(fileManager: FileManager = .default) -> URL? {
        let candidates = [
            "/usr/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3"
        ].map { URL(fileURLWithPath: $0) }

        return candidates.first {
            fileManager.isExecutableFile(atPath: $0.path)
        }
    }
}

private func expandedURL(_ path: String) -> URL {
    let expanded = (path as NSString).expandingTildeInPath
    return URL(fileURLWithPath: expanded)
}
