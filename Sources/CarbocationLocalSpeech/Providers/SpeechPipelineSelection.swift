import Foundation

public enum FluidAudioDiarizationModelID: String, Codable, Hashable, Sendable, CaseIterable {
    case offline = "diarization.fluid-audio.offline"
    case streamingSortformer = "diarization.fluid-audio.streaming.sortformer"
    case streamingLSEEND = "diarization.fluid-audio.streaming.ls-eend"
}

public enum DiarizationModelSelection: Hashable, Sendable {
    case fluidAudio(FluidAudioDiarizationModelID)

    public init?(storageValue: String) {
        guard let id = FluidAudioDiarizationModelID(rawValue: storageValue) else {
            return nil
        }
        self = .fluidAudio(id)
    }

    public var storageValue: String {
        switch self {
        case .fluidAudio(let id):
            return id.rawValue
        }
    }

    public var fluidAudioID: FluidAudioDiarizationModelID? {
        switch self {
        case .fluidAudio(let id):
            return id
        }
    }
}

extension DiarizationModelSelection: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let selection = DiarizationModelSelection(storageValue: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid diarization model selection: \(value)"
            )
        }
        self = selection
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storageValue)
    }
}

public struct SpeechDiarizationSelection: Codable, Hashable, Sendable {
    public var file: DiarizationModelSelection?
    public var streaming: DiarizationModelSelection?

    public init(
        file: DiarizationModelSelection? = nil,
        streaming: DiarizationModelSelection? = nil
    ) {
        self.file = file
        self.streaming = streaming
    }

    public static let off = SpeechDiarizationSelection()
}

public struct SpeechDiarizationUsage: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let file = SpeechDiarizationUsage(rawValue: 1 << 0)
    public static let streaming = SpeechDiarizationUsage(rawValue: 1 << 1)
    public static let all: SpeechDiarizationUsage = [.file, .streaming]
}

public struct SpeechPipelineSelection: Hashable, Sendable {
    private static let storagePrefix = "speech-pipeline.v1"
    private static let disabledDiarizationStorageValue = "none"

    public var transcription: SpeechModelSelection
    public var diarization: SpeechDiarizationSelection

    public init(
        transcription: SpeechModelSelection,
        diarization: SpeechDiarizationSelection = .off
    ) {
        self.transcription = transcription
        self.diarization = diarization
    }

    public init?(storageValue: String) {
        let trimmed = storageValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let components = trimmed.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        if components.first == Self.storagePrefix {
            guard components.count == 4,
                  let transcription = SpeechModelSelection(storageValue: components[1])
            else {
                return nil
            }
            guard let file = Self.diarizationSelection(from: components[2]),
                  let streaming = Self.diarizationSelection(from: components[3])
            else {
                return nil
            }
            self.init(
                transcription: transcription,
                diarization: SpeechDiarizationSelection(file: file, streaming: streaming)
            )
            return
        }

        guard let transcription = SpeechModelSelection(storageValue: trimmed) else {
            return nil
        }
        self.init(transcription: transcription, diarization: .off)
    }

    public var storageValue: String {
        [
            Self.storagePrefix,
            transcription.storageValue,
            Self.storageValue(for: diarization.file),
            Self.storageValue(for: diarization.streaming)
        ].joined(separator: "|")
    }

    private static func storageValue(for selection: DiarizationModelSelection?) -> String {
        selection?.storageValue ?? disabledDiarizationStorageValue
    }

    private static func diarizationSelection(from value: String) -> DiarizationModelSelection?? {
        if value == disabledDiarizationStorageValue {
            return .some(nil)
        }
        guard let selection = DiarizationModelSelection(storageValue: value) else {
            return nil
        }
        return .some(selection)
    }
}

public extension SpeechPipelineSelection {
    func applyingDiarizationUsage(
        _ usage: SpeechDiarizationUsage,
        defaultFileSelection: DiarizationModelSelection = DiarizationModelCatalog.defaultFile.selection,
        defaultStreamingSelection: DiarizationModelSelection = DiarizationModelCatalog.defaultStreaming.selection
    ) -> SpeechPipelineSelection {
        SpeechPipelineSelection(
            transcription: transcription,
            diarization: SpeechDiarizationSelection(
                file: usage.contains(.file)
                    ? diarization.file ?? defaultFileSelection
                    : nil,
                streaming: usage.contains(.streaming)
                    ? diarization.streaming ?? defaultStreamingSelection
                    : nil
            )
        )
    }
}

extension SpeechPipelineSelection: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let selection = SpeechPipelineSelection(storageValue: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid speech pipeline selection: \(value)"
            )
        }
        self = selection
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storageValue)
    }
}

public struct DiarizationModelCapabilities: Codable, Hashable, Sendable {
    public var supportsFileDiarization: Bool
    public var supportsStreamingDiarization: Bool

    public init(
        supportsFileDiarization: Bool = false,
        supportsStreamingDiarization: Bool = false
    ) {
        self.supportsFileDiarization = supportsFileDiarization
        self.supportsStreamingDiarization = supportsStreamingDiarization
    }

    public static let fileOnly = DiarizationModelCapabilities(supportsFileDiarization: true)
    public static let streamingOnly = DiarizationModelCapabilities(supportsStreamingDiarization: true)
}

public struct DiarizationModelOption: Identifiable, Hashable, Sendable {
    public var selection: DiarizationModelSelection
    public var displayName: String
    public var subtitle: String
    public var systemImageName: String
    public var capabilities: DiarizationModelCapabilities

    public var id: String {
        selection.storageValue
    }

    public init(
        selection: DiarizationModelSelection,
        displayName: String,
        subtitle: String,
        systemImageName: String,
        capabilities: DiarizationModelCapabilities
    ) {
        self.selection = selection
        self.displayName = displayName
        self.subtitle = subtitle
        self.systemImageName = systemImageName
        self.capabilities = capabilities
    }
}

public struct DiarizationModelLoadPlan: Hashable, Sendable {
    public var selection: DiarizationModelSelection
    public var displayName: String
    public var capabilities: DiarizationModelCapabilities
    public var availability: SpeechProviderAvailability

    public init(
        selection: DiarizationModelSelection,
        displayName: String,
        capabilities: DiarizationModelCapabilities,
        availability: SpeechProviderAvailability
    ) {
        self.selection = selection
        self.displayName = displayName
        self.capabilities = capabilities
        self.availability = availability
    }
}

public protocol DiarizationModelLoadPlanning: Sendable {
    func loadPlan(for selection: DiarizationModelSelection) async -> DiarizationModelLoadPlan?
}

public struct CatalogDiarizationModelLoadPlanner: DiarizationModelLoadPlanning {
    public var options: [DiarizationModelOption]

    public init(options: [DiarizationModelOption] = DiarizationModelCatalog.all) {
        self.options = options
    }

    public func loadPlan(for selection: DiarizationModelSelection) async -> DiarizationModelLoadPlan? {
        guard let option = DiarizationModelCatalog.option(for: selection, among: options) else {
            return nil
        }
        return DiarizationModelLoadPlan(
            selection: option.selection,
            displayName: option.displayName,
            capabilities: option.capabilities,
            availability: .available
        )
    }
}

public struct SpeechPipelineCapabilities: Codable, Hashable, Sendable {
    public var transcription: SpeechModelCapabilities
    public var supportsFileDiarization: Bool
    public var supportsStreamingDiarization: Bool

    public init(
        transcription: SpeechModelCapabilities,
        supportsFileDiarization: Bool = false,
        supportsStreamingDiarization: Bool = false
    ) {
        self.transcription = transcription
        self.supportsFileDiarization = supportsFileDiarization
        self.supportsStreamingDiarization = supportsStreamingDiarization
    }
}

public enum DiarizationModelCatalog {
    public static let fluidAudioOffline = DiarizationModelOption(
        selection: .fluidAudio(.offline),
        displayName: "FluidAudio offline diarization",
        subtitle: "Speaker turns for recorded files and prepared audio.",
        systemImageName: "person.2.wave.2",
        capabilities: .fileOnly
    )

    public static let fluidAudioStreamingSortformer = DiarizationModelOption(
        selection: .fluidAudio(.streamingSortformer),
        displayName: "FluidAudio streaming Sortformer",
        subtitle: "Recommended live speaker turns with low-latency updates.",
        systemImageName: "waveform.and.person.filled",
        capabilities: .streamingOnly
    )

    public static let fluidAudioStreamingLSEEND = DiarizationModelOption(
        selection: .fluidAudio(.streamingLSEEND),
        displayName: "FluidAudio streaming LS-EEND",
        subtitle: "Alternative live speaker diarization backend.",
        systemImageName: "waveform.and.person.filled",
        capabilities: .streamingOnly
    )

    public static let all: [DiarizationModelOption] = [
        fluidAudioOffline,
        fluidAudioStreamingSortformer,
        fluidAudioStreamingLSEEND
    ]

    public static let defaultFile = fluidAudioOffline
    public static let defaultStreaming = fluidAudioStreamingSortformer

    public static func option(
        for selection: DiarizationModelSelection,
        among options: [DiarizationModelOption] = all
    ) -> DiarizationModelOption? {
        options.first { $0.selection == selection }
    }
}
