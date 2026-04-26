import CarbocationAppleSpeechRuntime
import CarbocationLocalSpeech
import XCTest

final class CarbocationAppleSpeechRuntimeTests: XCTestCase {
    func testAvailabilityAndSystemOptionUseSameOfferPolicy() async {
        let locale = Locale(identifier: "en_US")
        let availability = await AppleSpeechEngine.availability(locale: locale)
        let option = await AppleSpeechEngine.systemModelOption(locale: locale)

        XCTAssertEqual(option != nil, availability.shouldOfferModelOption)
        XCTAssertEqual(option?.selection, .system(.appleSpeech))
    }

    func testUnsupportedFeatureMapping() {
        let unsupported = AppleSpeechEngine.unsupportedFeatures(for: TranscriptionOptions(
            task: .translate,
            timestampMode: .words
        ))

        XCTAssertTrue(unsupported.contains(.translation))
        XCTAssertTrue(unsupported.contains(.wordTimestamps))
        XCTAssertFalse(unsupported.contains(.diarization))
    }
}
