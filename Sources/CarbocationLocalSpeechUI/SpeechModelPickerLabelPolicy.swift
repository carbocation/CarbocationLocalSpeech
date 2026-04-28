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
    public static let bestLiveEnglishLabel = SpeechModelPickerStatusLabel("Best Live English", tone: .accent)
    public static let bestLiveMultilingualLabel = SpeechModelPickerStatusLabel("Best Live Multilingual", tone: .accent)
    public static let bestFileEnglishLabel = SpeechModelPickerStatusLabel("Best File English", tone: .accent)
    public static let bestFileMultilingualLabel = SpeechModelPickerStatusLabel("Best File Multilingual", tone: .accent)
    public static let bestInstalledLabel = SpeechModelPickerStatusLabel("Best Installed", tone: .positive)

    public static let defaultSystemProviderLabels: [SpeechModelSelection: SpeechModelPickerStatusLabel] = [
        .system(.appleSpeech): builtInLabel
    ]

    public static let defaultRecommendationLabels: [CuratedSpeechModelRecommendation: SpeechModelPickerStatusLabel] = [
        .bestLiveEnglish: bestLiveEnglishLabel,
        .bestLiveMultilingual: bestLiveMultilingualLabel,
        .bestFileEnglish: bestFileEnglishLabel,
        .bestFileMultilingual: bestFileMultilingualLabel
    ]

    public static let `default` = SpeechModelPickerLabelPolicy()

    public var recommendedLabel: SpeechModelPickerStatusLabel?
    public var bestInstalledLabel: SpeechModelPickerStatusLabel?
    public var systemProviderLabels: [SpeechModelSelection: SpeechModelPickerStatusLabel]
    public var recommendationLabels: [CuratedSpeechModelRecommendation: SpeechModelPickerStatusLabel]

    public init(
        recommendedLabel: SpeechModelPickerStatusLabel? = Self.recommendedLabel,
        bestInstalledLabel: SpeechModelPickerStatusLabel? = Self.bestInstalledLabel,
        systemProviderLabels: [SpeechModelSelection: SpeechModelPickerStatusLabel] = Self.defaultSystemProviderLabels,
        recommendationLabels: [CuratedSpeechModelRecommendation: SpeechModelPickerStatusLabel] = Self.defaultRecommendationLabels
    ) {
        self.recommendedLabel = recommendedLabel
        self.bestInstalledLabel = bestInstalledLabel
        self.systemProviderLabels = systemProviderLabels
        self.recommendationLabels = recommendationLabels
    }

    public func systemProviderLabel(for option: SpeechSystemModelOption) -> SpeechModelPickerStatusLabel? {
        systemProviderLabels[option.selection]
    }

    public func curatedModelLabel(for model: CuratedSpeechModel) -> SpeechModelPickerStatusLabel? {
        guard let recommendation = model.recommendation else { return nil }
        return recommendationLabels[recommendation] ?? recommendedLabel
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
        recommendedCuratedModels: [CuratedSpeechModel]
    ) -> SpeechModelPickerStatusLabel? {
        for recommendedModel in recommendedCuratedModels where Self.installedModel(model, matches: recommendedModel) {
            return curatedModelLabel(for: recommendedModel)
        }
        return nil
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

    public static func recommendedInstalledCuratedModels(
        installedModels: [InstalledSpeechModel],
        curatedModels: [CuratedSpeechModel]
    ) -> [CuratedSpeechModel] {
        CuratedSpeechModelCatalog.recommendedModels(among: curatedModels).filter { curatedModel in
            installedModels.contains { installedModel($0, matches: curatedModel) }
        }
    }

    public static func bestInstalledCuratedModel(
        forPhysicalMemoryBytes _: UInt64,
        installedModels: [InstalledSpeechModel],
        curatedModels: [CuratedSpeechModel]
    ) -> CuratedSpeechModel? {
        recommendedInstalledCuratedModels(
            installedModels: installedModels,
            curatedModels: curatedModels
        ).first
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
