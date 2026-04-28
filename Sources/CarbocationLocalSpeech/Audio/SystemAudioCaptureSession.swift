import AudioToolbox
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
    case processTapFormatUnavailable(OSStatus)
    case unsupportedProcessTapFormat(String)
    case ioProcCreationFailed(OSStatus)
    case deviceStartFailed(OSStatus)

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
        case .processTapFormatUnavailable(let status):
            return "Could not read the system audio tap format. Core Audio status: \(status)."
        case .unsupportedProcessTapFormat(let detail):
            return "Unsupported system audio tap format: \(detail)"
        case .ioProcCreationFailed(let status):
            return "Could not create the system audio input callback. Core Audio status: \(status)."
        case .deviceStartFailed(let status):
            return "Could not start system audio capture. Core Audio status: \(status)."
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
            return try makeStartedIOProc(
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

    private static func makeStartedIOProc(
        aggregateDevice: AudioHardwareAggregateDevice,
        processTap: AudioHardwareTap,
        configuration: AudioCaptureConfiguration,
        continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation
    ) throws -> SystemAudioCaptureState {
        let targetChannelCount = max(1, configuration.preferredChannelCount)
        let format = try processTapFormat(for: processTap)
        let timing = CaptureTiming()
        let callbackQueue = DispatchQueue(
            label: "CarbocationLocalSpeech.SystemAudioCaptureSession.io",
            qos: .userInitiated
        )
        var ioProcID: AudioDeviceIOProcID?

        let createStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateDevice.id, callbackQueue) { _, inputData, _, _, _ in
            guard let chunk = AudioChunk(
                audioBufferList: inputData,
                format: format,
                targetChannelCount: targetChannelCount,
                timing: timing
            ) else {
                return
            }
            continuation.yield(chunk)
        }
        guard createStatus == noErr, let ioProcID else {
            throw SystemAudioCaptureError.ioProcCreationFailed(createStatus)
        }

        let startStatus = AudioDeviceStart(aggregateDevice.id, ioProcID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(aggregateDevice.id, ioProcID)
            throw SystemAudioCaptureError.deviceStartFailed(startStatus)
        }

        return SystemAudioCaptureState(
            aggregateDevice: aggregateDevice,
            processTap: processTap,
            ioProcID: ioProcID
        )
    }

    private static func processTapFormat(for tap: AudioHardwareTap) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tap.id, &address, 0, nil, &size, &format)
        guard status == noErr else {
            throw SystemAudioCaptureError.processTapFormatUnavailable(status)
        }
        guard format.mFormatID == kAudioFormatLinearPCM else {
            throw SystemAudioCaptureError.unsupportedProcessTapFormat("Expected linear PCM.")
        }
        guard format.mSampleRate > 0, format.mChannelsPerFrame > 0 else {
            throw SystemAudioCaptureError.unsupportedProcessTapFormat("Expected a positive sample rate and at least one channel.")
        }
        guard format.mBitsPerChannel == 16 || format.mBitsPerChannel == 32 else {
            throw SystemAudioCaptureError.unsupportedProcessTapFormat("Expected 16-bit or 32-bit PCM.")
        }
        return format
    }
}

@available(macOS 15.0, *)
private final class SystemAudioCaptureState: @unchecked Sendable {
    private let aggregateDevice: AudioHardwareAggregateDevice
    private let processTap: AudioHardwareTap
    private let ioProcID: AudioDeviceIOProcID

    init(
        aggregateDevice: AudioHardwareAggregateDevice,
        processTap: AudioHardwareTap,
        ioProcID: AudioDeviceIOProcID
    ) {
        self.aggregateDevice = aggregateDevice
        self.processTap = processTap
        self.ioProcID = ioProcID
    }

    func stop() {
        AudioDeviceStop(aggregateDevice.id, ioProcID)
        AudioDeviceDestroyIOProcID(aggregateDevice.id, ioProcID)
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
        audioBufferList inputData: UnsafePointer<AudioBufferList>,
        format: AudioStreamBasicDescription,
        targetChannelCount: Int,
        timing: CaptureTiming
    ) {
        let channelCount = Int(format.mChannelsPerFrame)
        let bytesPerSample = max(1, Int(format.mBitsPerChannel / 8))
        let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isNonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard channelCount > 0, !buffers.isEmpty else { return nil }

        let frameLength: Int
        if isNonInterleaved {
            frameLength = buffers.map { Int($0.mDataByteSize) / bytesPerSample }.min() ?? 0
        } else {
            let bytesPerFrame = max(bytesPerSample * channelCount, Int(format.mBytesPerFrame))
            frameLength = Int(buffers[0].mDataByteSize) / bytesPerFrame
        }
        guard frameLength > 0 else { return nil }

        var samples: [Float] = []
        let emittedChannelCount: Int
        if targetChannelCount == 1 {
            emittedChannelCount = 1
            samples.reserveCapacity(frameLength)
            for frame in 0..<frameLength {
                var sample: Float = 0
                for channel in 0..<channelCount {
                    sample += Self.sample(
                        in: buffers,
                        format: format,
                        frame: frame,
                        channel: channel,
                        bytesPerSample: bytesPerSample,
                        isFloat: isFloat,
                        isNonInterleaved: isNonInterleaved
                    )
                }
                samples.append(sample / Float(max(1, channelCount)))
            }
        } else {
            emittedChannelCount = channelCount
            samples.reserveCapacity(frameLength * channelCount)
            for frame in 0..<frameLength {
                for channel in 0..<channelCount {
                    samples.append(Self.sample(
                        in: buffers,
                        format: format,
                        frame: frame,
                        channel: channel,
                        bytesPerSample: bytesPerSample,
                        isFloat: isFloat,
                        isNonInterleaved: isNonInterleaved
                    ))
                }
            }
        }

        let duration = Double(frameLength) / format.mSampleRate
        self.init(
            samples: samples,
            sampleRate: format.mSampleRate,
            channelCount: emittedChannelCount,
            startTime: timing.claim(duration: duration),
            duration: duration
        )
    }

    private static func sample(
        in buffers: UnsafeMutableAudioBufferListPointer,
        format: AudioStreamBasicDescription,
        frame: Int,
        channel: Int,
        bytesPerSample: Int,
        isFloat: Bool,
        isNonInterleaved: Bool
    ) -> Float {
        if isNonInterleaved {
            guard channel < buffers.count, let data = buffers[channel].mData else { return 0 }
            return sample(in: data, sampleIndex: frame, bytesPerSample: bytesPerSample, isFloat: isFloat)
        }

        guard let data = buffers[0].mData else { return 0 }
        let channelCount = max(1, Int(format.mChannelsPerFrame))
        return sample(
            in: data,
            sampleIndex: frame * channelCount + channel,
            bytesPerSample: bytesPerSample,
            isFloat: isFloat
        )
    }

    private static func sample(
        in data: UnsafeMutableRawPointer,
        sampleIndex: Int,
        bytesPerSample: Int,
        isFloat: Bool
    ) -> Float {
        if isFloat, bytesPerSample == MemoryLayout<Float>.size {
            return data.assumingMemoryBound(to: Float.self)[sampleIndex]
        }
        if bytesPerSample == MemoryLayout<Int16>.size {
            return Float(data.assumingMemoryBound(to: Int16.self)[sampleIndex]) / Float(Int16.max)
        }
        if bytesPerSample == MemoryLayout<Int32>.size {
            return Float(data.assumingMemoryBound(to: Int32.self)[sampleIndex]) / Float(Int32.max)
        }
        return 0
    }
}
