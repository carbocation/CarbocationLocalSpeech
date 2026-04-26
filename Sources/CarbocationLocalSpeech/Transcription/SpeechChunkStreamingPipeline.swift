import Foundation

public enum SpeechChunkStreamingPipeline {
    public typealias ChunkTranscription = @Sendable (PreparedAudio, TranscriptionOptions) async throws -> Transcript

    public static func stream(
        audio: AsyncThrowingStream<AudioChunk, Error>,
        backend: SpeechBackendDescriptor,
        options: StreamingTranscriptionOptions,
        transcribe: @escaping ChunkTranscription
    ) -> AsyncThrowingStream<TranscriptEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(.started(backend))

                let detector = EnergyVoiceActivityDetector()
                var chunker = SpeechChunker(configuration: options.chunking)
                var committedSegments: [TranscriptSegment] = []
                var pendingPartialID: UUID?

                do {
                    for try await chunk in audio {
                        try Task.checkCancellation()

                        let activity = try detector.analyze(chunk)
                        continuation.yield(.audioLevel(AudioLevelMeter.measure(samples: chunk.samples, time: chunk.startTime)))
                        continuation.yield(.voiceActivity(activity))

                        for emitted in chunker.append(chunk, activity: activity) {
                            try await process(
                                emitted,
                                options: options,
                                transcribe: transcribe,
                                committedSegments: &committedSegments,
                                pendingPartialID: &pendingPartialID,
                                continuation: continuation
                            )
                        }
                    }

                    for emitted in chunker.finish() {
                        try await process(
                            emitted,
                            options: options,
                            transcribe: transcribe,
                            committedSegments: &committedSegments,
                            pendingPartialID: &pendingPartialID,
                            continuation: continuation
                        )
                    }

                    continuation.yield(.completed(Transcript(
                        segments: committedSegments,
                        backend: backend
                    )))
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

    private static func process(
        _ emitted: SpeechAudioChunk,
        options: StreamingTranscriptionOptions,
        transcribe: ChunkTranscription,
        committedSegments: inout [TranscriptSegment],
        pendingPartialID: inout UUID?,
        continuation: AsyncThrowingStream<TranscriptEvent, Error>.Continuation
    ) async throws {
        try Task.checkCancellation()

        let startedAt = Date()
        let transcript = try await transcribe(emitted.audio, options.transcription)
        let processingDuration = Date().timeIntervalSince(startedAt)
        let segments = transcript.segments
            .map { offset($0, by: emitted.startTime) }
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        continuation.yield(.progress(TranscriptionProgress(
            processedDuration: emitted.startTime + emitted.audio.duration
        )))
        continuation.yield(.stats(TranscriptionStats(
            audioDuration: emitted.audio.duration,
            processingDuration: processingDuration,
            realTimeFactor: emitted.audio.duration > 0 ? processingDuration / emitted.audio.duration : nil,
            segmentCount: segments.count
        )))

        guard !segments.isEmpty else {
            return
        }

        if shouldCommit(emitted: emitted, strategy: options.partialCommitStrategy) {
            for segment in segments {
                committedSegments.append(segment)
                continuation.yield(.committed(segment))
            }
            pendingPartialID = nil
        } else {
            let partial = TranscriptPartial(
                text: segments.map(\.text).joined(separator: " "),
                startTime: segments.first?.startTime ?? emitted.startTime,
                endTime: segments.last?.endTime ?? (emitted.startTime + emitted.audio.duration)
            )
            if let previousID = pendingPartialID {
                continuation.yield(.revision(TranscriptRevision(
                    replacesPartialID: previousID,
                    replacement: partial
                )))
            } else {
                continuation.yield(.partial(partial))
            }
            pendingPartialID = partial.id
        }
    }

    private static func shouldCommit(
        emitted: SpeechAudioChunk,
        strategy: PartialCommitStrategy
    ) -> Bool {
        if emitted.isFinal {
            return true
        }

        switch strategy {
        case .silence:
            return false
        case .chunkBoundary, .silenceOrChunkBoundary:
            return true
        }
    }

    private static func offset(_ segment: TranscriptSegment, by offset: TimeInterval) -> TranscriptSegment {
        TranscriptSegment(
            id: segment.id,
            text: segment.text,
            startTime: segment.startTime + offset,
            endTime: segment.endTime + offset,
            words: segment.words.map { word in
                TranscriptWord(
                    id: word.id,
                    text: word.text,
                    startTime: word.startTime + offset,
                    endTime: word.endTime + offset,
                    confidence: word.confidence
                )
            },
            speaker: segment.speaker,
            confidence: segment.confidence
        )
    }
}
