import AudioToolbox
import AVFoundation
import CoreMedia
import Foundation
import OSLog

private let audioCaptureLog = Logger(
    subsystem: "com.carbocation.CarbocationLocalSpeech",
    category: "AudioCapture"
)

public enum AudioPreparationError: Error, LocalizedError, Sendable {
    case unreadableAudio(URL)
    case unsupportedFormat(String)

    public var errorDescription: String? {
        switch self {
        case .unreadableAudio(let url):
            return "Could not read audio at \(url.lastPathComponent)."
        case .unsupportedFormat(let detail):
            return "Unsupported audio format: \(detail)"
        }
    }
}

public struct AVAssetAudioFileReader: Sendable {
    public init() {}

    public func prepareFile(at url: URL) async throws -> PreparedAudio {
        do {
            return try await prepareWithAssetReader(at: url)
        } catch {
            return try prepareWithAudioFile(at: url)
        }
    }

    private func prepareWithAudioFile(at url: URL) throws -> PreparedAudio {
        let audioFile = try AVAudioFile(forReading: url)
        let frameCount = AVAudioFrameCount(max(0, min(Int64(UInt32.max), audioFile.length)))
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: audioFile.processingFormat,
            frameCapacity: frameCount
        ) else {
            throw AudioPreparationError.unreadableAudio(url)
        }
        try audioFile.read(into: buffer)
        guard let channels = buffer.floatChannelData else {
            throw AudioPreparationError.unsupportedFormat("Expected floating-point PCM.")
        }

        let channelCount = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        var mono: [Float] = []
        mono.reserveCapacity(frames)
        for frame in 0..<frames {
            var sample: Float = 0
            for channel in 0..<channelCount {
                sample += channels[channel][frame]
            }
            mono.append(sample / Float(max(1, channelCount)))
        }

        return PreparedAudio(
            samples: mono,
            sampleRate: buffer.format.sampleRate,
            duration: Double(frames) / buffer.format.sampleRate
        )
    }

    private func prepareWithAssetReader(at url: URL) async throws -> PreparedAudio {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw AudioPreparationError.unsupportedFormat("No audio track.")
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: Self.assetReaderOutputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw AudioPreparationError.unsupportedFormat("Could not create an audio track reader.")
        }
        reader.add(output)

        guard reader.startReading() else {
            throw reader.error ?? AudioPreparationError.unreadableAudio(url)
        }

        var mono: [Float] = []
        var sampleRate: Double?
        while let sampleBuffer = output.copyNextSampleBuffer() {
            try appendMonoSamples(from: sampleBuffer, to: &mono, sampleRate: &sampleRate)
        }

        if reader.status == .failed {
            throw reader.error ?? AudioPreparationError.unreadableAudio(url)
        }
        guard let sampleRate, sampleRate > 0 else {
            throw AudioPreparationError.unsupportedFormat("Missing audio sample rate.")
        }

        return PreparedAudio(
            samples: mono,
            sampleRate: sampleRate,
            duration: Double(mono.count) / sampleRate
        )
    }

    private func appendMonoSamples(
        from sampleBuffer: CMSampleBuffer,
        to mono: inout [Float],
        sampleRate: inout Double?
    ) throws {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescriptionPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else {
            throw AudioPreparationError.unsupportedFormat("Missing audio stream description.")
        }

        let streamDescription = streamDescriptionPointer.pointee
        guard streamDescription.mFormatID == kAudioFormatLinearPCM,
              streamDescription.mBitsPerChannel == 32,
              streamDescription.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              streamDescription.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        else {
            throw AudioPreparationError.unsupportedFormat("Expected interleaved 32-bit float PCM.")
        }

        let channelCount = max(1, Int(streamDescription.mChannelsPerFrame))
        if sampleRate == nil {
            sampleRate = streamDescription.mSampleRate
        }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return
        }

        let byteCount = CMBlockBufferGetDataLength(blockBuffer)
        guard byteCount > 0 else { return }

        var data = Data(count: byteCount)
        try data.withUnsafeMutableBytes { bytes in
            guard let destination = bytes.baseAddress else { return }
            let status = CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: byteCount,
                destination: destination
            )
            guard status == noErr else {
                throw AudioPreparationError.unsupportedFormat("Could not copy decoded audio sample buffer.")
            }
        }

        data.withUnsafeBytes { bytes in
            let floatSamples = bytes.bindMemory(to: Float.self)
            let frameCount = floatSamples.count / channelCount
            mono.reserveCapacity(mono.count + frameCount)
            for frame in 0..<frameCount {
                var sample: Float = 0
                for channel in 0..<channelCount {
                    sample += floatSamples[frame * channelCount + channel]
                }
                mono.append(sample / Float(channelCount))
            }
        }
    }

    private static let assetReaderOutputSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false
    ]
}

public struct AudioResampler16kMono: AudioPreparing {
    public var targetSampleRate: Double
    private let reader: AVAssetAudioFileReader

    public init(targetSampleRate: Double = 16_000, reader: AVAssetAudioFileReader = AVAssetAudioFileReader()) {
        self.targetSampleRate = targetSampleRate
        self.reader = reader
    }

    public func prepareFile(at url: URL) async throws -> PreparedAudio {
        let prepared = try await reader.prepareFile(at: url)
        let chunk = AudioChunk(
            samples: prepared.samples,
            sampleRate: prepared.sampleRate,
            channelCount: 1,
            startTime: 0,
            duration: prepared.duration
        )
        let resampled = try prepareChunk(chunk)
        return PreparedAudio(
            samples: resampled.samples,
            sampleRate: resampled.sampleRate,
            duration: resampled.duration
        )
    }

    public func prepareChunk(_ chunk: AudioChunk) throws -> AudioChunk {
        let mono = mixToMono(chunk.samples, channelCount: chunk.channelCount)
        guard chunk.sampleRate > 0, targetSampleRate > 0 else {
            throw AudioPreparationError.unsupportedFormat("Sample rate must be positive.")
        }
        guard abs(chunk.sampleRate - targetSampleRate) > 0.0001 else {
            return AudioChunk(
                samples: mono,
                sampleRate: targetSampleRate,
                channelCount: 1,
                startTime: chunk.startTime,
                duration: Double(mono.count) / targetSampleRate,
                recoveryEvent: chunk.recoveryEvent
            )
        }

        let ratio = targetSampleRate / chunk.sampleRate
        let outputCount = max(0, Int((Double(mono.count) * ratio).rounded()))
        guard outputCount > 0 else {
            return AudioChunk(
                samples: [],
                sampleRate: targetSampleRate,
                channelCount: 1,
                startTime: chunk.startTime,
                duration: 0,
                recoveryEvent: chunk.recoveryEvent
            )
        }

        var output = Array(repeating: Float(0), count: outputCount)
        for index in output.indices {
            let sourcePosition = Double(index) / ratio
            let lower = min(mono.count - 1, max(0, Int(sourcePosition.rounded(.down))))
            let upper = min(mono.count - 1, lower + 1)
            let fraction = Float(sourcePosition - Double(lower))
            output[index] = mono[lower] + (mono[upper] - mono[lower]) * fraction
        }

        return AudioChunk(
            samples: output,
            sampleRate: targetSampleRate,
            channelCount: 1,
            startTime: chunk.startTime,
            duration: Double(output.count) / targetSampleRate,
            recoveryEvent: chunk.recoveryEvent
        )
    }

    private func mixToMono(_ samples: [Float], channelCount: Int) -> [Float] {
        let channelCount = max(1, channelCount)
        guard channelCount > 1 else { return samples }
        let frameCount = samples.count / channelCount
        var mono: [Float] = []
        mono.reserveCapacity(frameCount)
        for frame in 0..<frameCount {
            var sample: Float = 0
            for channel in 0..<channelCount {
                sample += samples[frame * channelCount + channel]
            }
            mono.append(sample / Float(channelCount))
        }
        return mono
    }
}

public enum AudioLevelMeter {
    public static func measure(samples: [Float], time: TimeInterval = 0) -> AudioLevel {
        guard !samples.isEmpty else {
            return AudioLevel(rms: 0, peak: 0, time: time)
        }
        var sumSquares: Float = 0
        var peak: Float = 0
        for sample in samples {
            let magnitude = abs(sample)
            peak = max(peak, magnitude)
            sumSquares += sample * sample
        }
        return AudioLevel(
            rms: sqrt(sumSquares / Float(samples.count)),
            peak: peak,
            time: time
        )
    }
}

private final class CaptureTiming: @unchecked Sendable {
    private let lock = NSLock()
    private var nextStartTime: TimeInterval = 0

    func advance(by duration: TimeInterval) {
        guard duration.isFinite, duration > 0 else { return }
        lock.lock()
        nextStartTime += duration
        lock.unlock()
    }

    func claim(duration: TimeInterval) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        let start = nextStartTime
        nextStartTime += duration
        return start
    }
}

private struct CaptureMonotonicTimestamp: Hashable, Sendable {
    private var uptimeNanoseconds: UInt64

    static func now() -> Self {
        Self(uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds)
    }

    func duration(to end: Self = .now()) -> TimeInterval {
        guard end.uptimeNanoseconds >= uptimeNanoseconds else { return 0 }
        return Double(end.uptimeNanoseconds - uptimeNanoseconds) / 1_000_000_000
    }
}

private final class CaptureRecoveryMarker: @unchecked Sendable {
    struct Context: Sendable {
        var reason: AudioCaptureRecoveryReason
        var attemptCount: Int
        var startedAt: CaptureMonotonicTimestamp
        var message: String?
    }

    private let lock = NSLock()
    private let timing: CaptureTiming
    private var context: Context?

    init(context: Context?, timing: CaptureTiming) {
        self.context = context
        self.timing = timing
    }

    func take() -> AudioCaptureRecoveryEvent? {
        lock.lock()
        guard let context else {
            lock.unlock()
            return nil
        }
        self.context = nil
        lock.unlock()

        let unavailableDuration = context.startedAt.duration()
        timing.advance(by: unavailableDuration)
        return AudioCaptureRecoveryEvent(
            reason: context.reason,
            attemptCount: context.attemptCount,
            unavailableDuration: unavailableDuration,
            message: context.message
        )
    }
}

private final class CaptureChunkDrain: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(
        label: "CarbocationLocalSpeech.AVAudioEngineCaptureSession.drain",
        qos: .userInitiated
    )
    private let continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation
    private let maximumBufferedDuration: TimeInterval

    private var chunks: [AudioChunk] = []
    private var bufferedDuration: TimeInterval = 0
    private var isDraining = false
    private var isFinishing = false
    private var finishError: Error?
    private var didFinish = false

    init(
        continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation,
        maximumBufferedDuration: TimeInterval
    ) {
        self.continuation = continuation
        self.maximumBufferedDuration = max(0.1, maximumBufferedDuration)
    }

    func enqueue(_ chunk: AudioChunk) {
        var droppedCount = 0
        var shouldScheduleDrain = false

        lock.lock()
        if isFinishing || didFinish {
            lock.unlock()
            return
        }

        chunks.append(chunk)
        bufferedDuration += max(0, chunk.duration)
        while chunks.count > 1, bufferedDuration > maximumBufferedDuration {
            let dropped = chunks.removeFirst()
            bufferedDuration = max(0, bufferedDuration - max(0, dropped.duration))
            droppedCount += 1
        }

        if !isDraining {
            isDraining = true
            shouldScheduleDrain = true
        }
        lock.unlock()

        if droppedCount > 0 {
            audioCaptureLog.warning("Dropped \(droppedCount, privacy: .public) buffered audio chunks during capture recovery")
        }
        if shouldScheduleDrain {
            scheduleDrain()
        }
    }

    func finish(throwing error: Error? = nil) {
        var shouldScheduleDrain = false

        lock.lock()
        if didFinish {
            lock.unlock()
            return
        }
        isFinishing = true
        finishError = error
        if !isDraining {
            isDraining = true
            shouldScheduleDrain = true
        }
        lock.unlock()

        if shouldScheduleDrain {
            scheduleDrain()
        }
    }

    private func scheduleDrain() {
        queue.async { [weak self] in
            self?.drainLoop()
        }
    }

    private func drainLoop() {
        while true {
            lock.lock()
            if !chunks.isEmpty {
                let chunk = chunks.removeFirst()
                bufferedDuration = max(0, bufferedDuration - max(0, chunk.duration))
                lock.unlock()
                continuation.yield(chunk)
                continue
            }

            if isFinishing {
                let error = finishError
                didFinish = true
                lock.unlock()
                continuation.finish(throwing: error)
                return
            }

            isDraining = false
            lock.unlock()
            return
        }
    }
}

public final class AVAudioEngineCaptureSession: AudioCapturing, @unchecked Sendable {
    private enum CaptureLifecycleState {
        case idle
        case starting
        case running
        case interrupted
        case recovering
        case stopping
        case failed
    }

    private struct RecoveryAttempt {
        var configuration: AudioCaptureConfiguration
        var reason: AudioCaptureRecoveryReason
        var startedAt: CaptureMonotonicTimestamp
        var attemptCount: Int
    }

    private let lock = NSLock()
    private let stopQueue = DispatchQueue(
        label: "CarbocationLocalSpeech.AVAudioEngineCaptureSession.stop",
        qos: .userInitiated
    )

    private var state: CaptureLifecycleState = .idle
    private var sessionGeneration: UInt64 = 0
    private var engineGeneration: UInt64 = 0
    private var engine: AVAudioEngine?
    private var engineObserver: NSObjectProtocol?
    private var sessionObservers: [NSObjectProtocol] = []
    private var continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation?
    private var drain: CaptureChunkDrain?
    private var timing: CaptureTiming?
    private var activeConfiguration: AudioCaptureConfiguration?
    private var recoveryTask: Task<Void, Never>?
    private var pendingRecoveryReason: AudioCaptureRecoveryReason?
    private var recoveryStartedAt: CaptureMonotonicTimestamp?
    private var consecutiveRecoveryAttempts = 0
#if os(iOS)
    private var didConfigureApplicationAudioSession = false
#endif

    public init() {}

    public func start(configuration: AudioCaptureConfiguration = AudioCaptureConfiguration()) -> AsyncThrowingStream<AudioChunk, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            stop()
            let drain = CaptureChunkDrain(
                continuation: continuation,
                maximumBufferedDuration: configuration.resilience.retainedBufferDuration
            )
            let sessionGeneration = beginSession(
                configuration: configuration,
                continuation: continuation,
                drain: drain
            )
            installSessionObservers(makeSessionObservers(for: sessionGeneration), sessionGeneration: sessionGeneration)

            let startTask = Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                do {
                    try await prepareToStart(configuration: configuration)
                    try Task.checkCancellation()
                    _ = try startEngine(
                        configuration: configuration,
                        sessionGeneration: sessionGeneration,
                        recoveryContext: nil
                    )
                } catch {
                    failSession(sessionGeneration: sessionGeneration, error: error)
                }
            }

            continuation.onTermination = { [weak self] _ in
                startTask.cancel()
                self?.stop()
            }
        }
    }

    private func beginSession(
        configuration: AudioCaptureConfiguration,
        continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation,
        drain: CaptureChunkDrain
    ) -> UInt64 {
        lock.lock()
        sessionGeneration &+= 1
        engineGeneration &+= 1
        let generation = sessionGeneration
        state = .starting
        self.continuation = continuation
        self.drain = drain
        self.timing = CaptureTiming()
        activeConfiguration = configuration
        pendingRecoveryReason = nil
        recoveryStartedAt = nil
        consecutiveRecoveryAttempts = 0
        lock.unlock()

        audioCaptureLog.info("Starting audio capture session generation=\(generation, privacy: .public)")
        return generation
    }

    private func startEngine(
        configuration: AudioCaptureConfiguration,
        sessionGeneration: UInt64,
        recoveryContext: CaptureRecoveryMarker.Context?
    ) throws -> Bool {
        guard let resources = reserveEngineStart(for: sessionGeneration) else {
            throw CancellationError()
        }

        let engineGeneration = resources.engineGeneration
        let drain = resources.drain
        let timing = resources.timing
        let audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate.isFinite,
              format.sampleRate > 0,
              format.channelCount > 0
        else {
            throw AudioCaptureError.inputRouteUnavailable
        }

        let frames = max(256, AVAudioFrameCount(configuration.frameDuration * format.sampleRate))
        let targetChannelCount = max(1, configuration.preferredChannelCount)
        let recoveryMarker = CaptureRecoveryMarker(context: recoveryContext, timing: timing)

        inputNode.installTap(onBus: 0, bufferSize: frames, format: format) { [weak self] buffer, _ in
            guard let self,
                  self.isCurrentEngine(sessionGeneration: sessionGeneration, engineGeneration: engineGeneration),
                  let chunk = Self.makeChunk(
                    from: buffer,
                    targetChannelCount: targetChannelCount,
                    timing: timing,
                    recoveryMarker: recoveryMarker
                  )
            else { return }
            drain.enqueue(chunk)
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw error
        }

        guard activateEngine(
            audioEngine,
            sessionGeneration: sessionGeneration,
            engineGeneration: engineGeneration
        ) else {
            stopEngine(audioEngine)
            return false
        }

        if let recoveryContext {
            audioCaptureLog.info(
                "Recovered audio capture reason=\(recoveryContext.reason.rawValue, privacy: .public) attempt=\(recoveryContext.attemptCount, privacy: .public)"
            )
        }
        return true
    }

    private static func makeChunk(
        from buffer: AVAudioPCMBuffer,
        targetChannelCount: Int,
        timing: CaptureTiming,
        recoveryMarker: CaptureRecoveryMarker
    ) -> AudioChunk? {
        guard let channels = buffer.floatChannelData else { return nil }
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard channelCount > 0,
              frameLength > 0,
              buffer.format.sampleRate.isFinite,
              buffer.format.sampleRate > 0
        else { return nil }

        var samples: [Float] = []
        let emittedChannelCount: Int
        if targetChannelCount == 1 {
            emittedChannelCount = 1
            samples.reserveCapacity(frameLength)
            for frame in 0..<frameLength {
                var sample: Float = 0
                for channel in 0..<channelCount {
                    sample += channels[channel][frame]
                }
                samples.append(sample / Float(channelCount))
            }
        } else {
            emittedChannelCount = channelCount
            samples.reserveCapacity(frameLength * channelCount)
            for frame in 0..<frameLength {
                for channel in 0..<channelCount {
                    samples.append(channels[channel][frame])
                }
            }
        }

        let duration = Double(frameLength) / buffer.format.sampleRate
        let recoveryEvent = recoveryMarker.take()
        return AudioChunk(
            samples: samples,
            sampleRate: buffer.format.sampleRate,
            channelCount: emittedChannelCount,
            startTime: timing.claim(duration: duration),
            duration: duration,
            recoveryEvent: recoveryEvent
        )
    }

    private func prepareToStart(configuration: AudioCaptureConfiguration) async throws {
#if os(iOS)
        try await requestMicrophoneAccessIfNeeded()
        try configureApplicationAudioSessionIfNeeded(configuration: configuration)
#else
        _ = configuration
#endif
    }

    private func configureApplicationAudioSessionIfNeeded(configuration: AudioCaptureConfiguration) throws {
#if os(iOS)
        guard configuration.configuresApplicationAudioSession else { return }

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement)
            try audioSession.setPreferredSampleRate(configuration.preferredSampleRate)
            try audioSession.setActive(true)
            markApplicationAudioSessionConfigured()
        } catch {
            throw AudioCaptureError.audioSessionConfigurationFailed(error.localizedDescription)
        }
#else
        _ = configuration
#endif
    }

    public func stop() {
        lock.lock()
        sessionGeneration &+= 1
        engineGeneration &+= 1
        state = .stopping
        let audioEngine = engine
        engine = nil
        let engineObserver = engineObserver
        self.engineObserver = nil
        let sessionObservers = sessionObservers
        self.sessionObservers = []
        let continuation = continuation
        self.continuation = nil
        let drain = drain
        self.drain = nil
        timing = nil
        activeConfiguration = nil
        pendingRecoveryReason = nil
        recoveryStartedAt = nil
        consecutiveRecoveryAttempts = 0
        let recoveryTask = recoveryTask
        self.recoveryTask = nil
#if os(iOS)
        let shouldDeactivateAudioSession = didConfigureApplicationAudioSession
        didConfigureApplicationAudioSession = false
#endif
        state = .idle
        lock.unlock()

        recoveryTask?.cancel()
        removeObserver(engineObserver)
        removeObservers(sessionObservers)
        drain?.finish()
        if drain == nil {
            continuation?.finish()
        }

        if let audioEngine {
            stopEngine(audioEngine)
        }

#if os(iOS)
        if shouldDeactivateAudioSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
#endif
    }

    private func reserveEngineStart(
        for sessionGeneration: UInt64
    ) -> (engineGeneration: UInt64, drain: CaptureChunkDrain, timing: CaptureTiming)? {
        lock.lock()
        defer { lock.unlock() }
        guard self.sessionGeneration == sessionGeneration,
              state != .stopping,
              state != .failed,
              let drain,
              let timing
        else {
            return nil
        }
        engineGeneration &+= 1
        return (engineGeneration, drain, timing)
    }

    private func activateEngine(
        _ audioEngine: AVAudioEngine,
        sessionGeneration: UInt64,
        engineGeneration: UInt64
    ) -> Bool {
        let newEngineObserver = makeEngineObserver(for: audioEngine, sessionGeneration: sessionGeneration)

        lock.lock()
        guard self.sessionGeneration == sessionGeneration,
              self.engineGeneration == engineGeneration,
              state != .stopping,
              state != .failed
        else {
            lock.unlock()
            removeObserver(newEngineObserver)
            return false
        }

        let oldEngine = engine
        let oldEngineObserver = engineObserver
        engine = audioEngine
        engineObserver = newEngineObserver
        state = .running
        pendingRecoveryReason = nil
        recoveryStartedAt = nil
        consecutiveRecoveryAttempts = 0
        lock.unlock()

        removeObserver(oldEngineObserver)
        if let oldEngine, oldEngine !== audioEngine {
            stopEngine(oldEngine)
        }
        return true
    }

    private func isCurrentEngine(sessionGeneration: UInt64, engineGeneration: UInt64) -> Bool {
        lock.lock()
        let isCurrent = self.sessionGeneration == sessionGeneration
            && self.engineGeneration == engineGeneration
            && state != .stopping
            && state != .failed
        lock.unlock()
        return isCurrent
    }

    private func makeEngineObserver(
        for audioEngine: AVAudioEngine,
        sessionGeneration: UInt64
    ) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: nil
        ) { [weak self] _ in
            self?.handleRecoveryTrigger(
                reason: .engineConfigurationChanged,
                sessionGeneration: sessionGeneration,
                invalidatesEngine: false
            )
        }
    }

    private func makeSessionObservers(for sessionGeneration: UInt64) -> [NSObjectProtocol] {
#if os(iOS)
        let center = NotificationCenter.default
        let audioSession = AVAudioSession.sharedInstance()
        return [
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: audioSession,
                queue: nil
            ) { [weak self] notification in
                self?.handleInterruption(notification, sessionGeneration: sessionGeneration)
            },
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: audioSession,
                queue: nil
            ) { [weak self] _ in
                self?.handleRecoveryTrigger(
                    reason: .routeChanged,
                    sessionGeneration: sessionGeneration,
                    invalidatesEngine: false
                )
            },
            center.addObserver(
                forName: AVAudioSession.mediaServicesWereLostNotification,
                object: audioSession,
                queue: nil
            ) { [weak self] _ in
                self?.handleRecoveryTrigger(
                    reason: .mediaServicesLost,
                    sessionGeneration: sessionGeneration,
                    invalidatesEngine: true
                )
            },
            center.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: audioSession,
                queue: nil
            ) { [weak self] _ in
                self?.handleRecoveryTrigger(
                    reason: .mediaServicesReset,
                    sessionGeneration: sessionGeneration,
                    invalidatesEngine: true
                )
            }
        ]
#else
        _ = sessionGeneration
        return []
#endif
    }

    private func installSessionObservers(
        _ observers: [NSObjectProtocol],
        sessionGeneration: UInt64
    ) {
        guard !observers.isEmpty else { return }

        lock.lock()
        guard self.sessionGeneration == sessionGeneration,
              state != .stopping,
              state != .failed
        else {
            lock.unlock()
            removeObservers(observers)
            return
        }
        sessionObservers = observers
        lock.unlock()
    }

    private func handleRecoveryTrigger(
        reason: AudioCaptureRecoveryReason,
        sessionGeneration: UInt64,
        invalidatesEngine: Bool
    ) {
        let shouldSchedule = detachEngineForRecovery(
            reason: reason,
            sessionGeneration: sessionGeneration,
            invalidatesEngine: invalidatesEngine
        )
        guard shouldSchedule else { return }

        audioCaptureLog.info("Scheduling audio capture recovery reason=\(reason.rawValue, privacy: .public)")
        scheduleRecovery(sessionGeneration: sessionGeneration)
    }

    private func detachEngineForRecovery(
        reason: AudioCaptureRecoveryReason,
        sessionGeneration: UInt64,
        invalidatesEngine: Bool
    ) -> Bool {
        lock.lock()
        guard self.sessionGeneration == sessionGeneration,
              state != .idle,
              state != .stopping,
              state != .failed,
              let configuration = activeConfiguration
        else {
            lock.unlock()
            return false
        }

        guard configuration.resilience.isEnabled else {
            lock.unlock()
            failSession(
                sessionGeneration: sessionGeneration,
                error: AudioCaptureError.recoveryAttemptsExhausted("Recovery is disabled.")
            )
            return false
        }

        state = .recovering
        engineGeneration &+= 1
        pendingRecoveryReason = reason
        if recoveryStartedAt == nil {
            recoveryStartedAt = .now()
        }
        let oldEngine = engine
        engine = nil
        let oldEngineObserver = engineObserver
        engineObserver = nil
        lock.unlock()

        removeObserver(oldEngineObserver)
        if let oldEngine, !invalidatesEngine {
            stopEngine(oldEngine)
        }
        return true
    }

    private func pauseForInterruption(sessionGeneration: UInt64) {
        lock.lock()
        guard self.sessionGeneration == sessionGeneration,
              state != .idle,
              state != .stopping,
              state != .failed
        else {
            lock.unlock()
            return
        }

        state = .interrupted
        engineGeneration &+= 1
        pendingRecoveryReason = .interruptionEnded
        if recoveryStartedAt == nil {
            recoveryStartedAt = .now()
        }
        let oldEngine = engine
        engine = nil
        let oldEngineObserver = engineObserver
        engineObserver = nil
        lock.unlock()

        removeObserver(oldEngineObserver)
        if let oldEngine {
            stopEngine(oldEngine)
        }
        audioCaptureLog.info("Paused audio capture for interruption")
    }

    private func scheduleRecovery(sessionGeneration: UInt64) {
        lock.lock()
        guard self.sessionGeneration == sessionGeneration,
              let configuration = activeConfiguration,
              state != .stopping,
              state != .failed
        else {
            lock.unlock()
            return
        }
        recoveryTask?.cancel()
        let debounce = configuration.resilience.recoveryDebounceDuration
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.runRecovery(sessionGeneration: sessionGeneration, debounce: debounce)
        }
        recoveryTask = task
        lock.unlock()
    }

    private func runRecovery(sessionGeneration: UInt64, debounce: TimeInterval) async {
        do {
            try await sleep(seconds: debounce)

            while !Task.isCancelled {
                guard let attempt = nextRecoveryAttempt(sessionGeneration: sessionGeneration) else {
                    return
                }

                do {
                    try configureApplicationAudioSessionIfNeeded(configuration: attempt.configuration)
                    let started = try startEngine(
                        configuration: attempt.configuration,
                        sessionGeneration: sessionGeneration,
                        recoveryContext: CaptureRecoveryMarker.Context(
                            reason: attempt.reason,
                            attemptCount: attempt.attemptCount,
                            startedAt: attempt.startedAt,
                            message: "recovered"
                        )
                    )
                    if started {
                        return
                    }
                    return
                } catch is CancellationError {
                    return
                } catch {
                    audioCaptureLog.error(
                        "Audio capture recovery attempt \(attempt.attemptCount, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                    )
                    if attempt.attemptCount >= attempt.configuration.resilience.maximumConsecutiveRecoveryAttempts {
                        failSession(
                            sessionGeneration: sessionGeneration,
                            error: AudioCaptureError.recoveryAttemptsExhausted(error.localizedDescription)
                        )
                        return
                    }
                    try await sleep(seconds: attempt.configuration.resilience.retryDelay(afterFailedAttempt: attempt.attemptCount))
                }
            }
        } catch is CancellationError {
            return
        } catch {
            failSession(sessionGeneration: sessionGeneration, error: error)
        }
    }

    private func nextRecoveryAttempt(sessionGeneration: UInt64) -> RecoveryAttempt? {
        lock.lock()
        defer { lock.unlock() }
        guard self.sessionGeneration == sessionGeneration,
              state != .stopping,
              state != .failed,
              let configuration = activeConfiguration,
              timing != nil
        else {
            return nil
        }

        state = .recovering
        consecutiveRecoveryAttempts += 1
        let startedAt = recoveryStartedAt ?? .now()
        recoveryStartedAt = startedAt
        return RecoveryAttempt(
            configuration: configuration,
            reason: pendingRecoveryReason ?? .engineConfigurationChanged,
            startedAt: startedAt,
            attemptCount: consecutiveRecoveryAttempts
        )
    }

    private func failSession(sessionGeneration: UInt64, error: Error) {
        lock.lock()
        guard self.sessionGeneration == sessionGeneration,
              state != .idle,
              state != .stopping,
              state != .failed
        else {
            lock.unlock()
            return
        }

        state = .failed
        engineGeneration &+= 1
        let audioEngine = engine
        engine = nil
        let engineObserver = engineObserver
        self.engineObserver = nil
        let sessionObservers = sessionObservers
        self.sessionObservers = []
        let continuation = continuation
        self.continuation = nil
        let drain = drain
        self.drain = nil
        timing = nil
        activeConfiguration = nil
        pendingRecoveryReason = nil
        recoveryStartedAt = nil
        consecutiveRecoveryAttempts = 0
        let recoveryTask = recoveryTask
        self.recoveryTask = nil
#if os(iOS)
        let shouldDeactivateAudioSession = didConfigureApplicationAudioSession
        didConfigureApplicationAudioSession = false
#endif
        state = .idle
        lock.unlock()

        recoveryTask?.cancel()
        removeObserver(engineObserver)
        removeObservers(sessionObservers)
        drain?.finish(throwing: error)
        if drain == nil {
            continuation?.finish(throwing: error)
        }
        if let audioEngine {
            stopEngine(audioEngine)
        }
#if os(iOS)
        if shouldDeactivateAudioSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
#endif
    }

    private func stopEngine(_ audioEngine: AVAudioEngine) {
        stopQueue.async {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
    }

    private func removeObserver(_ observer: NSObjectProtocol?) {
        guard let observer else { return }
        NotificationCenter.default.removeObserver(observer)
    }

    private func removeObservers(_ observers: [NSObjectProtocol]) {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func sleep(seconds: TimeInterval) async throws {
        let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
    }

#if os(iOS)
    private func handleInterruption(_ notification: Notification, sessionGeneration: UInt64) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else { return }

        switch type {
        case .began:
            pauseForInterruption(sessionGeneration: sessionGeneration)
        case .ended:
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            if options.contains(.shouldResume) {
                handleRecoveryTrigger(
                    reason: .interruptionEnded,
                    sessionGeneration: sessionGeneration,
                    invalidatesEngine: false
                )
            } else {
                failSession(
                    sessionGeneration: sessionGeneration,
                    error: AudioCaptureError.unrecoverableInterruption("System did not grant shouldResume.")
                )
            }
        @unknown default:
            failSession(
                sessionGeneration: sessionGeneration,
                error: AudioCaptureError.unrecoverableInterruption("Unknown interruption type.")
            )
        }
    }

    private func markApplicationAudioSessionConfigured() {
        lock.lock()
        didConfigureApplicationAudioSession = true
        lock.unlock()
    }

    private func requestMicrophoneAccessIfNeeded() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await MicrophonePermissionHelper.requestAccess()
            guard granted else {
                throw AudioCaptureError.microphonePermissionDenied
            }
        case .denied:
            throw AudioCaptureError.microphonePermissionDenied
        case .restricted:
            throw AudioCaptureError.microphonePermissionRestricted
        @unknown default:
            throw AudioCaptureError.microphonePermissionDenied
        }
    }
#endif
}

public enum MicrophonePermissionHelper {
    public static func authorizationStatus() -> MicrophonePermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            return .notDetermined
        case .restricted:
            return .restricted
        case .denied:
            return .denied
        case .authorized:
            return .authorized
        @unknown default:
            return .unknown
        }
    }

    public static func requestAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
