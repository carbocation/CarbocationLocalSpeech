import AudioToolbox
import AVFoundation
import CoreMedia
import Foundation

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
                duration: Double(mono.count) / targetSampleRate
            )
        }

        let ratio = targetSampleRate / chunk.sampleRate
        let outputCount = max(0, Int((Double(mono.count) * ratio).rounded()))
        guard outputCount > 0 else {
            return AudioChunk(samples: [], sampleRate: targetSampleRate, channelCount: 1, startTime: chunk.startTime, duration: 0)
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
            duration: Double(output.count) / targetSampleRate
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

    func claim(duration: TimeInterval) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        let start = nextStartTime
        nextStartTime += duration
        return start
    }
}

public final class AVAudioEngineCaptureSession: AudioCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private let stopQueue = DispatchQueue(
        label: "CarbocationLocalSpeech.AVAudioEngineCaptureSession.stop",
        qos: .userInitiated
    )
    private var engine: AVAudioEngine?
    private var continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation?

    public init() {}

    public func start(configuration: AudioCaptureConfiguration = AudioCaptureConfiguration()) -> AsyncThrowingStream<AudioChunk, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            stop()

            lock.lock()
            let audioEngine = AVAudioEngine()
            engine = audioEngine
            self.continuation = continuation
            lock.unlock()

            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            let frames = max(256, AVAudioFrameCount(configuration.frameDuration * format.sampleRate))
            let targetChannelCount = max(1, configuration.preferredChannelCount)
            let timing = CaptureTiming()

            inputNode.installTap(onBus: 0, bufferSize: frames, format: format) { buffer, _ in
                guard let channels = buffer.floatChannelData else { return }
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
                continuation.yield(AudioChunk(
                    samples: samples,
                    sampleRate: buffer.format.sampleRate,
                    channelCount: emittedChannelCount,
                    startTime: timing.claim(duration: duration),
                    duration: duration
                ))
            }

            do {
                audioEngine.prepare()
                try audioEngine.start()
            } catch {
                inputNode.removeTap(onBus: 0)
                clear(audioEngine: audioEngine)
                continuation.finish(throwing: error)
            }

            continuation.onTermination = { [weak self] _ in
                self?.stop()
            }
        }
    }

    public func stop() {
        lock.lock()
        let audioEngine = engine
        engine = nil
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        continuation?.finish()

        if let audioEngine {
            stopQueue.async {
                audioEngine.stop()
                audioEngine.inputNode.removeTap(onBus: 0)
            }
        }
    }

    private func clear(audioEngine expectedEngine: AVAudioEngine) {
        lock.lock()
        if engine === expectedEngine {
            engine = nil
            continuation = nil
        }
        lock.unlock()
    }
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
