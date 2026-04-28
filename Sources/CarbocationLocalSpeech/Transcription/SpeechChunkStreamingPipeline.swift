import Foundation

@_spi(Internal) public enum SpeechChunkStreamingPipeline {
    public typealias ChunkTranscription = @Sendable (PreparedAudio, TranscriptionOptions) async throws -> Transcript
    @_spi(Internal) public typealias TimedChunkTranscription = @Sendable (SpeechAudioChunk, TranscriptionOptions) async throws -> Transcript

    public static func stream(
        audio: AsyncThrowingStream<AudioChunk, Error>,
        backend: SpeechBackendDescriptor,
        options: StreamingTranscriptionOptions,
        transcribe: @escaping ChunkTranscription
    ) -> AsyncThrowingStream<TranscriptEvent, Error> {
        stream(
            audio: audio,
            backend: backend,
            options: options,
            transcribeTimed: { chunk, options in
                try await transcribe(chunk.audio, options)
            },
            voiceActivityDetector: nil,
            startupDiagnostics: []
        )
    }

    @_spi(Internal) public static func stream(
        audio: AsyncThrowingStream<AudioChunk, Error>,
        backend: SpeechBackendDescriptor,
        options: StreamingTranscriptionOptions,
        transcribeTimed transcribe: @escaping TimedChunkTranscription,
        voiceActivityDetector injectedVoiceActivityDetector: VoiceActivityDetecting? = nil,
        startupDiagnostics: [TranscriptionDiagnostic] = []
    ) -> AsyncThrowingStream<TranscriptEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(.started(backend))
                for diagnostic in startupDiagnostics {
                    continuation.yield(.diagnostic(diagnostic))
                }

                let detector: VoiceActivityDetecting? = options.transcription.voiceActivityDetection.mode == .disabled
                    ? nil
                    : injectedVoiceActivityDetector ?? EnergyVoiceActivityDetector(sensitivity: options.transcription.voiceActivityDetection.sensitivity)
                var committedSegments: [TranscriptSegment] = []
                var agreementState = LocalAgreementState(
                    policy: Self.resolvedCommitmentPolicy(options),
                    allowsFallbackCommit: Self.localAgreementAllowsFallbackCommit(for: options)
                )

                do {
                    switch options.emulation.window {
                    case .vadUtterances(let configuration):
                        var chunker = SpeechChunker(configuration: configuration)
                        for try await chunk in audio {
                            try Task.checkCancellation()

                            continuation.yield(.audioLevel(AudioLevelMeter.measure(samples: chunk.samples, time: chunk.startTime)))
                            let activity = try voiceActivity(for: chunk, detector: detector, continuation: continuation)

                            for emitted in chunker.append(chunk, activity: activity) {
                                try await process(
                                    emitted,
                                    backend: backend,
                                    options: options,
                                    transcribe: transcribe,
                                    committedSegments: &committedSegments,
                                    agreementState: &agreementState,
                                    continuation: continuation
                                )
                                resetVoiceActivityStateIfNeeded(detector, after: emitted)
                            }
                        }

                        for emitted in chunker.finish() {
                            try await process(
                                emitted,
                                backend: backend,
                                options: options,
                                transcribe: transcribe,
                                committedSegments: &committedSegments,
                                agreementState: &agreementState,
                                continuation: continuation
                            )
                            resetVoiceActivityStateIfNeeded(detector, after: emitted)
                        }
                    case .rollingBuffer(let maxDuration, let updateInterval, let overlap):
                        var window = SpeechRollingWindow(
                            maximumBufferDuration: maxDuration,
                            updateInterval: updateInterval,
                            overlapDuration: overlap
                        )
                        for try await chunk in audio {
                            try Task.checkCancellation()

                            continuation.yield(.audioLevel(AudioLevelMeter.measure(samples: chunk.samples, time: chunk.startTime)))
                            try reportVoiceActivityIfNeeded(for: chunk, detector: detector, continuation: continuation)

                            for emitted in window.append(chunk) {
                                try await process(
                                    emitted,
                                    backend: backend,
                                    options: options,
                                    transcribe: transcribe,
                                    committedSegments: &committedSegments,
                                    agreementState: &agreementState,
                                    continuation: continuation
                                )
                                resetVoiceActivityStateIfNeeded(detector, after: emitted)
                            }
                        }

                        for emitted in window.finish() {
                            try await process(
                                emitted,
                                backend: backend,
                                options: options,
                                transcribe: transcribe,
                                committedSegments: &committedSegments,
                                agreementState: &agreementState,
                                continuation: continuation
                            )
                            resetVoiceActivityStateIfNeeded(detector, after: emitted)
                        }
                    case .contextualRollingBuffer(let maxDuration, let updateInterval, let finalSilenceDelay):
                        try await streamContextualRollingBuffer(
                            audio: audio,
                            backend: backend,
                            options: options,
                            transcribe: transcribe,
                            detector: detector,
                            maximumBufferDuration: maxDuration,
                            updateInterval: updateInterval,
                            finalSilenceDelay: finalSilenceDelay,
                            continuation: continuation
                        )
                        return
                    }

                    flushPendingLocalAgreementIfNeeded(
                        backend: backend,
                        options: options,
                        committedSegments: &committedSegments,
                        agreementState: &agreementState,
                        continuation: continuation
                    )
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

    private static func voiceActivity(
        for chunk: AudioChunk,
        detector: VoiceActivityDetecting?,
        continuation: AsyncThrowingStream<TranscriptEvent, Error>.Continuation
    ) throws -> VoiceActivityEvent {
        guard let detector else {
            return VoiceActivityEvent(
                state: .speech,
                startTime: chunk.startTime,
                endTime: chunk.startTime + chunk.duration
            )
        }

        return try reportVoiceActivity(for: chunk, detector: detector, continuation: continuation)
    }

    private static func reportVoiceActivityIfNeeded(
        for chunk: AudioChunk,
        detector: VoiceActivityDetecting?,
        continuation: AsyncThrowingStream<TranscriptEvent, Error>.Continuation
    ) throws {
        guard let detector else { return }
        _ = try reportVoiceActivity(for: chunk, detector: detector, continuation: continuation)
    }

    private static func optionalVoiceActivity(
        for chunk: AudioChunk,
        detector: VoiceActivityDetecting?,
        continuation: AsyncThrowingStream<TranscriptEvent, Error>.Continuation
    ) throws -> VoiceActivityEvent? {
        guard let detector else { return nil }
        return try reportVoiceActivity(for: chunk, detector: detector, continuation: continuation)
    }

    private static func reportVoiceActivity(
        for chunk: AudioChunk,
        detector: VoiceActivityDetecting,
        continuation: AsyncThrowingStream<TranscriptEvent, Error>.Continuation
    ) throws -> VoiceActivityEvent {
        if let analyzer = detector as? VoiceActivityAnalyzing {
            let analysis = try analyzer.analyzeWithDiagnostics(chunk)
            for diagnostic in analysis.diagnostics {
                continuation.yield(.diagnostic(diagnostic))
            }
            continuation.yield(.voiceActivity(analysis.activity))
            return analysis.activity
        }

        let activity = try detector.analyze(chunk)
        continuation.yield(.voiceActivity(activity))
        return activity
    }

    private static func resetVoiceActivityStateIfNeeded(
        _ detector: VoiceActivityDetecting?,
        after emitted: SpeechAudioChunk
    ) {
        guard emitted.isFinal else { return }
        (detector as? VoiceActivityDetectionStateResetting)?.resetVoiceActivityState()
    }

    private static func streamContextualRollingBuffer(
        audio: AsyncThrowingStream<AudioChunk, Error>,
        backend: SpeechBackendDescriptor,
        options: StreamingTranscriptionOptions,
        transcribe: @escaping TimedChunkTranscription,
        detector: VoiceActivityDetecting?,
        maximumBufferDuration: TimeInterval,
        updateInterval: TimeInterval,
        finalSilenceDelay: TimeInterval,
        continuation: AsyncThrowingStream<TranscriptEvent, Error>.Continuation
    ) async throws {
        let queue = CoalescingTranscriptionQueue()

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await produceContextualRollingChunks(
                    audio: audio,
                    queue: queue,
                    detector: detector,
                    usesNoVAD: options.transcription.voiceActivityDetection.mode == .disabled,
                    maximumBufferDuration: maximumBufferDuration,
                    updateInterval: updateInterval,
                    finalSilenceDelay: finalSilenceDelay,
                    continuation: continuation
                )
            }

            group.addTask {
                try await consumeQueuedTranscriptions(
                    queue: queue,
                    backend: backend,
                    options: options,
                    transcribe: transcribe,
                    continuation: continuation
                )
            }

            do {
                while try await group.next() != nil {}
            } catch {
                group.cancelAll()
                await queue.fail(error)
                throw error
            }
        }
    }

    private static func produceContextualRollingChunks(
        audio: AsyncThrowingStream<AudioChunk, Error>,
        queue: CoalescingTranscriptionQueue,
        detector: VoiceActivityDetecting?,
        usesNoVAD: Bool,
        maximumBufferDuration: TimeInterval,
        updateInterval: TimeInterval,
        finalSilenceDelay: TimeInterval,
        continuation: AsyncThrowingStream<TranscriptEvent, Error>.Continuation
    ) async throws {
        var window = SpeechContextualRollingWindow(
            maximumBufferDuration: maximumBufferDuration,
            updateInterval: updateInterval,
            finalSilenceDelay: finalSilenceDelay,
            voiceActivityMode: .leadingSilence
        )
        var frontierLowEnergyDuration: TimeInterval = 0

        do {
            for try await chunk in audio {
                try Task.checkCancellation()

                let level = AudioLevelMeter.measure(samples: chunk.samples, time: chunk.startTime)
                continuation.yield(.audioLevel(level))
                if usesNoVAD, isLowEnergyFrontier(level) {
                    frontierLowEnergyDuration += chunk.duration
                } else {
                    frontierLowEnergyDuration = 0
                }
                let activity = try optionalVoiceActivity(for: chunk, detector: detector, continuation: continuation)
                let result = window.append(chunk, activity: activity)
                if let audioGap = result.audioGap {
                    continuation.yield(.diagnostic(TranscriptionDiagnostic(
                        source: "streaming.pipeline",
                        message: "audio_gap=\(audioGap.formattedStreamingDebug)s",
                        time: chunk.startTime
                    )))
                }
                emitContextualWindowDiagnostics(result, continuation: continuation)
                for emitted in result.chunks {
                    let queued = chunkWithFrontierIdle(
                        emitted,
                        usesNoVAD: usesNoVAD,
                        duration: frontierLowEnergyDuration
                    )
                    await queue.enqueue(queued)
                    resetVoiceActivityStateIfNeeded(detector, after: queued)
                }
                if let silenceFlushTime = result.silenceFlushTime {
                    continuation.yield(.diagnostic(TranscriptionDiagnostic(
                        source: "streaming.pipeline",
                        message: "contextual_silence_flush=\(silenceFlushTime.formattedStreamingDebug)s",
                        time: silenceFlushTime
                    )))
                    await queue.enqueueFlushPending(time: silenceFlushTime)
                }
            }

            for emitted in window.finish() {
                let queued = chunkWithFrontierIdle(
                    emitted,
                    usesNoVAD: usesNoVAD,
                    duration: frontierLowEnergyDuration
                )
                await queue.enqueue(queued)
                resetVoiceActivityStateIfNeeded(detector, after: queued)
            }
            await queue.finish()
        } catch {
            await queue.fail(error)
            throw error
        }
    }

    private static func consumeQueuedTranscriptions(
        queue: CoalescingTranscriptionQueue,
        backend: SpeechBackendDescriptor,
        options: StreamingTranscriptionOptions,
        transcribe: @escaping TimedChunkTranscription,
        continuation: AsyncThrowingStream<TranscriptEvent, Error>.Continuation
    ) async throws {
        var committedSegments: [TranscriptSegment] = []
        var agreementState = LocalAgreementState(
            policy: resolvedCommitmentPolicy(options),
            allowsFallbackCommit: localAgreementAllowsFallbackCommit(for: options)
        )

        while let work = try await queue.next() {
            try Task.checkCancellation()
            switch work {
            case .transcribe(let emitted):
                try await process(
                    emitted,
                    backend: backend,
                    options: options,
                    transcribe: transcribe,
                    committedSegments: &committedSegments,
                    agreementState: &agreementState,
                    continuation: continuation
                )
            case .flushPending:
                flushPendingLocalAgreementIfNeeded(
                    backend: backend,
                    options: options,
                    committedSegments: &committedSegments,
                    agreementState: &agreementState,
                    continuation: continuation
                )
            }
        }

        flushPendingLocalAgreementIfNeeded(
            backend: backend,
            options: options,
            committedSegments: &committedSegments,
            agreementState: &agreementState,
            continuation: continuation
        )
        continuation.yield(.completed(Transcript(
            segments: committedSegments,
            backend: backend
        )))
        continuation.finish()
    }

    private static func emitContextualWindowDiagnostics(
        _ result: SpeechContextualRollingWindow.AppendResult,
        continuation: AsyncThrowingStream<TranscriptEvent, Error>.Continuation
    ) {
        if let speechStartTime = result.speechStartTime {
            continuation.yield(.diagnostic(TranscriptionDiagnostic(
                source: "streaming.pipeline",
                message: "speech_start=\(speechStartTime.formattedStreamingDebug)s",
                time: speechStartTime
            )))
        }

        if let leadingSilenceTrimmed = result.leadingSilenceTrimmed {
            continuation.yield(.diagnostic(TranscriptionDiagnostic(
                source: "streaming.pipeline",
                message: "leading_silence_trimmed=\(leadingSilenceTrimmed.formattedStreamingDebug)s"
            )))
        }

        if let turnFinalTime = result.turnFinalTime {
            continuation.yield(.diagnostic(TranscriptionDiagnostic(
                source: "streaming.pipeline",
                message: "turn_final=\(turnFinalTime.formattedStreamingDebug)s",
                time: turnFinalTime
            )))
        }
    }

    private static func process(
        _ emitted: SpeechAudioChunk,
        backend: SpeechBackendDescriptor,
        options: StreamingTranscriptionOptions,
        transcribe: TimedChunkTranscription,
        committedSegments: inout [TranscriptSegment],
        agreementState: inout LocalAgreementState,
        continuation: AsyncThrowingStream<TranscriptEvent, Error>.Continuation
    ) async throws {
        try Task.checkCancellation()

        let startedAt = Date()
        let transcriptionOptions = stableContextTranscriptionOptions(
            from: options.transcription,
            streamingOptions: options,
            committedSegments: committedSegments
        )
        let transcript = try await transcribe(emitted, transcriptionOptions)
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

        if let staleReplay = staleReplayRejection(
            rawHypothesisText: segments.map(\.text).joined(separator: " "),
            emitted: emitted,
            options: options,
            committedSegments: committedSegments
        ) {
            continuation.yield(.diagnostic(TranscriptionDiagnostic(
                source: "streaming.pipeline",
                message: staleReplay,
                time: emitted.startTime
            )))
            return
        }

        let candidateSegments = candidateSegments(
            from: segments,
            options: options,
            committedSegments: committedSegments
        )

        guard !candidateSegments.isEmpty else {
            return
        }

        if rejectsPathologicalRepetition(for: options),
           containsPathologicalRepetition(candidateSegments.map(\.text).joined(separator: " ")) {
            continuation.yield(.diagnostic(TranscriptionDiagnostic(
                source: "streaming.pipeline",
                message: "hypothesis_rejected=repetition",
                time: emitted.startTime
            )))
            return
        }

        switch resolvedCommitmentPolicy(options) {
        case .immediate:
            commit(candidateSegments, backend: backend, committedSegments: &committedSegments, continuation: continuation)
            agreementState.reset()
        case .providerFinals, .silence:
            if emitted.isFinal {
                commit(candidateSegments, backend: backend, committedSegments: &committedSegments, continuation: continuation)
                agreementState.reset()
            } else {
                publishPartial(
                    candidateSegments,
                    backend: backend,
                    committedSegments: committedSegments,
                    continuation: continuation
                )
            }
        case .localAgreement:
            if emitted.isFinal {
                let didCommitFinal = commitFinalLocalAgreement(
                    candidateSegments,
                    backend: backend,
                    options: options,
                    committedSegments: &committedSegments,
                    agreementState: &agreementState,
                    allowsUnconfirmedFinalCommit: localAgreementAllowsUnconfirmedFinalCommit(for: options),
                    continuation: continuation
                )
                if didCommitFinal || localAgreementAllowsUnconfirmedFinalCommit(for: options) {
                    agreementState.reset()
                }
            } else {
                processLocalAgreement(
                    candidateSegments,
                    backend: backend,
                    options: options,
                    committedSegments: &committedSegments,
                    agreementState: &agreementState,
                    continuation: continuation
                )
            }
        case .automatic:
            if emitted.isFinal {
                commit(candidateSegments, backend: backend, committedSegments: &committedSegments, continuation: continuation)
                agreementState.reset()
            } else {
                publishPartial(
                    candidateSegments,
                    backend: backend,
                    committedSegments: committedSegments,
                    continuation: continuation
                )
            }
        }
    }

    private static func candidateSegments(
        from segments: [TranscriptSegment],
        options: StreamingTranscriptionOptions,
        committedSegments: [TranscriptSegment]
    ) -> [TranscriptSegment] {
        switch options.emulation.window {
        case .contextualRollingBuffer:
            return contextualCandidateSegments(
                from: segments,
                committedSegments: committedSegments
            )
        case .rollingBuffer, .vadUtterances:
            let overlapDuration = options.emulation.overlapDeduplication
                ? options.emulation.window.overlapDuration
                : 0
            return segments.compactMap { segment in
                removeCommittedOverlap(
                    from: segment,
                    committedSegments: committedSegments,
                    overlapDuration: overlapDuration
                )
            }
        }
    }

    private static func contextualCandidateSegments(
        from segments: [TranscriptSegment],
        committedSegments: [TranscriptSegment]
    ) -> [TranscriptSegment] {
        guard let firstSegment = segments.first,
              let lastSegment = segments.last else {
            return []
        }

        let hypothesis = segments.map(\.text).joined(separator: " ")
        let trimResult = removeCommittedContextPrefix(
            in: hypothesis,
            after: committedSegments
        )
        let candidateText = trimResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidateText.isEmpty else { return [] }

        let startTime = estimateStartTime(
            afterRemovingPrefixTokenCount: trimResult.removedTokenCount,
            from: hypothesis,
            firstSegment: firstSegment,
            lastSegment: lastSegment
        )

        return [TranscriptSegment(
            text: candidateText,
            startTime: startTime,
            endTime: max(startTime, lastSegment.endTime)
        )]
    }

    private static func commitFinalLocalAgreement(
        _ segments: [TranscriptSegment],
        backend: SpeechBackendDescriptor,
        options: StreamingTranscriptionOptions,
        committedSegments: inout [TranscriptSegment],
        agreementState: inout LocalAgreementState,
        allowsUnconfirmedFinalCommit: Bool,
        continuation: AsyncThrowingStream<TranscriptEvent, Error>.Continuation
    ) -> Bool {
        let finalHypothesis = removeCommittedPrefixForWindow(
            in: segments.map(\.text).joined(separator: " "),
            after: committedSegments,
            options: options
        )
        let mergedFinalText = allowsUnconfirmedFinalCommit
            ? agreementState.flush(currentHypothesis: finalHypothesis)
            : agreementState.flushConfirmed(
                currentHypothesis: finalHypothesis,
                clearWhenEmpty: false
            )
        let finalText = removeCommittedPrefixForWindow(
            in: mergedFinalText,
            after: committedSegments,
            options: options
        )

        guard !finalText.isEmpty,
              let firstSegment = segments.first,
              let lastSegment = segments.last else {
            continuation.yield(.snapshot(StreamingTranscriptSnapshot(
                stable: Transcript(segments: committedSegments, backend: backend)
            )))
            return false
        }

        commit(
            [TranscriptSegment(
                text: finalText,
                startTime: firstSegment.startTime,
                endTime: max(firstSegment.startTime, lastSegment.endTime)
            )],
            backend: backend,
            committedSegments: &committedSegments,
            continuation: continuation
        )
        return true
    }

    private static func commit(
        _ segments: [TranscriptSegment],
        backend: SpeechBackendDescriptor,
        committedSegments: inout [TranscriptSegment],
        continuation: AsyncThrowingStream<TranscriptEvent, Error>.Continuation
    ) {
        for segment in segments {
            committedSegments.append(segment)
        }
        continuation.yield(.snapshot(StreamingTranscriptSnapshot(
            stable: Transcript(segments: committedSegments, backend: backend)
        )))
    }

    private static func flushPendingLocalAgreementIfNeeded(
        backend: SpeechBackendDescriptor,
        options: StreamingTranscriptionOptions,
        committedSegments: inout [TranscriptSegment],
        agreementState: inout LocalAgreementState,
        continuation: AsyncThrowingStream<TranscriptEvent, Error>.Continuation
    ) {
        guard case .localAgreement = resolvedCommitmentPolicy(options) else {
            return
        }
        let finalText = removeCommittedPrefixForWindow(
            in: agreementState.flushPending(),
            after: committedSegments,
            options: options
        )
        guard !finalText.isEmpty else { return }

        let startTime = committedSegments.last?.endTime ?? 0
        commit(
            [TranscriptSegment(
                text: finalText,
                startTime: startTime,
                endTime: startTime
            )],
            backend: backend,
            committedSegments: &committedSegments,
            continuation: continuation
        )
    }

    private static func processLocalAgreement(
        _ segments: [TranscriptSegment],
        backend: SpeechBackendDescriptor,
        options: StreamingTranscriptionOptions,
        committedSegments: inout [TranscriptSegment],
        agreementState: inout LocalAgreementState,
        continuation: AsyncThrowingStream<TranscriptEvent, Error>.Continuation
    ) {
        let hypothesis = removeCommittedPrefixForWindow(
            in: segments.map(\.text).joined(separator: " "),
            after: committedSegments,
            options: options
        )
        let agreement = agreementState.accept(hypothesis: hypothesis)

        if !agreement.confirmedPrefix.isEmpty,
           let firstSegment = segments.first,
           let lastSegment = segments.last {
            let confirmedPrefix = removeCommittedPrefixForWindow(
                in: agreement.confirmedPrefix,
                after: committedSegments,
                options: options
            )
            if !confirmedPrefix.isEmpty {
                let segment = TranscriptSegment(
                    text: confirmedPrefix,
                    startTime: firstSegment.startTime,
                    endTime: max(firstSegment.startTime, lastSegment.endTime)
                )
                committedSegments.append(segment)
            }
        }

        guard !agreement.unconfirmedText.isEmpty,
              let firstSegment = segments.first,
              let lastSegment = segments.last
        else {
            continuation.yield(.snapshot(StreamingTranscriptSnapshot(
                stable: Transcript(segments: committedSegments, backend: backend)
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
            continuation: continuation
        )
    }

    private static func publishPartial(
        _ segments: [TranscriptSegment],
        backend: SpeechBackendDescriptor,
        committedSegments: [TranscriptSegment],
        continuation: AsyncThrowingStream<TranscriptEvent, Error>.Continuation
    ) {
        guard let firstSegment = segments.first,
              let lastSegment = segments.last else {
            return
        }

        let volatile = Transcript(
            segments: [TranscriptSegment(
                text: segments.map(\.text).joined(separator: " "),
                startTime: firstSegment.startTime,
                endTime: lastSegment.endTime
            )],
            backend: backend
        )
        continuation.yield(.snapshot(StreamingTranscriptSnapshot(
            stable: Transcript(segments: committedSegments, backend: backend),
            volatile: volatile,
            volatileRange: TranscriptTimeRange(startTime: firstSegment.startTime, endTime: lastSegment.endTime)
        )))
    }

    private static func removeCommittedPrefixForWindow(
        in text: String,
        after committedSegments: [TranscriptSegment],
        options: StreamingTranscriptionOptions
    ) -> String {
        switch options.emulation.window {
        case .contextualRollingBuffer:
            return removeCommittedContextPrefix(
                in: text,
                after: committedSegments
            ).text
        case .rollingBuffer, .vadUtterances:
            return removeCommittedTextPrefix(
                in: text,
                after: committedSegments
            )
        }
    }

    private static func removeCommittedTextPrefix(
        in text: String,
        after committedSegments: [TranscriptSegment]
    ) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }

        let committedText = committedOverlapText(from: committedSegments)
        let trimResult = trimDuplicatePrefix(in: text, after: committedText)
        guard trimResult.removedTokenCount > 0 else {
            return text
        }

        return trimResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func resolvedCommitmentPolicy(_ options: StreamingTranscriptionOptions) -> TranscriptCommitmentPolicy {
        switch options.commitment {
        case .automatic:
            switch options.emulation.window {
            case .rollingBuffer, .contextualRollingBuffer:
                return .localAgreement(iterations: 2)
            case .vadUtterances:
                return .providerFinals
            }
        case .providerFinals, .localAgreement, .silence, .immediate:
            return options.commitment
        }
    }

    private static func stableContextTranscriptionOptions(
        from transcriptionOptions: TranscriptionOptions,
        streamingOptions: StreamingTranscriptionOptions,
        committedSegments: [TranscriptSegment]
    ) -> TranscriptionOptions {
        guard usesStablePromptContext(for: streamingOptions),
              let stableContext = stablePromptContext(from: committedSegments) else {
            return transcriptionOptions
        }

        var updated = transcriptionOptions
        if let initialPrompt = transcriptionOptions.initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !initialPrompt.isEmpty {
            updated.initialPrompt = "\(initialPrompt)\n\(stableContext)"
        } else {
            updated.initialPrompt = stableContext
        }
        return updated
    }

    private static func usesStablePromptContext(for options: StreamingTranscriptionOptions) -> Bool {
        switch options.emulation.window {
        case .rollingBuffer, .contextualRollingBuffer:
            return true
        case .vadUtterances:
            return false
        }
    }

    private static func stablePromptContext(from committedSegments: [TranscriptSegment]) -> String? {
        let committedText = committedSegments
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !committedText.isEmpty else { return nil }

        let maximumTokenCount = 96
        let textTokens = tokens(in: committedText)
        guard textTokens.count > maximumTokenCount else {
            return "Previous stable transcript:\n\(committedText)"
        }

        let suffixStart = textTokens[textTokens.count - maximumTokenCount].range.lowerBound
        let suffix = String(committedText[suffixStart...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !suffix.isEmpty else { return nil }
        return "Previous stable transcript:\n\(suffix)"
    }

    private static func localAgreementAllowsFallbackCommit(for options: StreamingTranscriptionOptions) -> Bool {
        switch options.emulation.window {
        case .contextualRollingBuffer:
            return false
        case .rollingBuffer, .vadUtterances:
            return true
        }
    }

    private static func localAgreementAllowsUnconfirmedFinalCommit(for options: StreamingTranscriptionOptions) -> Bool {
        switch options.emulation.window {
        case .contextualRollingBuffer:
            return false
        case .rollingBuffer, .vadUtterances:
            return true
        }
    }

    private static func rejectsPathologicalRepetition(for options: StreamingTranscriptionOptions) -> Bool {
        switch options.emulation.window {
        case .contextualRollingBuffer:
            return true
        case .rollingBuffer, .vadUtterances:
            return false
        }
    }

    private static let noVADStaleReplayMinimumFrontierIdleDuration: TimeInterval = 1.0
    private static let noVADStaleReplayRMSFloor: Float = 0.002
    private static let noVADStaleReplayPeakFloor: Float = 0.008
    private static let staleReplayMinimumCandidateTokenCount = 6
    private static let staleReplayMinimumMatchedTokenCount = 6
    private static let staleReplayMinimumOverlapRatio = 0.70
    private static let staleReplayMaximumTrailingUnmatchedTokenCount = 2

    private static func isLowEnergyFrontier(_ level: AudioLevel) -> Bool {
        level.rms <= noVADStaleReplayRMSFloor && level.peak <= noVADStaleReplayPeakFloor
    }

    private static func chunkWithFrontierIdle(
        _ chunk: SpeechAudioChunk,
        usesNoVAD: Bool,
        duration: TimeInterval
    ) -> SpeechAudioChunk {
        guard usesNoVAD else { return chunk }
        var updated = chunk
        updated.frontierLowEnergyDuration = duration
        return updated
    }

    private static func staleReplayRejection(
        rawHypothesisText: String,
        emitted: SpeechAudioChunk,
        options: StreamingTranscriptionOptions,
        committedSegments: [TranscriptSegment]
    ) -> String? {
        guard options.transcription.voiceActivityDetection.mode == .disabled,
              case .contextualRollingBuffer = options.emulation.window,
              !emitted.isFinal,
              !usesImmediateCommitment(options),
              emitted.frontierLowEnergyDuration >= noVADStaleReplayMinimumFrontierIdleDuration,
              let analysis = staleReplayAnalysis(
                  candidateText: rawHypothesisText,
                  committedSegments: committedSegments
              )
        else {
            return nil
        }

        return [
            "hypothesis_rejected=stale_replay",
            "overlap=\(analysis.overlapRatio.formattedStreamingDebug)",
            "matched=\(analysis.matchedTokenCount)/\(analysis.candidateTokenCount)",
            "frontier_idle=\(emitted.frontierLowEnergyDuration.formattedStreamingDebug)s",
            "trailing_unmatched=\(analysis.trailingUnmatchedTokenCount)"
        ].joined(separator: " ")
    }

    private static func usesImmediateCommitment(_ options: StreamingTranscriptionOptions) -> Bool {
        if case .immediate = resolvedCommitmentPolicy(options) {
            return true
        }
        return false
    }

    private static func staleReplayAnalysis(
        candidateText: String,
        committedSegments: [TranscriptSegment]
    ) -> StaleReplayAnalysis? {
        let candidateTokens = tokens(in: candidateText).map(\.normalized)
        guard candidateTokens.count >= staleReplayMinimumCandidateTokenCount else {
            return nil
        }

        let committedText = committedSegments
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let committedTokens = Array(tokens(in: committedText).suffix(200)).map(\.normalized)
        guard committedTokens.count >= staleReplayMinimumMatchedTokenCount else {
            return nil
        }

        let matchedCandidateIndices = longestCommonSubsequenceCandidateIndices(
            candidateTokens: candidateTokens,
            committedTokens: committedTokens
        )
        guard let lastMatchedCandidateIndex = matchedCandidateIndices.last else {
            return nil
        }

        let matchedTokenCount = matchedCandidateIndices.count
        let overlapRatio = Double(matchedTokenCount) / Double(candidateTokens.count)
        let trailingUnmatchedTokenCount = candidateTokens.count - lastMatchedCandidateIndex - 1
        guard matchedTokenCount >= staleReplayMinimumMatchedTokenCount,
              overlapRatio >= staleReplayMinimumOverlapRatio,
              trailingUnmatchedTokenCount <= staleReplayMaximumTrailingUnmatchedTokenCount else {
            return nil
        }

        return StaleReplayAnalysis(
            overlapRatio: overlapRatio,
            matchedTokenCount: matchedTokenCount,
            candidateTokenCount: candidateTokens.count,
            trailingUnmatchedTokenCount: trailingUnmatchedTokenCount
        )
    }

    private static func longestCommonSubsequenceCandidateIndices(
        candidateTokens: [String],
        committedTokens: [String]
    ) -> [Int] {
        guard !candidateTokens.isEmpty, !committedTokens.isEmpty else {
            return []
        }

        var lengths = Array(
            repeating: Array(repeating: 0, count: candidateTokens.count + 1),
            count: committedTokens.count + 1
        )

        for committedIndex in 0..<committedTokens.count {
            for candidateIndex in 0..<candidateTokens.count {
                if tokensAreEquivalent(committedTokens[committedIndex], candidateTokens[candidateIndex]) {
                    lengths[committedIndex + 1][candidateIndex + 1] = lengths[committedIndex][candidateIndex] + 1
                } else {
                    lengths[committedIndex + 1][candidateIndex + 1] = max(
                        lengths[committedIndex][candidateIndex + 1],
                        lengths[committedIndex + 1][candidateIndex]
                    )
                }
            }
        }

        var committedIndex = committedTokens.count
        var candidateIndex = candidateTokens.count
        var matchedCandidateIndices: [Int] = []

        while committedIndex > 0, candidateIndex > 0 {
            let currentCommitted = committedTokens[committedIndex - 1]
            let currentCandidate = candidateTokens[candidateIndex - 1]
            if tokensAreEquivalent(currentCommitted, currentCandidate),
               lengths[committedIndex][candidateIndex] == lengths[committedIndex - 1][candidateIndex - 1] + 1 {
                matchedCandidateIndices.append(candidateIndex - 1)
                committedIndex -= 1
                candidateIndex -= 1
            } else if lengths[committedIndex - 1][candidateIndex] >= lengths[committedIndex][candidateIndex - 1] {
                committedIndex -= 1
            } else {
                candidateIndex -= 1
            }
        }

        return matchedCandidateIndices.reversed()
    }

    private static func splitConfirmedPrefix(
        in text: String,
        tokenCount: Int
    ) -> (prefix: String, remainder: String) {
        let tokens = tokens(in: text)
        guard tokenCount > 0, tokenCount <= tokens.count else {
            return ("", text.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let prefixEnd = endIndexIncludingTrailingPunctuation(
            after: tokens[tokenCount - 1].range.upperBound,
            in: text
        )
        let prefix = String(text[..<prefixEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
        let remainder = trimLeadingOverlapSeparators(String(text[prefixEnd...]))
        return (prefix, remainder)
    }

    private static func endIndexIncludingTrailingPunctuation(
        after index: String.Index,
        in text: String
    ) -> String.Index {
        var endIndex = index
        while endIndex < text.endIndex {
            let character = text[endIndex]
            guard character.unicodeScalars.allSatisfy({ CharacterSet.punctuationCharacters.contains($0) }) else {
                break
            }
            endIndex = text.index(after: endIndex)
        }
        return endIndex
    }

    private static func commonPrefixTokenCount(in texts: [String]) -> Int {
        let tokenLists = texts.map { tokens(in: $0).map(\.normalized) }
        guard let first = tokenLists.first, !first.isEmpty else { return 0 }

        var count = 0
        while count < first.count {
            let token = first[count]
            guard tokenLists.allSatisfy({ count < $0.count && tokensAreEquivalent($0[count], token) }) else {
                break
            }
            count += 1
        }

        return count
    }

    private static func containsPathologicalRepetition(_ text: String) -> Bool {
        let normalizedTokens = tokens(in: text).map(\.normalized)
        guard normalizedTokens.count >= 12 else { return false }

        let maximumPhraseLength = min(12, normalizedTokens.count / 3)
        guard maximumPhraseLength >= 4 else { return false }

        for phraseLength in stride(from: maximumPhraseLength, through: 4, by: -1) {
            var index = 0
            while index + phraseLength * 3 <= normalizedTokens.count {
                let phrase = Array(normalizedTokens[index..<(index + phraseLength)])
                var repetitionCount = 1
                var nextIndex = index + phraseLength

                while nextIndex + phraseLength <= normalizedTokens.count {
                    let nextPhrase = Array(normalizedTokens[nextIndex..<(nextIndex + phraseLength)])
                    guard tokenSequencesMatch(phrase, nextPhrase) else {
                        break
                    }
                    repetitionCount += 1
                    nextIndex += phraseLength
                }

                if repetitionCount >= 3 {
                    return true
                }
                index += 1
            }
        }

        return false
    }

    private struct LocalAgreementState {
        private let requiredIterations: Int
        private let allowsFallbackCommit: Bool
        private var hypotheses: [String] = []

        init(policy: TranscriptCommitmentPolicy, allowsFallbackCommit: Bool) {
            if case .localAgreement(let iterations) = policy {
                self.requiredIterations = max(2, iterations)
            } else {
                self.requiredIterations = 2
            }
            self.allowsFallbackCommit = allowsFallbackCommit
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
            if allowsFallbackCommit,
               confirmedTokenCount == 0,
               let previousHypothesis = hypotheses.dropLast().last {
                let expired = SpeechChunkStreamingPipeline.expiredPrefixBeforeWindowShift(
                    previous: previousHypothesis,
                    current: trimmedHypothesis
                )
                if !expired.prefix.isEmpty {
                    hypotheses = [trimmedHypothesis]
                    return (expired.prefix, trimmedHypothesis)
                }

                let previous = previousHypothesis.trimmingCharacters(in: .whitespacesAndNewlines)
                if !previous.isEmpty {
                    hypotheses = [trimmedHypothesis]
                    return (previous, trimmedHypothesis)
                }
            }

            let split = SpeechChunkStreamingPipeline.splitConfirmedPrefix(
                in: trimmedHypothesis,
                tokenCount: confirmedTokenCount
            )
            hypotheses = split.remainder.isEmpty ? [] : [split.remainder]
            return (split.prefix, split.remainder)
        }

        mutating func flush(currentHypothesis: String) -> String {
            let pendingHypothesis = hypotheses.last ?? ""
            hypotheses.removeAll(keepingCapacity: true)
            return SpeechChunkStreamingPipeline.mergeOverlappingText(
                pendingHypothesis,
                currentHypothesis
            )
        }

        mutating func flushConfirmed(
            currentHypothesis: String,
            clearWhenEmpty: Bool = true
        ) -> String {
            let trimmedHypotheses = (hypotheses + [currentHypothesis])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            guard trimmedHypotheses.count >= 2 else {
                if clearWhenEmpty {
                    hypotheses.removeAll(keepingCapacity: true)
                }
                return ""
            }

            let confirmedTokenCount = SpeechChunkStreamingPipeline.commonPrefixTokenCount(
                in: trimmedHypotheses
            )
            let split = SpeechChunkStreamingPipeline.splitConfirmedPrefix(
                in: trimmedHypotheses.last ?? "",
                tokenCount: confirmedTokenCount
            )
            if split.prefix.isEmpty {
                if clearWhenEmpty {
                    hypotheses.removeAll(keepingCapacity: true)
                }
                return ""
            }

            hypotheses.removeAll(keepingCapacity: true)
            return split.prefix
        }

        mutating func flushPending() -> String {
            let pendingHypothesis = hypotheses.last ?? ""
            hypotheses.removeAll(keepingCapacity: true)
            return pendingHypothesis
        }

        mutating func reset() {
            hypotheses.removeAll(keepingCapacity: true)
        }
    }

    private static func expiredPrefixBeforeWindowShift(
        previous: String,
        current: String
    ) -> (prefix: String, remainder: String) {
        let previousTokens = tokens(in: previous)
        let currentTokens = tokens(in: current)
        let previousNormalized = previousTokens.map(\.normalized)
        let currentNormalized = currentTokens.map(\.normalized)
        let overlapTokenCount = suffixPrefixOverlapTokenCount(
            previousTokens: previousNormalized,
            currentTokens: currentNormalized
        )

        if overlapTokenCount > 0, overlapTokenCount < previousTokens.count {
            let expiredTokenCount = previousTokens.count - overlapTokenCount
            let split = splitConfirmedPrefix(in: previous, tokenCount: expiredTokenCount)
            return (split.prefix, current.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        if let overlapStart = internalPrefixOverlapStart(
            previousTokens: previousNormalized,
            currentTokens: currentNormalized
        ) {
            let split = splitConfirmedPrefix(in: previous, tokenCount: overlapStart)
            return (split.prefix, current.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return ("", current.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func mergeOverlappingText(_ first: String, _ second: String) -> String {
        let first = first.trimmingCharacters(in: .whitespacesAndNewlines)
        let second = second.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !first.isEmpty else { return second }
        guard !second.isEmpty else { return first }

        let firstTokens = tokens(in: first)
        let secondTokens = tokens(in: second)
        let firstNormalized = firstTokens.map(\.normalized)
        let secondNormalized = secondTokens.map(\.normalized)

        if isPrefix(firstNormalized, of: secondNormalized) {
            return second
        }

        if isPrefix(secondNormalized, of: firstNormalized) {
            return first
        }

        let overlapTokenCount = suffixPrefixOverlapTokenCount(
            previousTokens: firstNormalized,
            currentTokens: secondNormalized
        )

        guard overlapTokenCount > 0 else {
            return "\(first) \(second)"
        }

        let secondRemainder = dropPrefixTokens(overlapTokenCount, from: second)
        guard !secondRemainder.isEmpty else { return first }
        return "\(first) \(secondRemainder)"
    }

    private static func isPrefix(_ prefix: [String], of tokens: [String]) -> Bool {
        guard !prefix.isEmpty, prefix.count <= tokens.count else { return false }
        return tokenSequencesMatch(Array(tokens.prefix(prefix.count)), prefix)
    }

    private static func suffixPrefixOverlapTokenCount(
        previousTokens: [String],
        currentTokens: [String]
    ) -> Int {
        let maximumOverlap = min(previousTokens.count, currentTokens.count)
        guard maximumOverlap > 0 else { return 0 }

        for count in stride(from: maximumOverlap, through: 1, by: -1) {
            if tokenSequencesMatch(Array(previousTokens.suffix(count)), Array(currentTokens.prefix(count))) {
                return count
            }
        }

        return 0
    }

    private static func internalPrefixOverlapStart(
        previousTokens: [String],
        currentTokens: [String]
    ) -> Int? {
        let minimumOverlap = 2
        let maximumOverlap = min(previousTokens.count, currentTokens.count, 12)
        guard maximumOverlap >= minimumOverlap, previousTokens.count > minimumOverlap else {
            return nil
        }

        for count in stride(from: maximumOverlap, through: minimumOverlap, by: -1) {
            let currentPrefix = Array(currentTokens.prefix(count))
            guard currentPrefix.count == count else { continue }

            let lastStart = previousTokens.count - count
            guard lastStart >= 1 else { continue }
            for start in 1...lastStart {
                let previousSlice = Array(previousTokens[start..<(start + count)])
                if tokenSequencesMatch(previousSlice, currentPrefix) {
                    return start
                }
            }
        }

        return nil
    }

    private static func dropPrefixTokens(_ count: Int, from text: String) -> String {
        let textTokens = tokens(in: text)
        guard count > 0, count <= textTokens.count else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let startIndex = textTokens[count - 1].range.upperBound
        return trimLeadingOverlapSeparators(String(text[startIndex...]))
    }

    private static func removeCommittedContextPrefix(
        in text: String,
        after committedSegments: [TranscriptSegment]
    ) -> (text: String, removedTokenCount: Int) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return ("", 0) }

        let committedText = committedSegments
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let candidateTokens = tokens(in: text)
        let committedTokens = tokens(in: committedText)
        guard !candidateTokens.isEmpty, !committedTokens.isEmpty else {
            return (text, 0)
        }

        let candidateNormalizedTokens = candidateTokens.map(\.normalized)
        let committedNormalizedTokens = Array(committedTokens.suffix(160)).map(\.normalized)
        let removableTokenCount = max(
            removableContextPrefixTokenCount(
                candidateTokens: candidateNormalizedTokens,
                committedTokens: committedNormalizedTokens
            ),
            removableContextReplayTokenCount(
                candidateTokens: candidateNormalizedTokens,
                committedTokens: committedNormalizedTokens
            )
        )
        guard removableTokenCount > 0 else {
            return (text, 0)
        }

        let trimmedText = dropPrefixTokens(removableTokenCount, from: text)
        return (trimmedText, removableTokenCount)
    }

    private static func removableContextPrefixTokenCount(
        candidateTokens: [String],
        committedTokens: [String]
    ) -> Int {
        guard let firstCandidateToken = candidateTokens.first,
              !committedTokens.isEmpty else {
            return 0
        }

        let maximumCandidateTokenCount = min(candidateTokens.count, 80)
        var bestMatchCount = 0

        for startIndex in committedTokens.indices {
            guard tokensAreEquivalent(committedTokens[startIndex], firstCandidateToken) else {
                continue
            }

            let matchCount = contiguousMatchTokenCount(
                candidateTokens: candidateTokens,
                candidateStartIndex: 0,
                committedTokens: committedTokens,
                committedStartIndex: startIndex,
                maximumCandidateTokenCount: maximumCandidateTokenCount
            )
            bestMatchCount = max(bestMatchCount, matchCount)
        }

        if bestMatchCount >= 2 {
            return bestMatchCount
        }

        let overlapCount = suffixPrefixOverlapTokenCount(
            previousTokens: committedTokens,
            currentTokens: candidateTokens
        )
        return overlapCount
    }

    private static func removableContextReplayTokenCount(
        candidateTokens: [String],
        committedTokens: [String]
    ) -> Int {
        guard candidateTokens.count >= 6, committedTokens.count >= 6 else {
            return 0
        }

        let maximumCandidateStartIndex = min(8, candidateTokens.count - 1)
        let maximumCandidateTokenCount = min(candidateTokens.count, 96)
        var bestRemovalTokenCount = 0

        for candidateStartIndex in 1...maximumCandidateStartIndex {
            for committedStartIndex in committedTokens.indices {
                guard tokensAreEquivalent(candidateTokens[candidateStartIndex], committedTokens[committedStartIndex]) else {
                    continue
                }

                let matchCount = contiguousMatchTokenCount(
                    candidateTokens: candidateTokens,
                    candidateStartIndex: candidateStartIndex,
                    committedTokens: committedTokens,
                    committedStartIndex: committedStartIndex,
                    maximumCandidateTokenCount: maximumCandidateTokenCount
                )
                let committedTrailingTokenCount = committedTokens.count - (committedStartIndex + matchCount)
                guard matchCount >= 6,
                      committedTrailingTokenCount <= 2 else {
                    continue
                }

                bestRemovalTokenCount = max(
                    bestRemovalTokenCount,
                    candidateStartIndex + matchCount
                )
            }
        }

        return bestRemovalTokenCount
    }

    private static func contiguousMatchTokenCount(
        candidateTokens: [String],
        candidateStartIndex: Int,
        committedTokens: [String],
        committedStartIndex: Int,
        maximumCandidateTokenCount: Int
    ) -> Int {
        var committedIndex = committedStartIndex
        var candidateIndex = candidateStartIndex
        var skippedCommittedTokenCount = 0
        var matchedTokenCount = 0

        while candidateIndex < maximumCandidateTokenCount,
              candidateIndex < candidateTokens.count,
              committedIndex < committedTokens.count {
            if tokensAreEquivalent(committedTokens[committedIndex], candidateTokens[candidateIndex]) {
                matchedTokenCount += 1
                candidateIndex += 1
                committedIndex += 1
                continue
            }

            skippedCommittedTokenCount += 1
            if skippedCommittedTokenCount > 12 {
                break
            }
            committedIndex += 1
        }

        return matchedTokenCount
    }

    private static func estimateStartTime(
        afterRemovingPrefixTokenCount removedTokenCount: Int,
        from text: String,
        firstSegment: TranscriptSegment,
        lastSegment: TranscriptSegment
    ) -> TimeInterval {
        guard removedTokenCount > 0 else {
            return firstSegment.startTime
        }

        let totalTokenCount = tokens(in: text).count
        guard totalTokenCount > 0 else {
            return firstSegment.startTime
        }

        let duration = max(0, lastSegment.endTime - firstSegment.startTime)
        let ratio = min(1, Double(removedTokenCount) / Double(totalTokenCount))
        return min(lastSegment.endTime, firstSegment.startTime + duration * ratio)
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

        let committedText = committedOverlapText(from: committedSegments)
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

    private static func committedOverlapText(from segments: [TranscriptSegment]) -> String {
        let maximumOverlapTokenCount = 12
        var collectedTexts: [String] = []
        var collectedTokenCount = 0

        for segment in segments.reversed() {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let textTokens = tokens(in: text)
            guard !textTokens.isEmpty else { continue }

            let neededTokenCount = maximumOverlapTokenCount - collectedTokenCount
            if textTokens.count > neededTokenCount {
                let suffixStart = textTokens[textTokens.count - neededTokenCount].range.lowerBound
                collectedTexts.append(String(text[suffixStart...]).trimmingCharacters(in: .whitespacesAndNewlines))
                break
            }

            collectedTexts.append(text)
            collectedTokenCount += textTokens.count
            if collectedTokenCount >= maximumOverlapTokenCount { break }
        }

        return collectedTexts.reversed().joined(separator: " ")
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
            if tokenSequencesMatch(Array(committedSuffix), Array(newPrefix)) {
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

    private static func tokenSequencesMatch(_ lhs: [String], _ rhs: [String]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { tokensAreEquivalent($0.0, $0.1) }
    }

    private static func tokensAreEquivalent(_ lhs: String, _ rhs: String) -> Bool {
        guard lhs != rhs else { return true }
        return !normalizedTokenAlternates(lhs).isDisjoint(with: normalizedTokenAlternates(rhs))
    }

    private static func normalizedTokenAlternates(_ token: String) -> Set<String> {
        var alternates: Set<String> = [token]
        if let numberAlternate = numberTokenAlternate(for: token) {
            alternates.insert(numberAlternate)
        }
        if token.count > 4, token.hasSuffix("'s") {
            alternates.insert(String(token.dropLast(2)))
        }
        if token.count > 5, token.hasSuffix("ies") {
            alternates.insert(String(token.dropLast(3)) + "y")
        }
        if token.count > 4,
           token.hasSuffix("s"),
           !token.hasSuffix("ss"),
           !token.hasSuffix("is"),
           !token.hasSuffix("us") {
            alternates.insert(String(token.dropLast()))
        }
        return alternates
    }

    private static func numberTokenAlternate(for token: String) -> String? {
        let numberWords: [String: String] = [
            "zero": "0",
            "one": "1",
            "two": "2",
            "three": "3",
            "four": "4",
            "five": "5",
            "six": "6",
            "seven": "7",
            "eight": "8",
            "nine": "9",
            "ten": "10",
            "eleven": "11",
            "twelve": "12",
            "thirteen": "13",
            "fourteen": "14",
            "fifteen": "15",
            "sixteen": "16",
            "seventeen": "17",
            "eighteen": "18",
            "nineteen": "19",
            "twenty": "20",
            "thirty": "30",
            "forty": "40",
            "fifty": "50",
            "sixty": "60",
            "seventy": "70",
            "eighty": "80",
            "ninety": "90"
        ]
        if let digit = numberWords[token] {
            return digit
        }
        return numberWords.first(where: { $0.value == token })?.key
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

private struct StaleReplayAnalysis {
    var overlapRatio: Double
    var matchedTokenCount: Int
    var candidateTokenCount: Int
    var trailingUnmatchedTokenCount: Int
}

private enum QueuedTranscriptionWork: Sendable {
    case transcribe(SpeechAudioChunk)
    case flushPending(time: TimeInterval)
}

private actor CoalescingTranscriptionQueue {
    private var pendingFinals: [SpeechAudioChunk] = []
    private var latestNonFinal: SpeechAudioChunk?
    private var pendingFlushTime: TimeInterval?
    private var isFinished = false
    private var failure: Error?
    private var waiter: CheckedContinuation<Void, Never>?

    func enqueue(_ chunk: SpeechAudioChunk) {
        if chunk.isFinal {
            latestNonFinal = nil
            pendingFinals.append(chunk)
        } else {
            pendingFlushTime = nil
            latestNonFinal = chunk
        }
        resumeWaiter()
    }

    func enqueueFlushPending(time: TimeInterval) {
        pendingFlushTime = time
        resumeWaiter()
    }

    func finish() {
        isFinished = true
        resumeWaiter()
    }

    func fail(_ error: Error) {
        failure = error
        isFinished = true
        pendingFinals.removeAll(keepingCapacity: true)
        latestNonFinal = nil
        pendingFlushTime = nil
        resumeWaiter()
    }

    func next() async throws -> QueuedTranscriptionWork? {
        while true {
            if let failure {
                throw failure
            }
            if !pendingFinals.isEmpty {
                return .transcribe(pendingFinals.removeFirst())
            }
            if let latestNonFinal {
                self.latestNonFinal = nil
                return .transcribe(latestNonFinal)
            }
            if let pendingFlushTime {
                self.pendingFlushTime = nil
                return .flushPending(time: pendingFlushTime)
            }
            if isFinished {
                return nil
            }

            await withCheckedContinuation { continuation in
                waiter = continuation
            }
        }
    }

    private func resumeWaiter() {
        let waiter = waiter
        self.waiter = nil
        waiter?.resume()
    }
}

private extension Double {
    var formattedStreamingDebug: String {
        String(format: "%.3f", self)
    }
}
