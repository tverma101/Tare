import Foundation

public enum JobStatus: String, CaseIterable, Codable, Hashable {
    case queued
    case extractingAudio
    case transcribing
    case exporting
    case completed
    case failed
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            return true
        case .queued, .extractingAudio, .transcribing, .exporting:
            return false
        }
    }

    public var displayName: String {
        switch self {
        case .queued:
            return "Queued"
        case .extractingAudio:
            return "Extracting audio"
        case .transcribing:
            return "Transcribing"
        case .exporting:
            return "Exporting"
        case .completed:
            return "Completed"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        }
    }
}

/// How far through a chunked transcription a job is.
public struct ChunkProgress: Hashable, Sendable {
    public let completed: Int
    public let total: Int

    public init(completed: Int, total: Int) {
        self.completed = completed
        self.total = total
    }
}

public struct TranscriptionJob: Identifiable, Hashable {
    public let id: UUID
    public var sourceURL: URL
    public var status: JobStatus
    public var progress: Double
    public var chunkProgress: ChunkProgress?
    public var transcript: Transcript?
    public var linkedTranscriptURL: URL?
    public var outputURLs: [URL]
    public var errorMessage: String?
    public var createdAt: Date
    public var startedAt: Date?
    public var completedAt: Date?

    public init(
        id: UUID = UUID(),
        sourceURL: URL,
        status: JobStatus = .queued,
        progress: Double = 0,
        chunkProgress: ChunkProgress? = nil,
        transcript: Transcript? = nil,
        linkedTranscriptURL: URL? = nil,
        outputURLs: [URL] = [],
        errorMessage: String? = nil,
        createdAt: Date = Date(),
        startedAt: Date? = nil,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.status = status
        self.progress = progress
        self.chunkProgress = chunkProgress
        self.transcript = transcript
        self.linkedTranscriptURL = linkedTranscriptURL
        self.outputURLs = outputURLs
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.completedAt = completedAt
    }

    public var displayName: String {
        sourceURL.deletingPathExtension().lastPathComponent
    }

    public var fileExtension: String {
        sourceURL.pathExtension.uppercased()
    }
}
