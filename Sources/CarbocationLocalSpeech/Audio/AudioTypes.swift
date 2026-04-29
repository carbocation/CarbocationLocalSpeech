import Foundation

public struct AudioChunk: Hashable, Sendable {
    public var samples: [Float]
    public var sampleRate: Double
    public var channelCount: Int
    public var startTime: TimeInterval
    public var duration: TimeInterval

    public init(
        samples: [Float],
        sampleRate: Double,
        channelCount: Int,
        startTime: TimeInterval,
        duration: TimeInterval? = nil
    ) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.channelCount = max(1, channelCount)
        self.startTime = startTime
        self.duration = duration ?? Double(samples.count) / Double(self.channelCount) / sampleRate
    }
}

public struct AudioCaptureConfiguration: Hashable, Sendable {
    public var preferredSampleRate: Double
    public var preferredChannelCount: Int
    public var frameDuration: TimeInterval
    public var configuresApplicationAudioSession: Bool

    public init(
        preferredSampleRate: Double = 16_000,
        preferredChannelCount: Int = 1,
        frameDuration: TimeInterval = 0.1,
        configuresApplicationAudioSession: Bool = true
    ) {
        self.preferredSampleRate = preferredSampleRate
        self.preferredChannelCount = preferredChannelCount
        self.frameDuration = frameDuration
        self.configuresApplicationAudioSession = configuresApplicationAudioSession
    }
}

public enum AudioCaptureError: Error, LocalizedError, Sendable {
    case microphonePermissionDenied
    case microphonePermissionRestricted
    case audioSessionConfigurationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone permission is denied."
        case .microphonePermissionRestricted:
            return "Microphone permission is restricted."
        case .audioSessionConfigurationFailed(let detail):
            return "Could not configure the audio session: \(detail)"
        }
    }
}

public protocol AudioCapturing: Sendable {
    func start(configuration: AudioCaptureConfiguration) -> AsyncThrowingStream<AudioChunk, Error>
    func stop()
}

public protocol AudioPreparing: Sendable {
    func prepareFile(at url: URL) async throws -> PreparedAudio
    func prepareChunk(_ chunk: AudioChunk) throws -> AudioChunk
}

public struct PreparedAudio: Hashable, Sendable {
    public var samples: [Float]
    public var sampleRate: Double
    public var duration: TimeInterval

    public init(samples: [Float], sampleRate: Double, duration: TimeInterval? = nil) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.duration = duration ?? Double(samples.count) / sampleRate
    }
}

public enum MicrophonePermissionStatus: String, Codable, Hashable, Sendable {
    case notDetermined
    case denied
    case authorized
    case restricted
    case unknown
}
