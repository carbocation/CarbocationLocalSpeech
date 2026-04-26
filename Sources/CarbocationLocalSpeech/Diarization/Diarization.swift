import Foundation

public struct SpeakerID: RawRepresentable, Codable, Hashable, Sendable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct SpeakerTurn: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var speaker: SpeakerID
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var confidence: Double?

    public init(
        id: UUID = UUID(),
        speaker: SpeakerID,
        startTime: TimeInterval,
        endTime: TimeInterval,
        confidence: Double? = nil
    ) {
        self.id = id
        self.speaker = speaker
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
    }
}

public protocol SpeakerDiarizer: Sendable {
    func diarize(file url: URL, options: DiarizationOptions) async throws -> [SpeakerTurn]
}

public struct DiarizationOptions: Hashable, Sendable {
    public var minimumSpeakerCount: Int?
    public var maximumSpeakerCount: Int?
    public var minimumTurnDuration: TimeInterval

    public init(
        minimumSpeakerCount: Int? = nil,
        maximumSpeakerCount: Int? = nil,
        minimumTurnDuration: TimeInterval = 0.5
    ) {
        self.minimumSpeakerCount = minimumSpeakerCount
        self.maximumSpeakerCount = maximumSpeakerCount
        self.minimumTurnDuration = minimumTurnDuration
    }
}

public enum SpeakerAttributionMerger {
    public static func merge(
        transcript: Transcript,
        speakerTurns: [SpeakerTurn],
        minimumOverlap: TimeInterval = 0.05
    ) -> Transcript {
        var copy = transcript
        copy.segments = transcript.segments.map { segment in
            var resolved = segment
            resolved.speaker = bestSpeaker(
                forStart: segment.startTime,
                end: segment.endTime,
                speakerTurns: speakerTurns,
                minimumOverlap: minimumOverlap
            )
            return resolved
        }
        return copy
    }

    private static func bestSpeaker(
        forStart start: TimeInterval,
        end: TimeInterval,
        speakerTurns: [SpeakerTurn],
        minimumOverlap: TimeInterval
    ) -> SpeakerID? {
        speakerTurns
            .map { turn -> (SpeakerTurn, TimeInterval) in
                let overlap = max(0, min(end, turn.endTime) - max(start, turn.startTime))
                return (turn, overlap)
            }
            .filter { $0.1 >= minimumOverlap }
            .max { lhs, rhs in lhs.1 < rhs.1 }?
            .0
            .speaker
    }
}

public struct MockSpeakerDiarizer: SpeakerDiarizer {
    public var turns: [SpeakerTurn]

    public init(turns: [SpeakerTurn]) {
        self.turns = turns
    }

    public func diarize(file url: URL, options: DiarizationOptions) async throws -> [SpeakerTurn] {
        _ = url
        _ = options
        return turns
    }
}
