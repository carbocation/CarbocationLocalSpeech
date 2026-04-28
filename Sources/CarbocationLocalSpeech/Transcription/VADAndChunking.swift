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

    public init(sensitivity: VoiceActivityDetectionSensitivity) {
        switch sensitivity {
        case .low:
            self.init(speechRMSThreshold: 0.02, minimumPeakThreshold: 0.04)
        case .medium:
            self.init()
        case .high:
            self.init(speechRMSThreshold: 0.006, minimumPeakThreshold: 0.012)
        }
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

@_spi(Internal) public struct VoiceActivitySmoothingConfiguration: Hashable, Sendable {
    public var enterSpeechDuration: TimeInterval
    public var exitSpeechDuration: TimeInterval

    public init(
        enterSpeechDuration: TimeInterval = 0.25,
        exitSpeechDuration: TimeInterval = 0.8
    ) {
        self.enterSpeechDuration = max(0, enterSpeechDuration)
        self.exitSpeechDuration = max(0, exitSpeechDuration)
    }

    public static let streamingDefault = VoiceActivitySmoothingConfiguration()
}

@_spi(Internal) public final class SmoothedVoiceActivityDetector: VoiceActivityAnalyzing, VoiceActivityDetectionStateResetting, @unchecked Sendable {
    private let detector: VoiceActivityDetecting
    private let configuration: VoiceActivitySmoothingConfiguration
    private let lock = NSLock()

    private var emittedState = VoiceActivityState.silence
    private var pendingRawState: VoiceActivityState?
    private var pendingStateStartTime: TimeInterval?
    private var pendingStateDuration: TimeInterval = 0
    private var lastInputEndTime: TimeInterval?

    public init(
        detector: VoiceActivityDetecting,
        configuration: VoiceActivitySmoothingConfiguration = .streamingDefault
    ) {
        self.detector = detector
        self.configuration = configuration
    }

    public func analyze(_ chunk: AudioChunk) throws -> VoiceActivityEvent {
        try analyzeWithDiagnostics(chunk).activity
    }

    public func analyzeWithDiagnostics(_ chunk: AudioChunk) throws -> VoiceActivityAnalysis {
        let rawActivity = try detector.analyze(chunk)

        lock.lock()
        defer { lock.unlock() }

        resetAfterDiscontinuityIfNeeded(for: chunk)
        let smoothing = applySmoothing(to: rawActivity)
        var diagnostics = [
            TranscriptionDiagnostic(
                source: "streaming.vad",
                message: "raw_vad=\(rawActivity.state.rawValue) smoothed_vad=\(smoothing.activity.state.rawValue) confidence=\(format(rawActivity.confidence)) pending=\(format(smoothing.pendingDuration))s",
                time: rawActivity.startTime
            )
        ]

        if smoothing.didTransition {
            diagnostics.append(TranscriptionDiagnostic(
                source: "streaming.vad",
                message: "smoothed_vad_transition=\(smoothing.activity.state.rawValue) raw_vad=\(rawActivity.state.rawValue) pending=\(format(smoothing.pendingDuration))s",
                time: smoothing.activity.startTime
            ))
        }

        lastInputEndTime = chunk.startTime + chunk.duration
        return VoiceActivityAnalysis(
            rawActivity: rawActivity,
            activity: smoothing.activity,
            diagnostics: diagnostics
        )
    }

    public func resetVoiceActivityState() {
        lock.lock()
        resetSmoothingState()
        lock.unlock()

        (detector as? VoiceActivityDetectionStateResetting)?.resetVoiceActivityState()
    }

    private func applySmoothing(to rawActivity: VoiceActivityEvent) -> (activity: VoiceActivityEvent, didTransition: Bool, pendingDuration: TimeInterval) {
        let rawDuration = max(0, rawActivity.endTime - rawActivity.startTime)
        if pendingRawState != rawActivity.state {
            pendingRawState = rawActivity.state
            pendingStateStartTime = rawActivity.startTime
            pendingStateDuration = 0
        }
        pendingStateDuration += rawDuration

        var didTransition = false
        var smoothedStartTime = rawActivity.startTime

        switch (emittedState, rawActivity.state) {
        case (.silence, .speech):
            if pendingStateDuration >= configuration.enterSpeechDuration {
                emittedState = .speech
                didTransition = true
                smoothedStartTime = pendingStateStartTime ?? rawActivity.startTime
            }
        case (.speech, .silence):
            if pendingStateDuration >= configuration.exitSpeechDuration {
                emittedState = .silence
                didTransition = true
                smoothedStartTime = pendingStateStartTime ?? rawActivity.startTime
            }
        default:
            break
        }

        let activity = VoiceActivityEvent(
            state: emittedState,
            startTime: smoothedStartTime,
            endTime: rawActivity.endTime,
            confidence: rawActivity.confidence
        )
        return (activity, didTransition, pendingStateDuration)
    }

    private func resetAfterDiscontinuityIfNeeded(for chunk: AudioChunk) {
        guard let lastInputEndTime else { return }
        let tolerance = audioContinuityTolerance(for: chunk)
        if chunk.startTime > lastInputEndTime + tolerance ||
            chunk.startTime + chunk.duration < lastInputEndTime - tolerance {
            resetSmoothingState()
        }
    }

    private func resetSmoothingState() {
        emittedState = .silence
        pendingRawState = nil
        pendingStateStartTime = nil
        pendingStateDuration = 0
        lastInputEndTime = nil
    }

    private func format(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.3f", value)
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
            return [emitChunk(isFinal: true, keepOverlap: false)]
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

@_spi(Internal) public struct SpeechContextualRollingWindow: Sendable {
    public enum VoiceActivityMode: Sendable {
        case turnFinals
        case leadingSilence
    }

    public struct AppendResult: Sendable {
        public var chunks: [SpeechAudioChunk]
        public var audioGap: TimeInterval?
        public var speechStartTime: TimeInterval?
        public var leadingSilenceTrimmed: TimeInterval?
        public var turnFinalTime: TimeInterval?
        public var silenceFlushTime: TimeInterval?

        public init(
            chunks: [SpeechAudioChunk],
            audioGap: TimeInterval? = nil,
            speechStartTime: TimeInterval? = nil,
            leadingSilenceTrimmed: TimeInterval? = nil,
            turnFinalTime: TimeInterval? = nil,
            silenceFlushTime: TimeInterval? = nil
        ) {
            self.chunks = chunks
            self.audioGap = audioGap
            self.speechStartTime = speechStartTime
            self.leadingSilenceTrimmed = leadingSilenceTrimmed
            self.turnFinalTime = turnFinalTime
            self.silenceFlushTime = silenceFlushTime
        }
    }

    public var maximumBufferDuration: TimeInterval
    public var updateInterval: TimeInterval
    public var finalSilenceDelay: TimeInterval
    public var preSpeechPaddingDuration: TimeInterval
    public var voiceActivityMode: VoiceActivityMode

    private var samples: [Float] = []
    private var sampleRate: Double?
    private var startTime: TimeInterval?
    private var lastEmissionEndTime: TimeInterval?
    private var silenceDuration: TimeInterval = 0
    private var usesVoiceActivity = false
    private var hasObservedSpeech = false
    private var hasActiveSpeechTurn = false
    private var hasEmittedTurnFinal = false
    private var hasEmittedSilenceFlush = false

    public init(
        maximumBufferDuration: TimeInterval,
        updateInterval: TimeInterval,
        finalSilenceDelay: TimeInterval,
        preSpeechPaddingDuration: TimeInterval = 0.5,
        voiceActivityMode: VoiceActivityMode = .turnFinals
    ) {
        self.maximumBufferDuration = max(0.1, maximumBufferDuration)
        self.updateInterval = max(0.05, updateInterval)
        self.finalSilenceDelay = max(0.05, finalSilenceDelay)
        self.preSpeechPaddingDuration = max(0, preSpeechPaddingDuration)
        self.voiceActivityMode = voiceActivityMode
    }

    public mutating func append(
        _ chunk: AudioChunk,
        activity: VoiceActivityEvent?
    ) -> AppendResult {
        var emitted: [SpeechAudioChunk] = []
        let gap = prepareForAppend(chunk)
        if gap != nil {
            if let final = emitChunk(isFinal: true, resetAfterEmit: true) {
                emitted.append(final)
            } else {
                reset()
            }
        }

        let startsSpeechTurn = activity?.state == .speech && !hasActiveSpeechTurn
        let isFirstObservedSpeech = startsSpeechTurn && !hasObservedSpeech
        appendSamples(from: chunk)
        apply(activity: activity, duration: chunk.duration)
        let leadingSilenceTrimmed = isFirstObservedSpeech
            ? trimBeforeSpeechStart(activity?.startTime ?? chunk.startTime)
            : nil
        trimIfNeeded()

        var turnFinalTime: TimeInterval?
        if shouldFinalizeForSilence, let final = emitChunk(isFinal: true, resetAfterEmit: false) {
            hasActiveSpeechTurn = false
            hasEmittedTurnFinal = true
            turnFinalTime = final.startTime + final.audio.duration
            emitted.append(final)
            return AppendResult(
                chunks: emitted,
                audioGap: gap,
                speechStartTime: startsSpeechTurn ? activity?.startTime : nil,
                leadingSilenceTrimmed: leadingSilenceTrimmed,
                turnFinalTime: turnFinalTime
            )
        }

        if shouldFlushForSilence {
            hasEmittedSilenceFlush = true
            // Decode the retained buffer once more; the queued pending flush commits the endpoint tail.
            if let endpoint = emitChunk(isFinal: false) {
                emitted.append(endpoint)
            }
            return AppendResult(
                chunks: emitted,
                audioGap: gap,
                speechStartTime: startsSpeechTurn ? activity?.startTime : nil,
                leadingSilenceTrimmed: leadingSilenceTrimmed,
                silenceFlushTime: bufferEndTime
            )
        }

        if shouldEmitUpdate, let update = emitChunk(isFinal: false) {
            emitted.append(update)
        }

        return AppendResult(
            chunks: emitted,
            audioGap: gap,
            speechStartTime: startsSpeechTurn ? activity?.startTime : nil,
            leadingSilenceTrimmed: leadingSilenceTrimmed,
            turnFinalTime: turnFinalTime
        )
    }

    public mutating func finish() -> [SpeechAudioChunk] {
        if usesVoiceActivity && !hasObservedSpeech {
            reset()
            return []
        }
        if voiceActivityMode == .turnFinals,
           usesVoiceActivity,
           !hasActiveSpeechTurn,
           hasEmittedTurnFinal {
            reset()
            return []
        }
        if voiceActivityMode == .leadingSilence,
           usesVoiceActivity,
           hasObservedSpeech,
           silenceDuration >= finalSilenceDelay {
            reset()
            return []
        }
        guard let final = emitChunk(isFinal: true, resetAfterEmit: true) else { return [] }
        return [final]
    }

    private var duration: TimeInterval {
        guard let sampleRate, sampleRate > 0 else { return 0 }
        return Double(samples.count) / sampleRate
    }

    private var bufferEndTime: TimeInterval? {
        guard let startTime else { return nil }
        return startTime + duration
    }

    private var shouldEmitUpdate: Bool {
        if usesVoiceActivity && !hasObservedSpeech {
            return false
        }
        if voiceActivityMode == .leadingSilence,
           usesVoiceActivity,
           hasObservedSpeech,
           silenceDuration >= finalSilenceDelay {
            return false
        }
        if voiceActivityMode == .turnFinals,
           usesVoiceActivity,
           !hasActiveSpeechTurn {
            return false
        }
        guard let startTime, let bufferEndTime else { return false }
        let lastEmissionEndTime = lastEmissionEndTime ?? startTime
        return bufferEndTime - lastEmissionEndTime >= updateInterval
    }

    private var shouldFinalizeForSilence: Bool {
        voiceActivityMode == .turnFinals
            && hasActiveSpeechTurn
            && !hasEmittedTurnFinal
            && silenceDuration >= finalSilenceDelay
    }

    private var shouldFlushForSilence: Bool {
        voiceActivityMode == .leadingSilence
            && usesVoiceActivity
            && hasObservedSpeech
            && !hasEmittedSilenceFlush
            && silenceDuration >= finalSilenceDelay
    }

    private mutating func appendSamples(from chunk: AudioChunk) {
        if sampleRate == nil || samples.isEmpty {
            sampleRate = chunk.sampleRate
            startTime = chunk.startTime
        }
        samples.append(contentsOf: monoSamples(from: chunk))
    }

    private mutating func apply(activity: VoiceActivityEvent?, duration: TimeInterval) {
        guard let activity else { return }
        usesVoiceActivity = true
        if activity.state == .speech {
            hasObservedSpeech = true
            hasActiveSpeechTurn = true
            hasEmittedTurnFinal = false
            hasEmittedSilenceFlush = false
            silenceDuration = 0
        } else {
            silenceDuration += duration
        }
    }

    private mutating func trimBeforeSpeechStart(_ speechStart: TimeInterval) -> TimeInterval? {
        guard let sampleRate, let startTime, sampleRate > 0 else { return nil }
        let keepStart = max(startTime, speechStart - preSpeechPaddingDuration)
        guard keepStart > startTime else { return nil }

        let droppedSamples = max(0, min(
            samples.count,
            Int(((keepStart - startTime) * sampleRate).rounded(.down))
        ))
        guard droppedSamples > 0 else { return nil }

        samples.removeFirst(droppedSamples)
        self.startTime = startTime + Double(droppedSamples) / sampleRate
        return Double(droppedSamples) / sampleRate
    }

    private mutating func trimIfNeeded() {
        guard let sampleRate, let startTime else { return }
        let maximumSamples = max(1, Int(maximumBufferDuration * sampleRate))
        guard samples.count > maximumSamples else { return }

        let droppedSamples = samples.count - maximumSamples
        samples.removeFirst(droppedSamples)
        self.startTime = startTime + Double(droppedSamples) / sampleRate
    }

    private mutating func emitChunk(isFinal: Bool, resetAfterEmit: Bool = true) -> SpeechAudioChunk? {
        guard !samples.isEmpty else {
            if isFinal && resetAfterEmit {
                reset()
            }
            return nil
        }

        let resolvedSampleRate = sampleRate ?? 16_000
        let resolvedStart = startTime ?? 0
        let prepared = PreparedAudio(
            samples: samples,
            sampleRate: resolvedSampleRate,
            duration: Double(samples.count) / resolvedSampleRate
        )
        lastEmissionEndTime = resolvedStart + prepared.duration

        if isFinal && resetAfterEmit {
            reset()
        }

        return SpeechAudioChunk(audio: prepared, startTime: resolvedStart, isFinal: isFinal)
    }

    private mutating func prepareForAppend(_ chunk: AudioChunk) -> TimeInterval? {
        if sampleRate == nil || samples.isEmpty {
            sampleRate = chunk.sampleRate
            startTime = chunk.startTime
            return nil
        }

        if let sampleRate, abs(sampleRate - chunk.sampleRate) > 0.0001 {
            return 0
        }

        guard let startTime else {
            self.startTime = chunk.startTime
            return nil
        }

        let expectedStart = startTime + duration
        let tolerance = audioContinuityTolerance(for: chunk)
        if chunk.startTime > expectedStart + tolerance ||
            chunk.startTime + chunk.duration < startTime - tolerance {
            let gap = max(0, chunk.startTime - expectedStart)
            return gap
        }

        return nil
    }

    private mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        sampleRate = nil
        startTime = nil
        lastEmissionEndTime = nil
        silenceDuration = 0
        usesVoiceActivity = false
        hasObservedSpeech = false
        hasActiveSpeechTurn = false
        hasEmittedTurnFinal = false
        hasEmittedSilenceFlush = false
    }
}
