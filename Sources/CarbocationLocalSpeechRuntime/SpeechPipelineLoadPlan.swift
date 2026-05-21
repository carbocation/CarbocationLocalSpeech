import CarbocationLocalSpeech
import Foundation

public struct SpeechPipelineLoadPlan: Hashable, Sendable {
    public var selection: SpeechPipelineSelection
    public var transcription: LocalSpeechLoadPlan
    public var fileDiarization: DiarizationModelLoadPlan?
    public var streamingDiarization: DiarizationModelLoadPlan?
    public var capabilities: SpeechPipelineCapabilities
    public var availability: SpeechProviderAvailability

    public init(
        selection: SpeechPipelineSelection,
        transcription: LocalSpeechLoadPlan,
        fileDiarization: DiarizationModelLoadPlan? = nil,
        streamingDiarization: DiarizationModelLoadPlan? = nil,
        capabilities: SpeechPipelineCapabilities,
        availability: SpeechProviderAvailability
    ) {
        self.selection = selection
        self.transcription = transcription
        self.fileDiarization = fileDiarization
        self.streamingDiarization = streamingDiarization
        self.capabilities = capabilities
        self.availability = availability
    }
}

public extension LocalSpeechEngine {
    nonisolated static func pipelineLoadPlan(
        from storageValue: String,
        in library: SpeechModelLibrary,
        locale: Locale = .current,
        refreshingLibrary: Bool = true,
        diarizationPlanner: any DiarizationModelLoadPlanning = CatalogDiarizationModelLoadPlanner()
    ) async -> SpeechPipelineLoadPlan? {
        guard let selection = SpeechPipelineSelection(storageValue: storageValue),
              let transcription = await loadPlan(
                from: selection.transcription.storageValue,
                in: library,
                locale: locale,
                refreshingLibrary: refreshingLibrary
              )
        else {
            return nil
        }

        guard let fileDiarization = await validateFileDiarization(
            selection.diarization.file,
            planner: diarizationPlanner
        ) else {
            return nil
        }
        guard let streamingDiarization = await validateStreamingDiarization(
            selection.diarization.streaming,
            planner: diarizationPlanner
        ) else {
            return nil
        }

        let availability = Self.pipelineAvailability(
            transcription: transcription,
            fileDiarization: fileDiarization,
            streamingDiarization: streamingDiarization
        )

        return SpeechPipelineLoadPlan(
            selection: selection,
            transcription: transcription,
            fileDiarization: fileDiarization,
            streamingDiarization: streamingDiarization,
            capabilities: SpeechPipelineCapabilities(
                transcription: transcription.capabilities,
                supportsFileDiarization: fileDiarization != nil,
                supportsStreamingDiarization: streamingDiarization != nil
            ),
            availability: availability
        )
    }

    private nonisolated static func validateFileDiarization(
        _ selection: DiarizationModelSelection?,
        planner: any DiarizationModelLoadPlanning
    ) async -> DiarizationModelLoadPlan?? {
        guard let selection else {
            return .some(nil)
        }
        guard let plan = await planner.loadPlan(for: selection),
              plan.capabilities.supportsFileDiarization,
              plan.availability.isPipelineLoadPlannable
        else {
            return nil
        }
        return .some(plan)
    }

    private nonisolated static func validateStreamingDiarization(
        _ selection: DiarizationModelSelection?,
        planner: any DiarizationModelLoadPlanning
    ) async -> DiarizationModelLoadPlan?? {
        guard let selection else {
            return .some(nil)
        }
        guard let plan = await planner.loadPlan(for: selection),
              plan.capabilities.supportsStreamingDiarization,
              plan.availability.isPipelineLoadPlannable
        else {
            return nil
        }
        return .some(plan)
    }

    private nonisolated static func pipelineAvailability(
        transcription: LocalSpeechLoadPlan,
        fileDiarization: DiarizationModelLoadPlan?,
        streamingDiarization: DiarizationModelLoadPlan?
    ) -> SpeechProviderAvailability {
        let componentAvailability = [
            transcription.availability,
            fileDiarization?.availability,
            streamingDiarization?.availability
        ].compactMap { $0 }

        return componentAvailability.first { !$0.isAvailable } ?? .available
    }
}

private extension SpeechProviderAvailability {
    var isPipelineLoadPlannable: Bool {
        switch self {
        case .available, .unavailable(.assetDownloadRequired):
            return true
        case .unavailable:
            return false
        }
    }
}
