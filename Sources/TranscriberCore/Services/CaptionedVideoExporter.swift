import Foundation

public enum CaptionedVideoExporterError: Error, LocalizedError {
    case ffmpegMissing
    case emptyCaptions
    case unsupportedSourceContainer(String)
    case muxFailed(String)
    case replacementFailed(String)

    public var errorDescription: String? {
        switch self {
        case .ffmpegMissing:
            return "ffmpeg was not found. Install it with Homebrew or add it to /opt/homebrew/bin/ffmpeg."
        case .emptyCaptions:
            return "No subtitle cues were available to embed in the video."
        case .unsupportedSourceContainer(let fileExtension):
            return "Direct subtitle attachment is not supported for .\(fileExtension) files."
        case .muxFailed(let reason):
            return "Captioned video export failed: \(reason)"
        case .replacementFailed(let reason):
            return "Captioned video replacement failed: \(reason)"
        }
    }
}

public struct AttachedCaptionedVideo: Hashable, Sendable {
    public var outputURL: URL
    public var backupURL: URL?
    public var replacedSource: Bool

    public init(outputURL: URL, backupURL: URL?, replacedSource: Bool) {
        self.outputURL = outputURL
        self.backupURL = backupURL
        self.replacedSource = replacedSource
    }
}

public final class CaptionedVideoExporter {
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

    public static func preferredOutputExtension(for sourceURL: URL) -> String {
        // IINA is mpv-based and handles Matroska subtitle flags reliably.
        // MP4/mov_text subtitle tracks can be embedded, but ffmpeg does not
        // reliably preserve the default subtitle disposition in MP4 files.
        return "mkv"
    }

    public func export(
        sourceURL: URL,
        captions: String,
        localeIdentifier: String,
        to destinationURL: URL
    ) async throws -> URL {
        guard let resolvedFFmpegURL = ffmpegURL ?? FFmpegAudioExtractor.resolveExecutable(named: "ffmpeg") else {
            throw CaptionedVideoExporterError.ffmpegMissing
        }

        guard !captions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CaptionedVideoExporterError.emptyCaptions
        }

        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("Tare", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        let captionsURL = temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("srt")
        try captions.write(to: captionsURL, atomically: true, encoding: .utf8)
        defer { try? fileManager.removeItem(at: captionsURL) }

        let arguments = Self.ffmpegArguments(
            sourceURL: sourceURL,
            captionsURL: captionsURL,
            destinationURL: destinationURL,
            languageCode: Self.ffmpegLanguageCode(from: localeIdentifier)
        )

        do {
            if destinationURL.pathExtension.lowercased() == "mkv" {
                let muxedURL = temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("mkv")
                defer { try? fileManager.removeItem(at: muxedURL) }

                _ = try await runner.run(
                    executableURL: resolvedFFmpegURL,
                    arguments: Self.ffmpegArguments(
                        sourceURL: sourceURL,
                        captionsURL: captionsURL,
                        destinationURL: muxedURL,
                        languageCode: Self.ffmpegLanguageCode(from: localeIdentifier)
                    ),
                    environment: WhisperTranscriptionService.transcriptionEnvironment()
                )

                _ = try await runner.run(
                    executableURL: resolvedFFmpegURL,
                    arguments: Self.defaultSubtitleRemuxArguments(
                        sourceURL: muxedURL,
                        destinationURL: destinationURL
                    ),
                    environment: WhisperTranscriptionService.transcriptionEnvironment()
                )
            } else {
                _ = try await runner.run(
                    executableURL: resolvedFFmpegURL,
                    arguments: arguments,
                    environment: WhisperTranscriptionService.transcriptionEnvironment()
                )
            }
            try validateOutputFile(destinationURL)
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw CaptionedVideoExporterError.muxFailed(error.localizedDescription)
        }

        return destinationURL
    }

    public func attachToSource(
        sourceURL: URL,
        captions: String,
        localeIdentifier: String
    ) async throws -> AttachedCaptionedVideo {
        let sourceExtension = sourceURL.pathExtension.lowercased()
        guard SupportedMedia.videoExtensions.contains(sourceExtension) else {
            throw CaptionedVideoExporterError.unsupportedSourceContainer(sourceExtension.isEmpty ? "file" : sourceExtension)
        }

        let sourceDirectory = sourceURL.deletingLastPathComponent()
        let shouldReplaceSource = Self.canReplaceSourceContainer(sourceExtension)
        let outputExtension = shouldReplaceSource ? sourceExtension : Self.preferredOutputExtension(for: sourceURL)
        let workingDirectory = sourceDirectory
            .appendingPathComponent(".TareWorking", isDirectory: true)
        try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)

        let temporaryURL = workingDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(outputExtension)
        defer {
            try? fileManager.removeItem(at: temporaryURL)
            try? fileManager.removeItem(at: workingDirectory)
        }

        _ = try await export(
            sourceURL: sourceURL,
            captions: captions,
            localeIdentifier: localeIdentifier,
            to: temporaryURL
        )

        if shouldReplaceSource {
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
                throw CaptionedVideoExporterError.replacementFailed(error.localizedDescription)
            }

            return AttachedCaptionedVideo(
                outputURL: sourceURL,
                backupURL: backupURL,
                replacedSource: true
            )
        }

        let preferredURL = sourceDirectory
            .appendingPathComponent("\(sourceURL.deletingPathExtension().lastPathComponent).captioned")
            .appendingPathExtension(outputExtension)
        let destinationURL = uniqueURL(for: preferredURL)
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        return AttachedCaptionedVideo(
            outputURL: destinationURL,
            backupURL: nil,
            replacedSource: false
        )
    }

    private static func canReplaceSourceContainer(_ fileExtension: String) -> Bool {
        fileExtension == "mkv"
    }

    private static func ffmpegArguments(
        sourceURL: URL,
        captionsURL: URL,
        destinationURL: URL,
        languageCode: String
    ) -> [String] {
        let destinationExtension = destinationURL.pathExtension.lowercased()
        let subtitleCodec = destinationExtension == "mkv" ? "srt" : "mov_text"
        var arguments = [
            "-hide_banner",
            "-loglevel", "error",
            "-nostdin",
            "-y",
            "-i", sourceURL.path,
            "-f", "srt",
            "-i", captionsURL.path,
            "-map", "0:v:0",
            "-map", "0:a?",
            "-map", "1:0",
            "-c:v", "copy",
            "-c:a", "copy",
            "-c:s", subtitleCodec,
            "-disposition:s:0", "default",
            "-metadata:s:s:0", "language=\(languageCode)",
            "-metadata:s:s:0", "title=Transcript",
            "-metadata:s:s:0", "handler_name=Transcript"
        ]

        if destinationExtension != "mkv" {
            arguments.append(contentsOf: ["-movflags", "+faststart"])
        }

        arguments.append(destinationURL.path)
        return arguments
    }

    private static func defaultSubtitleRemuxArguments(
        sourceURL: URL,
        destinationURL: URL
    ) -> [String] {
        [
            "-hide_banner",
            "-loglevel", "error",
            "-nostdin",
            "-y",
            "-i", sourceURL.path,
            "-map", "0",
            "-c", "copy",
            "-disposition:s:0", "default",
            "-metadata:s:s:0", "title=Transcript",
            "-metadata:s:s:0", "handler_name=Transcript",
            destinationURL.path
        ]
    }

    private static func ffmpegLanguageCode(from identifier: String) -> String {
        guard let language = WhisperTranscriptionService.languageCode(from: identifier) else {
            return "und"
        }

        return [
            "ar": "ara",
            "de": "deu",
            "en": "eng",
            "es": "spa",
            "fr": "fra",
            "hi": "hin",
            "ja": "jpn",
            "ko": "kor",
            "pt": "por",
            "ru": "rus",
            "zh": "zho"
        ][language] ?? language
    }

    private func uniqueBackupURL(for sourceURL: URL) -> URL {
        let backupDirectory = sourceURL
            .deletingLastPathComponent()
            .appendingPathComponent("Original Video Backups", isDirectory: true)
        let timestamp = Self.backupDateFormatter.string(from: Date())
        let baseURL = backupDirectory
            .appendingPathComponent("\(sourceURL.deletingPathExtension().lastPathComponent).original-\(timestamp)")
            .appendingPathExtension(sourceURL.pathExtension)

        return uniqueURL(for: baseURL)
    }

    private func uniqueURL(for preferredURL: URL) -> URL {
        guard !fileManager.fileExists(atPath: preferredURL.path) else {
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

        return preferredURL
    }

    private func validateOutputFile(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path),
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.int64Value > 0 else {
            throw CaptionedVideoExporterError.muxFailed("ffmpeg produced an empty output file")
        }
    }

    private static let backupDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
