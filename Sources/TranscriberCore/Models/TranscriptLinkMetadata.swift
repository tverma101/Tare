import Foundation

/// The durable relationship between a source media file and the transcript
/// artifacts produced for it by Tare.
public struct TranscriptLinkMetadata: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

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
        createdAt: Date = Date()
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
    }

    public var primaryTranscriptPath: String? {
        transcriptPaths.first
    }

    public var primaryTranscriptURL: URL? {
        guard let primaryTranscriptPath else { return nil }
        return URL(fileURLWithPath: primaryTranscriptPath)
    }
}
