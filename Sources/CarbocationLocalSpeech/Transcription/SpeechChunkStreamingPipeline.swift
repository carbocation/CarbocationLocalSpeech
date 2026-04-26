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
                var committedSegments: [TranscriptSegment] = []
                var pendingPartialID: UUID?
                var agreementState = LocalAgreementState(policy: Self.resolvedCommitmentPolicy(options))

                do {
                    switch options.emulation.window {
                    case .vadUtterances(let configuration):
                        var chunker = SpeechChunker(configuration: configuration)
                        for try await chunk in audio {
                            try Task.checkCancellation()

                            let activity = try detector.analyze(chunk)
                            continuation.yield(.audioLevel(AudioLevelMeter.measure(samples: chunk.samples, time: chunk.startTime)))
                            continuation.yield(.voiceActivity(activity))

                            for emitted in chunker.append(chunk, activity: activity) {
                                try await process(
                                    emitted,
                                    backend: backend,
                                    options: options,
                                    transcribe: transcribe,
                                    committedSegments: &committedSegments,
                                    pendingPartialID: &pendingPartialID,
                                    agreementState: &agreementState,
                                    continuation: continuation
                                )
                            }
                        }

                        for emitted in chunker.finish() {
                            try await process(
                                emitted,
                                backend: backend,
                                options: options,
                                transcribe: transcribe,
                                committedSegments: &committedSegments,
                                pendingPartialID: &pendingPartialID,
                                agreementState: &agreementState,
                                continuation: continuation
                            )
                        }
                    case .rollingBuffer(let maxDuration, let updateInterval, let overlap):
                        var window = SpeechRollingWindow(
                            maximumBufferDuration: maxDuration,
                            updateInterval: updateInterval,
                            overlapDuration: overlap
                        )
                        for try await chunk in audio {
                            try Task.checkCancellation()

                            let activity = try detector.analyze(chunk)
                            continuation.yield(.audioLevel(AudioLevelMeter.measure(samples: chunk.samples, time: chunk.startTime)))
                            continuation.yield(.voiceActivity(activity))

                            for emitted in window.append(chunk) {
                                try await process(
                                    emitted,
                                    backend: backend,
                                    options: options,
                                    transcribe: transcribe,
                                    committedSegments: &committedSegments,
                                    pendingPartialID: &pendingPartialID,
                                    agreementState: &agreementState,
                                    continuation: continuation
                                )
                            }
                        }

                        for emitted in window.finish() {
                            try await process(
                                emitted,
                                backend: backend,
                                options: options,
                                transcribe: transcribe,
                                committedSegments: &committedSegments,
                                pendingPartialID: &pendingPartialID,
                                agreementState: &agreementState,
                                continuation: continuation
                            )
                        }
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
        backend: SpeechBackendDescriptor,
        options: StreamingTranscriptionOptions,
        transcribe: ChunkTranscription,
        committedSegments: inout [TranscriptSegment],
        pendingPartialID: inout UUID?,
        agreementState: inout LocalAgreementState,
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

        let overlapDuration = options.emulation.overlapDeduplication
            ? options.emulation.window.overlapDuration
            : 0
        let candidateSegments = segments.compactMap { segment in
            removeCommittedOverlap(
                from: segment,
                committedSegments: committedSegments,
                overlapDuration: overlapDuration
            )
        }

        guard !candidateSegments.isEmpty else {
            return
        }

        switch resolvedCommitmentPolicy(options) {
        case .immediate:
            commit(candidateSegments, backend: backend, committedSegments: &committedSegments, pendingPartialID: &pendingPartialID, continuation: continuation)
            agreementState.reset()
        case .providerFinals, .silence:
            if emitted.isFinal {
                commit(candidateSegments, backend: backend, committedSegments: &committedSegments, pendingPartialID: &pendingPartialID, continuation: continuation)
                agreementState.reset()
            } else {
                publishPartial(
                    candidateSegments,
                    backend: backend,
                    committedSegments: committedSegments,
                    pendingPartialID: &pendingPartialID,
                    continuation: continuation
                )
            }
        case .localAgreement:
            if emitted.isFinal {
                commit(candidateSegments, backend: backend, committedSegments: &committedSegments, pendingPartialID: &pendingPartialID, continuation: continuation)
                agreementState.reset()
            } else {
                processLocalAgreement(
                    candidateSegments,
                    backend: backend,
                    committedSegments: &committedSegments,
                    pendingPartialID: &pendingPartialID,
                    agreementState: &agreementState,
                    continuation: continuation
                )
            }
        case .automatic:
            if emitted.isFinal {
                commit(candidateSegments, backend: backend, committedSegments: &committedSegments, pendingPartialID: &pendingPartialID, continuation: continuation)
                agreementState.reset()
            } else {
                publishPartial(
                    candidateSegments,
                    backend: backend,
                    committedSegments: committedSegments,
                    pendingPartialID: &pendingPartialID,
                    continuation: continuation
                )
            }
        }
    }

    private static func commit(
        _ segments: [TranscriptSegment],
        backend: SpeechBackendDescriptor,
        committedSegments: inout [TranscriptSegment],
        pendingPartialID: inout UUID?,
        continuation: AsyncThrowingStream<TranscriptEvent, Error>.Continuation
    ) {
        for segment in segments {
            committedSegments.append(segment)
            continuation.yield(.committed(segment))
        }
        pendingPartialID = nil
        continuation.yield(.snapshot(StreamingTranscriptSnapshot(
            committed: Transcript(segments: committedSegments, backend: backend)
        )))
    }

    private static func processLocalAgreement(
        _ segments: [TranscriptSegment],
        backend: SpeechBackendDescriptor,
        committedSegments: inout [TranscriptSegment],
        pendingPartialID: inout UUID?,
        agreementState: inout LocalAgreementState,
        continuation: AsyncThrowingStream<TranscriptEvent, Error>.Continuation
    ) {
        let hypothesis = segments.map(\.text).joined(separator: " ")
        let agreement = agreementState.accept(hypothesis: hypothesis)

        if !agreement.confirmedPrefix.isEmpty,
           let firstSegment = segments.first,
           let lastSegment = segments.last {
            let segment = TranscriptSegment(
                text: agreement.confirmedPrefix,
                startTime: firstSegment.startTime,
                endTime: max(firstSegment.startTime, lastSegment.endTime)
            )
            committedSegments.append(segment)
            continuation.yield(.committed(segment))
            pendingPartialID = nil
        }

        guard !agreement.unconfirmedText.isEmpty,
              let firstSegment = segments.first,
              let lastSegment = segments.last
        else {
            continuation.yield(.snapshot(StreamingTranscriptSnapshot(
                committed: Transcript(segments: committedSegments, backend: backend)
            )))
            return
        }

        publishPartial(
            [TranscriptSegment(
                text: agreement.unconfirmedText,
                startTime: firstSegment.startTime,
                endTime: max(firstSegment.startTime, lastSegment.endTime)
            )],
            backend: backend,
            committedSegments: committedSegments,
            pendingPartialID: &pendingPartialID,
            continuation: continuation
        )
    }

    private static func publishPartial(
        _ segments: [TranscriptSegment],
        backend: SpeechBackendDescriptor,
        committedSegments: [TranscriptSegment],
        pendingPartialID: inout UUID?,
        continuation: AsyncThrowingStream<TranscriptEvent, Error>.Continuation
    ) {
        guard let firstSegment = segments.first,
              let lastSegment = segments.last else {
            return
        }

        let partial = TranscriptPartial(
            text: segments.map(\.text).joined(separator: " "),
            startTime: firstSegment.startTime,
            endTime: lastSegment.endTime
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
        continuation.yield(.snapshot(StreamingTranscriptSnapshot(
            committed: Transcript(segments: committedSegments, backend: backend),
            unconfirmed: partial,
            volatileRange: TranscriptTimeRange(startTime: partial.startTime, endTime: partial.endTime)
        )))
    }

    private static func resolvedCommitmentPolicy(_ options: StreamingTranscriptionOptions) -> TranscriptCommitmentPolicy {
        switch options.commitment {
        case .automatic:
            switch options.emulation.window {
            case .rollingBuffer:
                return .localAgreement(iterations: 2)
            case .vadUtterances:
                return .providerFinals
            }
        case .providerFinals, .localAgreement, .silence, .immediate:
            return options.commitment
        }
    }

    private static func splitConfirmedPrefix(
        in text: String,
        tokenCount: Int
    ) -> (prefix: String, remainder: String) {
        let tokens = tokens(in: text)
        guard tokenCount > 0, tokenCount <= tokens.count else {
            return ("", text.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let prefixEnd = tokens[tokenCount - 1].range.upperBound
        let prefix = String(text[..<prefixEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
        let remainder = trimLeadingOverlapSeparators(String(text[prefixEnd...]))
        return (prefix, remainder)
    }

    private static func commonPrefixTokenCount(in texts: [String]) -> Int {
        let tokenLists = texts.map { tokens(in: $0).map(\.normalized) }
        guard let first = tokenLists.first, !first.isEmpty else { return 0 }

        var count = 0
        while count < first.count {
            let token = first[count]
            guard tokenLists.allSatisfy({ count < $0.count && $0[count] == token }) else {
                break
            }
            count += 1
        }

        return count
    }

    private struct LocalAgreementState {
        private let requiredIterations: Int
        private var hypotheses: [String] = []

        init(policy: TranscriptCommitmentPolicy) {
            if case .localAgreement(let iterations) = policy {
                self.requiredIterations = max(2, iterations)
            } else {
                self.requiredIterations = 2
            }
        }

        mutating func accept(hypothesis: String) -> (confirmedPrefix: String, unconfirmedText: String) {
            let trimmedHypothesis = hypothesis.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedHypothesis.isEmpty else {
                hypotheses.removeAll(keepingCapacity: true)
                return ("", "")
            }

            hypotheses.append(trimmedHypothesis)
            if hypotheses.count > requiredIterations {
                hypotheses.removeFirst(hypotheses.count - requiredIterations)
            }

            guard hypotheses.count >= requiredIterations else {
                return ("", trimmedHypothesis)
            }

            let confirmedTokenCount = SpeechChunkStreamingPipeline.commonPrefixTokenCount(in: hypotheses)
            let split = SpeechChunkStreamingPipeline.splitConfirmedPrefix(
                in: trimmedHypothesis,
                tokenCount: confirmedTokenCount
            )
            hypotheses = split.remainder.isEmpty ? [] : [split.remainder]
            return (split.prefix, split.remainder)
        }

        mutating func reset() {
            hypotheses.removeAll(keepingCapacity: true)
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
