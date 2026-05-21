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
    private let memoryPressurePolicy: FluidAudioModelMemoryPressurePolicy
    nonisolated(unsafe) private var memoryPressureMonitor: FluidAudioMemoryPressureMonitor?
    private var models: OfflineDiarizerModels?
    private var activeModelOperationCount = 0
    private var pendingMemoryPressureEviction = false

    public init(
        config: OfflineDiarizerConfig = .default,
        modelsDirectory: URL? = nil,
        modelConfiguration: MLModelConfiguration? = nil,
        memoryPressurePolicy: FluidAudioModelMemoryPressurePolicy = .evictWhenIdle
    ) {
        self.baseConfig = config
        self.modelsDirectory = modelsDirectory
        self.modelConfiguration = modelConfiguration
        self.memoryPressurePolicy = memoryPressurePolicy
        if memoryPressurePolicy != .disabled {
            self.memoryPressureMonitor = FluidAudioMemoryPressureMonitor { [weak self] _ in
                Task {
                    await self?.handleMemoryPressure()
                }
            }
        } else {
            self.memoryPressureMonitor = nil
        }
    }

    public func installModels(
        onProgress: @escaping @Sendable (FluidAudioModelInstallProgress) -> Void = { _ in }
    ) async throws {
        beginModelOperation()
        defer { endModelOperation() }

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
        pendingMemoryPressureEviction = false
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
        beginModelOperation()
        defer { endModelOperation() }

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
                speakerDatabase: fluidResult.speakerDatabase,
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
        beginModelOperation()
        defer { endModelOperation() }

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
                speakerDatabase: fluidResult.speakerDatabase,
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

    private func beginModelOperation() {
        activeModelOperationCount += 1
    }

    private func endModelOperation() {
        activeModelOperationCount = max(0, activeModelOperationCount - 1)
        evictModelsIfIdleForMemoryPressure()
    }

    private func handleMemoryPressure() {
        guard memoryPressurePolicy == .evictWhenIdle else { return }
        pendingMemoryPressureEviction = true
        evictModelsIfIdleForMemoryPressure()
    }

    private func evictModelsIfIdleForMemoryPressure() {
        guard pendingMemoryPressureEviction,
              activeModelOperationCount == 0
        else {
            return
        }

        models = nil
        pendingMemoryPressureEviction = false
    }

    internal func simulateMemoryPressureForTesting() {
        handleMemoryPressure()
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

    internal nonisolated func map(
        segments: [TimedSpeakerSegment],
        speakerDatabase: [String: [Float]]? = nil,
        timings: PipelineTimings?,
        audioDuration: TimeInterval,
        minimumTurnDuration: TimeInterval,
        exclusiveOutput: Bool
    ) -> CarbocationLocalSpeech.DiarizationResult {
        let filteredSegments = segments
            .filter { TimeInterval($0.durationSeconds) >= minimumTurnDuration }

        let turns: [SpeakerTurn] = filteredSegments
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
        let speakerVoiceEmbeddings = buildSpeakerVoiceEmbeddings(
            from: filteredSegments,
            speakerDatabase: speakerDatabase,
            orderedSpeakerIDs: speakers.map(\.id)
        )
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
            speakerVoiceEmbeddings: speakerVoiceEmbeddings,
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

    private nonisolated func buildSpeakerVoiceEmbeddings(
        from segments: [TimedSpeakerSegment],
        speakerDatabase: [String: [Float]]?,
        orderedSpeakerIDs: [SpeakerID]
    ) -> [CarbocationLocalSpeech.SpeakerVoiceEmbedding] {
        orderedSpeakerIDs.compactMap { speakerID in
            let speakerSegments = segments.filter { $0.speakerId == speakerID.rawValue }
            let databaseEmbedding = validEmbedding(speakerDatabase?[speakerID.rawValue])
            let vector = databaseEmbedding ?? averagedEmbedding(from: speakerSegments)
            guard let vector else { return nil }

            let speechDuration = speakerSegments.reduce(0) { total, segment in
                total + TimeInterval(segment.durationSeconds)
            }
            let sampleCount = max(
                1,
                speakerSegments.filter { validEmbedding($0.embedding) != nil }.count
            )
            let quality = averagedQuality(from: speakerSegments)

            return CarbocationLocalSpeech.SpeakerVoiceEmbedding(
                speaker: speakerID,
                vector: vector,
                modelIdentifier: "FluidAudio.WeSpeaker.v2",
                source: "FluidAudio.offline",
                speechDuration: speechDuration,
                sampleCount: sampleCount,
                quality: quality,
                metadata: [
                    "backend": "FluidAudio",
                    "embeddingSource": databaseEmbedding == nil ? "segmentAverage" : "speakerDatabase"
                ]
            )
        }
    }

    private nonisolated func validEmbedding(_ embedding: [Float]?) -> [Float]? {
        guard let embedding,
              !embedding.isEmpty
        else {
            return nil
        }
        var magnitudeSquared: Float = 0
        for value in embedding {
            guard value.isFinite else { return nil }
            magnitudeSquared += value * value
        }
        guard magnitudeSquared > 0 else { return nil }
        return embedding
    }

    private nonisolated func averagedEmbedding(from segments: [TimedSpeakerSegment]) -> [Float]? {
        let embeddings = segments.compactMap { validEmbedding($0.embedding) }
        guard let first = embeddings.first else { return nil }

        var sum = [Float](repeating: 0, count: first.count)
        var count = 0
        for embedding in embeddings where embedding.count == first.count {
            for index in embedding.indices {
                sum[index] += embedding[index]
            }
            count += 1
        }
        guard count > 0 else { return nil }
        return sum.map { $0 / Float(count) }
    }

    private nonisolated func averagedQuality(from segments: [TimedSpeakerSegment]) -> Double? {
        guard !segments.isEmpty else { return nil }
        let total = segments.reduce(0) { partial, segment in
            partial + Double(segment.qualityScore)
        }
        return total / Double(segments.count)
    }
}
