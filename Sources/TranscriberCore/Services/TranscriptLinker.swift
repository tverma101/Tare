import CryptoKit
import Foundation

public enum TranscriptLinkerError: Error, LocalizedError {
    case manifestEncodingFailed

    public var errorDescription: String? {
        switch self {
        case .manifestEncodingFailed:
            return "Tare could not encode the transcript link metadata."
        }
    }
}

/// Writes and discovers the small amount of metadata needed to keep a source
/// media file associated with the transcript artifacts Tare produced for it.
///
/// The visible manifest lives beside the transcript output. A hidden pointer
/// beside the source media makes the relationship discoverable when the media
/// is imported again, while the audio exporter also embeds a compact copy in
/// standard `comment`/`description` tags for tools that do not preserve dotfiles.
public final class TranscriptLinker {
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let compactEncoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        compactEncoder = JSONEncoder()
        compactEncoder.outputFormatting = [.sortedKeys]
        compactEncoder.dateEncodingStrategy = .iso8601

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public func manifestURL(
        for sourceURL: URL,
        outputDirectory: URL,
        baseName: String? = nil
    ) -> URL {
        let resolvedBaseName = baseName.map(OutputFolderPlanner.sanitizedBaseName)
            ?? OutputFolderPlanner.transcriptBaseName(for: sourceURL)
        let preferredURL = outputDirectory
            .appendingPathComponent("\(resolvedBaseName).tare-link")
            .appendingPathExtension("json")
        return uniqueURL(for: preferredURL)
    }

    public func sourceSidecarURL(for sourceURL: URL) -> URL {
        sourceURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(sourceURL.lastPathComponent).tare-link")
            .appendingPathExtension("json")
    }

    public func metadata(
        for transcript: Transcript,
        sourceURL: URL,
        transcriptURLs: [URL],
        manifestURL: URL,
        modelIdentifier: String,
        displayName: String? = nil,
        folderName: String? = nil,
        namingProvider: String? = nil,
        namingModelIdentifier: String? = nil,
        namingStrategy: String? = nil,
        transcriptDirectoryURL: URL? = nil
    ) -> TranscriptLinkMetadata {
        let sourceValues = try? sourceURL.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey
        ])
        let sourcePath = sourceURL.standardizedFileURL.path
        let sidecarURL = sourceSidecarURL(for: sourceURL)
        let transcriptPaths = transcriptURLs.map { $0.standardizedFileURL.path }

        return TranscriptLinkMetadata(
            sourceName: sourceURL.lastPathComponent,
            sourcePath: sourcePath,
            sourceFileSize: sourceValues?.fileSize.map(Int64.init),
            sourceModifiedAt: sourceValues?.contentModificationDate,
            transcriptPaths: transcriptPaths,
            manifestPath: manifestURL.standardizedFileURL.path,
            sourceSidecarPath: sidecarURL.standardizedFileURL.path,
            transcriptSHA256: Self.sha256(for: transcript.fullText),
            modelIdentifier: modelIdentifier,
            localeIdentifier: transcript.localeIdentifier,
            createdAt: transcript.createdAt,
            displayName: displayName,
            folderName: folderName,
            namingProvider: namingProvider,
            namingModelIdentifier: namingModelIdentifier,
            namingStrategy: namingStrategy,
            transcriptDirectoryPath: transcriptDirectoryURL?.standardizedFileURL.path
        )
    }

    /// Writes the visible manifest and best-effort source-side pointer.
    ///
    /// The output manifest is authoritative and failures are surfaced. The
    /// source-side pointer is deliberately best-effort because a read-only
    /// media directory should not make an otherwise successful transcription
    /// fail after the audio has already been tagged.
    @discardableResult
    public func write(_ metadata: TranscriptLinkMetadata) throws -> URL {
        let manifestData: Data
        let sidecarData: Data
        do {
            manifestData = try encoder.encode(metadata)
            sidecarData = try compactEncoder.encode(metadata)
        } catch {
            throw TranscriptLinkerError.manifestEncodingFailed
        }

        let manifestURL = URL(fileURLWithPath: metadata.manifestPath)
        try fileManager.createDirectory(
            at: manifestURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try manifestData.write(to: manifestURL, options: [.atomic])

        let sidecarURL = URL(fileURLWithPath: metadata.sourceSidecarPath)
        if sidecarURL.standardizedFileURL.path != manifestURL.standardizedFileURL.path {
            try? sidecarData.write(to: sidecarURL, options: [.atomic])
        }

        return manifestURL
    }

    /// Finds a Tare link previously written beside the source media.
    public func existingLink(for sourceURL: URL) -> TranscriptLinkMetadata? {
        let sourcePath = sourceURL.standardizedFileURL.path
        let sourceDirectory = sourceURL.deletingLastPathComponent()
        var candidates = [sourceSidecarURL(for: sourceURL)]

        if let directoryContents = try? fileManager.contentsOfDirectory(
            at: sourceDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            candidates.append(contentsOf: directoryContents.filter {
                $0.pathExtension.lowercased() == "json"
                    && $0.lastPathComponent.hasSuffix(".tare-link.json")
            })
        }

        var seenPaths = Set<String>()
        for candidate in candidates {
            let candidatePath = candidate.standardizedFileURL.path
            guard seenPaths.insert(candidatePath).inserted else { continue }
            guard let data = try? Data(contentsOf: candidate),
                  let metadata = try? decoder.decode(TranscriptLinkMetadata.self, from: data),
                  metadata.schemaVersion <= TranscriptLinkMetadata.currentSchemaVersion else {
                continue
            }

            let samePath = metadata.sourcePath == sourcePath
            let sameName = metadata.sourceName.caseInsensitiveCompare(sourceURL.lastPathComponent) == .orderedSame
            guard samePath || sameName else { continue }
            return metadata
        }

        return nil
    }

    public static func audioMetadataComment(for metadata: TranscriptLinkMetadata) -> String {
        "Tare transcript link \(metadata.linkID.uuidString)"
    }

    public static func audioMetadataDescription(for metadata: TranscriptLinkMetadata) -> String? {
        guard let json = compactJSON(for: metadata) else { return nil }
        return "Tare transcript link metadata: \(json)"
    }

    public static func compactJSON(for metadata: TranscriptLinkMetadata) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(metadata) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func decodeEmbeddedMetadata(from value: String) -> TranscriptLinkMetadata? {
        guard let openingBrace = value.firstIndex(of: "{") else { return nil }
        let json = String(value[openingBrace...])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = json.data(using: .utf8),
              let metadata = try? decoder.decode(TranscriptLinkMetadata.self, from: data),
              metadata.schemaVersion <= TranscriptLinkMetadata.currentSchemaVersion else {
            return nil
        }
        return metadata
    }

    public static func ffmpegMetadataArguments(for metadata: TranscriptLinkMetadata) -> [String] {
        var arguments = [
            "-metadata", "comment=\(audioMetadataComment(for: metadata))"
        ]

        if let description = audioMetadataDescription(for: metadata) {
            arguments.append(contentsOf: ["-metadata", "description=\(description)"])
        }

        return arguments
    }

    private static func sha256(for value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
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
}
