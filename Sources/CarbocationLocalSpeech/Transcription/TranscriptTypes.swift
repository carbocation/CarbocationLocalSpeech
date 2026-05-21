import Foundation

public struct SpeechDiagnostic: Codable, Hashable, Sendable {
    public var source: String
    public var message: String
    public var time: TimeInterval?

    public init(source: String, message: String, time: TimeInterval? = nil) {
        self.source = source
        self.message = message
        self.time = time
    }
}

public typealias TranscriptionDiagnostic = SpeechDiagnostic

public struct Transcript: Codable, Hashable, Sendable {
    public var segments: [TranscriptSegment]
    public var language: SpeechLanguage?
    public var duration: TimeInterval?
    public var backend: SpeechBackendDescriptor?

    public init(
        segments: [TranscriptSegment] = [],
        language: SpeechLanguage? = nil,
        duration: TimeInterval? = nil,
        backend: SpeechBackendDescriptor? = nil
    ) {
        self.segments = segments
        self.language = language
        self.duration = duration
        self.backend = backend
    }

    public var text: String {
        segments.map(\.text).joined(separator: " ")
    }
}

public struct TranscriptSegment: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var text: String
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var words: [TranscriptWord]
    public var speaker: SpeakerID?
    public var confidence: Double?

    public init(
        id: UUID = UUID(),
        text: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        words: [TranscriptWord] = [],
        speaker: SpeakerID? = nil,
        confidence: Double? = nil
    ) {
        self.id = id
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.words = words
        self.speaker = speaker
        self.confidence = confidence
    }
}

public struct TranscriptWord: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var text: String
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var confidence: Double?
    public var speaker: SpeakerID?

    public init(
        id: UUID = UUID(),
        text: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        confidence: Double? = nil,
        speaker: SpeakerID? = nil
    ) {
        self.id = id
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
        self.speaker = speaker
    }
}

public enum TranscriptionUseCase: String, Codable, Hashable, Sendable {
    case general
    case dictation
    case meeting
}

public enum TranscriptionTask: String, Codable, Hashable, Sendable {
    case transcribe
    case translate
}

public enum TimestampMode: String, Codable, Hashable, Sendable {
    case segments
    case words
}

public enum VoiceActivityDetectionMode: String, Codable, Hashable, Sendable {
    case automatic
    case enabled
    case disabled
}

public enum VoiceActivityDetectionSensitivity: String, Codable, Hashable, Sendable {
    case low
    case medium
    case high
}

public struct VoiceActivityDetectionOptions: Hashable, Sendable {
    public var mode: VoiceActivityDetectionMode
    public var sensitivity: VoiceActivityDetectionSensitivity

    public init(
        mode: VoiceActivityDetectionMode = .automatic,
        sensitivity: VoiceActivityDetectionSensitivity = .medium
    ) {
        self.mode = mode
        self.sensitivity = sensitivity
    }

    public static let automatic = VoiceActivityDetectionOptions()
    public static let enabled = VoiceActivityDetectionOptions(mode: .enabled)
    public static let disabled = VoiceActivityDetectionOptions(mode: .disabled)
}

public struct TranscriptionOptions: Hashable, Sendable {
    public var useCase: TranscriptionUseCase
    public var language: String?
    public var task: TranscriptionTask
    public var timestampMode: TimestampMode
    public var initialPrompt: String?
    public var contextualStrings: [String]
    public var suppressBlankAudio: Bool
    public var temperature: Double?
    public var voiceActivityDetection: VoiceActivityDetectionOptions

    public init(
        useCase: TranscriptionUseCase = .general,
        language: String? = nil,
        task: TranscriptionTask = .transcribe,
        timestampMode: TimestampMode = .segments,
        initialPrompt: String? = nil,
        contextualStrings: [String] = [],
        suppressBlankAudio: Bool = true,
        temperature: Double? = nil,
        voiceActivityDetection: VoiceActivityDetectionOptions = .automatic
    ) {
        self.useCase = useCase
        self.language = language
        self.task = task
        self.timestampMode = timestampMode
        self.initialPrompt = initialPrompt
        self.contextualStrings = contextualStrings
        self.suppressBlankAudio = suppressBlankAudio
        self.temperature = temperature
        self.voiceActivityDetection = voiceActivityDetection
    }
}

public enum SpeakerAttributionPolicy: String, Codable, Hashable, Sendable {
    case preferExclusiveWordLevel
    case preferStandardWordLevel
    case segmentLargestOverlap
}

public struct DiarizationRequest: Codable, Hashable, Sendable {
    public var options: DiarizationOptions
    public var policy: SpeakerAttributionPolicy

    public init(
        options: DiarizationOptions = DiarizationOptions(),
        policy: SpeakerAttributionPolicy = .preferExclusiveWordLevel
    ) {
        self.options = options
        self.policy = policy
    }
}

public struct SpeechAnalysisOptions: Hashable, Sendable {
    public var transcription: TranscriptionOptions
    public var diarization: DiarizationRequest?

    public init(
        transcription: TranscriptionOptions = TranscriptionOptions(),
        diarization: DiarizationRequest? = nil
    ) {
        self.transcription = transcription
        self.diarization = diarization
    }
}

public struct StreamingDiarizationRequest: Codable, Hashable, Sendable {
    public var options: DiarizationOptions
    public var backend: StreamingDiarizationBackend
    public var emitsTentativeTurns: Bool
    public var attributionPolicy: SpeakerAttributionPolicy
    public var attributionLookbackWindow: TimeInterval
    public var attributionJitterBufferDelay: TimeInterval
    public var maximumAttributionJitterBufferDelay: TimeInterval?
    public var attributionCacheRetentionWindow: TimeInterval

    public init(
        options: DiarizationOptions = DiarizationOptions(),
        backend: StreamingDiarizationBackend = .automatic,
        emitsTentativeTurns: Bool = true,
        attributionPolicy: SpeakerAttributionPolicy = .preferStandardWordLevel,
        attributionLookbackWindow: TimeInterval = 30,
        attributionJitterBufferDelay: TimeInterval = 0.75,
        maximumAttributionJitterBufferDelay: TimeInterval? = nil,
        attributionCacheRetentionWindow: TimeInterval = 600
    ) {
        self.options = options
        self.backend = backend
        self.emitsTentativeTurns = emitsTentativeTurns
        self.attributionPolicy = attributionPolicy
        self.attributionLookbackWindow = attributionLookbackWindow
        self.attributionJitterBufferDelay = attributionJitterBufferDelay
        self.maximumAttributionJitterBufferDelay = maximumAttributionJitterBufferDelay.map { max(0, $0) }
        self.attributionCacheRetentionWindow = max(0, attributionCacheRetentionWindow)
    }

    private enum CodingKeys: String, CodingKey {
        case options
        case backend
        case emitsTentativeTurns
        case attributionPolicy
        case attributionLookbackWindow
        case attributionJitterBufferDelay
        case maximumAttributionJitterBufferDelay
        case attributionCacheRetentionWindow
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        options = try container.decodeIfPresent(DiarizationOptions.self, forKey: .options) ?? DiarizationOptions()
        backend = try container.decodeIfPresent(StreamingDiarizationBackend.self, forKey: .backend) ?? .automatic
        emitsTentativeTurns = try container.decodeIfPresent(Bool.self, forKey: .emitsTentativeTurns) ?? true
        attributionPolicy = try container.decodeIfPresent(
            SpeakerAttributionPolicy.self,
            forKey: .attributionPolicy
        ) ?? .preferStandardWordLevel
        attributionLookbackWindow = try container.decodeIfPresent(
            TimeInterval.self,
            forKey: .attributionLookbackWindow
        ) ?? 30
        attributionJitterBufferDelay = try container.decodeIfPresent(
            TimeInterval.self,
            forKey: .attributionJitterBufferDelay
        ) ?? 0.75
        maximumAttributionJitterBufferDelay = try container.decodeIfPresent(
            TimeInterval.self,
            forKey: .maximumAttributionJitterBufferDelay
        ).map { max(0, $0) }
        attributionCacheRetentionWindow = max(0, try container.decodeIfPresent(
            TimeInterval.self,
            forKey: .attributionCacheRetentionWindow
        ) ?? 600)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(options, forKey: .options)
        try container.encode(backend, forKey: .backend)
        try container.encode(emitsTentativeTurns, forKey: .emitsTentativeTurns)
        try container.encode(attributionPolicy, forKey: .attributionPolicy)
        try container.encode(attributionLookbackWindow, forKey: .attributionLookbackWindow)
        try container.encode(attributionJitterBufferDelay, forKey: .attributionJitterBufferDelay)
        try container.encodeIfPresent(maximumAttributionJitterBufferDelay, forKey: .maximumAttributionJitterBufferDelay)
        try container.encode(attributionCacheRetentionWindow, forKey: .attributionCacheRetentionWindow)
    }

    public var streamingOptions: StreamingDiarizationOptions {
        StreamingDiarizationOptions(
            options: options,
            backend: backend,
            emitsTentativeTurns: emitsTentativeTurns
        )
    }
}

public enum StreamingAudioBacklogPolicy: String, Codable, Hashable, Sendable {
    case fatal
    case dropDiarization
}

public struct StreamingSpeechAnalysisOptions: Hashable, Sendable {
    public var transcription: StreamingTranscriptionOptions
    public var diarization: StreamingDiarizationRequest?
    public var audioFanOutBufferLimit: Int
    public var backlogPolicy: StreamingAudioBacklogPolicy

    public init(
        transcription: StreamingTranscriptionOptions = StreamingTranscriptionOptions(),
        diarization: StreamingDiarizationRequest? = nil,
        audioFanOutBufferLimit: Int = 128,
        backlogPolicy: StreamingAudioBacklogPolicy = .fatal
    ) {
        self.transcription = transcription
        self.diarization = diarization
        self.audioFanOutBufferLimit = max(1, audioFanOutBufferLimit)
        self.backlogPolicy = backlogPolicy
    }
}

public enum SpeechAnalysisError: Error, LocalizedError, Sendable {
    case unsupportedFeature(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFeature(let details):
            return "Unsupported speech analysis feature: \(details)"
        }
    }
}

public struct SpeechAnalysisResult: Codable, Hashable, Sendable {
    public var transcript: Transcript?
    public var diarization: DiarizationResult?
    public var speakerAttributedTranscript: Transcript?
    public var diagnostics: [SpeechDiagnostic]

    public init(
        transcript: Transcript? = nil,
        diarization: DiarizationResult? = nil,
        speakerAttributedTranscript: Transcript? = nil,
        diagnostics: [SpeechDiagnostic] = []
    ) {
        self.transcript = transcript
        self.diarization = diarization
        self.speakerAttributedTranscript = speakerAttributedTranscript
        self.diagnostics = diagnostics
    }
}

public enum StreamingSpeechAnalysisEvent: Hashable, Sendable {
    case transcription(TranscriptEvent)
    case diarization(StreamingDiarizationSnapshot)
    case speakerAttributedSnapshot(StreamingTranscriptSnapshot)
    case completed(SpeechAnalysisResult)
}

public protocol SpeechTranscriber: Sendable {
    func transcribe(file url: URL, options: TranscriptionOptions) async throws -> Transcript
    func transcribe(audio: PreparedAudio, options: TranscriptionOptions) async throws -> Transcript
    func stream(
        audio: AsyncThrowingStream<AudioChunk, Error>,
        options: StreamingTranscriptionOptions
    ) -> AsyncThrowingStream<TranscriptEvent, Error>
}
