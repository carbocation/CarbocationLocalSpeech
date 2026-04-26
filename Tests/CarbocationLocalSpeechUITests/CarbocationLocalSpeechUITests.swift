import CarbocationLocalSpeech
@testable import CarbocationLocalSpeechUI
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

    func testLiveTranscriptDebugSnapshotBuildsReadableCommittedTranscript() {
        let events: [TranscriptEvent] = [
            .progress(TranscriptionProgress(processedDuration: 0.8)),
            .stats(TranscriptionStats(audioDuration: 0.8, processingDuration: 0.2, realTimeFactor: 0.25, segmentCount: 2)),
            .snapshot(StreamingTranscriptSnapshot(stable: Transcript(segments: [
                TranscriptSegment(text: " hello ", startTime: 0.0, endTime: 0.4),
                TranscriptSegment(text: "world", startTime: 0.4, endTime: 0.8)
            ])))
        ]

        let snapshot = LiveTranscriptDebugSnapshot(events: events)

        XCTAssertEqual(snapshot.transcriptText, "hello world")
        XCTAssertEqual(snapshot.stableText, "hello world")
        XCTAssertEqual(snapshot.volatileText, "")
        XCTAssertEqual(snapshot.latestText, "world")
        XCTAssertEqual(snapshot.latestTimeRange, "0.40-0.80")
        XCTAssertEqual(snapshot.segmentCount, 2)
        XCTAssertEqual(snapshot.processedDuration, 0.8)
        XCTAssertEqual(snapshot.realTimeFactor, 0.25)
    }

    func testLiveTranscriptDebugSnapshotShowsPartialUntilCommit() {
        let events: [TranscriptEvent] = [
            .snapshot(StreamingTranscriptSnapshot(volatile: Transcript(segments: [
                TranscriptSegment(text: "hel", startTime: 0.0, endTime: 0.2)
            ]))),
            .snapshot(StreamingTranscriptSnapshot(volatile: Transcript(segments: [
                TranscriptSegment(text: "hello wor", startTime: 0.0, endTime: 0.6)
            ])))
        ]

        let partialSnapshot = LiveTranscriptDebugSnapshot(events: events)

        XCTAssertEqual(partialSnapshot.transcriptText, "hello wor")
        XCTAssertEqual(partialSnapshot.stableText, "")
        XCTAssertEqual(partialSnapshot.volatileText, "hello wor")
        XCTAssertEqual(partialSnapshot.latestText, "hello wor")
        XCTAssertEqual(partialSnapshot.latestTimeRange, "0.00-0.60")
        XCTAssertTrue(partialSnapshot.hasVolatileText)
        XCTAssertEqual(partialSnapshot.segmentCount, 0)

        let committedSnapshot = LiveTranscriptDebugSnapshot(events: events + [
            .snapshot(StreamingTranscriptSnapshot(stable: Transcript(segments: [
                TranscriptSegment(text: "hello world", startTime: 0.0, endTime: 0.8)
            ])))
        ])

        XCTAssertEqual(committedSnapshot.transcriptText, "hello world")
        XCTAssertEqual(committedSnapshot.stableText, "hello world")
        XCTAssertEqual(committedSnapshot.volatileText, "")
        XCTAssertEqual(committedSnapshot.latestText, "hello world")
        XCTAssertFalse(committedSnapshot.hasVolatileText)
        XCTAssertEqual(committedSnapshot.segmentCount, 1)
    }

    func testLiveTranscriptDebugSnapshotUsesProviderSnapshot() {
        let committed = TranscriptSegment(text: "hello", startTime: 0.0, endTime: 0.4)
        let volatile = TranscriptSegment(text: "world", startTime: 0.4, endTime: 0.8)

        let snapshot = LiveTranscriptDebugSnapshot(events: [
            .snapshot(StreamingTranscriptSnapshot(
                stable: Transcript(segments: [committed]),
                volatile: Transcript(segments: [volatile]),
                volatileRange: TranscriptTimeRange(startTime: 0.4, endTime: 0.8)
            ))
        ])

        XCTAssertEqual(snapshot.transcriptText, "hello world")
        XCTAssertEqual(snapshot.stableText, "hello")
        XCTAssertEqual(snapshot.volatileText, "world")
        XCTAssertEqual(snapshot.latestText, "world")
        XCTAssertTrue(snapshot.hasVolatileText)
        XCTAssertEqual(snapshot.segmentCount, 1)
    }
}
