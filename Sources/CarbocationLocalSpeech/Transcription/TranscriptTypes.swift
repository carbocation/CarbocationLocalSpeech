import Foundation

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

    public init(
        id: UUID = UUID(),
        text: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        confidence: Double? = nil
    ) {
        self.id = id
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
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

public protocol SpeechTranscriber: Sendable {
    func transcribe(file url: URL, options: TranscriptionOptions) async throws -> Transcript
    func transcribe(audio: PreparedAudio, options: TranscriptionOptions) async throws -> Transcript
    func stream(
        audio: AsyncThrowingStream<AudioChunk, Error>,
        options: StreamingTranscriptionOptions
    ) -> AsyncThrowingStream<TranscriptEvent, Error>
}
