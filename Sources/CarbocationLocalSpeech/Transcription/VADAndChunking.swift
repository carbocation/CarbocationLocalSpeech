import Foundation

private func monoSamples(from chunk: AudioChunk) -> [Float] {
    let channelCount = max(1, chunk.channelCount)
    guard channelCount > 1 else { return chunk.samples }

    let frameCount = chunk.samples.count / channelCount
    var mono: [Float] = []
    mono.reserveCapacity(frameCount)
    for frame in 0..<frameCount {
        var sample: Float = 0
        for channel in 0..<channelCount {
            sample += chunk.samples[frame * channelCount + channel]
        }
        mono.append(sample / Float(channelCount))
    }
    return mono
}

private func audioContinuityTolerance(for chunk: AudioChunk) -> TimeInterval {
    max(0.25, min(1.0, max(0.05, chunk.duration) * 2))
}

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

@_spi(Internal) public struct SpeechChunker: Sendable {
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
        prepareForAppend(chunk)

        samples.append(contentsOf: monoSamples(from: chunk))
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

    private mutating func prepareForAppend(_ chunk: AudioChunk) {
        if sampleRate == nil || samples.isEmpty {
            sampleRate = chunk.sampleRate
            startTime = chunk.startTime
            return
        }

        if let sampleRate, abs(sampleRate - chunk.sampleRate) > 0.0001 {
            reset()
            self.sampleRate = chunk.sampleRate
            startTime = chunk.startTime
            return
        }

        guard let startTime else {
            self.startTime = chunk.startTime
            return
        }

        let expectedStart = startTime + duration
        let tolerance = audioContinuityTolerance(for: chunk)
        if chunk.startTime > expectedStart + tolerance ||
            chunk.startTime + chunk.duration < startTime - tolerance {
            reset()
            sampleRate = chunk.sampleRate
            self.startTime = chunk.startTime
        }
    }

    private mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        sampleRate = nil
        startTime = nil
        silenceDuration = 0
        speechDuration = 0
    }
}

@_spi(Internal) public struct SpeechRollingWindow: Sendable {
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
        self.overlapDuration = min(max(0, overlapDuration), self.maximumBufferDuration)
    }

    public mutating func append(_ chunk: AudioChunk) -> [SpeechAudioChunk] {
        prepareForAppend(chunk)

        samples.append(contentsOf: monoSamples(from: chunk))
        trimIfNeeded()

        guard let startTime else { return [] }
        let endTime = startTime + duration
        let lastEmissionEndTime = lastEmissionEndTime ?? startTime
        guard endTime - lastEmissionEndTime >= updateInterval else {
            return []
        }

        guard let emitted = emitChunk(isFinal: false) else {
            return []
        }
        return [emitted]
    }

    public mutating func finish() -> [SpeechAudioChunk] {
        guard !samples.isEmpty else { return [] }
        guard let emitted = emitChunk(isFinal: true) else {
            reset()
            return []
        }
        return [emitted]
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

    private mutating func emitChunk(isFinal: Bool) -> SpeechAudioChunk? {
        let resolvedSampleRate = sampleRate ?? 16_000
        let bufferStart = startTime ?? 0
        let bufferEnd = bufferStart + duration
        let emissionStart: TimeInterval
        if let lastEmissionEndTime {
            emissionStart = max(bufferStart, lastEmissionEndTime - overlapDuration)
        } else {
            emissionStart = bufferStart
        }
        guard bufferEnd > emissionStart else {
            if isFinal {
                reset()
            }
            return nil
        }

        let startOffset = max(0, min(
            samples.count,
            Int(((emissionStart - bufferStart) * resolvedSampleRate).rounded(.down))
        ))
        let emittedSamples = Array(samples[startOffset...])
        let prepared = PreparedAudio(
            samples: emittedSamples,
            sampleRate: resolvedSampleRate,
            duration: Double(emittedSamples.count) / resolvedSampleRate
        )
        lastEmissionEndTime = bufferEnd

        if isFinal {
            reset()
        } else {
            samples = emittedSamples
            startTime = emissionStart
        }

        return SpeechAudioChunk(audio: prepared, startTime: emissionStart, isFinal: isFinal)
    }

    private mutating func prepareForAppend(_ chunk: AudioChunk) {
        if sampleRate == nil || samples.isEmpty {
            sampleRate = chunk.sampleRate
            startTime = chunk.startTime
            return
        }

        if let sampleRate, abs(sampleRate - chunk.sampleRate) > 0.0001 {
            reset()
            self.sampleRate = chunk.sampleRate
            startTime = chunk.startTime
            return
        }

        guard let startTime else {
            self.startTime = chunk.startTime
            return
        }

        let expectedStart = startTime + duration
        let tolerance = audioContinuityTolerance(for: chunk)
        if chunk.startTime > expectedStart + tolerance ||
            chunk.startTime + chunk.duration < startTime - tolerance {
            reset()
            sampleRate = chunk.sampleRate
            self.startTime = chunk.startTime
        }
    }

    private mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        sampleRate = nil
        startTime = nil
        lastEmissionEndTime = nil
    }
}
