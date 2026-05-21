import CarbocationLocalSpeech
@preconcurrency import CoreML
import FluidAudio
import Foundation

public enum FluidAudioSpeakerDiarizerError: Error, LocalizedError, Sendable {
    case modelAssetsMissing(String)
    case inferenceFailed(String)

    public var errorDescription: String? {
        switch self {
        case .modelAssetsMissing(let details):
            return "FluidAudio model assets missing: \(details)"
        case .inferenceFailed(let details):
            return "FluidAudio inference failed: \(details)"
        }
    }
}

@available(macOS 14.0, iOS 17.0, *)
public actor FluidAudioSpeakerDiarizer: CarbocationLocalSpeech.SpeakerDiarizer {
    private let modelsDirectory: URL?
    private let modelConfiguration: MLModelConfiguration?
    private let baseConfig: OfflineDiarizerConfig
    private var models: OfflineDiarizerModels?

    public init(
        config: OfflineDiarizerConfig = .default,
        modelsDirectory: URL? = nil,
        modelConfiguration: MLModelConfiguration? = nil
    ) {
        self.baseConfig = config
        self.modelsDirectory = modelsDirectory
        self.modelConfiguration = modelConfiguration
    }

    public func installModels() async throws {
        do {
            models = try await OfflineDiarizerModels.load(
                from: modelsDirectory,
                configuration: modelConfiguration
            )
        } catch {
            throw FluidAudioSpeakerDiarizerError.modelAssetsMissing(error.localizedDescription)
        }
    }

    public func diarize(
        audio: CarbocationLocalSpeech.PreparedAudio,
        options: CarbocationLocalSpeech.DiarizationOptions
    ) async throws -> CarbocationLocalSpeech.DiarizationResult {
        try options.validate()
        guard let models else {
            throw FluidAudioSpeakerDiarizerError.modelAssetsMissing(
                "Call FluidAudioSpeakerDiarizer.installModels() before diarize(audio:options:)."
            )
        }

        var config = baseConfig
        config.clustering.minSpeakers = options.minimumSpeakerCount
        config.clustering.maxSpeakers = options.maximumSpeakerCount
        config.clustering.numSpeakers = options.exactSpeakerCount

        let manager = OfflineDiarizerManager(config: config)
        manager.initialize(models: models)

        do {
            let samples = try resampledSamplesIfNeeded(
                audio: audio,
                targetSampleRate: Double(config.segmentation.sampleRate)
            )
            let fluidResult = try await manager.process(audio: samples)
            return map(
                segments: fluidResult.segments,
                timings: fluidResult.timings,
                audioDuration: audio.duration,
                minimumTurnDuration: options.minimumTurnDuration,
                exclusiveOutput: config.postProcessing.exclusiveSegments
            )
        } catch let error as FluidAudioSpeakerDiarizerError {
            throw error
        } catch {
            throw FluidAudioSpeakerDiarizerError.inferenceFailed(error.localizedDescription)
        }
    }

    private func resampledSamplesIfNeeded(
        audio: CarbocationLocalSpeech.PreparedAudio,
        targetSampleRate: Double
    ) throws -> [Float] {
        guard abs(audio.sampleRate - targetSampleRate) > 0.0001 else {
            return audio.samples
        }

        let chunk = AudioChunk(
            samples: audio.samples,
            sampleRate: audio.sampleRate,
            channelCount: 1,
            startTime: 0,
            duration: audio.duration
        )
        return try AudioResampler16kMono(targetSampleRate: targetSampleRate)
            .prepareChunk(chunk)
            .samples
    }

    private nonisolated func map(
        segments: [TimedSpeakerSegment],
        timings: PipelineTimings?,
        audioDuration: TimeInterval,
        minimumTurnDuration: TimeInterval,
        exclusiveOutput: Bool
    ) -> CarbocationLocalSpeech.DiarizationResult {
        let turns: [SpeakerTurn] = segments
            .filter { TimeInterval($0.durationSeconds) >= minimumTurnDuration }
            .map { segment in
                SpeakerTurn(
                    speaker: SpeakerID(rawValue: segment.speakerId),
                    startTime: TimeInterval(segment.startTimeSeconds),
                    endTime: TimeInterval(segment.endTimeSeconds),
                    confidence: Double(segment.qualityScore),
                    isOverlap: false,
                    isExclusive: exclusiveOutput,
                    source: "FluidAudio.offline"
                )
            }
            .sorted { lhs, rhs in
                if lhs.startTime == rhs.startTime {
                    return lhs.speaker.rawValue < rhs.speaker.rawValue
                }
                return lhs.startTime < rhs.startTime
            }

        let speakers = buildSpeakers(from: turns)
        let duration = max(audioDuration, turns.map { $0.endTime }.max() ?? 0)
        let diagnostics = timings.map { timings in
            [
                SpeechDiagnostic(
                    source: "FluidAudio.offline",
                    message: "Diarization completed in \(String(format: "%.3f", timings.totalProcessingSeconds))s"
                )
            ]
        } ?? []

        return CarbocationLocalSpeech.DiarizationResult(
            turns: turns,
            exclusiveTurns: exclusiveOutput ? turns : [],
            speakers: speakers,
            duration: duration,
            backend: SpeechBackendDescriptor(kind: .fluidAudio, displayName: "FluidAudio Offline Diarizer"),
            diagnostics: diagnostics
        )
    }

    private nonisolated func buildSpeakers(from turns: [SpeakerTurn]) -> [CarbocationLocalSpeech.Speaker] {
        var speakerIDs: [SpeakerID] = []
        var confidencesBySpeaker: [SpeakerID: [Double]] = [:]

        for turn in turns {
            if !speakerIDs.contains(turn.speaker) {
                speakerIDs.append(turn.speaker)
            }
            if let confidence = turn.confidence {
                confidencesBySpeaker[turn.speaker, default: []].append(confidence)
            }
        }

        return speakerIDs.map { speakerID in
            let confidences = confidencesBySpeaker[speakerID] ?? []
            let averageConfidence = confidences.isEmpty
                ? nil
                : confidences.reduce(0, +) / Double(confidences.count)
            return CarbocationLocalSpeech.Speaker(
                id: speakerID,
                displayName: speakerID.rawValue,
                confidence: averageConfidence,
                metadata: ["source": "FluidAudio.offline"]
            )
        }
    }
}
