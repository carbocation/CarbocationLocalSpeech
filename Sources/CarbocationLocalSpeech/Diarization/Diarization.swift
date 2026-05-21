import Foundation

public struct SpeakerID: RawRepresentable, Codable, Hashable, Sendable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct Speaker: Codable, Hashable, Sendable {
    public var id: SpeakerID
    public var displayName: String?
    public var confidence: Double?
    public var metadata: [String: String]

    public init(
        id: SpeakerID,
        displayName: String? = nil,
        confidence: Double? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.displayName = displayName
        self.confidence = confidence
        self.metadata = metadata
    }
}

public struct SpeakerTurn: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var speaker: SpeakerID
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var confidence: Double?
    public var isOverlap: Bool
    public var isExclusive: Bool
    public var source: String?

    public init(
        id: UUID = UUID(),
        speaker: SpeakerID,
        startTime: TimeInterval,
        endTime: TimeInterval,
        confidence: Double? = nil,
        isOverlap: Bool = false,
        isExclusive: Bool = false,
        source: String? = nil
    ) {
        self.id = id
        self.speaker = speaker
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
        self.isOverlap = isOverlap
        self.isExclusive = isExclusive
        self.source = source
    }
}

public struct DiarizationResult: Codable, Hashable, Sendable {
    public var turns: [SpeakerTurn]
    public var exclusiveTurns: [SpeakerTurn]
    public var speakers: [Speaker]
    public var duration: TimeInterval
    public var backend: SpeechBackendDescriptor?
    public var diagnostics: [SpeechDiagnostic]

    public init(
        turns: [SpeakerTurn],
        exclusiveTurns: [SpeakerTurn] = [],
        speakers: [Speaker],
        duration: TimeInterval,
        backend: SpeechBackendDescriptor? = nil,
        diagnostics: [SpeechDiagnostic] = []
    ) {
        self.turns = turns
        self.exclusiveTurns = exclusiveTurns
        self.speakers = speakers
        self.duration = duration
        self.backend = backend
        self.diagnostics = diagnostics
    }
}

public enum DiarizationValidationError: Error, LocalizedError, Sendable {
    case invalidValue(String)
    case conflictingBounds(String)

    public var errorDescription: String? {
        switch self {
        case .invalidValue(let details), .conflictingBounds(let details):
            return "Diarization options validation failed: \(details)"
        }
    }
}

public struct DiarizationOptions: Codable, Hashable, Sendable {
    public var minimumSpeakerCount: Int?
    public var maximumSpeakerCount: Int?
    public var exactSpeakerCount: Int?
    public var minimumTurnDuration: TimeInterval

    public init(
        minimumSpeakerCount: Int? = nil,
        maximumSpeakerCount: Int? = nil,
        exactSpeakerCount: Int? = nil,
        minimumTurnDuration: TimeInterval = 0.5
    ) {
        self.minimumSpeakerCount = minimumSpeakerCount
        self.maximumSpeakerCount = maximumSpeakerCount
        self.exactSpeakerCount = exactSpeakerCount
        self.minimumTurnDuration = minimumTurnDuration
    }

    public func validate() throws {
        guard minimumTurnDuration >= 0 else {
            throw DiarizationValidationError.invalidValue(
                "minimumTurnDuration (\(minimumTurnDuration)) cannot be negative"
            )
        }

        if let exactSpeakerCount, exactSpeakerCount <= 0 {
            throw DiarizationValidationError.invalidValue(
                "exactSpeakerCount (\(exactSpeakerCount)) must be positive"
            )
        }
        if let minimumSpeakerCount, minimumSpeakerCount <= 0 {
            throw DiarizationValidationError.invalidValue(
                "minimumSpeakerCount (\(minimumSpeakerCount)) must be positive"
            )
        }
        if let maximumSpeakerCount, maximumSpeakerCount <= 0 {
            throw DiarizationValidationError.invalidValue(
                "maximumSpeakerCount (\(maximumSpeakerCount)) must be positive"
            )
        }

        if let exactSpeakerCount {
            if let minimumSpeakerCount, exactSpeakerCount < minimumSpeakerCount {
                throw DiarizationValidationError.conflictingBounds(
                    "exactSpeakerCount (\(exactSpeakerCount)) is less than minimumSpeakerCount (\(minimumSpeakerCount))"
                )
            }
            if let maximumSpeakerCount, exactSpeakerCount > maximumSpeakerCount {
                throw DiarizationValidationError.conflictingBounds(
                    "exactSpeakerCount (\(exactSpeakerCount)) is greater than maximumSpeakerCount (\(maximumSpeakerCount))"
                )
            }
        }

        if let minimumSpeakerCount,
           let maximumSpeakerCount,
           minimumSpeakerCount > maximumSpeakerCount {
            throw DiarizationValidationError.conflictingBounds(
                "minimumSpeakerCount (\(minimumSpeakerCount)) is greater than maximumSpeakerCount (\(maximumSpeakerCount))"
            )
        }
    }
}

public protocol SpeakerDiarizer: Sendable {
    func diarize(audio: PreparedAudio, options: DiarizationOptions) async throws -> DiarizationResult
}

public extension SpeakerDiarizer {
    func diarize(file url: URL, options: DiarizationOptions) async throws -> DiarizationResult {
        let audio = try await AudioResampler16kMono().prepareFile(at: url)
        return try await diarize(audio: audio, options: options)
    }
}

public final class FileSpeakerDiarizerAdapter: SpeakerDiarizer, Sendable {
    private let urlDiarizer: @Sendable (URL, DiarizationOptions) async throws -> DiarizationResult

    public init(urlDiarizer: @escaping @Sendable (URL, DiarizationOptions) async throws -> DiarizationResult) {
        self.urlDiarizer = urlDiarizer
    }

    public func diarize(audio: PreparedAudio, options: DiarizationOptions) async throws -> DiarizationResult {
        let writer = AudioTemporaryFileWriter()
        let fileURL = try writer.write(audio: audio)
        defer {
            try? FileManager.default.removeItem(at: fileURL)
        }
        return try await urlDiarizer(fileURL, options)
    }
}

public struct MockSpeakerDiarizer: SpeakerDiarizer {
    public var result: DiarizationResult

    public init(result: DiarizationResult) {
        self.result = result
    }

    public init(turns: [SpeakerTurn], duration: TimeInterval? = nil) {
        let orderedSpeakerIDs = turns.reduce(into: [SpeakerID]()) { ids, turn in
            guard !ids.contains(turn.speaker) else { return }
            ids.append(turn.speaker)
        }
        let speakers = orderedSpeakerIDs.map { Speaker(id: $0) }
        self.result = DiarizationResult(
            turns: turns,
            exclusiveTurns: turns.filter(\.isExclusive),
            speakers: speakers,
            duration: duration ?? turns.map(\.endTime).max() ?? 0,
            backend: nil
        )
    }

    public func diarize(audio: PreparedAudio, options: DiarizationOptions) async throws -> DiarizationResult {
        _ = audio
        try options.validate()
        return result
    }
}
