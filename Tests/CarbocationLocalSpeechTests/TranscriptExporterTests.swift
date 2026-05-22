import Foundation
import XCTest
@testable import CarbocationLocalSpeech

final class TranscriptExporterTests: XCTestCase {
    func testSRTSkipsEmptySegmentsAndUsesSpeakerLabels() throws {
        let speakerOne = SpeakerID(rawValue: "speaker_1")
        let ada = SpeakerID(rawValue: "ada")
        let transcript = Transcript(segments: [
            TranscriptSegment(
                id: uuid("00000000-0000-0000-0000-000000000001"),
                text: " Hello team ",
                startTime: 0,
                endTime: 1.234,
                speaker: speakerOne
            ),
            TranscriptSegment(
                id: uuid("00000000-0000-0000-0000-000000000002"),
                text: "   ",
                startTime: 1.3,
                endTime: 1.4,
                speaker: speakerOne
            ),
            TranscriptSegment(
                id: uuid("00000000-0000-0000-0000-000000000003"),
                text: "Next item",
                startTime: 3_661.2,
                endTime: 3_662.456,
                speaker: ada
            )
        ])
        let source = TranscriptExportSource(
            transcript: transcript,
            speakers: [
                Speaker(id: speakerOne),
                Speaker(id: ada, displayName: "Ada")
            ],
            generatedAt: Date(timeIntervalSince1970: 0)
        )

        let artifact = try TranscriptExporter.export(format: .srt, source: source)
        XCTAssertEqual(artifact.fileExtension, "srt")
        XCTAssertEqual(artifact.mediaType, "application/x-subrip; charset=utf-8")
        XCTAssertEqual(artifact.role, "subRipSubtitles")
        XCTAssertEqual(
            utf8String(artifact),
            """
            1
            00:00:00,000 --> 00:00:01,234
            [Speaker 1] Hello team

            2
            01:01:01,200 --> 01:01:02,456
            [Ada] Next item

            """
        )
    }

    func testWebVTTUsesHeaderVoiceSpansAndSpeakerStyleBlock() throws {
        let bob = SpeakerID(rawValue: "bob")
        let transcript = Transcript(segments: [
            TranscriptSegment(
                text: "5 < 7 & ready",
                startTime: 0.5,
                endTime: 2,
                speaker: bob
            )
        ])
        let source = TranscriptExportSource(
            transcript: transcript,
            speakers: [Speaker(id: bob, displayName: "Bob")],
            generatedAt: Date(timeIntervalSince1970: 0)
        )

        let artifact = try TranscriptExporter.export(
            format: .webVTT,
            source: source,
            options: TranscriptExportOptions(
                speakerStyles: [bob: TranscriptSpeakerStyle(color: "#00AAFF")]
            )
        )

        XCTAssertEqual(artifact.fileExtension, "vtt")
        XCTAssertEqual(artifact.mediaType, "text/vtt; charset=utf-8")
        XCTAssertEqual(
            utf8String(artifact),
            """
            WEBVTT

            STYLE
            ::cue(v[voice=\"Bob\"]) { color: #00AAFF; }

            00:00:00.500 --> 00:00:02.000
            <v Bob>5 &lt; 7 &amp; ready

            """
        )
    }

    func testMarkdownGroupsSpeakerTurnsWithAvatarsTimestampsAndEscaping() throws {
        let alice = SpeakerID(rawValue: "alice")
        let transcript = Transcript(segments: [
            TranscriptSegment(
                text: "Hello *team*",
                startTime: 0,
                endTime: 1,
                speaker: alice
            ),
            TranscriptSegment(
                text: "First [item]",
                startTime: 1,
                endTime: 2,
                speaker: alice
            ),
            TranscriptSegment(
                text: "Unknown > note",
                startTime: 2,
                endTime: 3
            )
        ])
        let source = TranscriptExportSource(
            transcript: transcript,
            speakers: [Speaker(id: alice, displayName: "Alice")],
            title: "Weekly Sync",
            sourceFileName: "weekly sync.m4a",
            generatedAt: Date(timeIntervalSince1970: 0)
        )

        let artifact = try TranscriptExporter.export(format: .markdownMinutes, source: source)
        let markdown = utf8String(artifact)

        XCTAssertEqual(artifact.fileExtension, "md")
        XCTAssertEqual(artifact.mediaType, "text/markdown; charset=utf-8")
        XCTAssertTrue(markdown.contains("# Weekly Sync"))
        XCTAssertTrue(markdown.contains("- Source: weekly sync.m4a"))
        XCTAssertTrue(markdown.contains("- Generated: 1970-01-01T00:00:00Z"))
        XCTAssertTrue(markdown.contains("### A Alice - 00:00:00.000-00:00:02.000"))
        XCTAssertTrue(markdown.contains("Hello \\*team\\* First \\[item\\]"))
        XCTAssertTrue(markdown.contains("### US Unknown Speaker - 00:00:02.000-00:00:03.000"))
        XCTAssertTrue(markdown.contains("Unknown \\> note"))
    }

    func testJSONUsesPortableSchemaWithSpeakersTurnsSegmentsAndWords() throws {
        let speaker = SpeakerID(rawValue: "speaker_0")
        let wordID = uuid("00000000-0000-0000-0000-000000000010")
        let segmentID = uuid("00000000-0000-0000-0000-000000000011")
        let turnID = uuid("00000000-0000-0000-0000-000000000012")
        let transcript = Transcript(
            segments: [
                TranscriptSegment(
                    id: segmentID,
                    text: "hello world",
                    startTime: 0,
                    endTime: 1,
                    words: [
                        TranscriptWord(
                            id: wordID,
                            text: "hello",
                            startTime: 0,
                            endTime: 0.4,
                            confidence: 0.7,
                            speaker: speaker
                        )
                    ],
                    speaker: speaker,
                    confidence: 0.8
                )
            ],
            duration: 1,
            backend: SpeechBackendDescriptor(kind: .mock, displayName: "Mock", version: "1.0")
        )
        let diarization = DiarizationResult(
            turns: [
                SpeakerTurn(
                    id: turnID,
                    speaker: speaker,
                    startTime: 0,
                    endTime: 1,
                    confidence: 0.9,
                    source: "test"
                )
            ],
            speakers: [Speaker(id: speaker)],
            duration: 1
        )
        let source = TranscriptExportSource(
            transcript: transcript,
            diarization: diarization,
            generatedAt: Date(timeIntervalSince1970: 0)
        )

        let artifact = try TranscriptExporter.export(format: .json, source: source)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: artifact.data) as? [String: Any])
        let metadata = try XCTUnwrap(json["metadata"] as? [String: Any])
        let speakers = try XCTUnwrap(json["speakers"] as? [[String: Any]])
        let turns = try XCTUnwrap(json["speakerTurns"] as? [[String: Any]])
        let segments = try XCTUnwrap(json["segments"] as? [[String: Any]])
        let firstSegment = try XCTUnwrap(segments.first)
        let words = try XCTUnwrap(firstSegment["words"] as? [[String: Any]])
        let firstWord = try XCTUnwrap(words.first)

        XCTAssertEqual(json["schema"] as? String, "com.carbocation.localspeech.transcript")
        XCTAssertEqual(json["version"] as? Int, 1)
        XCTAssertEqual(metadata["generatedAt"] as? String, "1970-01-01T00:00:00Z")
        XCTAssertEqual((metadata["backend"] as? [String: Any])?["displayName"] as? String, "Mock")
        XCTAssertEqual(speakers.first?["id"] as? String, "speaker_0")
        XCTAssertEqual(turns.first?["speakerLabel"] as? String, "Speaker 0")
        XCTAssertEqual(firstSegment["id"] as? String, segmentID.uuidString)
        XCTAssertEqual(firstSegment["speakerLabel"] as? String, "Speaker 0")
        XCTAssertEqual(firstSegment["confidence"] as? Double, 0.8)
        XCTAssertEqual(firstWord["id"] as? String, wordID.uuidString)
        XCTAssertEqual(firstWord["speakerLabel"] as? String, "Speaker 0")
        XCTAssertEqual(firstWord["confidence"] as? Double, 0.7)
    }

    func testExporterDerivesSpeakerAttributionFromDiarization() throws {
        let speaker = SpeakerID(rawValue: "speaker_0")
        let transcript = Transcript(segments: [
            TranscriptSegment(text: "Derived label", startTime: 0, endTime: 1)
        ])
        let diarization = DiarizationResult(
            turns: [SpeakerTurn(speaker: speaker, startTime: 0, endTime: 1)],
            speakers: [Speaker(id: speaker)],
            duration: 1
        )
        let source = TranscriptExportSource(
            transcript: transcript,
            diarization: diarization,
            generatedAt: Date(timeIntervalSince1970: 0)
        )

        let artifact = try TranscriptExporter.export(format: .srt, source: source)

        XCTAssertTrue(utf8String(artifact).contains("[Speaker 0] Derived label"))
    }

    func testExporterMetadataAndSanitizedDefaultFilename() throws {
        let source = TranscriptExportSource(
            transcript: Transcript(segments: [
                TranscriptSegment(text: "hello", startTime: 0, endTime: 1)
            ]),
            sourceFileName: "Quarterly Call?.mov",
            generatedAt: Date(timeIntervalSince1970: 0)
        )

        let artifact = try TranscriptExporter.export(format: .markdownMinutes, source: source)

        XCTAssertEqual(artifact.fileName, "Quarterly-Call.md")
        XCTAssertEqual(artifact.fileExtension, "md")
        XCTAssertEqual(artifact.mediaType, "text/markdown; charset=utf-8")
        XCTAssertEqual(artifact.role, "meetingMinutes")
    }

    func testAnalysisResultConvenienceInitializerRequiresTranscript() throws {
        XCTAssertThrowsError(try TranscriptExportSource(analysisResult: SpeechAnalysisResult())) { error in
            XCTAssertEqual(error as? TranscriptExportError, .missingTranscript)
        }
    }

    private func utf8String(_ artifact: TranscriptExportArtifact) -> String {
        String(decoding: artifact.data, as: UTF8.self)
    }

    private func uuid(_ string: String) -> UUID {
        UUID(uuidString: string)!
    }
}
