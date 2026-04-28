import AudioToolbox
import AVFoundation
import CoreAudio
import Darwin
import Foundation

@available(macOS 15.0, *)
public struct SystemAudioCaptureOptions: Hashable, Sendable {
    public var excludesCurrentProcessAudio: Bool
    public var tapName: String

    public init(
        excludesCurrentProcessAudio: Bool = true,
        tapName: String = "Carbocation Local Speech System Audio"
    ) {
        self.excludesCurrentProcessAudio = excludesCurrentProcessAudio
        self.tapName = tapName
    }
}

@available(macOS 15.0, *)
public enum SystemAudioCaptureError: Error, LocalizedError, Sendable {
    case processTapCreationFailed
    case aggregateDeviceCreationFailed
    case inputAudioUnitUnavailable
    case audioUnitDeviceSelectionFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .processTapCreationFailed:
            return "Could not create a system audio tap."
        case .aggregateDeviceCreationFailed:
            return "Could not create a system audio aggregate device."
        case .inputAudioUnitUnavailable:
            return "Could not access the system audio input unit."
        case .audioUnitDeviceSelectionFailed(let status):
            return "Could not route system audio into the capture engine. Core Audio status: \(status)."
        }
    }
}

@available(macOS 15.0, *)
public final class SystemAudioCaptureSession: AudioCapturing, @unchecked Sendable {
    private let options: SystemAudioCaptureOptions
    private let lock = NSLock()
    private let stopQueue = DispatchQueue(
        label: "CarbocationLocalSpeech.SystemAudioCaptureSession.stop",
        qos: .userInitiated
    )
    private var state: SystemAudioCaptureState?
    private var continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation?

    public init(options: SystemAudioCaptureOptions = SystemAudioCaptureOptions()) {
        self.options = options
    }

    public func start(configuration: AudioCaptureConfiguration = AudioCaptureConfiguration()) -> AsyncThrowingStream<AudioChunk, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            stop()

            lock.lock()
            self.continuation = continuation
            lock.unlock()

            do {
                let state = try Self.makeStartedState(
                    options: options,
                    configuration: configuration,
                    continuation: continuation
                )
                lock.lock()
                self.state = state
                lock.unlock()
            } catch {
                clear()
                continuation.finish(throwing: error)
            }

            continuation.onTermination = { [weak self] _ in
                self?.stop()
            }
        }
    }

    public func stop() {
        lock.lock()
        let state = state
        self.state = nil
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        continuation?.finish()

        if let state {
            stopQueue.async {
                state.stop()
            }
        }
    }

    private func clear() {
        lock.lock()
        state = nil
        continuation = nil
        lock.unlock()
    }

    private static func makeStartedState(
        options: SystemAudioCaptureOptions,
        configuration: AudioCaptureConfiguration,
        continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation
    ) throws -> SystemAudioCaptureState {
        let processTap = try makeProcessTap(options: options, configuration: configuration)
        var aggregateDevice: AudioHardwareAggregateDevice?
        do {
            let device = try makeAggregateDevice(for: processTap, options: options)
            aggregateDevice = device
            return try makeStartedEngine(
                aggregateDevice: device,
                processTap: processTap,
                configuration: configuration,
                continuation: continuation
            )
        } catch {
            if let aggregateDevice {
                try? AudioHardwareSystem.shared.destroyAggregateDevice(aggregateDevice)
            }
            try? AudioHardwareSystem.shared.destroyProcessTap(processTap)
            throw error
        }
    }

    private static func makeProcessTap(
        options: SystemAudioCaptureOptions,
        configuration: AudioCaptureConfiguration
    ) throws -> AudioHardwareTap {
        let excludedProcessIDs = currentProcessIDsToExclude(options: options)
        let targetChannelCount = max(1, configuration.preferredChannelCount)
        let description = targetChannelCount == 1
            ? CATapDescription(monoGlobalTapButExcludeProcesses: excludedProcessIDs)
            : CATapDescription(stereoGlobalTapButExcludeProcesses: excludedProcessIDs)
        description.name = options.tapName
        description.isPrivate = true
        description.muteBehavior = .unmuted

        guard let tap = try AudioHardwareSystem.shared.makeProcessTap(description: description) else {
            throw SystemAudioCaptureError.processTapCreationFailed
        }
        return tap
    }

    private static func currentProcessIDsToExclude(options: SystemAudioCaptureOptions) -> [AudioObjectID] {
        guard options.excludesCurrentProcessAudio,
              let process = try? AudioHardwareSystem.shared.process(for: getpid())
        else {
            return []
        }
        return [process.id]
    }

    private static func makeAggregateDevice(
        for tap: AudioHardwareTap,
        options: SystemAudioCaptureOptions
    ) throws -> AudioHardwareAggregateDevice {
        let tapDescription: [String: Any] = [
            kAudioSubTapUIDKey: try tap.uid,
            kAudioSubTapDriftCompensationKey: true,
            kAudioSubTapDriftCompensationQualityKey: kAudioAggregateDriftCompensationMaxQuality
        ]
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "\(options.tapName) Aggregate",
            kAudioAggregateDeviceUIDKey: "com.carbocation.localspeech.system-audio.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceTapListKey: [tapDescription]
        ]

        guard let device = try AudioHardwareSystem.shared.makeAggregateDevice(description: aggregateDescription) else {
            throw SystemAudioCaptureError.aggregateDeviceCreationFailed
        }
        return device
    }

    private static func makeStartedEngine(
        aggregateDevice: AudioHardwareAggregateDevice,
        processTap: AudioHardwareTap,
        configuration: AudioCaptureConfiguration,
        continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation
    ) throws -> SystemAudioCaptureState {
        let audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        try route(inputNode: inputNode, to: aggregateDevice)

        let format = inputNode.outputFormat(forBus: 0)
        let frames = max(256, AVAudioFrameCount(configuration.frameDuration * format.sampleRate))
        let targetChannelCount = max(1, configuration.preferredChannelCount)
        let timing = CaptureTiming()

        inputNode.installTap(onBus: 0, bufferSize: frames, format: format) { buffer, _ in
            guard let chunk = AudioChunk(
                pcmBuffer: buffer,
                targetChannelCount: targetChannelCount,
                timing: timing
            ) else {
                return
            }
            continuation.yield(chunk)
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            audioEngine.stop()
            throw error
        }

        return SystemAudioCaptureState(
            engine: audioEngine,
            inputNode: inputNode,
            aggregateDevice: aggregateDevice,
            processTap: processTap
        )
    }

    private static func route(
        inputNode: AVAudioInputNode,
        to aggregateDevice: AudioHardwareAggregateDevice
    ) throws {
        guard let audioUnit = inputNode.audioUnit else {
            throw SystemAudioCaptureError.inputAudioUnitUnavailable
        }

        var deviceID = aggregateDevice.id
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioObjectID>.size)
        )
        guard status == noErr else {
            throw SystemAudioCaptureError.audioUnitDeviceSelectionFailed(status)
        }
    }
}

@available(macOS 15.0, *)
private final class SystemAudioCaptureState: @unchecked Sendable {
    private let engine: AVAudioEngine
    private let inputNode: AVAudioInputNode
    private let aggregateDevice: AudioHardwareAggregateDevice
    private let processTap: AudioHardwareTap

    init(
        engine: AVAudioEngine,
        inputNode: AVAudioInputNode,
        aggregateDevice: AudioHardwareAggregateDevice,
        processTap: AudioHardwareTap
    ) {
        self.engine = engine
        self.inputNode = inputNode
        self.aggregateDevice = aggregateDevice
        self.processTap = processTap
    }

    func stop() {
        engine.stop()
        inputNode.removeTap(onBus: 0)
        try? AudioHardwareSystem.shared.destroyAggregateDevice(aggregateDevice)
        try? AudioHardwareSystem.shared.destroyProcessTap(processTap)
    }
}

private final class CaptureTiming: @unchecked Sendable {
    private let lock = NSLock()
    private var nextStartTime: TimeInterval = 0

    func claim(duration: TimeInterval) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        let start = nextStartTime
        nextStartTime += duration
        return start
    }
}

private extension AudioChunk {
    init?(
        pcmBuffer buffer: AVAudioPCMBuffer,
        targetChannelCount: Int,
        timing: CaptureTiming
    ) {
        guard let channels = buffer.floatChannelData else { return nil }
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
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
                samples.append(sample / Float(max(1, channelCount)))
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
        self.init(
            samples: samples,
            sampleRate: buffer.format.sampleRate,
            channelCount: emittedChannelCount,
            startTime: timing.claim(duration: duration),
            duration: duration
        )
    }
}
