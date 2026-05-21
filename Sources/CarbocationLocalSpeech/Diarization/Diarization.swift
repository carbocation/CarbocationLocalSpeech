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
    public var speakerVoiceEmbeddings: [SpeakerVoiceEmbedding]
    public var duration: TimeInterval
    public var backend: SpeechBackendDescriptor?
    public var diagnostics: [SpeechDiagnostic]

    public init(
        turns: [SpeakerTurn],
        exclusiveTurns: [SpeakerTurn] = [],
        speakers: [Speaker],
        speakerVoiceEmbeddings: [SpeakerVoiceEmbedding] = [],
        duration: TimeInterval,
        backend: SpeechBackendDescriptor? = nil,
        diagnostics: [SpeechDiagnostic] = []
    ) {
        self.turns = turns
        self.exclusiveTurns = exclusiveTurns
        self.speakers = speakers
        self.speakerVoiceEmbeddings = speakerVoiceEmbeddings
        self.duration = duration
        self.backend = backend
        self.diagnostics = diagnostics
    }

    private enum CodingKeys: String, CodingKey {
        case turns
        case exclusiveTurns
        case speakers
        case speakerVoiceEmbeddings
        case duration
        case backend
        case diagnostics
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        turns = try container.decode([SpeakerTurn].self, forKey: .turns)
        exclusiveTurns = try container.decodeIfPresent([SpeakerTurn].self, forKey: .exclusiveTurns) ?? []
        speakers = try container.decode([Speaker].self, forKey: .speakers)
        speakerVoiceEmbeddings = try container.decodeIfPresent(
            [SpeakerVoiceEmbedding].self,
            forKey: .speakerVoiceEmbeddings
        ) ?? []
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        backend = try container.decodeIfPresent(SpeechBackendDescriptor.self, forKey: .backend)
        diagnostics = try container.decodeIfPresent([SpeechDiagnostic].self, forKey: .diagnostics) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(turns, forKey: .turns)
        try container.encode(exclusiveTurns, forKey: .exclusiveTurns)
        try container.encode(speakers, forKey: .speakers)
        try container.encode(speakerVoiceEmbeddings, forKey: .speakerVoiceEmbeddings)
        try container.encode(duration, forKey: .duration)
        try container.encodeIfPresent(backend, forKey: .backend)
        try container.encode(diagnostics, forKey: .diagnostics)
    }
}

public extension DiarizationResult {
    static let empty = DiarizationResult(turns: [], speakers: [], duration: 0)
}

public enum StreamingDiarizationBackend: String, Codable, Hashable, Sendable {
    case automatic
    case sortformer
    case lsEEND
}

public struct StreamingDiarizationOptions: Codable, Hashable, Sendable {
    public var options: DiarizationOptions
    public var backend: StreamingDiarizationBackend
    public var emitsTentativeTurns: Bool

    public init(
        options: DiarizationOptions = DiarizationOptions(),
        backend: StreamingDiarizationBackend = .automatic,
        emitsTentativeTurns: Bool = true
    ) {
        self.options = options
        self.backend = backend
        self.emitsTentativeTurns = emitsTentativeTurns
    }
}

public struct StreamingDiarizationSnapshot: Codable, Hashable, Sendable {
    public var stable: DiarizationResult
    public var volatile: DiarizationResult?
    public var volatileRange: TranscriptTimeRange?

    public init(
        stable: DiarizationResult = .empty,
        volatile: DiarizationResult? = nil,
        volatileRange: TranscriptTimeRange? = nil
    ) {
        self.stable = stable
        self.volatile = volatile
        self.volatileRange = volatileRange
    }

    public var diarization: DiarizationResult {
        guard let volatile, !volatile.turns.isEmpty else {
            return stable
        }

        let combinedTurns = stable.turns + volatile.turns
        let combinedExclusiveTurns = stable.exclusiveTurns + volatile.exclusiveTurns
        let referencedSpeakerIDs = (combinedTurns + combinedExclusiveTurns).reduce(into: [SpeakerID]()) { ids, turn in
            guard !ids.contains(turn.speaker) else { return }
            ids.append(turn.speaker)
        }
        let availableSpeakers = stable.speakers + volatile.speakers
        let speakers = referencedSpeakerIDs.map { speakerID in
            availableSpeakers.first { $0.id == speakerID } ?? Speaker(id: speakerID)
        }
        let availableVoiceEmbeddings = stable.speakerVoiceEmbeddings + volatile.speakerVoiceEmbeddings
        let speakerVoiceEmbeddings = referencedSpeakerIDs.compactMap { speakerID in
            availableVoiceEmbeddings.last { $0.speaker == speakerID }
        }

        return DiarizationResult(
            turns: combinedTurns,
            exclusiveTurns: combinedExclusiveTurns,
            speakers: speakers,
            speakerVoiceEmbeddings: speakerVoiceEmbeddings,
            duration: max(stable.duration, volatile.duration),
            backend: stable.backend ?? volatile.backend,
            diagnostics: stable.diagnostics + volatile.diagnostics
        )
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
    func diarize(file url: URL, options: DiarizationOptions) async throws -> DiarizationResult
    func diarize(audio: PreparedAudio, options: DiarizationOptions) async throws -> DiarizationResult
}

public protocol StreamingSpeakerDiarizer: Sendable {
    func stream(
        audio: AsyncThrowingStream<AudioChunk, Error>,
        options: StreamingDiarizationOptions
    ) -> AsyncThrowingStream<StreamingDiarizationSnapshot, Error>
}

public protocol DiarizationModelLifecycle: Sendable {
    func unloadModels() async throws
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

    public func diarize(file url: URL, options: DiarizationOptions) async throws -> DiarizationResult {
        try await urlDiarizer(url, options)
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

public struct MockStreamingSpeakerDiarizer: StreamingSpeakerDiarizer {
    public var snapshots: [StreamingDiarizationSnapshot]

    public init(snapshots: [StreamingDiarizationSnapshot]) {
        self.snapshots = snapshots
    }

    public init(turns: [SpeakerTurn], duration: TimeInterval? = nil) {
        let orderedSpeakerIDs = turns.reduce(into: [SpeakerID]()) { ids, turn in
            guard !ids.contains(turn.speaker) else { return }
            ids.append(turn.speaker)
        }
        let speakers = orderedSpeakerIDs.map { Speaker(id: $0) }
        self.snapshots = [
            StreamingDiarizationSnapshot(stable: DiarizationResult(
                turns: turns,
                exclusiveTurns: turns.filter(\.isExclusive),
                speakers: speakers,
                duration: duration ?? turns.map(\.endTime).max() ?? 0
            ))
        ]
    }

    public func stream(
        audio: AsyncThrowingStream<AudioChunk, Error>,
        options: StreamingDiarizationOptions
    ) -> AsyncThrowingStream<StreamingDiarizationSnapshot, Error> {
        let snapshots = snapshots
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try options.options.validate()
                    for try await _ in audio {
                        try Task.checkCancellation()
                    }
                    for snapshot in snapshots {
                        continuation.yield(snapshot)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
