import Foundation

public enum AudioLyricsEmbedderError: Error, LocalizedError {
    case ffmpegMissing
    case emptyLyrics
    case unsupportedSourceContainer(String)
    case muxFailed(String)
    case replacementFailed(String)

    public var errorDescription: String? {
        switch self {
        case .ffmpegMissing:
            return "ffmpeg was not found. Install it with Homebrew or add it to /opt/homebrew/bin/ffmpeg."
        case .emptyLyrics:
            return "No lyrics were available to embed in the audio file."
        case .unsupportedSourceContainer(let fileExtension):
            return "Direct lyrics attachment is not supported for .\(fileExtension) files."
        case .muxFailed(let reason):
            return "Audio lyrics embedding failed: \(reason)"
        case .replacementFailed(let reason):
            return "Audio lyrics replacement failed: \(reason)"
        }
    }
}

public struct AttachedAudioLyrics: Hashable, Sendable {
    public var outputURL: URL
    public var backupURL: URL
    public var replacedSource: Bool

    public init(outputURL: URL, backupURL: URL, replacedSource: Bool) {
        self.outputURL = outputURL
        self.backupURL = backupURL
        self.replacedSource = replacedSource
    }
}

public final class AudioLyricsEmbedder {
    private let fileManager: FileManager
    private let runner: ProcessRunner
    private let ffmpegURL: URL?

    public init(
        fileManager: FileManager = .default,
        runner: ProcessRunner = ProcessRunner(),
        ffmpegURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.runner = runner
        self.ffmpegURL = ffmpegURL
    }

    public static func canAttachLyrics(to sourceURL: URL) -> Bool {
        supportedLyricsExtensions.contains(sourceURL.pathExtension.lowercased())
    }

    public func attachToSource(
        sourceURL: URL,
        lyrics: String,
        linkMetadata: TranscriptLinkMetadata? = nil
    ) async throws -> AttachedAudioLyrics {
        guard let resolvedFFmpegURL = ffmpegURL ?? FFmpegAudioExtractor.resolveExecutable(named: "ffmpeg") else {
            throw AudioLyricsEmbedderError.ffmpegMissing
        }

        let sourceExtension = sourceURL.pathExtension.lowercased()
        guard Self.canAttachLyrics(to: sourceURL) else {
            throw AudioLyricsEmbedderError.unsupportedSourceContainer(sourceExtension.isEmpty ? "file" : sourceExtension)
        }

        let cleanedLyrics = lyrics.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedLyrics.isEmpty else {
            throw AudioLyricsEmbedderError.emptyLyrics
        }

        let sourceDirectory = sourceURL.deletingLastPathComponent()
        let workingDirectory = sourceDirectory
            .appendingPathComponent(".TareWorking", isDirectory: true)
        try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)

        let temporaryURL = workingDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(sourceExtension)
        defer {
            try? fileManager.removeItem(at: temporaryURL)
            try? fileManager.removeItem(at: workingDirectory)
        }

        do {
            _ = try await runner.run(
                executableURL: resolvedFFmpegURL,
                arguments: Self.ffmpegArguments(
                    sourceURL: sourceURL,
                    lyrics: cleanedLyrics,
                    destinationURL: temporaryURL,
                    linkMetadata: linkMetadata
                ),
                environment: WhisperTranscriptionService.transcriptionEnvironment()
            )
        } catch {
            throw AudioLyricsEmbedderError.muxFailed(error.localizedDescription)
        }

        let backupURL = uniqueBackupURL(for: sourceURL)
        do {
            try fileManager.createDirectory(
                at: backupURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(at: sourceURL, to: backupURL)
            try fileManager.moveItem(at: temporaryURL, to: sourceURL)
        } catch {
            if !fileManager.fileExists(atPath: sourceURL.path),
               fileManager.fileExists(atPath: backupURL.path) {
                try? fileManager.moveItem(at: backupURL, to: sourceURL)
            }
            throw AudioLyricsEmbedderError.replacementFailed(error.localizedDescription)
        }

        return AttachedAudioLyrics(
            outputURL: sourceURL,
            backupURL: backupURL,
            replacedSource: true
        )
    }

    private static func ffmpegArguments(
        sourceURL: URL,
        lyrics: String,
        destinationURL: URL,
        linkMetadata: TranscriptLinkMetadata?
    ) -> [String] {
        var arguments = [
            "-hide_banner",
            "-loglevel", "error",
            "-nostdin",
            "-y",
            "-i", sourceURL.path,
            "-map", "0",
            "-c", "copy",
            "-metadata", "lyrics=\(lyrics)"
        ]

        if let linkMetadata {
            arguments.append(contentsOf: TranscriptLinker.ffmpegMetadataArguments(for: linkMetadata))
        }

        if destinationURL.pathExtension.lowercased() == "mp3" {
            arguments.append(contentsOf: ["-id3v2_version", "3"])
        }

        arguments.append(destinationURL.path)
        return arguments
    }

    private func uniqueBackupURL(for sourceURL: URL) -> URL {
        let backupDirectory = sourceURL
            .deletingLastPathComponent()
            .appendingPathComponent("Original Audio Backups", isDirectory: true)
        let timestamp = Self.backupDateFormatter.string(from: Date())
        let baseURL = backupDirectory
            .appendingPathComponent("\(sourceURL.deletingPathExtension().lastPathComponent).original-\(timestamp)")
            .appendingPathExtension(sourceURL.pathExtension)

        return uniqueURL(for: baseURL)
    }

    private func uniqueURL(for preferredURL: URL) -> URL {
        guard fileManager.fileExists(atPath: preferredURL.path) else {
            return preferredURL
        }

        let baseURL = preferredURL.deletingPathExtension()
        let pathExtension = preferredURL.pathExtension

        for index in 2...999 {
            let candidate = baseURL
                .deletingLastPathComponent()
                .appendingPathComponent("\(baseURL.lastPathComponent)-\(index)")
                .appendingPathExtension(pathExtension)

            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return baseURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(baseURL.lastPathComponent)-\(UUID().uuidString)")
            .appendingPathExtension(pathExtension)
    }

    private static let supportedLyricsExtensions: Set<String> = [
        "caf", "m4a", "mp3"
    ]

    private static let backupDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
