import AVFoundation
import Foundation

public enum TemporaryAudioFormat: Sendable {
    case wavFloat32
    case cafFloat32

    public var fileExtension: String {
        switch self {
        case .wavFloat32:
            return "wav"
        case .cafFloat32:
            return "caf"
        }
    }

    var baseSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }
}

public struct AudioTemporaryFileWriter: Sendable {
    public init() {}

    public func write(audio: PreparedAudio, format: TemporaryAudioFormat = .wavFloat32) throws -> URL {
        guard audio.sampleRate > 0 else {
            throw AudioPreparationError.unsupportedFormat("Sample rate must be positive.")
        }

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("diarization-\(UUID().uuidString).\(format.fileExtension)")

        var settings = format.baseSettings
        settings[AVSampleRateKey] = audio.sampleRate
        settings[AVNumberOfChannelsKey] = 1

        let audioFile = try AVAudioFile(forWriting: fileURL, settings: settings)
        guard let bufferFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: audio.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioPreparationError.unsupportedFormat("Failed to create Float32 mono format.")
        }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: bufferFormat,
            frameCapacity: AVAudioFrameCount(max(1, audio.samples.count))
        ) else {
            throw AudioPreparationError.unreadableAudio(fileURL)
        }

        buffer.frameLength = AVAudioFrameCount(audio.samples.count)
        guard let floatData = buffer.floatChannelData?[0] else {
            throw AudioPreparationError.unsupportedFormat("Failed to access Float32 channel data for temporary write.")
        }

        for index in audio.samples.indices {
            floatData[index] = audio.samples[index]
        }

        try audioFile.write(from: buffer)
        return fileURL
    }
}
