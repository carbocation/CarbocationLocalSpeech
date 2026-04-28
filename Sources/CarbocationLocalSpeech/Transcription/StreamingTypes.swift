import Foundation

public struct StreamingTranscriptionOptions: Hashable, Sendable {
    public var transcription: TranscriptionOptions
    public var strategy: StreamingTranscriptionStrategy
    @_spi(Internal) public var implementation: StreamingImplementationPreference
    @_spi(Internal) public var commitment: TranscriptCommitmentPolicy
    @_spi(Internal) public var emulation: EmulatedStreamingOptions

    public init(
        transcription: TranscriptionOptions = TranscriptionOptions(useCase: .dictation),
        strategy: StreamingTranscriptionStrategy = .automatic
    ) {
        self.transcription = transcription
        self.strategy = strategy
        self.implementation = .automatic
        self.commitment = .automatic
        self.emulation = strategy.defaultEmulatedStreamingOptions
    }

    @_spi(Internal) public init(
        transcription: TranscriptionOptions = TranscriptionOptions(useCase: .dictation),
        strategy: StreamingTranscriptionStrategy = .automatic,
        implementation: StreamingImplementationPreference = .automatic,
        commitment: TranscriptCommitmentPolicy = .automatic,
        emulation: EmulatedStreamingOptions? = nil
    ) {
        self.transcription = transcription
        self.strategy = strategy
        self.implementation = implementation
        self.commitment = commitment
        self.emulation = emulation ?? strategy.defaultEmulatedStreamingOptions
    }

    @_spi(Internal) public init(
        transcription: TranscriptionOptions = TranscriptionOptions(useCase: .dictation),
        commitment: TranscriptCommitmentPolicy,
        strategy: StreamingTranscriptionStrategy = .automatic,
        implementation: StreamingImplementationPreference = .automatic,
        emulation: EmulatedStreamingOptions? = nil
    ) {
        self.transcription = transcription
        self.strategy = strategy
        self.implementation = implementation
        self.commitment = commitment
        self.emulation = emulation ?? strategy.defaultEmulatedStreamingOptions
    }
}

public enum StreamingTranscriptionStrategy: String, Codable, CaseIterable, Hashable, Sendable {
    case automatic
    case lowestLatency
    case balanced
    case accurate
    case fileQuality

    @_spi(Internal) public var defaultChunkingConfiguration: SpeechChunkingConfiguration {
        switch self {
        case .automatic, .balanced:
            return .balancedDictation
        case .lowestLatency:
            return SpeechChunkingConfiguration(maximumChunkDuration: 1.5, overlapDuration: 0.25, silenceCommitDelay: 0.35, minimumSpeechDuration: 0.15)
        case .accurate:
            return SpeechChunkingConfiguration(maximumChunkDuration: 8.0, overlapDuration: 1.0, silenceCommitDelay: 0.6, minimumSpeechDuration: 0.25)
        case .fileQuality:
            return SpeechChunkingConfiguration(maximumChunkDuration: 60.0, overlapDuration: 1.5, silenceCommitDelay: 1.0, minimumSpeechDuration: 0.25)
        }
    }

    @_spi(Internal) public var defaultEmulatedStreamingOptions: EmulatedStreamingOptions {
        switch self {
        case .automatic, .balanced:
            return EmulatedStreamingOptions(
                window: .rollingBuffer(maxDuration: 8.0, updateInterval: 1.5, overlap: 1.0)
            )
        case .lowestLatency:
            return EmulatedStreamingOptions(
                window: .rollingBuffer(maxDuration: 4.0, updateInterval: 0.75, overlap: 0.5)
            )
        case .accurate:
            return EmulatedStreamingOptions(
                window: .rollingBuffer(maxDuration: 12.0, updateInterval: 2.0, overlap: 1.0)
            )
        case .fileQuality:
            return EmulatedStreamingOptions(
                window: .rollingBuffer(maxDuration: 30.0, updateInterval: 5.0, overlap: 1.5)
            )
        }
    }

    @_spi(Internal) public var defaultContextualStreamingOptions: EmulatedStreamingOptions {
        switch self {
        case .automatic, .balanced:
            return EmulatedStreamingOptions(
                window: .contextualRollingBuffer(maxDuration: 20.0, updateInterval: 2.0, finalSilenceDelay: 0.8)
            )
        case .lowestLatency:
            return EmulatedStreamingOptions(
                window: .contextualRollingBuffer(maxDuration: 6.0, updateInterval: 1.0, finalSilenceDelay: 0.5)
            )
        case .accurate:
            return EmulatedStreamingOptions(
                window: .contextualRollingBuffer(maxDuration: 20.0, updateInterval: 3.0, finalSilenceDelay: 1.0)
            )
        case .fileQuality:
            return EmulatedStreamingOptions(
                window: .contextualRollingBuffer(maxDuration: 30.0, updateInterval: 5.0, finalSilenceDelay: 1.2)
            )
        }
    }
}

@_spi(Internal) public enum StreamingImplementationPreference: String, Codable, Hashable, Sendable {
    case automatic
    case native
    case emulated
}

@_spi(Internal) public enum TranscriptCommitmentPolicy: Hashable, Sendable {
    case automatic
    case providerFinals
    case localAgreement(iterations: Int)
    case silence
    case immediate
}

@_spi(Internal) public struct EmulatedStreamingOptions: Hashable, Sendable {
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

@_spi(Internal) public enum AudioWindowingPolicy: Hashable, Sendable {
    case vadUtterances(SpeechChunkingConfiguration)
    case rollingBuffer(maxDuration: TimeInterval, updateInterval: TimeInterval, overlap: TimeInterval)
    case contextualRollingBuffer(maxDuration: TimeInterval, updateInterval: TimeInterval, finalSilenceDelay: TimeInterval)

    public var overlapDuration: TimeInterval {
        switch self {
        case .vadUtterances(let configuration):
            return configuration.overlapDuration
        case .rollingBuffer(_, _, let overlap):
            return max(0, overlap)
        case .contextualRollingBuffer(let maxDuration, _, _):
            return max(0, maxDuration)
        }
    }
}

public enum TranscriptEvent: Hashable, Sendable {
    case started(SpeechBackendDescriptor)
    case audioLevel(AudioLevel)
    case voiceActivity(VoiceActivityEvent)
    case diagnostic(TranscriptionDiagnostic)
    case snapshot(StreamingTranscriptSnapshot)
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
    public var stable: Transcript
    public var volatile: Transcript?
    public var volatileRange: TranscriptTimeRange?

    public init(
        stable: Transcript = Transcript(),
        volatile: Transcript? = nil,
        volatileRange: TranscriptTimeRange? = nil
    ) {
        self.stable = stable
        self.volatile = volatile
        self.volatileRange = volatileRange
    }

    public var transcript: Transcript {
        guard let volatile, !volatile.segments.isEmpty else {
            return stable
        }
        return Transcript(
            segments: stable.segments + volatile.segments,
            language: stable.language ?? volatile.language,
            duration: volatile.duration ?? stable.duration,
            backend: stable.backend ?? volatile.backend
        )
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

@_spi(Internal) public struct VoiceActivityAnalysis: Sendable {
    public var rawActivity: VoiceActivityEvent
    public var activity: VoiceActivityEvent
    public var diagnostics: [TranscriptionDiagnostic]

    public init(
        rawActivity: VoiceActivityEvent,
        activity: VoiceActivityEvent,
        diagnostics: [TranscriptionDiagnostic] = []
    ) {
        self.rawActivity = rawActivity
        self.activity = activity
        self.diagnostics = diagnostics
    }
}

@_spi(Internal) public protocol VoiceActivityAnalyzing: VoiceActivityDetecting {
    func analyzeWithDiagnostics(_ chunk: AudioChunk) throws -> VoiceActivityAnalysis
}

@_spi(Internal) public protocol VoiceActivityDetectionStateResetting: Sendable {
    func resetVoiceActivityState()
}

@_spi(Internal) public struct SpeechChunkingConfiguration: Hashable, Sendable {
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

@_spi(Internal) public struct SpeechAudioChunk: Hashable, Sendable {
    public var audio: PreparedAudio
    public var startTime: TimeInterval
    public var isFinal: Bool
    public var frontierLowEnergyDuration: TimeInterval

    public init(
        audio: PreparedAudio,
        startTime: TimeInterval,
        isFinal: Bool,
        frontierLowEnergyDuration: TimeInterval = 0
    ) {
        self.audio = audio
        self.startTime = startTime
        self.isFinal = isFinal
        self.frontierLowEnergyDuration = frontierLowEnergyDuration
    }
}
