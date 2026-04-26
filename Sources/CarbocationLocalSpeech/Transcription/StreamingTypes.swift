import Foundation

public struct StreamingTranscriptionOptions: Hashable, Sendable {
    public var transcription: TranscriptionOptions
    public var chunking: SpeechChunkingConfiguration
    public var partialCommitStrategy: PartialCommitStrategy
    public var latencyPreset: SpeechLatencyPreset

    public init(
        transcription: TranscriptionOptions = TranscriptionOptions(useCase: .dictation),
        chunking: SpeechChunkingConfiguration = .balancedDictation,
        partialCommitStrategy: PartialCommitStrategy = .silenceOrChunkBoundary,
        latencyPreset: SpeechLatencyPreset = .balancedDictation
    ) {
        self.transcription = transcription
        self.chunking = chunking
        self.partialCommitStrategy = partialCommitStrategy
        self.latencyPreset = latencyPreset
    }
}

public enum SpeechLatencyPreset: String, Codable, CaseIterable, Hashable, Sendable {
    case lowestLatency
    case balancedDictation
    case accuracy
    case fileQuality

    public var defaultChunkingConfiguration: SpeechChunkingConfiguration {
        switch self {
        case .lowestLatency:
            return SpeechChunkingConfiguration(maximumChunkDuration: 1.5, overlapDuration: 0.25, silenceCommitDelay: 0.35, minimumSpeechDuration: 0.15)
        case .balancedDictation:
            return .balancedDictation
        case .accuracy:
            return SpeechChunkingConfiguration(maximumChunkDuration: 8.0, overlapDuration: 1.0, silenceCommitDelay: 0.6, minimumSpeechDuration: 0.25)
        case .fileQuality:
            return SpeechChunkingConfiguration(maximumChunkDuration: 60.0, overlapDuration: 1.5, silenceCommitDelay: 1.0, minimumSpeechDuration: 0.25)
        }
    }
}

public enum PartialCommitStrategy: String, Codable, Hashable, Sendable {
    case silence
    case chunkBoundary
    case silenceOrChunkBoundary
}

public enum TranscriptEvent: Hashable, Sendable {
    case started(SpeechBackendDescriptor)
    case audioLevel(AudioLevel)
    case voiceActivity(VoiceActivityEvent)
    case partial(TranscriptPartial)
    case revision(TranscriptRevision)
    case committed(TranscriptSegment)
    case progress(TranscriptionProgress)
    case stats(TranscriptionStats)
    case completed(Transcript)
}

public struct TranscriptPartial: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var text: String
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var stability: Double?

    public init(
        id: UUID = UUID(),
        text: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        stability: Double? = nil
    ) {
        self.id = id
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.stability = stability
    }
}

public struct TranscriptRevision: Hashable, Sendable {
    public var replacesPartialID: UUID
    public var replacement: TranscriptPartial

    public init(replacesPartialID: UUID, replacement: TranscriptPartial) {
        self.replacesPartialID = replacesPartialID
        self.replacement = replacement
    }
}

public struct AudioLevel: Hashable, Sendable {
    public var rms: Float
    public var peak: Float
    public var time: TimeInterval

    public init(rms: Float, peak: Float, time: TimeInterval) {
        self.rms = rms
        self.peak = peak
        self.time = time
    }
}

public struct TranscriptionProgress: Hashable, Sendable {
    public var processedDuration: TimeInterval
    public var totalDuration: TimeInterval?
    public var fractionComplete: Double?

    public init(processedDuration: TimeInterval, totalDuration: TimeInterval? = nil, fractionComplete: Double? = nil) {
        self.processedDuration = processedDuration
        self.totalDuration = totalDuration
        self.fractionComplete = fractionComplete
    }
}

public struct TranscriptionStats: Hashable, Sendable {
    public var audioDuration: TimeInterval
    public var processingDuration: TimeInterval
    public var realTimeFactor: Double?
    public var segmentCount: Int

    public init(
        audioDuration: TimeInterval,
        processingDuration: TimeInterval,
        realTimeFactor: Double? = nil,
        segmentCount: Int
    ) {
        self.audioDuration = audioDuration
        self.processingDuration = processingDuration
        self.realTimeFactor = realTimeFactor
        self.segmentCount = segmentCount
    }
}

public enum VoiceActivityState: String, Codable, Hashable, Sendable {
    case silence
    case speech
}

public struct VoiceActivityEvent: Hashable, Sendable {
    public var state: VoiceActivityState
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var confidence: Double?

    public init(
        state: VoiceActivityState,
        startTime: TimeInterval,
        endTime: TimeInterval,
        confidence: Double? = nil
    ) {
        self.state = state
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
    }
}

public protocol VoiceActivityDetecting: Sendable {
    func analyze(_ chunk: AudioChunk) throws -> VoiceActivityEvent
}

public struct SpeechChunkingConfiguration: Hashable, Sendable {
    public var maximumChunkDuration: TimeInterval
    public var overlapDuration: TimeInterval
    public var silenceCommitDelay: TimeInterval
    public var minimumSpeechDuration: TimeInterval

    public init(
        maximumChunkDuration: TimeInterval,
        overlapDuration: TimeInterval,
        silenceCommitDelay: TimeInterval,
        minimumSpeechDuration: TimeInterval
    ) {
        self.maximumChunkDuration = maximumChunkDuration
        self.overlapDuration = min(max(0, overlapDuration), maximumChunkDuration)
        self.silenceCommitDelay = max(0, silenceCommitDelay)
        self.minimumSpeechDuration = max(0, minimumSpeechDuration)
    }

    public static let balancedDictation = SpeechChunkingConfiguration(
        maximumChunkDuration: 3.0,
        overlapDuration: 0.5,
        silenceCommitDelay: 0.45,
        minimumSpeechDuration: 0.2
    )
}

public struct SpeechAudioChunk: Hashable, Sendable {
    public var audio: PreparedAudio
    public var startTime: TimeInterval
    public var isFinal: Bool

    public init(audio: PreparedAudio, startTime: TimeInterval, isFinal: Bool) {
        self.audio = audio
        self.startTime = startTime
        self.isFinal = isFinal
    }
}
