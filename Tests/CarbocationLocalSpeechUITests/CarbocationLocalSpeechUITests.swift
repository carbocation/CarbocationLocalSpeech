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
}
