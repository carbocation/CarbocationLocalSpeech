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
private protocol StreamingDiarizerSessionFactory: Sendable {
    func makeDiarizer() throws -> any Diarizer
    func cleanup()
}

@available(macOS 14.0, iOS 17.0, *)
private final class SortformerStreamingDiarizerSessionFactory: StreamingDiarizerSessionFactory, @unchecked Sendable {
    private let config: SortformerConfig
    private let mainModel: MLModel
    private let compilationDuration: TimeInterval

    init(models: SortformerModels, config: SortformerConfig) {
        self.config = config
        self.mainModel = models.mainModel
        self.compilationDuration = models.compilationDuration
    }

    func makeDiarizer() throws -> any Diarizer {
        let sessionModels = try SortformerModels(
            config: config,
            main: mainModel,
            compilationDuration: compilationDuration
        )
        let diarizer = SortformerDiarizer(config: config)
        diarizer.initialize(models: sessionModels)
        return diarizer
    }

    func cleanup() {}
}

@available(macOS 14.0, iOS 17.0, *)
private final class LSEENDStreamingDiarizerSessionFactory: StreamingDiarizerSessionFactory, @unchecked Sendable {
    private let model: LSEENDModel

    init(model: LSEENDModel) {
        self.model = model
    }

    func makeDiarizer() throws -> any Diarizer {
        let diarizer = LSEENDDiarizer()
        try diarizer.initialize(model: model)
        return diarizer
    }

    func cleanup() {}
}

@available(macOS 14.0, iOS 17.0, *)
private final class ClosureStreamingDiarizerSessionFactory: StreamingDiarizerSessionFactory, @unchecked Sendable {
    private let makeHandler: () throws -> any Diarizer
    private let cleanupHandler: () -> Void

    init(
        makeHandler: @escaping () throws -> any Diarizer,
        cleanupHandler: @escaping () -> Void = {}
    ) {
        self.makeHandler = makeHandler
        self.cleanupHandler = cleanupHandler
    }

    func makeDiarizer() throws -> any Diarizer {
        try makeHandler()
    }

    func cleanup() {
        cleanupHandler()
    }
}

@available(macOS 14.0, iOS 17.0, *)
private final class FluidAudioStreamingDiarizerSession: @unchecked Sendable {
    let id: UUID
    let diarizer: any Diarizer
    let backend: StreamingDiarizationBackend
    let displayName: String

    init(
        id: UUID,
        diarizer: any Diarizer,
        backend: StreamingDiarizationBackend,
        displayName: String
    ) {
        self.id = id
        self.diarizer = diarizer
        self.backend = backend
        self.displayName = displayName
    }
}

@available(macOS 14.0, iOS 17.0, *)
public actor FluidAudioStreamingSpeakerDiarizer: CarbocationLocalSpeech.StreamingSpeakerDiarizer,
    CarbocationLocalSpeech.DiarizationModelLifecycle {
    private let modelsDirectory: URL?
    private let computeUnits: FluidAudioStreamingComputeUnits
    private let sortformerConfig: SortformerConfig
    private let lseendVariant: LSEENDVariant
    private let lseendStepSize: LSEENDStepSize
    private let memoryPressurePolicy: FluidAudioModelMemoryPressurePolicy
    nonisolated(unsafe) private var memoryPressureMonitor: FluidAudioMemoryPressureMonitor?

    private var sortformerSessionFactory: (any StreamingDiarizerSessionFactory)?
    private var lseendSessionFactory: (any StreamingDiarizerSessionFactory)?
    private var activeInstallID: UUID?
    private var activeStreamIDs = Set<UUID>()
    private var pendingMemoryPressureEviction = false

    public init(
        modelsDirectory: URL? = nil,
        computeUnits: MLComputeUnits = .all,
        sortformerConfig: SortformerConfig = .fastV2_1,
        lseendVariant: LSEENDVariant = .dihard3,
        lseendStepSize: LSEENDStepSize = .step100ms,
        memoryPressurePolicy: FluidAudioModelMemoryPressurePolicy = .evictWhenIdle
    ) {
        self.modelsDirectory = modelsDirectory
        self.computeUnits = .uniform(computeUnits)
        self.sortformerConfig = sortformerConfig
        self.lseendVariant = lseendVariant
        self.lseendStepSize = lseendStepSize
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

    public init(
        modelsDirectory: URL? = nil,
        computeUnits: FluidAudioStreamingComputeUnits,
        sortformerConfig: SortformerConfig = .fastV2_1,
        lseendVariant: LSEENDVariant = .dihard3,
        lseendStepSize: LSEENDStepSize = .step100ms,
        memoryPressurePolicy: FluidAudioModelMemoryPressurePolicy = .evictWhenIdle
    ) {
        self.modelsDirectory = modelsDirectory
        self.computeUnits = computeUnits
        self.sortformerConfig = sortformerConfig
        self.lseendVariant = lseendVariant
        self.lseendStepSize = lseendStepSize
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

    internal init(
        sortformerDiarizer: (any Diarizer)? = nil,
        lseendDiarizer: (any Diarizer)? = nil,
        memoryPressurePolicy: FluidAudioModelMemoryPressurePolicy = .disabled
    ) {
        self.modelsDirectory = nil
        self.computeUnits = .uniform(.all)
        self.sortformerConfig = .fastV2_1
        self.lseendVariant = .dihard3
        self.lseendStepSize = .step100ms
        self.memoryPressurePolicy = memoryPressurePolicy
        if let sortformerDiarizer {
            self.sortformerSessionFactory = ClosureStreamingDiarizerSessionFactory(
                makeHandler: { sortformerDiarizer },
                cleanupHandler: { sortformerDiarizer.cleanup() }
            )
        }
        if let lseendDiarizer {
            self.lseendSessionFactory = ClosureStreamingDiarizerSessionFactory(
                makeHandler: { lseendDiarizer },
                cleanupHandler: { lseendDiarizer.cleanup() }
            )
        }
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

    internal init(
        sortformerSessionFactory: @escaping () throws -> any Diarizer,
        lseendSessionFactory: (() throws -> any Diarizer)? = nil,
        memoryPressurePolicy: FluidAudioModelMemoryPressurePolicy = .disabled
    ) {
        self.modelsDirectory = nil
        self.computeUnits = .uniform(.all)
        self.sortformerConfig = .fastV2_1
        self.lseendVariant = .dihard3
        self.lseendStepSize = .step100ms
        self.memoryPressurePolicy = memoryPressurePolicy
        self.sortformerSessionFactory = ClosureStreamingDiarizerSessionFactory(makeHandler: sortformerSessionFactory)
        if let lseendSessionFactory {
            self.lseendSessionFactory = ClosureStreamingDiarizerSessionFactory(makeHandler: lseendSessionFactory)
        }
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
        backend: StreamingDiarizationBackend = .automatic,
        onProgress: @escaping @Sendable (FluidAudioModelInstallProgress) -> Void = { _ in }
    ) async throws {
        let operationID = try beginInstall()
        defer { endInstall(operationID) }

        onProgress(FluidAudioModelInstallProgress(fractionCompleted: 0, phase: .starting(backend)))
        do {
            try Task.checkCancellation()
            switch backend {
            case .automatic, .sortformer:
                try await installSortformer(onProgress: onProgress)
            case .lsEEND:
                try await installLSEEND(onProgress: onProgress)
            }
            try Task.checkCancellation()
            onProgress(FluidAudioModelInstallProgress(fractionCompleted: 1, phase: .finished(backend)))
        } catch let error as FluidAudioStreamingSpeakerDiarizerError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
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
                    try options.options.validate()
                    try Task.checkCancellation()
                    let session = try await self.makeSession(for: options.backend)
                    do {
                        try await Self.runStreamSession(
                            audio: audio,
                            options: options,
                            continuation: continuation,
                            session: session
                        )
                        session.diarizer.cleanup()
                        await self.endStream(session.id)
                    } catch {
                        session.diarizer.cleanup()
                        await self.endStream(session.id)
                        throw error
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

    public func unloadModels() async throws {
        if let activeInstallID {
            throw FluidAudioStreamingSpeakerDiarizerError.operationInProgress(
                "Cannot unload models while model installation \(activeInstallID) is active."
            )
        }
        if !activeStreamIDs.isEmpty {
            throw FluidAudioStreamingSpeakerDiarizerError.operationInProgress(
                "Cannot unload models while \(activeStreamIDs.count) streaming session(s) are active."
            )
        }
        pendingMemoryPressureEviction = false
        evictInstalledModels()
    }

    private func evictInstalledModels() {
        sortformerSessionFactory?.cleanup()
        lseendSessionFactory?.cleanup()
        sortformerSessionFactory = nil
        lseendSessionFactory = nil
    }

    private func handleMemoryPressure() {
        guard memoryPressurePolicy == .evictWhenIdle else { return }
        pendingMemoryPressureEviction = true
        evictModelsIfIdleForMemoryPressure()
    }

    private func evictModelsIfIdleForMemoryPressure() {
        guard pendingMemoryPressureEviction,
              activeInstallID == nil,
              activeStreamIDs.isEmpty
        else {
            return
        }

        evictInstalledModels()
        pendingMemoryPressureEviction = false
    }

    internal func simulateMemoryPressureForTesting() {
        handleMemoryPressure()
    }

    private func installSortformer(
        onProgress: @escaping @Sendable (FluidAudioModelInstallProgress) -> Void
    ) async throws {
        try Task.checkCancellation()
        let models = try await SortformerModels.loadFromHuggingFace(
            config: sortformerConfig,
            cacheDirectory: modelsDirectory,
            computeUnits: computeUnits.sortformer,
            progressHandler: { progress in
                onProgress(FluidAudioModelInstallDiagnostics.mapProgress(progress))
            }
        )
        try Task.checkCancellation()
        sortformerSessionFactory = SortformerStreamingDiarizerSessionFactory(
            models: models,
            config: sortformerConfig
        )
    }

    private func installLSEEND(
        onProgress: @escaping @Sendable (FluidAudioModelInstallProgress) -> Void
    ) async throws {
        try Task.checkCancellation()
        let model = try await LSEENDModel.loadFromHuggingFace(
            variant: lseendVariant,
            stepSize: lseendStepSize,
            cacheDirectory: modelsDirectory,
            computeUnits: computeUnits.lsEEND,
            progressHandler: { progress in
                onProgress(FluidAudioModelInstallDiagnostics.mapProgress(progress))
            }
        )
        try Task.checkCancellation()
        lseendSessionFactory = LSEENDStreamingDiarizerSessionFactory(model: model)
    }

    private nonisolated static func runStreamSession(
        audio: AsyncThrowingStream<AudioChunk, Error>,
        options: StreamingDiarizationOptions,
        continuation: AsyncThrowingStream<StreamingDiarizationSnapshot, Error>.Continuation,
        session: FluidAudioStreamingDiarizerSession
    ) async throws {
        let diarizer = session.diarizer
        var baseTime: TimeInterval?
        var recoveryGeneration = 0

        do {
            diarizer.reset()
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
                        backend: session.backend,
                        displayName: session.displayName,
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
                    backend: session.backend,
                    displayName: session.displayName,
                    speakerNamespace: Self.speakerNamespace(forRecoveryGeneration: recoveryGeneration)
                )
                if snapshot.hasTurns {
                    continuation.yield(snapshot)
                }
            }
        } catch let error as FluidAudioStreamingSpeakerDiarizerError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw FluidAudioStreamingSpeakerDiarizerError.inferenceFailed(error.localizedDescription)
        }
    }

    @discardableResult
    private func beginInstall() throws -> UUID {
        if let activeInstallID {
            throw FluidAudioStreamingSpeakerDiarizerError.operationInProgress(
                "Cannot start model installation while model installation \(activeInstallID) is active."
            )
        }
        if !activeStreamIDs.isEmpty {
            throw FluidAudioStreamingSpeakerDiarizerError.operationInProgress(
                "Cannot start model installation while \(activeStreamIDs.count) streaming session(s) are active."
            )
        }
        let id = UUID()
        activeInstallID = id
        return id
    }

    private func endInstall(_ id: UUID) {
        guard activeInstallID == id else { return }
        activeInstallID = nil
        evictModelsIfIdleForMemoryPressure()
    }

    private func makeSession(
        for backend: StreamingDiarizationBackend
    ) throws -> FluidAudioStreamingDiarizerSession {
        if let activeInstallID {
            throw FluidAudioStreamingSpeakerDiarizerError.operationInProgress(
                "Cannot start streaming session while model installation \(activeInstallID) is active."
            )
        }
        let (factory, resolvedBackend, displayName) = try resolveSessionFactory(for: backend)
        let id = UUID()
        activeStreamIDs.insert(id)
        do {
            let diarizer = try factory.makeDiarizer()
            return FluidAudioStreamingDiarizerSession(
                id: id,
                diarizer: diarizer,
                backend: resolvedBackend,
                displayName: displayName
            )
        } catch {
            activeStreamIDs.remove(id)
            throw error
        }
    }

    private func endStream(_ id: UUID) {
        activeStreamIDs.remove(id)
        evictModelsIfIdleForMemoryPressure()
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

    private func resolveSessionFactory(
        for backend: StreamingDiarizationBackend
    ) throws -> (any StreamingDiarizerSessionFactory, StreamingDiarizationBackend, String) {
        switch backend {
        case .automatic:
            if let sortformerSessionFactory {
                return (
                    sortformerSessionFactory,
                    StreamingDiarizationBackend.sortformer,
                    "FluidAudio Streaming Sortformer"
                )
            }
            if let lseendSessionFactory {
                return (
                    lseendSessionFactory,
                    StreamingDiarizationBackend.lsEEND,
                    "FluidAudio Streaming LS-EEND"
                )
            }
            throw FluidAudioStreamingSpeakerDiarizerError.modelAssetsMissing(
                "Call FluidAudioStreamingSpeakerDiarizer.installModels() before stream(audio:options:)."
            )
        case .sortformer:
            guard let sortformerSessionFactory else {
                throw FluidAudioStreamingSpeakerDiarizerError.modelAssetsMissing(
                    "Call FluidAudioStreamingSpeakerDiarizer.installModels(backend: .sortformer) before streaming Sortformer diarization."
                )
            }
            return (
                sortformerSessionFactory,
                StreamingDiarizationBackend.sortformer,
                "FluidAudio Streaming Sortformer"
            )
        case .lsEEND:
            guard let lseendSessionFactory else {
                throw FluidAudioStreamingSpeakerDiarizerError.modelAssetsMissing(
                    "Call FluidAudioStreamingSpeakerDiarizer.installModels(backend: .lsEEND) before streaming LS-EEND diarization."
                )
            }
            return (
                lseendSessionFactory,
                StreamingDiarizationBackend.lsEEND,
                "FluidAudio Streaming LS-EEND"
            )
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
