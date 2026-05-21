import CarbocationLocalSpeech
@preconcurrency import CoreML
import FluidAudio
import Foundation

public enum FluidAudioStreamingSpeakerDiarizerError: Error, LocalizedError, Sendable {
    case modelAssetsMissing(String)
    case modelDownloadFailed(String)
    case lowDiskSpace(String)
    case modelCompilationFailed(String)
    case modelCompilationTimeout(String)
    case inferenceFailed(String)
    case operationInProgress(String)

    public var errorDescription: String? {
        switch self {
        case .modelAssetsMissing(let details):
            return "FluidAudio streaming model assets missing: \(details)"
        case .modelDownloadFailed(let details):
            return "FluidAudio streaming model download failed: \(details)"
        case .lowDiskSpace(let details):
            return "FluidAudio streaming model installation failed because disk space is low: \(details)"
        case .modelCompilationFailed(let details):
            return "FluidAudio streaming model compilation failed: \(details)"
        case .modelCompilationTimeout(let details):
            return "FluidAudio streaming model compilation timed out: \(details)"
        case .inferenceFailed(let details):
            return "FluidAudio streaming inference failed: \(details)"
        case .operationInProgress(let details):
            return "FluidAudio streaming diarizer operation already in progress: \(details)"
        }
    }
}

public struct FluidAudioStreamingComputeUnits: Sendable {
    public var sortformer: MLComputeUnits
    public var lsEEND: MLComputeUnits

    public init(sortformer: MLComputeUnits = .all, lsEEND: MLComputeUnits = .all) {
        self.sortformer = sortformer
        self.lsEEND = lsEEND
    }

    public static func uniform(_ computeUnits: MLComputeUnits) -> FluidAudioStreamingComputeUnits {
        FluidAudioStreamingComputeUnits(sortformer: computeUnits, lsEEND: computeUnits)
    }
}

@available(macOS 14.0, iOS 17.0, *)
public actor FluidAudioStreamingSpeakerDiarizer: CarbocationLocalSpeech.StreamingSpeakerDiarizer,
    CarbocationLocalSpeech.DiarizationModelLifecycle {
    private enum ActiveOperation: Sendable, Equatable {
        case installing(UUID)
        case streaming(UUID)

        var description: String {
            switch self {
            case .installing:
                return "model installation"
            case .streaming:
                return "streaming session"
            }
        }
    }

    private let modelsDirectory: URL?
    private let computeUnits: FluidAudioStreamingComputeUnits
    private let sortformerConfig: SortformerConfig
    private let lseendVariant: LSEENDVariant
    private let lseendStepSize: LSEENDStepSize

    private var sortformerDiarizer: (any Diarizer)?
    private var lseendDiarizer: (any Diarizer)?
    private var activeOperation: ActiveOperation?

    public init(
        modelsDirectory: URL? = nil,
        computeUnits: MLComputeUnits = .all,
        sortformerConfig: SortformerConfig = .fastV2_1,
        lseendVariant: LSEENDVariant = .dihard3,
        lseendStepSize: LSEENDStepSize = .step100ms
    ) {
        self.modelsDirectory = modelsDirectory
        self.computeUnits = .uniform(computeUnits)
        self.sortformerConfig = sortformerConfig
        self.lseendVariant = lseendVariant
        self.lseendStepSize = lseendStepSize
    }

    public init(
        modelsDirectory: URL? = nil,
        computeUnits: FluidAudioStreamingComputeUnits,
        sortformerConfig: SortformerConfig = .fastV2_1,
        lseendVariant: LSEENDVariant = .dihard3,
        lseendStepSize: LSEENDStepSize = .step100ms
    ) {
        self.modelsDirectory = modelsDirectory
        self.computeUnits = computeUnits
        self.sortformerConfig = sortformerConfig
        self.lseendVariant = lseendVariant
        self.lseendStepSize = lseendStepSize
    }

    internal init(
        sortformerDiarizer: (any Diarizer)? = nil,
        lseendDiarizer: (any Diarizer)? = nil
    ) {
        self.modelsDirectory = nil
        self.computeUnits = .uniform(.all)
        self.sortformerConfig = .fastV2_1
        self.lseendVariant = .dihard3
        self.lseendStepSize = .step100ms
        self.sortformerDiarizer = sortformerDiarizer
        self.lseendDiarizer = lseendDiarizer
    }

    public func installModels(
        backend: StreamingDiarizationBackend = .automatic,
        onProgress: @escaping @Sendable (FluidAudioModelInstallProgress) -> Void = { _ in }
    ) async throws {
        let operationID = try beginOperation(.installing(UUID()))
        defer { endOperation(operationID) }

        onProgress(FluidAudioModelInstallProgress(fractionCompleted: 0, phase: .starting(backend)))
        do {
            switch backend {
            case .automatic, .sortformer:
                try await installSortformer(onProgress: onProgress)
            case .lsEEND:
                try await installLSEEND(onProgress: onProgress)
            }
            onProgress(FluidAudioModelInstallProgress(fractionCompleted: 1, phase: .finished(backend)))
        } catch let error as FluidAudioStreamingSpeakerDiarizerError {
            throw error
        } catch {
            throw Self.installError(from: error)
        }
    }

    public nonisolated func stream(
        audio: AsyncThrowingStream<AudioChunk, Error>,
        options: StreamingDiarizationOptions
    ) -> AsyncThrowingStream<StreamingDiarizationSnapshot, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.runStream(
                        audio: audio,
                        options: options,
                        continuation: continuation
                    )
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

    public func unloadModels() async throws {
        if let activeOperation {
            throw FluidAudioStreamingSpeakerDiarizerError.operationInProgress(
                "Cannot unload models while \(activeOperation.description) is active."
            )
        }
        sortformerDiarizer?.cleanup()
        lseendDiarizer?.cleanup()
        sortformerDiarizer = nil
        lseendDiarizer = nil
    }

    private func installSortformer(
        onProgress: @escaping @Sendable (FluidAudioModelInstallProgress) -> Void
    ) async throws {
        let models = try await SortformerModels.loadFromHuggingFace(
            config: sortformerConfig,
            cacheDirectory: modelsDirectory,
            computeUnits: computeUnits.sortformer,
            progressHandler: { progress in
                onProgress(FluidAudioModelInstallDiagnostics.mapProgress(progress))
            }
        )
        let diarizer = SortformerDiarizer(config: sortformerConfig)
        diarizer.initialize(models: models)
        sortformerDiarizer = diarizer
    }

    private func installLSEEND(
        onProgress: @escaping @Sendable (FluidAudioModelInstallProgress) -> Void
    ) async throws {
        let diarizer = LSEENDDiarizer()
        try await diarizer.initialize(
            variant: lseendVariant,
            stepSize: lseendStepSize,
            cacheDirectory: modelsDirectory,
            computeUnits: computeUnits.lsEEND,
            progressHandler: { progress in
                onProgress(FluidAudioModelInstallDiagnostics.mapProgress(progress))
            }
        )
        lseendDiarizer = diarizer
    }

    private func runStream(
        audio: AsyncThrowingStream<AudioChunk, Error>,
        options: StreamingDiarizationOptions,
        continuation: AsyncThrowingStream<StreamingDiarizationSnapshot, Error>.Continuation
    ) async throws {
        try options.options.validate()
        let operationID = try beginOperation(.streaming(UUID()))
        defer { endOperation(operationID) }

        let (diarizer, backend, displayName) = try resolveDiarizer(for: options.backend)
        diarizer.reset()

        var baseTime: TimeInterval?
        var recoveryGeneration = 0

        do {
            for try await chunk in audio {
                try Task.checkCancellation()

                if chunk.recoveryEvent != nil {
                    diarizer.reset()
                    baseTime = chunk.startTime
                    recoveryGeneration += 1
                } else if baseTime == nil {
                    baseTime = chunk.startTime
                }

                guard let currentBaseTime = baseTime else { continue }
                if try diarizer.process(samples: chunk.samples, sourceSampleRate: chunk.sampleRate) != nil {
                    let snapshot = Self.mapSnapshot(
                        finalizedSegments: Self.finalizedSegments(from: diarizer.timeline),
                        tentativeSegments: Self.tentativeSegments(from: diarizer.timeline),
                        baseTime: currentBaseTime,
                        options: options,
                        backend: backend,
                        displayName: displayName,
                        speakerNamespace: Self.speakerNamespace(forRecoveryGeneration: recoveryGeneration)
                    )
                    if snapshot.hasTurns {
                        continuation.yield(snapshot)
                    }
                }
            }

            if let currentBaseTime = baseTime {
                _ = try diarizer.finalizeSession()
                let snapshot = Self.mapSnapshot(
                    finalizedSegments: Self.finalizedSegments(from: diarizer.timeline),
                    tentativeSegments: [],
                    baseTime: currentBaseTime,
                    options: options,
                    backend: backend,
                    displayName: displayName,
                    speakerNamespace: Self.speakerNamespace(forRecoveryGeneration: recoveryGeneration)
                )
                if snapshot.hasTurns {
                    continuation.yield(snapshot)
                }
            }
        } catch let error as FluidAudioStreamingSpeakerDiarizerError {
            throw error
        } catch {
            throw FluidAudioStreamingSpeakerDiarizerError.inferenceFailed(error.localizedDescription)
        }
    }

    @discardableResult
    private func beginOperation(_ operation: ActiveOperation) throws -> UUID {
        if let activeOperation {
            throw FluidAudioStreamingSpeakerDiarizerError.operationInProgress(
                "Cannot start \(operation.description) while \(activeOperation.description) is active."
            )
        }

        activeOperation = operation
        switch operation {
        case .installing(let id), .streaming(let id):
            return id
        }
    }

    private func endOperation(_ id: UUID) {
        switch activeOperation {
        case .installing(id), .streaming(id):
            activeOperation = nil
        case .installing, .streaming, nil:
            break
        }
    }

    internal nonisolated static func installError(from error: Error) -> FluidAudioStreamingSpeakerDiarizerError {
        if let error = error as? FluidAudioStreamingSpeakerDiarizerError {
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

    private func resolveDiarizer(
        for backend: StreamingDiarizationBackend
    ) throws -> (any Diarizer, StreamingDiarizationBackend, String) {
        switch backend {
        case .automatic:
            if let sortformerDiarizer {
                return (sortformerDiarizer, StreamingDiarizationBackend.sortformer, "FluidAudio Streaming Sortformer")
            }
            if let lseendDiarizer {
                return (lseendDiarizer, StreamingDiarizationBackend.lsEEND, "FluidAudio Streaming LS-EEND")
            }
            throw FluidAudioStreamingSpeakerDiarizerError.modelAssetsMissing(
                "Call FluidAudioStreamingSpeakerDiarizer.installModels() before stream(audio:options:)."
            )
        case .sortformer:
            guard let sortformerDiarizer else {
                throw FluidAudioStreamingSpeakerDiarizerError.modelAssetsMissing(
                    "Call FluidAudioStreamingSpeakerDiarizer.installModels(backend: .sortformer) before streaming Sortformer diarization."
                )
            }
            return (sortformerDiarizer, StreamingDiarizationBackend.sortformer, "FluidAudio Streaming Sortformer")
        case .lsEEND:
            guard let lseendDiarizer else {
                throw FluidAudioStreamingSpeakerDiarizerError.modelAssetsMissing(
                    "Call FluidAudioStreamingSpeakerDiarizer.installModels(backend: .lsEEND) before streaming LS-EEND diarization."
                )
            }
            return (lseendDiarizer, StreamingDiarizationBackend.lsEEND, "FluidAudio Streaming LS-EEND")
        }
    }

    internal nonisolated static func mapSnapshot(
        finalizedSegments: [DiarizerSegment],
        tentativeSegments: [DiarizerSegment],
        baseTime: TimeInterval,
        options: StreamingDiarizationOptions,
        backend: StreamingDiarizationBackend,
        displayName: String,
        speakerNamespace: String? = nil
    ) -> StreamingDiarizationSnapshot {
        let backendDescriptor = SpeechBackendDescriptor(kind: .fluidAudio, displayName: displayName)
        let stable = mapResult(
            segments: finalizedSegments,
            baseTime: baseTime,
            minimumTurnDuration: options.options.minimumTurnDuration,
            backend: backendDescriptor,
            source: sourceName(base: "FluidAudio.streaming.\(backend.rawValue)", speakerNamespace: speakerNamespace),
            speakerNamespace: speakerNamespace
        )

        guard options.emitsTentativeTurns else {
            return StreamingDiarizationSnapshot(stable: stable)
        }

        let volatile = mapResult(
            segments: tentativeSegments,
            baseTime: baseTime,
            minimumTurnDuration: options.options.minimumTurnDuration,
            backend: backendDescriptor,
            source: sourceName(
                base: "FluidAudio.streaming.\(backend.rawValue).tentative",
                speakerNamespace: speakerNamespace
            ),
            speakerNamespace: speakerNamespace
        )
        let volatileRange = volatile.turns.isEmpty
            ? nil
            : TranscriptTimeRange(
                startTime: volatile.turns.map(\.startTime).min() ?? 0,
                endTime: volatile.turns.map(\.endTime).max() ?? 0
            )

        return StreamingDiarizationSnapshot(
            stable: stable,
            volatile: volatile.turns.isEmpty ? nil : volatile,
            volatileRange: volatileRange
        )
    }

    private nonisolated static func mapResult(
        segments: [DiarizerSegment],
        baseTime: TimeInterval,
        minimumTurnDuration: TimeInterval,
        backend: SpeechBackendDescriptor,
        source: String,
        speakerNamespace: String?
    ) -> CarbocationLocalSpeech.DiarizationResult {
        let filtered = segments
            .filter { TimeInterval($0.duration) >= minimumTurnDuration }
            .sorted { lhs, rhs in
                if lhs.startTime == rhs.startTime {
                    return lhs.speakerIndex < rhs.speakerIndex
                }
                return lhs.startTime < rhs.startTime
            }

        let overlapFlags = filtered.map { segment in
            filtered.contains { other in
                other.speakerIndex != segment.speakerIndex
                    && other.startTime < segment.endTime
                    && segment.startTime < other.endTime
            }
        }

        let turns = filtered.enumerated().map { index, segment in
            let speakerID = speakerID(for: segment.speakerIndex, namespace: speakerNamespace)
            return SpeakerTurn(
                speaker: speakerID,
                startTime: baseTime + TimeInterval(segment.startTime),
                endTime: baseTime + TimeInterval(segment.endTime),
                confidence: segment.activity > 0 ? Double(segment.activity) : nil,
                isOverlap: overlapFlags[index],
                isExclusive: false,
                source: source
            )
        }

        let speakers = buildSpeakers(from: turns)
        return CarbocationLocalSpeech.DiarizationResult(
            turns: turns,
            exclusiveTurns: [],
            speakers: speakers,
            duration: max(0, turns.map(\.endTime).max() ?? 0),
            backend: backend
        )
    }

    private nonisolated static func speakerNamespace(forRecoveryGeneration recoveryGeneration: Int) -> String? {
        recoveryGeneration > 0 ? "recovery_\(recoveryGeneration)" : nil
    }

    private nonisolated static func sourceName(base: String, speakerNamespace: String?) -> String {
        guard let speakerNamespace else { return base }
        return "\(base).\(speakerNamespace)"
    }

    private nonisolated static func buildSpeakers(from turns: [SpeakerTurn]) -> [CarbocationLocalSpeech.Speaker] {
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
                displayName: displayName(for: speakerID),
                confidence: averageConfidence,
                metadata: ["source": "FluidAudio.streaming"]
            )
        }
    }

    private nonisolated static func speakerID(for speakerIndex: Int, namespace: String?) -> SpeakerID {
        let rawValue = namespace.map { "\($0)_speaker_\(speakerIndex)" } ?? "speaker_\(speakerIndex)"
        return SpeakerID(rawValue: rawValue)
    }

    private nonisolated static func displayName(for speakerID: SpeakerID) -> String {
        let parts = speakerID.rawValue.split(separator: "_")
        guard let index = parts.last else {
            return speakerID.rawValue
        }
        if parts.count >= 4,
           parts[0] == "recovery",
           parts[2] == "speaker" {
            return "Speaker \(index) (recovery \(parts[1]))"
        }
        return "Speaker \(index)"
    }

    private nonisolated static func finalizedSegments(from timeline: DiarizerTimeline) -> [DiarizerSegment] {
        timeline.speakers.values.flatMap(\.finalizedSegments)
    }

    private nonisolated static func tentativeSegments(from timeline: DiarizerTimeline) -> [DiarizerSegment] {
        timeline.speakers.values.flatMap(\.tentativeSegments)
    }
}

private extension StreamingDiarizationSnapshot {
    var hasTurns: Bool {
        !stable.turns.isEmpty || !(volatile?.turns.isEmpty ?? true)
    }
}
