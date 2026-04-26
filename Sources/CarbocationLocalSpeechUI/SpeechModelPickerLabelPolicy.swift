import CarbocationLocalSpeech
import Foundation

public struct SpeechModelPickerStatusLabel: Equatable, Hashable, Sendable {
    public enum Tone: Equatable, Hashable, Sendable {
        case accent
        case positive
        case warning
        case secondary
    }

    public var title: String
    public var systemImageName: String?
    public var tone: Tone

    public init(
        _ title: String,
        systemImageName: String? = nil,
        tone: Tone = .accent
    ) {
        self.title = title
        self.systemImageName = systemImageName
        self.tone = tone
    }
}

public struct SpeechModelPickerLabelPolicy: Equatable, Sendable {
    public static let builtInLabel = SpeechModelPickerStatusLabel("Built In", tone: .secondary)
    public static let recommendedLabel = SpeechModelPickerStatusLabel("Recommended", tone: .accent)
    public static let bestInstalledLabel = SpeechModelPickerStatusLabel("Best Installed", tone: .positive)

    public static let defaultSystemProviderLabels: [SpeechModelSelection: SpeechModelPickerStatusLabel] = [
        .system(.appleSpeech): builtInLabel
    ]

    public static let `default` = SpeechModelPickerLabelPolicy()

    public var recommendedLabel: SpeechModelPickerStatusLabel?
    public var bestInstalledLabel: SpeechModelPickerStatusLabel?
    public var systemProviderLabels: [SpeechModelSelection: SpeechModelPickerStatusLabel]

    public init(
        recommendedLabel: SpeechModelPickerStatusLabel? = Self.recommendedLabel,
        bestInstalledLabel: SpeechModelPickerStatusLabel? = Self.bestInstalledLabel,
        systemProviderLabels: [SpeechModelSelection: SpeechModelPickerStatusLabel] = Self.defaultSystemProviderLabels
    ) {
        self.recommendedLabel = recommendedLabel
        self.bestInstalledLabel = bestInstalledLabel
        self.systemProviderLabels = systemProviderLabels
    }

    public func systemProviderLabel(for option: SpeechSystemModelOption) -> SpeechModelPickerStatusLabel? {
        systemProviderLabels[option.selection]
    }

    public func curatedModelLabel(
        for model: CuratedSpeechModel,
        recommendedCuratedModel: CuratedSpeechModel?
    ) -> SpeechModelPickerStatusLabel? {
        guard let recommendedCuratedModel,
              model.id == recommendedCuratedModel.id
        else { return nil }
        return recommendedLabel
    }

    public func installedModelLabel(
        for model: InstalledSpeechModel,
        recommendedCuratedModel: CuratedSpeechModel?,
        bestInstalledCuratedModel: CuratedSpeechModel?
    ) -> SpeechModelPickerStatusLabel? {
        if let recommendedCuratedModel,
           Self.installedModel(model, matches: recommendedCuratedModel) {
            return recommendedLabel
        }

        if let bestInstalledCuratedModel,
           Self.installedModel(model, matches: bestInstalledCuratedModel) {
            return bestInstalledLabel
        }

        return nil
    }

    public static func bestInstalledCuratedModel(
        forPhysicalMemoryBytes physicalMemoryBytes: UInt64,
        installedModels: [InstalledSpeechModel],
        curatedModels: [CuratedSpeechModel]
    ) -> CuratedSpeechModel? {
        guard physicalMemoryBytes > 0 else { return nil }

        var bestFit: CuratedSpeechModel?
        for curatedModel in curatedModels where curatedModel.recommendedRAMBytes <= physicalMemoryBytes {
            guard installedModels.contains(where: { installedModel($0, matches: curatedModel) }) else {
                continue
            }

            if bestFit == nil || Self.curatedModel(curatedModel, isBetterRecommendationThan: bestFit!) {
                bestFit = curatedModel
            }
        }
        return bestFit
    }

    private static func curatedModel(
        _ model: CuratedSpeechModel,
        isBetterRecommendationThan other: CuratedSpeechModel
    ) -> Bool {
        if model.recommendedRAMBytes != other.recommendedRAMBytes {
            return model.recommendedRAMBytes > other.recommendedRAMBytes
        }
        return model.approxSizeBytes > other.approxSizeBytes
    }

    public static func installedModel(
        _ installedModel: InstalledSpeechModel,
        matches curatedModel: CuratedSpeechModel
    ) -> Bool {
        guard installedModel.source == .curated else { return false }
        if let hfRepo = curatedModel.hfRepo,
           let hfFilename = curatedModel.hfFilename {
            return installedModel.hfRepo == hfRepo && installedModel.hfFilename == hfFilename
        }
        return installedModel.family == curatedModel.family
            && installedModel.variant == curatedModel.variant
    }
}
