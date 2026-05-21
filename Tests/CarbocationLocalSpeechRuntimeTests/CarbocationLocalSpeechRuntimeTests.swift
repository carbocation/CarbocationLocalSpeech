import CarbocationLocalSpeech
import CarbocationLocalSpeechRuntime
import XCTest

final class CarbocationLocalSpeechRuntimeTests: XCTestCase {
    func testSelectionParsing() throws {
        let id = UUID()
        XCTAssertEqual(try LocalSpeechEngine.selection(from: id.uuidString), .installed(id))
        XCTAssertEqual(try LocalSpeechEngine.selection(from: "system.apple-speech"), .system(.appleSpeech))
        XCTAssertThrowsError(try LocalSpeechEngine.selection(from: "bad"))
    }

    func testTranscribeRequiresLoadedSelection() async {
        let engine = LocalSpeechEngine()
        do {
            _ = try await engine.transcribe(
                audio: PreparedAudio(samples: [], sampleRate: 16_000),
                options: TranscriptionOptions()
            )
            XCTFail("Expected no loaded selection error.")
        } catch let error as LocalSpeechEngineError {
            XCTAssertEqual(error.errorDescription, LocalSpeechEngineError.noSelectionLoaded.errorDescription)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAnalyzerASROnlyReturnsNilDiarization() async throws {
        let transcript = Transcript(segments: [
            TranscriptSegment(text: "hello", startTime: 0, endTime: 0.5)
        ])
        let analyzer = LocalSpeechAnalyzer(transcriber: MockSpeechTranscriber(transcript: transcript))

        let result = try await analyzer.analyze(
            audio: PreparedAudio(samples: Array(repeating: 0, count: 1_600), sampleRate: 16_000),
            options: SpeechAnalysisOptions()
        )

        XCTAssertEqual(result.transcript, transcript)
        XCTAssertNil(result.diarization)
        XCTAssertNil(result.speakerAttributedTranscript)
    }

    func testAnalyzerDiarizationRequestRequiresRegisteredDiarizer() async {
        let analyzer = LocalSpeechAnalyzer(transcriber: MockSpeechTranscriber())

        do {
            _ = try await analyzer.analyze(
                audio: PreparedAudio(samples: [], sampleRate: 16_000),
                options: SpeechAnalysisOptions(diarization: DiarizationRequest())
            )
            XCTFail("Expected unsupported feature error.")
        } catch let error as SpeechAnalysisError {
            XCTAssertEqual(
                error.errorDescription,
                SpeechAnalysisError.unsupportedFeature(
                    "Diarization was requested, but no speaker diarizer is registered."
                ).errorDescription
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAnalyzerCombinesTranscriptDiarizationAndSpeakerAttribution() async throws {
        let speaker = SpeakerID(rawValue: "A")
        let transcript = Transcript(segments: [
            TranscriptSegment(
                text: "hello",
                startTime: 0,
                endTime: 0.5,
                words: [TranscriptWord(text: "hello", startTime: 0, endTime: 0.5)]
            )
        ])
        let diarization = DiarizationResult(
            turns: [SpeakerTurn(speaker: speaker, startTime: 0, endTime: 0.5, isExclusive: true)],
            exclusiveTurns: [SpeakerTurn(speaker: speaker, startTime: 0, endTime: 0.5, isExclusive: true)],
            speakers: [Speaker(id: speaker)],
            duration: 0.5,
            diagnostics: [SpeechDiagnostic(source: "test", message: "diarized")]
        )
        let analyzer = LocalSpeechAnalyzer(
            transcriber: MockSpeechTranscriber(transcript: transcript),
            diarizer: MockSpeakerDiarizer(result: diarization)
        )

        let result = try await analyzer.analyze(
            audio: PreparedAudio(samples: Array(repeating: 0, count: 8_000), sampleRate: 16_000),
            options: SpeechAnalysisOptions(diarization: DiarizationRequest())
        )

        XCTAssertEqual(result.diarization, diarization)
        XCTAssertEqual(result.speakerAttributedTranscript?.segments.first?.speaker, speaker)
        XCTAssertEqual(result.speakerAttributedTranscript?.segments.first?.words.first?.speaker, speaker)
        XCTAssertTrue(result.diagnostics.contains { $0.source == "test" })
        XCTAssertTrue(result.diagnostics.contains { $0.source == "merger" })
    }

    func testStreamingAnalyzerDiarizationRequestRequiresRegisteredStreamingDiarizer() async {
        let analyzer = LocalSpeechAnalyzer(transcriber: MockSpeechTranscriber())
        let audio = AsyncThrowingStream<AudioChunk, Error> { continuation in
            continuation.finish()
        }

        do {
            for try await _ in analyzer.stream(
                audio: audio,
                options: StreamingSpeechAnalysisOptions(diarization: StreamingDiarizationRequest())
            ) {}
            XCTFail("Expected unsupported feature error.")
        } catch let error as SpeechAnalysisError {
            XCTAssertEqual(
                error.errorDescription,
                SpeechAnalysisError.unsupportedFeature(
                    "Streaming diarization was requested, but no streaming speaker diarizer is registered."
                ).errorDescription
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testStreamingAnalyzerFansOutAudioAndEmitsSpeakerAttributedSnapshots() async throws {
        let speaker = SpeakerID(rawValue: "A")
        let transcript = Transcript(segments: [
            TranscriptSegment(
                text: "hello",
                startTime: 0,
                endTime: 0.2,
                words: [TranscriptWord(text: "hello", startTime: 0, endTime: 0.2)]
            )
        ])
        let diarization = DiarizationResult(
            turns: [SpeakerTurn(speaker: speaker, startTime: 0, endTime: 0.2)],
            speakers: [Speaker(id: speaker)],
            duration: 0.2,
            backend: SpeechBackendDescriptor(kind: .mock, displayName: "Mock Streaming Diarizer")
        )
        let asrRecorder = AudioChunkRecorder()
        let diarizationRecorder = AudioChunkRecorder()
        let analyzer = LocalSpeechAnalyzer(
            transcriber: RecordingStreamingTranscriber(
                recorder: asrRecorder,
                events: [
                    .snapshot(StreamingTranscriptSnapshot(stable: transcript)),
                    .completed(transcript)
                ]
            ),
            streamingDiarizer: RecordingStreamingDiarizer(
                recorder: diarizationRecorder,
                snapshots: [StreamingDiarizationSnapshot(stable: diarization)]
            )
        )

        let stream = analyzer.stream(
            audio: testAudioChunks(),
            options: StreamingSpeechAnalysisOptions(diarization: StreamingDiarizationRequest(
                attributionJitterBufferDelay: 0
            ))
        )

        var events: [StreamingSpeechAnalysisEvent] = []
        for try await event in stream {
            events.append(event)
        }

        let asrChunks = await asrRecorder.recordedChunks()
        let diarizationChunks = await diarizationRecorder.recordedChunks()
        XCTAssertEqual(asrChunks.map(\.startTime), [0, 0.1])
        XCTAssertEqual(diarizationChunks.map(\.startTime), [0, 0.1])

        XCTAssertTrue(events.contains { event in
            if case .diarization(let snapshot) = event {
                return snapshot.stable.turns.first?.speaker == speaker
            }
            return false
        })
        XCTAssertTrue(events.contains { event in
            if case .speakerAttributedSnapshot(let snapshot) = event {
                return snapshot.stable.segments.first?.speaker == speaker
                    && snapshot.stable.segments.first?.words.first?.speaker == speaker
            }
            return false
        })
        XCTAssertTrue(events.contains { event in
            if case .completed(let result) = event {
                return result.diarization == diarization
                    && result.speakerAttributedTranscript?.segments.first?.speaker == speaker
            }
            return false
        })
    }

    func testStreamingAnalyzerLocksAttributedStableWindowAcrossDiarizationUpdates() async throws {
        let speakerA = SpeakerID(rawValue: "A")
        let speakerB = SpeakerID(rawValue: "B")
        let transcript = Transcript(segments: [
            TranscriptSegment(
                text: "old",
                startTime: 0,
                endTime: 0.2,
                words: [TranscriptWord(text: "old", startTime: 0, endTime: 0.2)]
            ),
            TranscriptSegment(
                text: "current",
                startTime: 1.0,
                endTime: 1.2,
                words: [TranscriptWord(text: "current", startTime: 1.0, endTime: 1.2)]
            )
        ])
        let fullDiarization = DiarizationResult(
            turns: [
                SpeakerTurn(speaker: speakerA, startTime: 0, endTime: 0.2),
                SpeakerTurn(speaker: speakerB, startTime: 1.0, endTime: 1.2)
            ],
            speakers: [Speaker(id: speakerA), Speaker(id: speakerB)],
            duration: 1.2
        )
        let recentOnlyDiarization = DiarizationResult(
            turns: [SpeakerTurn(speaker: speakerB, startTime: 1.0, endTime: 1.2)],
            speakers: [Speaker(id: speakerB)],
            duration: 1.2
        )
        let analyzer = LocalSpeechAnalyzer(
            transcriber: ChunkedStreamingTranscriber(eventsByChunk: [
                [.snapshot(StreamingTranscriptSnapshot(stable: transcript))],
                [.snapshot(StreamingTranscriptSnapshot(stable: transcript)), .completed(transcript)]
            ]),
            streamingDiarizer: RecordingStreamingDiarizer(
                recorder: AudioChunkRecorder(),
                snapshots: [
                    StreamingDiarizationSnapshot(stable: fullDiarization),
                    StreamingDiarizationSnapshot(stable: recentOnlyDiarization)
                ]
            )
        )

        let stream = analyzer.stream(
            audio: testAudioChunks(startTimes: [0, 1.0]),
            options: StreamingSpeechAnalysisOptions(diarization: StreamingDiarizationRequest(
                attributionLookbackWindow: 0.5,
                attributionJitterBufferDelay: 0
            ))
        )

        var lastAttributedSnapshot: StreamingTranscriptSnapshot?
        for try await event in stream {
            if case .speakerAttributedSnapshot(let snapshot) = event {
                lastAttributedSnapshot = snapshot
            }
        }

        let attributedSegments = try XCTUnwrap(lastAttributedSnapshot?.stable.segments)
        XCTAssertEqual(attributedSegments.first { $0.text == "old" }?.speaker, speakerA)
        XCTAssertEqual(attributedSegments.first { $0.text == "current" }?.speaker, speakerB)
    }

    func testStreamingAnalyzerReconcilesOnlyChangedLockedSegments() async throws {
        let removedID = UUID()
        let preservedID = UUID()
        let currentID = UUID()
        let speakerA = SpeakerID(rawValue: "A")
        let speakerB = SpeakerID(rawValue: "B")
        let speakerC = SpeakerID(rawValue: "C")
        let removed = TranscriptSegment(
            id: removedID,
            text: "removed",
            startTime: 0,
            endTime: 0.2,
            words: [TranscriptWord(text: "removed", startTime: 0, endTime: 0.2)]
        )
        let preserved = TranscriptSegment(
            id: preservedID,
            text: "preserved",
            startTime: 0.3,
            endTime: 0.5,
            words: [TranscriptWord(text: "preserved", startTime: 0.3, endTime: 0.5)]
        )
        let current = TranscriptSegment(
            id: currentID,
            text: "current",
            startTime: 1.0,
            endTime: 1.2,
            words: [TranscriptWord(text: "current", startTime: 1.0, endTime: 1.2)]
        )
        let firstTranscript = Transcript(segments: [removed, preserved, current])
        let revisedTranscript = Transcript(segments: [preserved, current])
        let fullDiarization = DiarizationResult(
            turns: [
                SpeakerTurn(speaker: speakerA, startTime: 0, endTime: 0.2),
                SpeakerTurn(speaker: speakerB, startTime: 0.3, endTime: 0.5),
                SpeakerTurn(speaker: speakerC, startTime: 1.0, endTime: 1.2)
            ],
            speakers: [Speaker(id: speakerA), Speaker(id: speakerB), Speaker(id: speakerC)],
            duration: 1.2
        )
        let recentOnlyDiarization = DiarizationResult(
            turns: [SpeakerTurn(speaker: speakerC, startTime: 1.0, endTime: 1.2)],
            speakers: [Speaker(id: speakerC)],
            duration: 1.2
        )
        let analyzer = LocalSpeechAnalyzer(
            transcriber: ChunkedStreamingTranscriber(eventsByChunk: [
                [.snapshot(StreamingTranscriptSnapshot(stable: firstTranscript))],
                [.snapshot(StreamingTranscriptSnapshot(stable: revisedTranscript)), .completed(revisedTranscript)]
            ]),
            streamingDiarizer: RecordingStreamingDiarizer(
                recorder: AudioChunkRecorder(),
                snapshots: [
                    StreamingDiarizationSnapshot(stable: fullDiarization),
                    StreamingDiarizationSnapshot(stable: recentOnlyDiarization)
                ]
            )
        )

        let stream = analyzer.stream(
            audio: testAudioChunks(startTimes: [0, 1.0]),
            options: StreamingSpeechAnalysisOptions(diarization: StreamingDiarizationRequest(
                attributionLookbackWindow: 0.5,
                attributionJitterBufferDelay: 0
            ))
        )

        var lastAttributedSnapshot: StreamingTranscriptSnapshot?
        for try await event in stream {
            if case .speakerAttributedSnapshot(let snapshot) = event {
                lastAttributedSnapshot = snapshot
            }
        }

        let attributedSegments = try XCTUnwrap(lastAttributedSnapshot?.stable.segments)
        XCTAssertNil(attributedSegments.first { $0.text == "removed" })
        XCTAssertEqual(attributedSegments.first { $0.text == "preserved" }?.speaker, speakerB)
        XCTAssertEqual(attributedSegments.first { $0.text == "current" }?.speaker, speakerC)
    }

    func testStreamingAnalyzerPrunesLockedAttributionCacheWithoutDroppingHistoricalLabels() async throws {
        let speakerA = SpeakerID(rawValue: "A")
        let speakerB = SpeakerID(rawValue: "B")
        let speakerC = SpeakerID(rawValue: "C")
        let old = TranscriptSegment(
            text: "old",
            startTime: 0,
            endTime: 0.2,
            words: [TranscriptWord(text: "old", startTime: 0, endTime: 0.2)]
        )
        let middle = TranscriptSegment(
            text: "middle",
            startTime: 1.0,
            endTime: 1.2,
            words: [TranscriptWord(text: "middle", startTime: 1.0, endTime: 1.2)]
        )
        let latest = TranscriptSegment(
            text: "latest",
            startTime: 2.0,
            endTime: 2.2,
            words: [TranscriptWord(text: "latest", startTime: 2.0, endTime: 2.2)]
        )
        let firstTranscript = Transcript(segments: [old, middle])
        let fullTranscript = Transcript(segments: [old, middle, latest])
        let initialDiarization = DiarizationResult(
            turns: [
                SpeakerTurn(speaker: speakerA, startTime: 0, endTime: 0.2),
                SpeakerTurn(speaker: speakerB, startTime: 1.0, endTime: 1.2)
            ],
            speakers: [Speaker(id: speakerA), Speaker(id: speakerB)],
            duration: 1.2
        )
        let middleAndLatestDiarization = DiarizationResult(
            turns: [
                SpeakerTurn(speaker: speakerB, startTime: 1.0, endTime: 1.2),
                SpeakerTurn(speaker: speakerC, startTime: 2.0, endTime: 2.2)
            ],
            speakers: [Speaker(id: speakerB), Speaker(id: speakerC)],
            duration: 2.2
        )
        let latestOnlyDiarization = DiarizationResult(
            turns: [SpeakerTurn(speaker: speakerC, startTime: 2.0, endTime: 2.2)],
            speakers: [Speaker(id: speakerC)],
            duration: 2.2
        )
        let analyzer = LocalSpeechAnalyzer(
            transcriber: DelayedChunkedStreamingTranscriber(
                eventsByChunk: [
                    [.snapshot(StreamingTranscriptSnapshot(stable: firstTranscript))],
                    [.snapshot(StreamingTranscriptSnapshot(stable: fullTranscript))],
                    [.snapshot(StreamingTranscriptSnapshot(stable: fullTranscript)), .completed(fullTranscript)]
                ],
                nanosecondsBeforeEvents: 10_000_000
            ),
            streamingDiarizer: RecordingStreamingDiarizer(
                recorder: AudioChunkRecorder(),
                snapshots: [
                    StreamingDiarizationSnapshot(stable: initialDiarization),
                    StreamingDiarizationSnapshot(stable: middleAndLatestDiarization),
                    StreamingDiarizationSnapshot(stable: latestOnlyDiarization)
                ]
            )
        )

        let stream = analyzer.stream(
            audio: testAudioChunks(startTimes: [0, 1.0, 2.0]),
            options: StreamingSpeechAnalysisOptions(diarization: StreamingDiarizationRequest(
                attributionLookbackWindow: 0.5,
                attributionJitterBufferDelay: 0,
                attributionCacheRetentionWindow: 0
            ))
        )

        var lastAttributedSnapshot: StreamingTranscriptSnapshot?
        for try await event in stream {
            if case .speakerAttributedSnapshot(let snapshot) = event {
                lastAttributedSnapshot = snapshot
            }
        }

        let attributedSegments = try XCTUnwrap(lastAttributedSnapshot?.stable.segments)
        XCTAssertEqual(attributedSegments.first { $0.text == "old" }?.speaker, speakerA)
        XCTAssertEqual(attributedSegments.first { $0.text == "middle" }?.speaker, speakerB)
        XCTAssertEqual(attributedSegments.first { $0.text == "latest" }?.speaker, speakerC)
    }

    func testStreamingAnalyzerRestoresHistoricRevisionAfterAttributionCachePruning() async throws {
        let speakerA = SpeakerID(rawValue: "A")
        let speakerB = SpeakerID(rawValue: "B")
        let speakerC = SpeakerID(rawValue: "C")
        let old = TranscriptSegment(
            text: "old",
            startTime: 0,
            endTime: 0.2,
            words: [TranscriptWord(text: "old", startTime: 0, endTime: 0.2)]
        )
        let revisedOld = TranscriptSegment(
            text: "revised old",
            startTime: 0,
            endTime: 0.25,
            words: [
                TranscriptWord(text: "revised", startTime: 0, endTime: 0.12),
                TranscriptWord(text: "old", startTime: 0.12, endTime: 0.25)
            ]
        )
        let middle = TranscriptSegment(
            text: "middle",
            startTime: 1.0,
            endTime: 1.2,
            words: [TranscriptWord(text: "middle", startTime: 1.0, endTime: 1.2)]
        )
        let latest = TranscriptSegment(
            text: "latest",
            startTime: 2.0,
            endTime: 2.2,
            words: [TranscriptWord(text: "latest", startTime: 2.0, endTime: 2.2)]
        )
        let firstTranscript = Transcript(segments: [old, middle])
        let fullTranscript = Transcript(segments: [old, middle, latest])
        let revisedTranscript = Transcript(segments: [revisedOld, middle, latest])
        let initialDiarization = DiarizationResult(
            turns: [
                SpeakerTurn(speaker: speakerA, startTime: 0, endTime: 0.2),
                SpeakerTurn(speaker: speakerB, startTime: 1.0, endTime: 1.2)
            ],
            speakers: [Speaker(id: speakerA), Speaker(id: speakerB)],
            duration: 1.2
        )
        let middleAndLatestDiarization = DiarizationResult(
            turns: [
                SpeakerTurn(speaker: speakerB, startTime: 1.0, endTime: 1.2),
                SpeakerTurn(speaker: speakerC, startTime: 2.0, endTime: 2.2)
            ],
            speakers: [Speaker(id: speakerB), Speaker(id: speakerC)],
            duration: 2.2
        )
        let latestOnlyDiarization = DiarizationResult(
            turns: [SpeakerTurn(speaker: speakerC, startTime: 2.0, endTime: 2.2)],
            speakers: [Speaker(id: speakerC)],
            duration: 2.2
        )
        let analyzer = LocalSpeechAnalyzer(
            transcriber: DelayedChunkedStreamingTranscriber(
                eventsByChunk: [
                    [.snapshot(StreamingTranscriptSnapshot(stable: firstTranscript))],
                    [.snapshot(StreamingTranscriptSnapshot(stable: fullTranscript))],
                    [.snapshot(StreamingTranscriptSnapshot(stable: revisedTranscript)), .completed(revisedTranscript)]
                ],
                nanosecondsBeforeEvents: 10_000_000
            ),
            streamingDiarizer: RecordingStreamingDiarizer(
                recorder: AudioChunkRecorder(),
                snapshots: [
                    StreamingDiarizationSnapshot(stable: initialDiarization),
                    StreamingDiarizationSnapshot(stable: middleAndLatestDiarization),
                    StreamingDiarizationSnapshot(stable: latestOnlyDiarization)
                ]
            )
        )

        let stream = analyzer.stream(
            audio: testAudioChunks(startTimes: [0, 1.0, 2.0]),
            options: StreamingSpeechAnalysisOptions(diarization: StreamingDiarizationRequest(
                attributionLookbackWindow: 0.5,
                attributionJitterBufferDelay: 0,
                attributionCacheRetentionWindow: 0
            ))
        )

        var lastAttributedSnapshot: StreamingTranscriptSnapshot?
        for try await event in stream {
            if case .speakerAttributedSnapshot(let snapshot) = event {
                lastAttributedSnapshot = snapshot
            }
        }

        let attributedSegments = try XCTUnwrap(lastAttributedSnapshot?.stable.segments)
        let revised = try XCTUnwrap(attributedSegments.first { $0.text == "revised old" })
        XCTAssertEqual(revised.speaker, speakerA)
        XCTAssertEqual(revised.words.map(\.speaker), [speakerA, speakerA])
        XCTAssertEqual(attributedSegments.first { $0.text == "middle" }?.speaker, speakerB)
        XCTAssertEqual(attributedSegments.first { $0.text == "latest" }?.speaker, speakerC)
    }

    func testStreamingAnalyzerJitterBufferDefersTailAttribution() async throws {
        let speaker = SpeakerID(rawValue: "A")
        let transcript = Transcript(segments: [
            TranscriptSegment(
                text: "ready",
                startTime: 0,
                endTime: 0.2,
                words: [TranscriptWord(text: "ready", startTime: 0, endTime: 0.2)]
            ),
            TranscriptSegment(
                text: "tail",
                startTime: 0.8,
                endTime: 1.0,
                words: [TranscriptWord(text: "tail", startTime: 0.8, endTime: 1.0)]
            )
        ])
        let diarization = DiarizationResult(
            turns: [SpeakerTurn(speaker: speaker, startTime: 0, endTime: 1.0)],
            speakers: [Speaker(id: speaker)],
            duration: 1.0
        )
        let analyzer = LocalSpeechAnalyzer(
            transcriber: ChunkedStreamingTranscriber(eventsByChunk: [
                [.snapshot(StreamingTranscriptSnapshot(stable: transcript))]
            ]),
            streamingDiarizer: RecordingStreamingDiarizer(
                recorder: AudioChunkRecorder(),
                snapshots: [StreamingDiarizationSnapshot(stable: diarization)]
            )
        )

        let stream = analyzer.stream(
            audio: testAudioChunks(startTimes: [0]),
            options: StreamingSpeechAnalysisOptions(diarization: StreamingDiarizationRequest(
                attributionJitterBufferDelay: 0.3
            ))
        )

        var lastAttributedSnapshot: StreamingTranscriptSnapshot?
        for try await event in stream {
            if case .speakerAttributedSnapshot(let snapshot) = event {
                lastAttributedSnapshot = snapshot
            }
        }

        let attributedSegments = try XCTUnwrap(lastAttributedSnapshot?.stable.segments)
        XCTAssertEqual(attributedSegments.first { $0.text == "ready" }?.speaker, speaker)
        XCTAssertNil(attributedSegments.first { $0.text == "tail" }?.speaker)
    }

    func testStreamingAnalyzerClampsExcessiveJitterBufferDelay() async throws {
        let speaker = SpeakerID(rawValue: "A")
        let transcript = Transcript(segments: [
            TranscriptSegment(
                text: "ready",
                startTime: 0,
                endTime: 0.2,
                words: [TranscriptWord(text: "ready", startTime: 0, endTime: 0.2)]
            ),
            TranscriptSegment(
                text: "tail",
                startTime: 0.8,
                endTime: 1.0,
                words: [TranscriptWord(text: "tail", startTime: 0.8, endTime: 1.0)]
            )
        ])
        let diarization = DiarizationResult(
            turns: [SpeakerTurn(speaker: speaker, startTime: 0, endTime: 1.0)],
            speakers: [Speaker(id: speaker)],
            duration: 1.0
        )
        let analyzer = LocalSpeechAnalyzer(
            transcriber: ChunkedStreamingTranscriber(eventsByChunk: [
                [.snapshot(StreamingTranscriptSnapshot(stable: transcript))]
            ]),
            streamingDiarizer: RecordingStreamingDiarizer(
                recorder: AudioChunkRecorder(),
                snapshots: [StreamingDiarizationSnapshot(stable: diarization)]
            )
        )

        let stream = analyzer.stream(
            audio: testAudioChunks(startTimes: [0]),
            options: StreamingSpeechAnalysisOptions(diarization: StreamingDiarizationRequest(
                attributionJitterBufferDelay: 100
            ))
        )

        var lastAttributedSnapshot: StreamingTranscriptSnapshot?
        for try await event in stream {
            if case .speakerAttributedSnapshot(let snapshot) = event {
                lastAttributedSnapshot = snapshot
            }
        }

        let attributedSegments = try XCTUnwrap(lastAttributedSnapshot?.stable.segments)
        XCTAssertEqual(attributedSegments.first { $0.text == "ready" }?.speaker, speaker)
        XCTAssertNil(attributedSegments.first { $0.text == "tail" }?.speaker)
    }

    func testStreamingAnalyzerAllowsLargeConfiguredJitterBufferDelay() async throws {
        let speaker = SpeakerID(rawValue: "A")
        let transcript = Transcript(
            segments: [
                TranscriptSegment(
                    text: "ready",
                    startTime: 0,
                    endTime: 1,
                    words: [TranscriptWord(text: "ready", startTime: 0, endTime: 1)]
                ),
                TranscriptSegment(
                    text: "remote tail",
                    startTime: 23,
                    endTime: 24,
                    words: [
                        TranscriptWord(text: "remote", startTime: 23, endTime: 23.5),
                        TranscriptWord(text: "tail", startTime: 23.5, endTime: 24)
                    ]
                )
            ],
            duration: 30
        )
        let diarization = DiarizationResult(
            turns: [SpeakerTurn(speaker: speaker, startTime: 0, endTime: 30)],
            speakers: [Speaker(id: speaker)],
            duration: 30
        )
        let analyzer = LocalSpeechAnalyzer(
            transcriber: ChunkedStreamingTranscriber(eventsByChunk: [
                [.snapshot(StreamingTranscriptSnapshot(stable: transcript))]
            ]),
            streamingDiarizer: RecordingStreamingDiarizer(
                recorder: AudioChunkRecorder(),
                snapshots: [StreamingDiarizationSnapshot(stable: diarization)]
            )
        )

        let stream = analyzer.stream(
            audio: testAudioChunks(startTimes: [0]),
            options: StreamingSpeechAnalysisOptions(diarization: StreamingDiarizationRequest(
                attributionJitterBufferDelay: 10,
                maximumAttributionJitterBufferDelay: 20
            ))
        )

        var lastAttributedSnapshot: StreamingTranscriptSnapshot?
        for try await event in stream {
            if case .speakerAttributedSnapshot(let snapshot) = event {
                lastAttributedSnapshot = snapshot
            }
        }

        let attributedSegments = try XCTUnwrap(lastAttributedSnapshot?.stable.segments)
        XCTAssertEqual(attributedSegments.first { $0.text == "ready" }?.speaker, speaker)
        XCTAssertNil(attributedSegments.first { $0.text == "remote tail" }?.speaker)
    }

    func testStreamingAnalyzerFanOutPropagatesInputErrorToBothConsumers() async throws {
        let asrRecorder = AudioChunkRecorder()
        let diarizationRecorder = AudioChunkRecorder()
        let analyzer = LocalSpeechAnalyzer(
            transcriber: RecordingStreamingTranscriber(recorder: asrRecorder, events: []),
            streamingDiarizer: RecordingStreamingDiarizer(recorder: diarizationRecorder, snapshots: [])
        )
        let stream = analyzer.stream(
            audio: failingAudioChunks(),
            options: StreamingSpeechAnalysisOptions(diarization: StreamingDiarizationRequest(
                attributionJitterBufferDelay: 0
            ))
        )

        do {
            for try await _ in stream {}
            XCTFail("Expected input stream error to propagate.")
        } catch StreamingFanOutTestError.input {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let asrChunks = await asrRecorder.recordedChunks()
        let diarizationChunks = await diarizationRecorder.recordedChunks()
        XCTAssertEqual(asrChunks.map(\.startTime), [0])
        XCTAssertEqual(diarizationChunks.map(\.startTime), [0])
    }

    func testStreamingAnalyzerFanOutFailsWhenConsumerBacklogExceeded() async throws {
        let analyzer = LocalSpeechAnalyzer(
            transcriber: RecordingStreamingTranscriber(recorder: AudioChunkRecorder(), events: []),
            streamingDiarizer: StalledStreamingDiarizer()
        )
        let stream = analyzer.stream(
            audio: testAudioChunks(startTimes: Array(stride(from: 0.0, to: 1.0, by: 0.05))),
            options: StreamingSpeechAnalysisOptions(
                diarization: StreamingDiarizationRequest(attributionJitterBufferDelay: 0),
                audioFanOutBufferLimit: 4
            )
        )

        do {
            for try await _ in stream {}
            XCTFail("Expected fan-out backlog overflow to fail the stream.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("fell behind"))
        }
    }

    func testStreamingAnalyzerCanDropBackloggedDiarizationAndContinueTranscription() async throws {
        let transcript = Transcript(segments: [
            TranscriptSegment(text: "transcription survives", startTime: 0, endTime: 0.5)
        ])
        let asrRecorder = AudioChunkRecorder()
        let analyzer = LocalSpeechAnalyzer(
            transcriber: RecordingStreamingTranscriber(
                recorder: asrRecorder,
                events: [.completed(transcript)]
            ),
            streamingDiarizer: StalledStreamingDiarizer()
        )
        let stream = analyzer.stream(
            audio: pacedTestAudioChunks(startTimes: Array(stride(from: 0.0, to: 1.0, by: 0.05))),
            options: StreamingSpeechAnalysisOptions(
                diarization: StreamingDiarizationRequest(attributionJitterBufferDelay: 0),
                audioFanOutBufferLimit: 4,
                backlogPolicy: .dropDiarization
            )
        )

        var sawDropDiagnostic = false
        var completed: SpeechAnalysisResult?
        for try await event in stream {
            switch event {
            case .transcription(.diagnostic(let diagnostic)):
                sawDropDiagnostic = diagnostic.message.contains("Dropped diarization stream")
            case .completed(let result):
                completed = result
            case .transcription, .diarization, .speakerAttributedSnapshot:
                break
            }
        }

        let asrChunks = await asrRecorder.recordedChunks()
        XCTAssertEqual(asrChunks.count, 20)
        XCTAssertTrue(sawDropDiagnostic)
        XCTAssertEqual(completed?.transcript, transcript)
        XCTAssertNil(completed?.diarization)
    }

    func testStreamingAnalyzerIgnoresLateDiarizationAfterSoftDrop() async throws {
        let speaker = SpeakerID(rawValue: "late")
        let transcript = Transcript(segments: [
            TranscriptSegment(text: "transcription only", startTime: 0, endTime: 0.5)
        ])
        let lateSnapshot = StreamingDiarizationSnapshot(stable: DiarizationResult(
            turns: [SpeakerTurn(speaker: speaker, startTime: 0, endTime: 0.5)],
            speakers: [Speaker(id: speaker)],
            duration: 0.5
        ))
        let analyzer = LocalSpeechAnalyzer(
            transcriber: RecordingStreamingTranscriber(
                recorder: AudioChunkRecorder(),
                events: [.completed(transcript)]
            ),
            streamingDiarizer: StalledEmittingStreamingDiarizer(snapshot: lateSnapshot)
        )
        let stream = analyzer.stream(
            audio: pacedTestAudioChunks(startTimes: Array(stride(from: 0.0, to: 1.0, by: 0.05))),
            options: StreamingSpeechAnalysisOptions(
                diarization: StreamingDiarizationRequest(attributionJitterBufferDelay: 0),
                audioFanOutBufferLimit: 4,
                backlogPolicy: .dropDiarization
            )
        )

        var sawLateDiarization = false
        var completed: SpeechAnalysisResult?
        for try await event in stream {
            switch event {
            case .diarization, .speakerAttributedSnapshot:
                sawLateDiarization = true
            case .completed(let result):
                completed = result
            case .transcription:
                break
            }
        }

        XCTAssertFalse(sawLateDiarization)
        XCTAssertEqual(completed?.transcript, transcript)
        XCTAssertNil(completed?.diarization)
    }

    func testEngineRegistersDiarizerForAnalyzerConstruction() async {
        let engine = LocalSpeechEngine()
        let speaker = SpeakerID(rawValue: "A")
        let diarization = DiarizationResult(
            turns: [SpeakerTurn(speaker: speaker, startTime: 0, endTime: 0.5)],
            speakers: [Speaker(id: speaker)],
            duration: 0.5,
            backend: SpeechBackendDescriptor(kind: .mock, displayName: "Mock Diarizer")
        )

        let initialDiarizer = await engine.activeDiarizer()
        XCTAssertNil(initialDiarizer)

        await engine.registerDiarizer(MockSpeakerDiarizer(result: diarization))
        await engine.registerStreamingDiarizer(MockStreamingSpeakerDiarizer(snapshots: [
            StreamingDiarizationSnapshot(stable: diarization)
        ]))

        let activeDiarizer = await engine.activeDiarizer()
        let activeStreamingDiarizer = await engine.activeStreamingDiarizer()
        XCTAssertNotNil(activeDiarizer)
        XCTAssertNotNil(activeStreamingDiarizer)
        let analyzer = await engine.makeAnalyzer()
        XCTAssertNotNil(analyzer as LocalSpeechAnalyzer?)
    }

    func testInstalledSelectionRoutesToWhisperProvider() async throws {
        let root = try makeTemporaryDirectory()
        let source = root.appendingPathComponent("ggml-base.en.bin")
        try Data("fake".utf8).write(to: source)

        let library = SpeechModelLibrary(root: root.appendingPathComponent("SpeechModels", isDirectory: true))
        let importResult = try await library.importFile(at: source, displayName: "Base")
        let model = importResult.model
        let engine = LocalSpeechEngine()
        let loaded = try await engine.load(
            selection: .installed(model.id),
            from: library,
            options: SpeechLoadOptions(preload: false)
        )
        let currentSelection = await engine.currentSelection()

        XCTAssertEqual(loaded.selection, .installed(model.id))
        XCTAssertEqual(loaded.backend.kind, .whisperCpp)
        XCTAssertEqual(currentSelection, .installed(model.id))
    }

    func testLoadDoesNotRefreshLibraryForInstalledSelection() async throws {
        let root = try makeTemporaryDirectory()
        let modelsRoot = root.appendingPathComponent("SpeechModels", isDirectory: true)
        let library = SpeechModelLibrary(root: modelsRoot)
        let id = try createMetadataFreeModel(in: modelsRoot)
        let engine = LocalSpeechEngine()

        do {
            _ = try await engine.load(
                selection: .installed(id),
                from: library,
                options: SpeechLoadOptions(preload: false)
            )
            XCTFail("Expected load to use the cached library state.")
        } catch LocalSpeechEngineError.installedModelNotFound(let missingID) {
            XCTAssertEqual(missingID, id)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCapabilitiesDifferentiateInstalledAndSystemProviders() async throws {
        let root = try makeTemporaryDirectory()
        let source = root.appendingPathComponent("ggml-base.en.bin")
        try Data("fake".utf8).write(to: source)
        let library = SpeechModelLibrary(root: root.appendingPathComponent("SpeechModels", isDirectory: true))
        let importResult = try await library.importFile(at: source, displayName: "Base")
        let model = importResult.model

        let installed = await LocalSpeechEngine.capabilities(for: .installed(model.id), in: library)
        let system = await LocalSpeechEngine.capabilities(for: .system(.appleSpeech), in: library)

        XCTAssertTrue(installed.supportsTranslation)
        XCTAssertTrue(installed.supportsWordTimestamps)
        XCTAssertFalse(system.supportsTranslation)
        XCTAssertFalse(system.supportsWordTimestamps)
    }

    func testLoadPlanReturnsNilForInvalidStorageValue() async throws {
        let root = try makeTemporaryDirectory()
        let library = SpeechModelLibrary(root: root.appendingPathComponent("SpeechModels", isDirectory: true))

        let plan = await LocalSpeechEngine.loadPlan(from: "bad", in: library)

        XCTAssertNil(plan)
    }

    func testLoadPlanRefreshesInstalledModelsOnDemand() async throws {
        let root = try makeTemporaryDirectory()
        let modelsRoot = root.appendingPathComponent("SpeechModels", isDirectory: true)
        let library = SpeechModelLibrary(root: modelsRoot)
        let id = try createMetadataFreeModel(in: modelsRoot)

        let plan = await LocalSpeechEngine.loadPlan(from: id.uuidString, in: library)

        XCTAssertEqual(plan?.selection, .installed(id))
        XCTAssertEqual(plan?.displayName, "ggml-base.en")
        XCTAssertEqual(plan?.availability, .available)
        XCTAssertEqual(plan?.capabilities, .whisperCppDefault)
    }

    func testLoadPlanCanUseCachedLibraryOnly() async throws {
        let root = try makeTemporaryDirectory()
        let modelsRoot = root.appendingPathComponent("SpeechModels", isDirectory: true)
        let library = SpeechModelLibrary(root: modelsRoot)
        let id = try createMetadataFreeModel(in: modelsRoot)

        let missing = await LocalSpeechEngine.loadPlan(
            from: id.uuidString,
            in: library,
            refreshingLibrary: false
        )
        XCTAssertNil(missing)

        _ = await library.refresh()
        let cached = await LocalSpeechEngine.loadPlan(
            from: id.uuidString,
            in: library,
            refreshingLibrary: false
        )
        XCTAssertEqual(cached?.selection, .installed(id))
    }

    func testLoadPlanReturnsNilForDeletedInstalledSelection() async throws {
        let root = try makeTemporaryDirectory()
        let source = root.appendingPathComponent("ggml-base.en.bin")
        try Data("fake".utf8).write(to: source)
        let modelsRoot = root.appendingPathComponent("SpeechModels", isDirectory: true)
        let library = SpeechModelLibrary(root: modelsRoot)
        let importResult = try await library.importFile(at: source, displayName: "Base")
        let model = importResult.model
        try FileManager.default.removeItem(at: modelsRoot.appendingPathComponent(model.id.uuidString, isDirectory: true))

        let plan = await LocalSpeechEngine.loadPlan(from: model.id.uuidString, in: library)

        XCTAssertNil(plan)
    }

    func testLoadPlanResolvesOnlyLoadPlannableSystemSelection() async throws {
        let root = try makeTemporaryDirectory()
        let library = SpeechModelLibrary(root: root.appendingPathComponent("SpeechModels", isDirectory: true))
        let locale = Locale(identifier: "en_US")
        let options = await LocalSpeechEngine.systemModelOptions(locale: locale)
        let option = options.first { $0.selection == .system(.appleSpeech) }

        let plan = await LocalSpeechEngine.loadPlan(
            from: SpeechSystemModelID.appleSpeech.rawValue,
            in: library,
            locale: locale
        )

        switch option?.availability {
        case .available, .unavailable(.assetDownloadRequired):
            XCTAssertEqual(plan?.selection, option?.selection)
            XCTAssertEqual(plan?.displayName, option?.displayName)
            XCTAssertEqual(plan?.capabilities, option?.capabilities)
            XCTAssertEqual(plan?.availability, option?.availability)
        case .unavailable, nil:
            XCTAssertNil(plan)
        }
    }

    func testSystemModelOptionsUseStorageIDs() async {
        let options = await LocalSpeechEngine.systemModelOptions(locale: Locale(identifier: "en_US"))
        for option in options {
            XCTAssertEqual(option.id, option.selection.storageValue)
        }
    }

    private func testAudioChunks(startTimes: [TimeInterval] = [0, 0.1]) -> AsyncThrowingStream<AudioChunk, Error> {
        AsyncThrowingStream<AudioChunk, Error> { continuation in
            for startTime in startTimes {
                continuation.yield(AudioChunk(
                    samples: Array(repeating: 0.05, count: 1_600),
                    sampleRate: 16_000,
                    channelCount: 1,
                    startTime: startTime,
                    duration: 0.1
                ))
            }
            continuation.finish()
        }
    }

    private func failingAudioChunks() -> AsyncThrowingStream<AudioChunk, Error> {
        AsyncThrowingStream<AudioChunk, Error> { continuation in
            continuation.yield(AudioChunk(
                samples: Array(repeating: 0.05, count: 1_600),
                sampleRate: 16_000,
                channelCount: 1,
                startTime: 0,
                duration: 0.1
            ))
            continuation.finish(throwing: StreamingFanOutTestError.input)
        }
    }

    private func pacedTestAudioChunks(
        startTimes: [TimeInterval],
        nanosecondsBetweenChunks: UInt64 = 5_000_000
    ) -> AsyncThrowingStream<AudioChunk, Error> {
        AsyncThrowingStream<AudioChunk, Error> { continuation in
            let task = Task {
                do {
                    for startTime in startTimes {
                        continuation.yield(AudioChunk(
                            samples: Array(repeating: 0.05, count: 1_600),
                            sampleRate: 16_000,
                            channelCount: 1,
                            startTime: startTime,
                            duration: 0.1
                        ))
                        try await Task.sleep(nanoseconds: nanosecondsBetweenChunks)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CarbocationLocalSpeechRuntimeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func createMetadataFreeModel(in modelsRoot: URL, filename: String = "ggml-base.en.bin") throws -> UUID {
        let id = UUID()
        let directory = modelsRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("fake".utf8).write(to: directory.appendingPathComponent(filename))
        return id
    }
}

private actor AudioChunkRecorder {
    private var chunks: [AudioChunk] = []

    func record(_ chunk: AudioChunk) {
        chunks.append(chunk)
    }

    func recordedChunks() -> [AudioChunk] {
        chunks
    }
}

private enum StreamingFanOutTestError: Error {
    case input
}

private struct RecordingStreamingTranscriber: SpeechTranscriber {
    var recorder: AudioChunkRecorder
    var events: [TranscriptEvent]

    func transcribe(file url: URL, options: TranscriptionOptions) async throws -> Transcript {
        _ = url
        _ = options
        return Transcript()
    }

    func transcribe(audio: PreparedAudio, options: TranscriptionOptions) async throws -> Transcript {
        _ = audio
        _ = options
        return Transcript()
    }

    func stream(
        audio: AsyncThrowingStream<AudioChunk, Error>,
        options: StreamingTranscriptionOptions
    ) -> AsyncThrowingStream<TranscriptEvent, Error> {
        let recorder = recorder
        let events = events
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    _ = options
                    for try await chunk in audio {
                        try Task.checkCancellation()
                        await recorder.record(chunk)
                    }
                    for event in events {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

private struct ChunkedStreamingTranscriber: SpeechTranscriber {
    var eventsByChunk: [[TranscriptEvent]]

    func transcribe(file url: URL, options: TranscriptionOptions) async throws -> Transcript {
        _ = url
        _ = options
        return Transcript()
    }

    func transcribe(audio: PreparedAudio, options: TranscriptionOptions) async throws -> Transcript {
        _ = audio
        _ = options
        return Transcript()
    }

    func stream(
        audio: AsyncThrowingStream<AudioChunk, Error>,
        options: StreamingTranscriptionOptions
    ) -> AsyncThrowingStream<TranscriptEvent, Error> {
        let eventsByChunk = eventsByChunk
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    _ = options
                    var index = 0
                    for try await _ in audio {
                        try Task.checkCancellation()
                        if index < eventsByChunk.count {
                            for event in eventsByChunk[index] {
                                continuation.yield(event)
                            }
                        }
                        index += 1
                    }
                    while index < eventsByChunk.count {
                        for event in eventsByChunk[index] {
                            continuation.yield(event)
                        }
                        index += 1
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

private struct DelayedChunkedStreamingTranscriber: SpeechTranscriber {
    var eventsByChunk: [[TranscriptEvent]]
    var nanosecondsBeforeEvents: UInt64

    func transcribe(file url: URL, options: TranscriptionOptions) async throws -> Transcript {
        _ = url
        _ = options
        return Transcript()
    }

    func transcribe(audio: PreparedAudio, options: TranscriptionOptions) async throws -> Transcript {
        _ = audio
        _ = options
        return Transcript()
    }

    func stream(
        audio: AsyncThrowingStream<AudioChunk, Error>,
        options: StreamingTranscriptionOptions
    ) -> AsyncThrowingStream<TranscriptEvent, Error> {
        let eventsByChunk = eventsByChunk
        let nanosecondsBeforeEvents = nanosecondsBeforeEvents
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    _ = options
                    var index = 0
                    for try await _ in audio {
                        try Task.checkCancellation()
                        if nanosecondsBeforeEvents > 0 {
                            try await Task.sleep(nanoseconds: nanosecondsBeforeEvents)
                        }
                        if index < eventsByChunk.count {
                            for event in eventsByChunk[index] {
                                continuation.yield(event)
                            }
                        }
                        index += 1
                    }
                    while index < eventsByChunk.count {
                        if nanosecondsBeforeEvents > 0 {
                            try await Task.sleep(nanoseconds: nanosecondsBeforeEvents)
                        }
                        for event in eventsByChunk[index] {
                            continuation.yield(event)
                        }
                        index += 1
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

private struct RecordingStreamingDiarizer: StreamingSpeakerDiarizer {
    var recorder: AudioChunkRecorder
    var snapshots: [StreamingDiarizationSnapshot]

    func stream(
        audio: AsyncThrowingStream<AudioChunk, Error>,
        options: StreamingDiarizationOptions
    ) -> AsyncThrowingStream<StreamingDiarizationSnapshot, Error> {
        let recorder = recorder
        let snapshots = snapshots
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try options.options.validate()
                    var index = 0
                    for try await chunk in audio {
                        try Task.checkCancellation()
                        await recorder.record(chunk)
                        if index < snapshots.count {
                            continuation.yield(snapshots[index])
                        }
                        index += 1
                    }
                    while index < snapshots.count {
                        continuation.yield(snapshots[index])
                        index += 1
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

private struct StalledStreamingDiarizer: StreamingSpeakerDiarizer {
    func stream(
        audio: AsyncThrowingStream<AudioChunk, Error>,
        options: StreamingDiarizationOptions
    ) -> AsyncThrowingStream<StreamingDiarizationSnapshot, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try options.options.validate()
                    try await Task.sleep(nanoseconds: 200_000_000)
                    for try await _ in audio {
                        try Task.checkCancellation()
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

private struct StalledEmittingStreamingDiarizer: StreamingSpeakerDiarizer {
    var snapshot: StreamingDiarizationSnapshot

    func stream(
        audio: AsyncThrowingStream<AudioChunk, Error>,
        options: StreamingDiarizationOptions
    ) -> AsyncThrowingStream<StreamingDiarizationSnapshot, Error> {
        let snapshot = snapshot
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try options.options.validate()
                    try await Task.sleep(nanoseconds: 200_000_000)
                    for try await _ in audio {
                        try Task.checkCancellation()
                    }
                    continuation.yield(snapshot)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
