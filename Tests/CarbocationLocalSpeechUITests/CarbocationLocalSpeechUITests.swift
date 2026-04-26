import CarbocationLocalSpeech
import CarbocationLocalSpeechUI
import XCTest

final class CarbocationLocalSpeechUITests: XCTestCase {
    func testDefaultAppleSpeechLabelIsBuiltIn() {
        let option = SpeechSystemModelOption(
            selection: .system(.appleSpeech),
            displayName: "Apple Speech",
            subtitle: "Built-in",
            systemImageName: "waveform.and.mic",
            capabilities: .appleSpeechDefault,
            availability: .available
        )

        let label = SpeechModelPickerLabelPolicy.default.systemProviderLabel(for: option)
        XCTAssertEqual(label?.title, "Built In")
        XCTAssertEqual(label?.tone, .secondary)
    }

    func testRecommendedAndBestInstalledLabelsApplyOnlyToCuratedModels() {
        let curatedSmall = CuratedSpeechModel(
            id: "small",
            displayName: "Small",
            subtitle: "",
            variant: "small.en",
            languageScope: .englishOnly,
            approxSizeBytes: 1,
            recommendedRAMGB: 8
        )
        let curatedMedium = CuratedSpeechModel(
            id: "medium",
            displayName: "Medium",
            subtitle: "",
            variant: "medium.en",
            languageScope: .englishOnly,
            approxSizeBytes: 2,
            recommendedRAMGB: 16
        )
        let installed = InstalledSpeechModel(
            displayName: "Small",
            variant: "small.en",
            languageScope: .englishOnly,
            assets: [SpeechModelAsset(role: .primaryWeights, relativePath: "ggml-small.en.bin", sizeBytes: 1)],
            source: .curated
        )
        let imported = InstalledSpeechModel(
            displayName: "Small Imported",
            variant: "small.en",
            languageScope: .englishOnly,
            assets: [SpeechModelAsset(role: .primaryWeights, relativePath: "ggml-small.en.bin", sizeBytes: 1)],
            source: .imported
        )

        XCTAssertTrue(SpeechModelPickerLabelPolicy.installedModel(installed, matches: curatedSmall))
        XCTAssertFalse(SpeechModelPickerLabelPolicy.installedModel(imported, matches: curatedSmall))

        let best = SpeechModelPickerLabelPolicy.bestInstalledCuratedModel(
            forPhysicalMemoryBytes: 32 * 1_073_741_824,
            installedModels: [installed],
            curatedModels: [curatedSmall, curatedMedium]
        )
        XCTAssertEqual(best?.id, "small")
    }

    func testRecommendedLabelAppliesToCuratedDownloadModel() {
        let curatedSmall = CuratedSpeechModel(
            id: "small",
            displayName: "Small",
            subtitle: "",
            variant: "small.en",
            languageScope: .englishOnly,
            approxSizeBytes: 1,
            recommendedRAMGB: 8
        )
        let curatedMedium = CuratedSpeechModel(
            id: "medium",
            displayName: "Medium",
            subtitle: "",
            variant: "medium.en",
            languageScope: .englishOnly,
            approxSizeBytes: 2,
            recommendedRAMGB: 16
        )

        let label = SpeechModelPickerLabelPolicy.default.curatedModelLabel(
            for: curatedMedium,
            recommendedCuratedModel: curatedMedium
        )
        let nonRecommendedLabel = SpeechModelPickerLabelPolicy.default.curatedModelLabel(
            for: curatedSmall,
            recommendedCuratedModel: curatedMedium
        )

        XCTAssertEqual(label?.title, "Recommended")
        XCTAssertEqual(label?.tone, .accent)
        XCTAssertNil(nonRecommendedLabel)
    }

    func testBestInstalledCuratedModelPrefersLargerModelWhenRAMTierTies() {
        let medium = CuratedSpeechModel(
            id: "medium",
            displayName: "Medium",
            subtitle: "",
            variant: "medium.en",
            languageScope: .englishOnly,
            approxSizeBytes: 1_530_000_000,
            recommendedRAMGB: 16
        )
        let largeTurbo = CuratedSpeechModel(
            id: "large-v3-turbo",
            displayName: "Large Turbo",
            subtitle: "",
            variant: "large-v3-turbo",
            languageScope: .multilingual,
            approxSizeBytes: 1_620_000_000,
            recommendedRAMGB: 16
        )
        let installedMedium = InstalledSpeechModel(
            displayName: "Medium",
            variant: "medium.en",
            languageScope: .englishOnly,
            assets: [SpeechModelAsset(role: .primaryWeights, relativePath: "ggml-medium.en.bin", sizeBytes: 1)],
            source: .curated
        )
        let installedLargeTurbo = InstalledSpeechModel(
            displayName: "Large Turbo",
            variant: "large-v3-turbo",
            languageScope: .multilingual,
            assets: [SpeechModelAsset(role: .primaryWeights, relativePath: "ggml-large-v3-turbo.bin", sizeBytes: 1)],
            source: .curated
        )

        let best = SpeechModelPickerLabelPolicy.bestInstalledCuratedModel(
            forPhysicalMemoryBytes: 48 * 1_073_741_824,
            installedModels: [installedMedium, installedLargeTurbo],
            curatedModels: [medium, largeTurbo]
        )

        XCTAssertEqual(best?.id, "large-v3-turbo")
    }
}
