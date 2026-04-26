@testable import CarbocationAppleSpeechRuntime
import AVFoundation
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

    func testAnalyzerInputClockPreventsResamplingRoundingOverlap() {
        var clock = AppleAnalyzerInputClock()

        let first = clock.claimStartTime(
            sourceStartTime: 0,
            frameCount: 1_601,
            sampleRate: 16_000
        )
        let second = clock.claimStartTime(
            sourceStartTime: 0.1,
            frameCount: 1_600,
            sampleRate: 16_000
        )

        XCTAssertEqual(first, 0, accuracy: 0.000_001)
        XCTAssertEqual(second, 1_601.0 / 16_000.0, accuracy: 0.000_001)
    }

    func testAnalyzerInputClockPreservesRealInputGap() {
        var clock = AppleAnalyzerInputClock()

        _ = clock.claimStartTime(
            sourceStartTime: 0,
            frameCount: 1_600,
            sampleRate: 16_000
        )
        let afterGap = clock.claimStartTime(
            sourceStartTime: 2,
            frameCount: 1_600,
            sampleRate: 16_000
        )

        XCTAssertEqual(afterGap, 2, accuracy: 0.000_001)
    }

    func testTemporaryAnalysisAudioFileWritesPreparedAudio() throws {
        let audio = PreparedAudio(
            samples: [0.0, 0.25, -0.25, 0.5, -0.5],
            sampleRate: 16_000
        )

        let url = try AppleSpeechEngine.writeTemporaryAudioFile(audio)
        defer { try? FileManager.default.removeItem(at: url) }

        let file = try AVAudioFile(forReading: url)

        XCTAssertEqual(file.length, AVAudioFramePosition(audio.samples.count))
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000, accuracy: 0.01)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
    }
}
