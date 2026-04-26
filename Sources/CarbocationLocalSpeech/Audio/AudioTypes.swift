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
        self.duration = duration ?? Double(samples.count / max(1, channelCount)) / sampleRate
    }
}

public struct AudioCaptureConfiguration: Hashable, Sendable {
    public var preferredSampleRate: Double
    public var preferredChannelCount: Int
    public var frameDuration: TimeInterval

    public init(
        preferredSampleRate: Double = 16_000,
        preferredChannelCount: Int = 1,
        frameDuration: TimeInterval = 0.1
    ) {
        self.preferredSampleRate = preferredSampleRate
        self.preferredChannelCount = preferredChannelCount
        self.frameDuration = frameDuration
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
