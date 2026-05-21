import Foundation

public struct AudioChunk: Hashable, Sendable {
    public var samples: [Float]
    public var sampleRate: Double
    public var channelCount: Int
    public var startTime: TimeInterval
    public var duration: TimeInterval
    public var recoveryEvent: AudioCaptureRecoveryEvent?

    public init(
        samples: [Float],
        sampleRate: Double,
        channelCount: Int,
        startTime: TimeInterval,
        duration: TimeInterval? = nil,
        recoveryEvent: AudioCaptureRecoveryEvent? = nil
    ) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.channelCount = max(1, channelCount)
        self.startTime = startTime
        self.duration = duration ?? Double(samples.count) / Double(self.channelCount) / sampleRate
        self.recoveryEvent = recoveryEvent
    }
}

public enum AudioCaptureRecoveryReason: String, Codable, CaseIterable, Hashable, Sendable {
    case engineConfigurationChanged
    case routeChanged
    case interruptionEnded
    case mediaServicesLost
    case mediaServicesReset
}

public struct AudioCaptureRecoveryEvent: Hashable, Sendable {
    public var reason: AudioCaptureRecoveryReason
    public var attemptCount: Int
    public var unavailableDuration: TimeInterval?
    public var message: String?

    public init(
        reason: AudioCaptureRecoveryReason,
        attemptCount: Int,
        unavailableDuration: TimeInterval? = nil,
        message: String? = nil
    ) {
        self.reason = reason
        self.attemptCount = max(1, attemptCount)
        self.unavailableDuration = unavailableDuration.map { max(0, $0) }
        self.message = message
    }
}

public struct AudioCaptureResilienceConfiguration: Hashable, Sendable {
    public var isEnabled: Bool
    public var retainedBufferDuration: TimeInterval
    public var maximumConsecutiveRecoveryAttempts: Int
    public var recoveryDebounceDuration: TimeInterval
    public var initialRecoveryDelay: TimeInterval
    public var maximumRecoveryDelay: TimeInterval

    public init(
        isEnabled: Bool = true,
        retainedBufferDuration: TimeInterval = 2.0,
        maximumConsecutiveRecoveryAttempts: Int = 5,
        recoveryDebounceDuration: TimeInterval = 0.075,
        initialRecoveryDelay: TimeInterval = 0.1,
        maximumRecoveryDelay: TimeInterval = 2.0
    ) {
        self.isEnabled = isEnabled
        self.retainedBufferDuration = max(0.1, retainedBufferDuration)
        self.maximumConsecutiveRecoveryAttempts = max(1, maximumConsecutiveRecoveryAttempts)
        self.recoveryDebounceDuration = min(0.1, max(0.05, recoveryDebounceDuration))
        self.initialRecoveryDelay = max(0.01, initialRecoveryDelay)
        self.maximumRecoveryDelay = max(self.initialRecoveryDelay, maximumRecoveryDelay)
    }

    @_spi(Internal) public func retryDelay(afterFailedAttempt attempt: Int) -> TimeInterval {
        let exponent = max(0, min(10, attempt - 1))
        let multiplier = pow(2.0, Double(exponent))
        return min(maximumRecoveryDelay, initialRecoveryDelay * multiplier)
    }
}

public struct AudioCaptureConfiguration: Hashable, Sendable {
    public var preferredSampleRate: Double
    public var preferredChannelCount: Int
    public var frameDuration: TimeInterval
    public var configuresApplicationAudioSession: Bool
    public var resilience: AudioCaptureResilienceConfiguration

    public init(
        preferredSampleRate: Double = 16_000,
        preferredChannelCount: Int = 1,
        frameDuration: TimeInterval = 0.1,
        configuresApplicationAudioSession: Bool = true,
        resilience: AudioCaptureResilienceConfiguration = AudioCaptureResilienceConfiguration()
    ) {
        self.preferredSampleRate = preferredSampleRate
        self.preferredChannelCount = preferredChannelCount
        self.frameDuration = frameDuration
        self.configuresApplicationAudioSession = configuresApplicationAudioSession
        self.resilience = resilience
    }
}

public enum AudioCaptureError: Error, LocalizedError, Sendable {
    case microphonePermissionDenied
    case microphonePermissionRestricted
    case audioSessionConfigurationFailed(String)
    case inputRouteUnavailable
    case unrecoverableInterruption(String)
    case recoveryAttemptsExhausted(String)

    public var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone permission is denied."
        case .microphonePermissionRestricted:
            return "Microphone permission is restricted."
        case .audioSessionConfigurationFailed(let detail):
            return "Could not configure the audio session: \(detail)"
        case .inputRouteUnavailable:
            return "No usable microphone input route is available."
        case .unrecoverableInterruption(let detail):
            return "Audio capture interruption could not be resumed: \(detail)"
        case .recoveryAttemptsExhausted(let detail):
            return "Audio capture recovery failed: \(detail)"
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
