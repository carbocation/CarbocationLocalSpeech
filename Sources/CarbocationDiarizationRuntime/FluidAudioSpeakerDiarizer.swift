import CarbocationLocalSpeech
import AVFoundation
@preconcurrency import CoreML
import FluidAudio
import Foundation

public enum FluidAudioSpeakerDiarizerError: Error, LocalizedError, Sendable {
    case modelAssetsMissing(String)
    case modelDownloadFailed(String)
    case lowDiskSpace(String)
    case modelCompilationFailed(String)
    case modelCompilationTimeout(String)
    case inferenceFailed(String)

    public var errorDescription: String? {
        switch self {
        case .modelAssetsMissing(let details):
            return "FluidAudio model assets missing: \(details)"
        case .modelDownloadFailed(let details):
            return "FluidAudio model download failed: \(details)"
        case .lowDiskSpace(let details):
            return "FluidAudio model installation failed because disk space is low: \(details)"
        case .modelCompilationFailed(let details):
            return "FluidAudio model compilation failed: \(details)"
        case .modelCompilationTimeout(let details):
            return "FluidAudio model compilation timed out: \(details)"
        case .inferenceFailed(let details):
            return "FluidAudio inference failed: \(details)"
        }
    }
}

@available(macOS 14.0, iOS 17.0, *)
public actor FluidAudioSpeakerDiarizer: CarbocationLocalSpeech.SpeakerDiarizer,
    CarbocationLocalSpeech.DiarizationModelLifecycle {
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

    public func installModels(
        onProgress: @escaping @Sendable (FluidAudioModelInstallProgress) -> Void = { _ in }
    ) async throws {
        onProgress(FluidAudioModelInstallProgress(fractionCompleted: 0, phase: .starting(nil)))
        do {
            try Task.checkCancellation()
            models = try await OfflineDiarizerModels.load(
                from: modelsDirectory,
                configuration: modelConfiguration,
                progressHandler: { progress in
                    onProgress(FluidAudioModelInstallDiagnostics.mapProgress(progress))
                }
            )
            try Task.checkCancellation()
            onProgress(FluidAudioModelInstallProgress(fractionCompleted: 1, phase: .finished(nil)))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.installError(from: error)
        }
    }

    public func unloadModels() async throws {
        models = nil
    }

    internal nonisolated static func installError(from error: Error) -> FluidAudioSpeakerDiarizerError {
        if let error = error as? FluidAudioSpeakerDiarizerError {
            return error
        }

        let (kind, detail) = FluidAudioModelInstallDiagnostics.classify(error)
        switch kind {
        case .downloadFailed:
            return .modelDownloadFailed(detail)
        case .lowDiskSpace:
            return .lowDiskSpace(detail)
        case .compilationFailed:
            return .modelCompilationFailed(detail)
        case .compilationTimeout:
            return .modelCompilationTimeout(detail)
        case .modelAssetsMissing:
            return .modelAssetsMissing(detail)
        }
    }

    internal func buildConfig(for options: CarbocationLocalSpeech.DiarizationOptions) -> OfflineDiarizerConfig {
        var config = baseConfig
        if let exactSpeakerCount = options.exactSpeakerCount {
            config.clustering.numSpeakers = exactSpeakerCount
            config.clustering.minSpeakers = nil
            config.clustering.maxSpeakers = nil
        } else if options.minimumSpeakerCount != nil || options.maximumSpeakerCount != nil {
            config.clustering.minSpeakers = options.minimumSpeakerCount
            config.clustering.maxSpeakers = options.maximumSpeakerCount
            config.clustering.numSpeakers = nil
        }
        return config
    }

    public func diarize(
        audio: CarbocationLocalSpeech.PreparedAudio,
        options: CarbocationLocalSpeech.DiarizationOptions
    ) async throws -> CarbocationLocalSpeech.DiarizationResult {
        try options.validate()
        try Task.checkCancellation()
        guard let models else {
            throw FluidAudioSpeakerDiarizerError.modelAssetsMissing(
                "Call FluidAudioSpeakerDiarizer.installModels() before diarize(audio:options:)."
            )
        }

        let config = buildConfig(for: options)
        let manager = OfflineDiarizerManager(config: config)
        manager.initialize(models: models)

        do {
            try Task.checkCancellation()
            let samples = try resampledSamplesIfNeeded(
                audio: audio,
                targetSampleRate: Double(config.segmentation.sampleRate)
            )
            let fluidResult = try await manager.process(audio: samples)
            try Task.checkCancellation()
            return map(
                segments: fluidResult.segments,
                timings: fluidResult.timings,
                audioDuration: audio.duration,
                minimumTurnDuration: options.minimumTurnDuration,
                exclusiveOutput: config.postProcessing.exclusiveSegments
            )
        } catch let error as FluidAudioSpeakerDiarizerError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw FluidAudioSpeakerDiarizerError.inferenceFailed(error.localizedDescription)
        }
    }

    public func diarize(
        file url: URL,
        options: CarbocationLocalSpeech.DiarizationOptions
    ) async throws -> CarbocationLocalSpeech.DiarizationResult {
        try options.validate()
        try Task.checkCancellation()
        guard let models else {
            throw FluidAudioSpeakerDiarizerError.modelAssetsMissing(
                "Call FluidAudioSpeakerDiarizer.installModels() before diarize(file:options:)."
            )
        }

        let config = buildConfig(for: options)
        let manager = OfflineDiarizerManager(config: config)
        manager.initialize(models: models)

        do {
            try Task.checkCancellation()
            let fluidResult = try await manager.process(url)
            try Task.checkCancellation()
            let duration = await audioDuration(forFile: url)
                ?? fluidResult.segments.map { TimeInterval($0.endTimeSeconds) }.max()
                ?? 0
            return map(
                segments: fluidResult.segments,
                timings: fluidResult.timings,
                audioDuration: duration,
                minimumTurnDuration: options.minimumTurnDuration,
                exclusiveOutput: config.postProcessing.exclusiveSegments
            )
        } catch let error as FluidAudioSpeakerDiarizerError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw FluidAudioSpeakerDiarizerError.inferenceFailed(error.localizedDescription)
        }
    }

    private nonisolated func audioDuration(forFile url: URL) async -> TimeInterval? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite && seconds > 0 ? seconds : nil
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
