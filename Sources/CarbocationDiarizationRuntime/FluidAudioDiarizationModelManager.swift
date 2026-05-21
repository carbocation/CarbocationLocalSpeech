import CarbocationLocalSpeech
@preconcurrency import CoreML
import FluidAudio
import Foundation

public enum FluidAudioDiarizationModelManagerError: Error, LocalizedError, Sendable {
    case unsupportedSelection(String)
    case unsupportedFileSelection(String)
    case unsupportedStreamingSelection(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSelection(let value):
            return "Unsupported FluidAudio diarization model selection: \(value)"
        case .unsupportedFileSelection(let value):
            return "FluidAudio file diarization requires \(FluidAudioDiarizationModelID.offline.rawValue), got \(value)."
        case .unsupportedStreamingSelection(let value):
            return "FluidAudio streaming diarization requires a streaming model, got \(value)."
        }
    }
}

@available(macOS 14.0, iOS 17.0, *)
public actor FluidAudioDiarizationModelManager: DiarizationModelLoadPlanning {
    private let modelsDirectory: URL?
    private let fileConfig: OfflineDiarizerConfig
    private let fileModelConfiguration: MLModelConfiguration?
    private let fileMemoryPressurePolicy: FluidAudioModelMemoryPressurePolicy
    private let streamingComputeUnits: FluidAudioStreamingComputeUnits
    private let streamingSortformerConfig: SortformerConfig
    private let streamingLSEENDVariant: LSEENDVariant
    private let streamingLSEENDStepSize: LSEENDStepSize
    private let streamingMemoryPressurePolicy: FluidAudioModelMemoryPressurePolicy

    public init(
        modelsDirectory: URL? = nil,
        fileConfig: OfflineDiarizerConfig = .default,
        fileModelConfiguration: MLModelConfiguration? = nil,
        fileMemoryPressurePolicy: FluidAudioModelMemoryPressurePolicy = .evictWhenIdle,
        streamingComputeUnits: FluidAudioStreamingComputeUnits = .uniform(.all),
        streamingSortformerConfig: SortformerConfig = .fastV2_1,
        streamingLSEENDVariant: LSEENDVariant = .dihard3,
        streamingLSEENDStepSize: LSEENDStepSize = .step100ms,
        streamingMemoryPressurePolicy: FluidAudioModelMemoryPressurePolicy = .evictWhenIdle
    ) {
        self.modelsDirectory = modelsDirectory
        self.fileConfig = fileConfig
        self.fileModelConfiguration = fileModelConfiguration
        self.fileMemoryPressurePolicy = fileMemoryPressurePolicy
        self.streamingComputeUnits = streamingComputeUnits
        self.streamingSortformerConfig = streamingSortformerConfig
        self.streamingLSEENDVariant = streamingLSEENDVariant
        self.streamingLSEENDStepSize = streamingLSEENDStepSize
        self.streamingMemoryPressurePolicy = streamingMemoryPressurePolicy
    }

    public func loadPlan(for selection: DiarizationModelSelection) async -> DiarizationModelLoadPlan? {
        guard let option = DiarizationModelCatalog.option(for: selection) else {
            return nil
        }
        return DiarizationModelLoadPlan(
            selection: option.selection,
            displayName: option.displayName,
            capabilities: option.capabilities,
            availability: .available
        )
    }

    public func makeFileDiarizer(
        selection: DiarizationModelSelection = .fluidAudio(.offline)
    ) throws -> FluidAudioSpeakerDiarizer {
        guard selection.fluidAudioID == .offline else {
            throw FluidAudioDiarizationModelManagerError.unsupportedFileSelection(selection.storageValue)
        }
        return FluidAudioSpeakerDiarizer(
            config: fileConfig,
            modelsDirectory: modelsDirectory,
            modelConfiguration: fileModelConfiguration,
            memoryPressurePolicy: fileMemoryPressurePolicy
        )
    }

    public func makeStreamingDiarizer(
        selection: DiarizationModelSelection = .fluidAudio(.streamingSortformer)
    ) throws -> FluidAudioStreamingSpeakerDiarizer {
        guard streamingBackend(for: selection) != nil else {
            throw FluidAudioDiarizationModelManagerError.unsupportedStreamingSelection(selection.storageValue)
        }
        return FluidAudioStreamingSpeakerDiarizer(
            modelsDirectory: modelsDirectory,
            computeUnits: streamingComputeUnits,
            sortformerConfig: streamingSortformerConfig,
            lseendVariant: streamingLSEENDVariant,
            lseendStepSize: streamingLSEENDStepSize,
            memoryPressurePolicy: streamingMemoryPressurePolicy
        )
    }

    @discardableResult
    public func installFileDiarizer(
        selection: DiarizationModelSelection = .fluidAudio(.offline),
        onProgress: @escaping @Sendable (FluidAudioModelInstallProgress) -> Void = { _ in }
    ) async throws -> FluidAudioSpeakerDiarizer {
        let diarizer = try makeFileDiarizer(selection: selection)
        try await diarizer.installModels(onProgress: onProgress)
        return diarizer
    }

    @discardableResult
    public func installStreamingDiarizer(
        selection: DiarizationModelSelection = .fluidAudio(.streamingSortformer),
        onProgress: @escaping @Sendable (FluidAudioModelInstallProgress) -> Void = { _ in }
    ) async throws -> FluidAudioStreamingSpeakerDiarizer {
        let backend = try streamingBackendOrThrow(for: selection)
        let diarizer = try makeStreamingDiarizer(selection: selection)
        try await diarizer.installModels(backend: backend, onProgress: onProgress)
        return diarizer
    }

    @discardableResult
    public func installModel(
        for selection: DiarizationModelSelection,
        onProgress: @escaping @Sendable (FluidAudioModelInstallProgress) -> Void = { _ in }
    ) async throws -> DiarizationModelLoadPlan {
        switch selection.fluidAudioID {
        case .offline:
            _ = try await installFileDiarizer(selection: selection, onProgress: onProgress)
        case .streamingSortformer, .streamingLSEEND:
            _ = try await installStreamingDiarizer(selection: selection, onProgress: onProgress)
        case nil:
            throw FluidAudioDiarizationModelManagerError.unsupportedSelection(selection.storageValue)
        }

        guard let plan = await loadPlan(for: selection) else {
            throw FluidAudioDiarizationModelManagerError.unsupportedSelection(selection.storageValue)
        }
        return plan
    }

    private func streamingBackendOrThrow(
        for selection: DiarizationModelSelection
    ) throws -> StreamingDiarizationBackend {
        guard let backend = streamingBackend(for: selection) else {
            throw FluidAudioDiarizationModelManagerError.unsupportedStreamingSelection(selection.storageValue)
        }
        return backend
    }

    private func streamingBackend(
        for selection: DiarizationModelSelection
    ) -> StreamingDiarizationBackend? {
        switch selection.fluidAudioID {
        case .streamingSortformer:
            return .sortformer
        case .streamingLSEEND:
            return .lsEEND
        case .offline, nil:
            return nil
        }
    }
}
