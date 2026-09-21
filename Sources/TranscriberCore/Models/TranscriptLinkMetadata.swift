import Foundation

/// The durable relationship between a source media file and the transcript
/// artifacts produced for it by Tare.
public struct TranscriptLinkMetadata: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var linkID: UUID
    public var sourceName: String
    public var sourcePath: String
    public var sourceFileSize: Int64?
    public var sourceModifiedAt: Date?
    public var transcriptPaths: [String]
    public var manifestPath: String
    public var sourceSidecarPath: String
    public var transcriptSHA256: String
    public var modelIdentifier: String
    public var localeIdentifier: String
    public var createdAt: Date
    /// The compact, human-readable name chosen for this transcript set.
    /// Optional so manifests written by Tare 0.1.4 remain readable.
    public var displayName: String?
    public var folderName: String?
    public var namingProvider: String?
    public var namingModelIdentifier: String?
    public var namingStrategy: String?
    public var transcriptDirectoryPath: String?

    public init(
        schemaVersion: Int = TranscriptLinkMetadata.currentSchemaVersion,
        linkID: UUID = UUID(),
        sourceName: String,
        sourcePath: String,
        sourceFileSize: Int64? = nil,
        sourceModifiedAt: Date? = nil,
        transcriptPaths: [String],
        manifestPath: String,
        sourceSidecarPath: String,
        transcriptSHA256: String,
        modelIdentifier: String,
        localeIdentifier: String,
        createdAt: Date = Date(),
        displayName: String? = nil,
        folderName: String? = nil,
        namingProvider: String? = nil,
        namingModelIdentifier: String? = nil,
        namingStrategy: String? = nil,
        transcriptDirectoryPath: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.linkID = linkID
        self.sourceName = sourceName
        self.sourcePath = sourcePath
        self.sourceFileSize = sourceFileSize
        self.sourceModifiedAt = sourceModifiedAt
        self.transcriptPaths = transcriptPaths
        self.manifestPath = manifestPath
        self.sourceSidecarPath = sourceSidecarPath
        self.transcriptSHA256 = transcriptSHA256
        self.modelIdentifier = modelIdentifier
        self.localeIdentifier = localeIdentifier
        self.createdAt = createdAt
        self.displayName = displayName
        self.folderName = folderName
        self.namingProvider = namingProvider
        self.namingModelIdentifier = namingModelIdentifier
        self.namingStrategy = namingStrategy
        self.transcriptDirectoryPath = transcriptDirectoryPath
    }

    public var primaryTranscriptPath: String? {
        transcriptPaths.first
    }

    public var primaryTranscriptURL: URL? {
        guard let primaryTranscriptPath else { return nil }
        return URL(fileURLWithPath: primaryTranscriptPath)
    }
}
