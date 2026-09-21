import Foundation
import Darwin
import TranscriberCore

@main
enum TranscriberBatch {
    static func main() async {
        do {
            try await run()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            fputs("Transcription failed: \(message)\n", stderr)
            exit(1)
        }
    }

    private static func run() async throws {
        var arguments = Array(CommandLine.arguments.dropFirst())
        var outputRootDirectory = OutputFolderPlanner.defaultRootDirectory()
        var outputWasSpecified = false
        var useSourceOutputDirectory = false
        var createBatchFolder = true
        var attachCaptionedVideoToSource = true
        var modelIdentifier = WhisperModelPreset.fastMultilingual.id
        var localeIdentifier = WhisperLanguagePreset.auto.id
        var chunkSeconds = 600
        var chunkWorkerCount = 1
        var formats: Set<ExportFormat> = [.text]

        func consumeValue(after option: String) throws -> String {
            guard let optionIndex = arguments.firstIndex(of: option), optionIndex + 1 < arguments.count else {
                throw BatchError.message("Missing value for \(option)")
            }

            let value = arguments.remove(at: optionIndex + 1)
            arguments.remove(at: optionIndex)
            return value
        }

        if arguments.contains("--help") || arguments.isEmpty {
            printUsage()
            return
        }

        if arguments.contains("--output") {
            outputRootDirectory = URL(fileURLWithPath: try consumeValue(after: "--output"), isDirectory: true)
            outputWasSpecified = true
        }

        if arguments.contains("--output-source-folder") {
            arguments.removeAll { $0 == "--output-source-folder" }
            useSourceOutputDirectory = true
        }

        if arguments.contains("--flat-output") {
            arguments.removeAll { $0 == "--flat-output" }
            createBatchFolder = false
        }

        if arguments.contains("--attach-to-source") {
            arguments.removeAll { $0 == "--attach-to-source" }
            attachCaptionedVideoToSource = true
        }

        if arguments.contains("--model") {
            modelIdentifier = WhisperModelPreset.normalizedIdentifier(try consumeValue(after: "--model"))
        }

        if arguments.contains("--language") {
            localeIdentifier = try consumeValue(after: "--language")
        }

        if arguments.contains("--locale") {
            localeIdentifier = try consumeValue(after: "--locale")
        }

        if arguments.contains("--chunk-seconds") {
            chunkSeconds = Int(try consumeValue(after: "--chunk-seconds")) ?? chunkSeconds
        }

        if arguments.contains("--chunk-workers") {
            chunkWorkerCount = Int(try consumeValue(after: "--chunk-workers")) ?? chunkWorkerCount
        }

        if arguments.contains("--formats") {
            let rawFormats = try consumeValue(after: "--formats")
            let parsedFormats = Set(rawFormats.split(separator: ",").compactMap { exportFormat(from: String($0)) })
            guard !parsedFormats.isEmpty else {
                throw BatchError.message("No valid export formats in \(rawFormats)")
            }
            let textFormats = parsedFormats.intersection(textSidecarFormats)
            formats = textFormats.isEmpty ? [.text] : textFormats
        }

        let inputURLs = SupportedMedia.preferredMacCompatibleURLs(
            from: arguments.map { URL(fileURLWithPath: $0) }
        )

        guard !inputURLs.isEmpty else {
            throw BatchError.message("No supported macOS-compatible media files were provided.")
        }

        if useSourceOutputDirectory && !outputWasSpecified {
            outputRootDirectory = OutputFolderPlanner.sourceOutputRootDirectory(
                for: inputURLs,
                fallback: outputRootDirectory
            )
        }

        let outputDirectory: URL
        if createBatchFolder {
            outputDirectory = try OutputFolderPlanner.createBatchDirectory(
                rootDirectory: outputRootDirectory,
                sourceURLs: inputURLs
            )
        } else {
            outputDirectory = outputRootDirectory
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        }

        let extractor = try FFmpegAudioExtractor()
        let transcriber = try WhisperTranscriptionService()
        let exporter = TranscriptExporter()
        let transcriptLinker = TranscriptLinker()
        let captionedVideoExporter = CaptionedVideoExporter()
        let audioLyricsEmbedder = AudioLyricsEmbedder()
        let batchStartedAt = Date()

        printLine("Output folder: \(outputDirectory.path)")

        for (offset, sourceURL) in inputURLs.enumerated() {
            let fileStartedAt = Date()
            logStep("Checking audio: \(sourceURL.lastPathComponent)", offset: offset, total: inputURLs.count, startedAt: batchStartedAt)
            let audioLevel = try await extractor.measureAudioLevel(of: sourceURL)
            let effectiveModelIdentifier = WhisperModelPreset.optimizedIdentifier(
                modelIdentifier,
                languageCode: WhisperTranscriptionService.languageCode(from: localeIdentifier)
            )

            let transcript: Transcript
            if audioLevel.isEffectivelySilent {
                let maxVolumeText = audioLevel.maxVolumeDB.map { String(format: "%.1f dB", $0) } ?? "unknown"
                logStep("No audible speech detected; exporting silence note", offset: offset, total: inputURLs.count, startedAt: batchStartedAt)
                transcript = Transcript(
                    sourceName: sourceURL.lastPathComponent,
                    localeIdentifier: localeIdentifier,
                    fullText: "No audible speech detected. Maximum audio level: \(maxVolumeText).",
                    segments: []
                )
            } else {
                logStep("Extracting audio", offset: offset, total: inputURLs.count, startedAt: batchStartedAt)
                let audioURL = try await extractor.extractAudio(from: sourceURL)
                defer { try? FileManager.default.removeItem(at: audioURL) }

                logStep("Transcribing with \(effectiveModelIdentifier)", offset: offset, total: inputURLs.count, startedAt: batchStartedAt)
                transcript = try await transcriber.transcribe(
                    audioURL: audioURL,
                    sourceName: sourceURL.lastPathComponent,
                    localeIdentifier: localeIdentifier,
                    modelIdentifier: effectiveModelIdentifier,
                    chunkSeconds: WhisperModelPreset.usesLongFormInference(effectiveModelIdentifier)
                        ? 0
                        : max(0, chunkSeconds),
                    chunkWorkerCount: max(1, chunkWorkerCount),
                    wordTimestamps: true
                )
            }

            logStep("Exporting", offset: offset, total: inputURLs.count, startedAt: batchStartedAt)
            var outputURLs: [URL] = []
            let exportFormats = formats.intersection(textSidecarFormats)

            if !exportFormats.isEmpty {
                outputURLs = try await exporter.export(
                    transcript,
                    sourceURL: sourceURL,
                    to: outputDirectory,
                    formats: exportFormats
                )
            }

            let manifestURL = transcriptLinker.manifestURL(
                for: sourceURL,
                outputDirectory: outputDirectory
            )
            let linkMetadata = transcriptLinker.metadata(
                for: transcript,
                sourceURL: sourceURL,
                transcriptURLs: outputURLs,
                manifestURL: manifestURL,
                modelIdentifier: effectiveModelIdentifier
            )

            if attachCaptionedVideoToSource,
               SupportedMedia.videoExtensions.contains(sourceURL.pathExtension.lowercased()),
               !transcript.segments.isEmpty {
                logStep("Embedding subtitles in source video", offset: offset, total: inputURLs.count, startedAt: batchStartedAt)
                let attachedVideo = try await captionedVideoExporter.attachToSource(
                    sourceURL: sourceURL,
                    captions: exporter.srtDocument(for: transcript),
                    localeIdentifier: transcript.localeIdentifier
                )
                outputURLs.append(attachedVideo.outputURL)
                if attachedVideo.replacedSource {
                    printLine("  attached \(attachedVideo.outputURL.path)")
                } else {
                    printLine("  packaged \(attachedVideo.outputURL.path)")
                }
                if let backupURL = attachedVideo.backupURL {
                    printLine("  backup \(backupURL.path)")
                }
            }

            if attachCaptionedVideoToSource,
               AudioLyricsEmbedder.canAttachLyrics(to: sourceURL) {
                logStep("Embedding lyrics in source audio", offset: offset, total: inputURLs.count, startedAt: batchStartedAt)
                let attachedAudio = try await audioLyricsEmbedder.attachToSource(
                    sourceURL: sourceURL,
                    lyrics: exporter.appleMusicLyricsDocument(for: transcript),
                    linkMetadata: linkMetadata
                )
                outputURLs.append(attachedAudio.outputURL)
                printLine("  attached lyrics \(attachedAudio.outputURL.path)")
                printLine("  backup \(attachedAudio.backupURL.path)")
            }

            let writtenManifestURL = try transcriptLinker.write(linkMetadata)
            outputURLs.append(writtenManifestURL)

            for outputURL in outputURLs {
                printLine("  wrote \(outputURL.path)")
            }

            let fileElapsed = Date().timeIntervalSince(fileStartedAt)
            logCompleted("Completed \(sourceURL.lastPathComponent) in \(formatDuration(fileElapsed))", completed: offset + 1, total: inputURLs.count, startedAt: batchStartedAt)
        }
    }

    private static func printUsage() {
        print(
            """
            usage: TranscriberBatch [--output DIR] [--output-source-folder] [--flat-output] [--attach-to-source] [--model MODEL] [--language auto|CODE] [--chunk-seconds N] [--chunk-workers N] [--formats text,timestampedText] FILE...

            Supported videos and audio files are embedded automatically. Sidecar text defaults to a plain transcript; timestampedText adds the annotated text file.
            """
        )
    }

    private static func exportFormat(from rawValue: String) -> ExportFormat? {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch normalized.lowercased() {
        case "plain", "plaintext", "plain-text", "plain_transcript", "plain-transcript":
            return .text
        case "timestamped", "timestampedtext", "timestamped-text", "timestamped_transcript", "timestamped-transcript", "annotated":
            return .timestampedText
        default:
            return ExportFormat(rawValue: normalized)
        }
    }

    private static let textSidecarFormats: Set<ExportFormat> = [.text, .timestampedText]

    private static func logStep(_ message: String, offset: Int, total: Int, startedAt: Date) {
        let elapsed = Date().timeIntervalSince(startedAt)
        let eta: String
        if offset > 0 {
            let average = elapsed / Double(offset)
            eta = formatDuration(average * Double(max(total - offset, 0)))
        } else {
            eta = "estimating"
        }

        printLine("[\(min(offset + 1, total))/\(total)] \(message) | elapsed \(formatDuration(elapsed)) | eta \(eta)")
    }

    private static func logCompleted(_ message: String, completed: Int, total: Int, startedAt: Date) {
        let elapsed = Date().timeIntervalSince(startedAt)
        let average = elapsed / Double(max(completed, 1))
        let eta = average * Double(max(total - completed, 0))
        printLine("[\(completed)/\(total)] \(message) | elapsed \(formatDuration(elapsed)) | eta \(formatDuration(eta))")
    }

    private static func printLine(_ message: String) {
        print(message)
        fflush(stdout)
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let rounded = max(0, Int(seconds.rounded()))
        let hours = rounded / 3600
        let minutes = (rounded % 3600) / 60
        let seconds = rounded % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }
}

enum BatchError: Error, LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message):
            return message
        }
    }
}
