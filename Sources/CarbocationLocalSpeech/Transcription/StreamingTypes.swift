import Foundation

public struct StreamingTranscriptionOptions: Hashable, Sendable {
    public var transcription: TranscriptionOptions
    public var implementation: StreamingImplementationPreference
    public var commitment: TranscriptCommitmentPolicy
    public var latencyPreset: SpeechLatencyPreset
    public var emulation: EmulatedStreamingOptions

    public init(
        transcription: TranscriptionOptions = TranscriptionOptions(useCase: .dictation),
        implementation: StreamingImplementationPreference = .automatic,
        commitment: TranscriptCommitmentPolicy = .automatic,
        latencyPreset: SpeechLatencyPreset = .balancedDictation,
        emulation: EmulatedStreamingOptions? = nil
    ) {
        self.transcription = transcription
        self.implementation = implementation
        self.commitment = commitment
        self.latencyPreset = latencyPreset
        self.emulation = emulation ?? latencyPreset.defaultEmulatedStreamingOptions
    }
}

public enum StreamingImplementationPreference: String, Codable, Hashable, Sendable {
    case automatic
    case native
    case emulated
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

    public var defaultEmulatedStreamingOptions: EmulatedStreamingOptions {
        switch self {
        case .lowestLatency:
            return EmulatedStreamingOptions(
                window: .rollingBuffer(maxDuration: 4.0, updateInterval: 0.75, overlap: 0.5)
            )
        case .balancedDictation:
            return EmulatedStreamingOptions(
                window: .rollingBuffer(maxDuration: 8.0, updateInterval: 1.5, overlap: 1.0)
            )
        case .accuracy:
            return EmulatedStreamingOptions(
                window: .rollingBuffer(maxDuration: 12.0, updateInterval: 2.0, overlap: 1.0)
            )
        case .fileQuality:
            return EmulatedStreamingOptions(
                window: .rollingBuffer(maxDuration: 30.0, updateInterval: 5.0, overlap: 1.5)
            )
        }
    }
}

public enum TranscriptCommitmentPolicy: Hashable, Sendable {
    case automatic
    case providerFinals
    case localAgreement(iterations: Int)
    case silence
    case immediate
}

public struct EmulatedStreamingOptions: Hashable, Sendable {
    public var window: AudioWindowingPolicy
    public var overlapDeduplication: Bool

    public init(
        window: AudioWindowingPolicy = .vadUtterances(.balancedDictation),
        overlapDeduplication: Bool = true
    ) {
        self.window = window
        self.overlapDeduplication = overlapDeduplication
    }
}

public enum AudioWindowingPolicy: Hashable, Sendable {
    case vadUtterances(SpeechChunkingConfiguration)
    case rollingBuffer(maxDuration: TimeInterval, updateInterval: TimeInterval, overlap: TimeInterval)

    public var overlapDuration: TimeInterval {
        switch self {
        case .vadUtterances(let configuration):
            return configuration.overlapDuration
        case .rollingBuffer(_, _, let overlap):
            return max(0, overlap)
        }
    }
}

public enum TranscriptEvent: Hashable, Sendable {
    case started(SpeechBackendDescriptor)
    case audioLevel(AudioLevel)
    case voiceActivity(VoiceActivityEvent)
    case diagnostic(TranscriptionDiagnostic)
    case snapshot(StreamingTranscriptSnapshot)
    case partial(TranscriptPartial)
    case revision(TranscriptRevision)
    case committed(TranscriptSegment)
    case progress(TranscriptionProgress)
    case stats(TranscriptionStats)
    case completed(Transcript)
}

public struct TranscriptionDiagnostic: Hashable, Sendable {
    public var source: String
    public var message: String
    public var time: TimeInterval?

    public init(source: String, message: String, time: TimeInterval? = nil) {
        self.source = source
        self.message = message
        self.time = time
    }
}

public struct StreamingTranscriptSnapshot: Hashable, Sendable {
    public var committed: Transcript
    public var unconfirmed: TranscriptPartial?
    public var volatileRange: TranscriptTimeRange?

    public init(
        committed: Transcript = Transcript(),
        unconfirmed: TranscriptPartial? = nil,
        volatileRange: TranscriptTimeRange? = nil
    ) {
        self.committed = committed
        self.unconfirmed = unconfirmed
        self.volatileRange = volatileRange
    }
}

public struct TranscriptTimeRange: Hashable, Sendable {
    public var startTime: TimeInterval
    public var endTime: TimeInterval

    public init(startTime: TimeInterval, endTime: TimeInterval) {
        self.startTime = startTime
        self.endTime = max(startTime, endTime)
    }
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
