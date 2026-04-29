import AVFoundation
import Foundation

public enum AudioRecordingFileFormat: Hashable, Sendable {
    case cafFloat32
    case wavPCM16
}

public struct AudioRecordingConfiguration: Hashable, Sendable {
    public var fileURL: URL
    public var format: AudioRecordingFileFormat
    public var overwriteExistingFile: Bool
    public var createParentDirectories: Bool

    public init(
        fileURL: URL,
        format: AudioRecordingFileFormat = .cafFloat32,
        overwriteExistingFile: Bool = false,
        createParentDirectories: Bool = true
    ) {
        self.fileURL = fileURL
        self.format = format
        self.overwriteExistingFile = overwriteExistingFile
        self.createParentDirectories = createParentDirectories
    }
}

public struct AudioRecordingSummary: Hashable, Sendable {
    public var fileURL: URL
    public var duration: TimeInterval
    public var sampleRate: Double
    public var channelCount: Int
    public var frameCount: Int64

    public init(
        fileURL: URL,
        duration: TimeInterval,
        sampleRate: Double,
        channelCount: Int,
        frameCount: Int64
    ) {
        self.fileURL = fileURL
        self.duration = duration
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.frameCount = frameCount
    }
}

public enum AudioRecordingError: Error, LocalizedError, Sendable {
    case fileAlreadyExists(URL)
    case invalidSampleRate(Double)
    case invalidFrameCount(sampleCount: Int, channelCount: Int)
    case formatChanged(
        expectedSampleRate: Double,
        actualSampleRate: Double,
        expectedChannelCount: Int,
        actualChannelCount: Int
    )
    case recordingFinished

    public var errorDescription: String? {
        switch self {
        case .fileAlreadyExists(let url):
            return "Audio recording file already exists: \(url.path)"
        case .invalidSampleRate(let sampleRate):
            return "Audio recording sample rate must be positive and finite: \(sampleRate)"
        case .invalidFrameCount(let sampleCount, let channelCount):
            return "Audio recording samples must contain complete frames. samples=\(sampleCount) channels=\(channelCount)"
        case .formatChanged(
            let expectedSampleRate,
            let actualSampleRate,
            let expectedChannelCount,
            let actualChannelCount
        ):
            return "Audio recording format changed from \(expectedSampleRate) Hz/\(expectedChannelCount) channels to \(actualSampleRate) Hz/\(actualChannelCount) channels."
        case .recordingFinished:
            return "Audio recording has already finished."
        }
    }
}

public actor AudioChunkFileRecorder {
    private let configuration: AudioRecordingConfiguration
    private let fileManager: FileManager
    private var audioFile: AVAudioFile?
    private var audioFormat: AVAudioFormat?
    private var sampleRate: Double?
    private var channelCount: Int?
    private var frameCount: Int64 = 0
    private var isFinished = false
    private var cachedSummary: AudioRecordingSummary?

    public init(configuration: AudioRecordingConfiguration) {
        self.configuration = configuration
        self.fileManager = .default
    }

    public func record(_ chunk: AudioChunk) throws {
        guard !isFinished else {
            throw AudioRecordingError.recordingFinished
        }
        guard !chunk.samples.isEmpty else {
            return
        }

        try validate(chunk)

        if audioFile == nil {
            try openFile(for: chunk)
        }

        guard let audioFile, let audioFormat else {
            return
        }

        let buffer = try Self.makeBuffer(
            from: chunk,
            format: configuration.format,
            audioFormat: audioFormat
        )
        try audioFile.write(from: buffer)
        frameCount += Int64(buffer.frameLength)
    }

    public func finish() throws -> AudioRecordingSummary? {
        if let cachedSummary {
            isFinished = true
            audioFile = nil
            audioFormat = nil
            return cachedSummary
        }

        isFinished = true
        audioFile = nil
        audioFormat = nil

        guard let sampleRate, let channelCount, frameCount > 0 else {
            return nil
        }

        let summary = AudioRecordingSummary(
            fileURL: configuration.fileURL,
            duration: Double(frameCount) / sampleRate,
            sampleRate: sampleRate,
            channelCount: channelCount,
            frameCount: frameCount
        )
        cachedSummary = summary
        return summary
    }

    private func validate(_ chunk: AudioChunk) throws {
        guard chunk.sampleRate.isFinite, chunk.sampleRate > 0 else {
            throw AudioRecordingError.invalidSampleRate(chunk.sampleRate)
        }
        guard chunk.channelCount > 0,
              chunk.samples.count % chunk.channelCount == 0,
              chunk.samples.count / chunk.channelCount <= Int(UInt32.max)
        else {
            throw AudioRecordingError.invalidFrameCount(
                sampleCount: chunk.samples.count,
                channelCount: chunk.channelCount
            )
        }

        guard let sampleRate, let channelCount else {
            return
        }
        guard abs(sampleRate - chunk.sampleRate) <= 0.000_001,
              channelCount == chunk.channelCount
        else {
            throw AudioRecordingError.formatChanged(
                expectedSampleRate: sampleRate,
                actualSampleRate: chunk.sampleRate,
                expectedChannelCount: channelCount,
                actualChannelCount: chunk.channelCount
            )
        }
    }

    private func openFile(for chunk: AudioChunk) throws {
        if fileManager.fileExists(atPath: configuration.fileURL.path) {
            guard configuration.overwriteExistingFile else {
                throw AudioRecordingError.fileAlreadyExists(configuration.fileURL)
            }
            try fileManager.removeItem(at: configuration.fileURL)
        }

        if configuration.createParentDirectories {
            let parent = configuration.fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        }

        let format = try Self.makeAudioFormat(
            recordingFormat: configuration.format,
            sampleRate: chunk.sampleRate,
            channelCount: chunk.channelCount
        )
        audioFile = try AVAudioFile(
            forWriting: configuration.fileURL,
            settings: Self.fileSettings(
                for: configuration.format,
                sampleRate: chunk.sampleRate,
                channelCount: chunk.channelCount
            ),
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        audioFormat = format
        sampleRate = chunk.sampleRate
        channelCount = chunk.channelCount
    }

    private static func makeAudioFormat(
        recordingFormat: AudioRecordingFileFormat,
        sampleRate: Double,
        channelCount: Int
    ) throws -> AVAudioFormat {
        let commonFormat: AVAudioCommonFormat
        switch recordingFormat {
        case .cafFloat32:
            commonFormat = .pcmFormatFloat32
        case .wavPCM16:
            commonFormat = .pcmFormatInt16
        }

        guard let format = AVAudioFormat(
            commonFormat: commonFormat,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channelCount),
            interleaved: false
        ) else {
            throw AudioRecordingError.invalidFrameCount(
                sampleCount: 0,
                channelCount: channelCount
            )
        }
        return format
    }

    private static func fileSettings(
        for format: AudioRecordingFileFormat,
        sampleRate: Double,
        channelCount: Int
    ) -> [String: Any] {
        switch format {
        case .cafFloat32:
            return [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channelCount,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
        case .wavPCM16:
            return [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
        }
    }

    private static func makeBuffer(
        from chunk: AudioChunk,
        format recordingFormat: AudioRecordingFileFormat,
        audioFormat: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        let frameCount = chunk.samples.count / chunk.channelCount
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: audioFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            throw AudioRecordingError.invalidFrameCount(
                sampleCount: chunk.samples.count,
                channelCount: chunk.channelCount
            )
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        switch recordingFormat {
        case .cafFloat32:
            guard let channels = buffer.floatChannelData else {
                throw AudioRecordingError.invalidFrameCount(
                    sampleCount: chunk.samples.count,
                    channelCount: chunk.channelCount
                )
            }
            for frame in 0..<frameCount {
                for channel in 0..<chunk.channelCount {
                    channels[channel][frame] = chunk.samples[frame * chunk.channelCount + channel]
                }
            }
        case .wavPCM16:
            guard let channels = buffer.int16ChannelData else {
                throw AudioRecordingError.invalidFrameCount(
                    sampleCount: chunk.samples.count,
                    channelCount: chunk.channelCount
                )
            }
            for frame in 0..<frameCount {
                for channel in 0..<chunk.channelCount {
                    channels[channel][frame] = pcm16Sample(
                        from: chunk.samples[frame * chunk.channelCount + channel]
                    )
                }
            }
        }

        return buffer
    }

    private static func pcm16Sample(from sample: Float) -> Int16 {
        if sample >= 1 {
            return Int16.max
        }
        if sample <= -1 {
            return Int16.min
        }
        return Int16(sample * Float(Int16.max))
    }
}

public enum AudioChunkStreams {
    public static func tap(
        _ source: AsyncThrowingStream<AudioChunk, Error>,
        bufferingPolicy: AsyncThrowingStream<AudioChunk, Error>.Continuation.BufferingPolicy = .bufferingNewest(8),
        onChunk: @escaping @Sendable (AudioChunk) async throws -> Void
    ) -> AsyncThrowingStream<AudioChunk, Error> {
        AsyncThrowingStream(bufferingPolicy: bufferingPolicy) { continuation in
            let task = Task {
                do {
                    for try await chunk in source {
                        try Task.checkCancellation()
                        try await onChunk(chunk)
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    public static func recording(
        _ source: AsyncThrowingStream<AudioChunk, Error>,
        recorder: AudioChunkFileRecorder,
        bufferingPolicy: AsyncThrowingStream<AudioChunk, Error>.Continuation.BufferingPolicy = .bufferingNewest(8)
    ) -> AsyncThrowingStream<AudioChunk, Error> {
        AsyncThrowingStream(bufferingPolicy: bufferingPolicy) { continuation in
            let task = Task {
                do {
                    for try await chunk in source {
                        try Task.checkCancellation()
                        try await recorder.record(chunk)
                        continuation.yield(chunk)
                    }
                    _ = try? await recorder.finish()
                    continuation.finish()
                } catch {
                    _ = try? await recorder.finish()
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
                Task {
                    _ = try? await recorder.finish()
                }
            }
        }
    }
}
