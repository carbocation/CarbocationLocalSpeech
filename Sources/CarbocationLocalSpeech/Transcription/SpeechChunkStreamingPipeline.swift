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
                guard let segment = removeCommittedOverlap(
                    from: segment,
                    committedSegments: committedSegments,
                    overlapDuration: options.chunking.overlapDuration
                ) else {
                    continue
                }

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

    private static func removeCommittedOverlap(
        from segment: TranscriptSegment,
        committedSegments: [TranscriptSegment],
        overlapDuration: TimeInterval
    ) -> TranscriptSegment? {
        guard overlapDuration > 0,
              let lastCommitted = committedSegments.last,
              segment.startTime <= lastCommitted.endTime + overlapDuration + 0.1
        else {
            return segment
        }

        let committedText = committedSegments.map(\.text).joined(separator: " ")
        let trimResult = trimDuplicatePrefix(in: segment.text, after: committedText)
        guard trimResult.removedTokenCount > 0 else {
            return segment
        }

        let trimmedText = trimResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            return nil
        }

        let trimmedWords: [TranscriptWord]
        if segment.words.count >= trimResult.removedTokenCount {
            trimmedWords = Array(segment.words.dropFirst(trimResult.removedTokenCount))
        } else {
            trimmedWords = []
        }

        let startTime = trimmedWords.first?.startTime ?? max(segment.startTime, lastCommitted.endTime)
        return TranscriptSegment(
            id: segment.id,
            text: trimmedText,
            startTime: startTime,
            endTime: max(startTime, segment.endTime),
            words: trimmedWords,
            speaker: segment.speaker,
            confidence: segment.confidence
        )
    }

    private static func trimDuplicatePrefix(
        in text: String,
        after committedText: String
    ) -> (text: String, removedTokenCount: Int) {
        let committedTokens = tokens(in: committedText)
        let newTokens = tokens(in: text)
        guard !committedTokens.isEmpty, !newTokens.isEmpty else {
            return (text, 0)
        }

        let maximumOverlap = min(committedTokens.count, newTokens.count, 12)
        var duplicateTokenCount = 0
        for count in stride(from: maximumOverlap, through: 1, by: -1) {
            let committedSuffix = committedTokens.suffix(count).map(\.normalized)
            let newPrefix = newTokens.prefix(count).map(\.normalized)
            if Array(committedSuffix) == Array(newPrefix) {
                duplicateTokenCount = count
                break
            }
        }

        guard duplicateTokenCount > 0 else {
            return (text, 0)
        }

        let cutIndex = newTokens[duplicateTokenCount - 1].range.upperBound
        let trimmed = trimLeadingOverlapSeparators(String(text[cutIndex...]))
        return (trimmed, duplicateTokenCount)
    }

    private static func trimLeadingOverlapSeparators(_ text: String) -> String {
        let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        var startIndex = text.startIndex

        while startIndex < text.endIndex,
              text[startIndex].unicodeScalars.allSatisfy({ separators.contains($0) }) {
            startIndex = text.index(after: startIndex)
        }

        return String(text[startIndex...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tokens(in text: String) -> [TranscriptTextToken] {
        var tokens: [TranscriptTextToken] = []
        var tokenStart: String.Index?

        for index in text.indices {
            let character = text[index]
            if character.isLetter || character.isNumber || character == "'" {
                if tokenStart == nil {
                    tokenStart = index
                }
            } else if let start = tokenStart {
                appendToken(from: start, to: index, in: text, tokens: &tokens)
                tokenStart = nil
            }
        }

        if let start = tokenStart {
            appendToken(from: start, to: text.endIndex, in: text, tokens: &tokens)
        }

        return tokens
    }

    private static func appendToken(
        from start: String.Index,
        to end: String.Index,
        in text: String,
        tokens: inout [TranscriptTextToken]
    ) {
        let value = String(text[start..<end])
        tokens.append(TranscriptTextToken(
            normalized: value.lowercased(),
            range: start..<end
        ))
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

private struct TranscriptTextToken {
    var normalized: String
    var range: Range<String.Index>
}
