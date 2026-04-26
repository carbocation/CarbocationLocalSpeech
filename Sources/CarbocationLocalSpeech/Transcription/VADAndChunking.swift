import Foundation

public struct EnergyVoiceActivityDetector: VoiceActivityDetecting {
    public var speechRMSThreshold: Float
    public var minimumPeakThreshold: Float

    public init(speechRMSThreshold: Float = 0.012, minimumPeakThreshold: Float = 0.02) {
        self.speechRMSThreshold = speechRMSThreshold
        self.minimumPeakThreshold = minimumPeakThreshold
    }

    public func analyze(_ chunk: AudioChunk) throws -> VoiceActivityEvent {
        let level = AudioLevelMeter.measure(samples: chunk.samples, time: chunk.startTime)
        let isSpeech = level.rms >= speechRMSThreshold || level.peak >= minimumPeakThreshold
        let confidence: Double
        if isSpeech {
            confidence = min(1, Double(max(level.rms / max(0.000_001, speechRMSThreshold), level.peak / max(0.000_001, minimumPeakThreshold))))
        } else {
            confidence = max(0, 1 - Double(level.rms / max(0.000_001, speechRMSThreshold)))
        }
        return VoiceActivityEvent(
            state: isSpeech ? .speech : .silence,
            startTime: chunk.startTime,
            endTime: chunk.startTime + chunk.duration,
            confidence: confidence
        )
    }
}

public struct SpeechChunker: Sendable {
    public var configuration: SpeechChunkingConfiguration

    private var samples: [Float] = []
    private var sampleRate: Double?
    private var startTime: TimeInterval?
    private var silenceDuration: TimeInterval = 0
    private var speechDuration: TimeInterval = 0

    public init(configuration: SpeechChunkingConfiguration = .balancedDictation) {
        self.configuration = configuration
    }

    public mutating func append(
        _ chunk: AudioChunk,
        activity: VoiceActivityEvent
    ) -> [SpeechAudioChunk] {
        if sampleRate == nil {
            sampleRate = chunk.sampleRate
            startTime = chunk.startTime
        }

        samples.append(contentsOf: chunk.samples)
        if activity.state == .speech {
            speechDuration += chunk.duration
            silenceDuration = 0
        } else {
            silenceDuration += chunk.duration
        }

        let currentDuration = duration
        if currentDuration >= configuration.maximumChunkDuration,
           speechDuration >= configuration.minimumSpeechDuration {
            return [emitChunk(isFinal: false)]
        }

        if silenceDuration >= configuration.silenceCommitDelay,
           speechDuration >= configuration.minimumSpeechDuration {
            return [emitChunk(isFinal: true)]
        }

        if silenceDuration >= configuration.silenceCommitDelay,
           speechDuration < configuration.minimumSpeechDuration {
            reset()
        }

        return []
    }

    public mutating func finish() -> [SpeechAudioChunk] {
        guard !samples.isEmpty else { return [] }
        return [emitChunk(isFinal: true, keepOverlap: false)]
    }

    private var duration: TimeInterval {
        guard let sampleRate, sampleRate > 0 else { return 0 }
        return Double(samples.count) / sampleRate
    }

    private mutating func emitChunk(isFinal: Bool, keepOverlap: Bool = true) -> SpeechAudioChunk {
        let resolvedSampleRate = sampleRate ?? 16_000
        let resolvedStart = startTime ?? 0
        let prepared = PreparedAudio(
            samples: samples,
            sampleRate: resolvedSampleRate,
            duration: Double(samples.count) / resolvedSampleRate
        )
        let emitted = SpeechAudioChunk(audio: prepared, startTime: resolvedStart, isFinal: isFinal)

        let overlapSamples = keepOverlap ? Int(configuration.overlapDuration * resolvedSampleRate) : 0
        if overlapSamples > 0, samples.count > overlapSamples {
            samples = Array(samples.suffix(overlapSamples))
            startTime = resolvedStart + max(0, prepared.duration - configuration.overlapDuration)
            speechDuration = min(configuration.overlapDuration, speechDuration)
            silenceDuration = 0
        } else {
            reset()
        }

        return emitted
    }

    private mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        sampleRate = nil
        startTime = nil
        silenceDuration = 0
        speechDuration = 0
    }
}

public struct SpeechRollingWindow: Sendable {
    public var maximumBufferDuration: TimeInterval
    public var updateInterval: TimeInterval
    public var overlapDuration: TimeInterval

    private var samples: [Float] = []
    private var sampleRate: Double?
    private var startTime: TimeInterval?
    private var lastEmissionEndTime: TimeInterval?

    public init(
        maximumBufferDuration: TimeInterval,
        updateInterval: TimeInterval,
        overlapDuration: TimeInterval
    ) {
        self.maximumBufferDuration = max(0.1, maximumBufferDuration)
        self.updateInterval = max(0.05, updateInterval)
        self.overlapDuration = max(0, overlapDuration)
    }

    public mutating func append(_ chunk: AudioChunk) -> [SpeechAudioChunk] {
        if sampleRate == nil {
            sampleRate = chunk.sampleRate
            startTime = chunk.startTime
        }

        samples.append(contentsOf: chunk.samples)
        trimIfNeeded()

        guard let startTime else { return [] }
        let endTime = startTime + duration
        let lastEmissionEndTime = lastEmissionEndTime ?? startTime
        guard endTime - lastEmissionEndTime >= updateInterval else {
            return []
        }

        return [emitChunk(isFinal: false)]
    }

    public mutating func finish() -> [SpeechAudioChunk] {
        guard !samples.isEmpty else { return [] }
        return [emitChunk(isFinal: true)]
    }

    private var duration: TimeInterval {
        guard let sampleRate, sampleRate > 0 else { return 0 }
        return Double(samples.count) / sampleRate
    }

    private mutating func trimIfNeeded() {
        guard let sampleRate, let startTime else { return }
        let maximumSamples = max(1, Int(maximumBufferDuration * sampleRate))
        guard samples.count > maximumSamples else { return }

        let droppedSamples = samples.count - maximumSamples
        samples.removeFirst(droppedSamples)
        self.startTime = startTime + Double(droppedSamples) / sampleRate
    }

    private mutating func emitChunk(isFinal: Bool) -> SpeechAudioChunk {
        let resolvedSampleRate = sampleRate ?? 16_000
        let resolvedStart = startTime ?? 0
        let prepared = PreparedAudio(
            samples: samples,
            sampleRate: resolvedSampleRate,
            duration: Double(samples.count) / resolvedSampleRate
        )
        lastEmissionEndTime = resolvedStart + prepared.duration

        if isFinal {
            reset()
        }

        return SpeechAudioChunk(audio: prepared, startTime: resolvedStart, isFinal: isFinal)
    }

    private mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        sampleRate = nil
        startTime = nil
        lastEmissionEndTime = nil
    }
}
