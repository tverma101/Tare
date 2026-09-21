import Foundation

public struct TranscriptWord: Codable, Hashable, Identifiable {
    public var id: UUID
    public var index: Int
    public var startTime: TimeInterval
    public var duration: TimeInterval
    public var text: String
    public var probability: Double?

    public init(
        id: UUID = UUID(),
        index: Int,
        startTime: TimeInterval,
        duration: TimeInterval,
        text: String,
        probability: Double? = nil
    ) {
        self.id = id
        self.index = index
        self.startTime = startTime
        self.duration = duration
        self.text = text
        self.probability = probability
    }

    public var endTime: TimeInterval {
        max(startTime + duration, startTime + 0.05)
    }
}

public struct TranscriptSegment: Codable, Hashable, Identifiable {
    public var id: UUID
    public var index: Int
    public var startTime: TimeInterval
    public var duration: TimeInterval
    public var text: String
    public var speaker: String?
    public var words: [TranscriptWord]

    public init(
        id: UUID = UUID(),
        index: Int,
        startTime: TimeInterval,
        duration: TimeInterval,
        text: String,
        speaker: String? = nil,
        words: [TranscriptWord] = []
    ) {
        self.id = id
        self.index = index
        self.startTime = startTime
        self.duration = duration
        self.text = text
        self.speaker = speaker
        self.words = words
    }

    public var endTime: TimeInterval {
        max(startTime + duration, startTime + 0.2)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case index
        case startTime
        case duration
        case text
        case speaker
        case words
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        index = try container.decode(Int.self, forKey: .index)
        startTime = try container.decode(TimeInterval.self, forKey: .startTime)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        text = try container.decode(String.self, forKey: .text)
        speaker = try container.decodeIfPresent(String.self, forKey: .speaker)
        words = try container.decodeIfPresent([TranscriptWord].self, forKey: .words) ?? []
    }
}

public struct Transcript: Codable, Hashable {
    public var sourceName: String
    public var createdAt: Date
    public var localeIdentifier: String
    public var fullText: String
    public var segments: [TranscriptSegment]

    public init(
        sourceName: String,
        createdAt: Date = Date(),
        localeIdentifier: String,
        fullText: String,
        segments: [TranscriptSegment]
    ) {
        self.sourceName = sourceName
        self.createdAt = createdAt
        self.localeIdentifier = localeIdentifier
        self.fullText = fullText
        self.segments = segments
    }
}
