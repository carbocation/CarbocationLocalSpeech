import CarbocationLocalSpeech
import Foundation

public actor LocalSpeechAnalyzer: Sendable {
    private let transcriber: any SpeechTranscriber
    private let diarizer: (any SpeakerDiarizer)?
    private let streamingDiarizer: (any StreamingSpeakerDiarizer)?

    public init(
        transcriber: any SpeechTranscriber,
        diarizer: (any SpeakerDiarizer)? = nil,
        streamingDiarizer: (any StreamingSpeakerDiarizer)? = nil
    ) {
        self.transcriber = transcriber
        self.diarizer = diarizer
        self.streamingDiarizer = streamingDiarizer
    }

    public func analyze(file url: URL, options: SpeechAnalysisOptions) async throws -> SpeechAnalysisResult {
        try options.diarization?.options.validate()
        guard options.diarization == nil || diarizer != nil else {
            throw SpeechAnalysisError.unsupportedFeature(
                "Diarization was requested, but no speaker diarizer is registered."
            )
        }

        let activeTranscriber = transcriber
        let activeDiarizer = diarizer

        return try await withThrowingTaskGroup(of: SpeechAnalysisSubResult.self) { group in
            group.addTask {
                let transcript = try await activeTranscriber.transcribe(
                    file: url,
                    options: options.transcription
                )
                return .transcript(transcript)
            }

            if let diarizationRequest = options.diarization,
               let registeredDiarizer = activeDiarizer {
                group.addTask {
                    let diarization = try await registeredDiarizer.diarize(
                        file: url,
                        options: diarizationRequest.options
                    )
                    return .diarization(diarization)
                }
            }

            var transcript: Transcript?
            var diarization: DiarizationResult?

            while let subResult = try await group.next() {
                switch subResult {
                case .transcript(let value):
                    transcript = value
                case .diarization(let value):
                    diarization = value
                }
            }

            return makeSpeechAnalysisResult(
                transcript: transcript,
                diarization: diarization,
                diarizationRequest: options.diarization
            )
        }
    }

    public func analyze(audio: PreparedAudio, options: SpeechAnalysisOptions) async throws -> SpeechAnalysisResult {
        try options.diarization?.options.validate()
        guard options.diarization == nil || diarizer != nil else {
            throw SpeechAnalysisError.unsupportedFeature(
                "Diarization was requested, but no speaker diarizer is registered."
            )
        }

        let activeTranscriber = transcriber
        let activeDiarizer = diarizer

        return try await withThrowingTaskGroup(of: SpeechAnalysisSubResult.self) { group in
            group.addTask {
                let transcript = try await activeTranscriber.transcribe(
                    audio: audio,
                    options: options.transcription
                )
                return .transcript(transcript)
            }

            if let diarizationRequest = options.diarization,
               let registeredDiarizer = activeDiarizer {
                group.addTask {
                    let diarization = try await registeredDiarizer.diarize(
                        audio: audio,
                        options: diarizationRequest.options
                    )
                    return .diarization(diarization)
                }
            }

            var transcript: Transcript?
            var diarization: DiarizationResult?

            while let subResult = try await group.next() {
                switch subResult {
                case .transcript(let value):
                    transcript = value
                case .diarization(let value):
                    diarization = value
                }
            }

            return makeSpeechAnalysisResult(
                transcript: transcript,
                diarization: diarization,
                diarizationRequest: options.diarization
            )
        }
    }

    public nonisolated func stream(
        audio: AsyncThrowingStream<AudioChunk, Error>,
        options: StreamingSpeechAnalysisOptions
    ) -> AsyncThrowingStream<StreamingSpeechAnalysisEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try options.diarization?.options.validate()
                    guard options.diarization == nil || streamingDiarizer != nil else {
                        throw SpeechAnalysisError.unsupportedFeature(
                            "Streaming diarization was requested, but no streaming speaker diarizer is registered."
                        )
                    }

                    if let diarizationRequest = options.diarization,
                       let activeStreamingDiarizer = streamingDiarizer {
                        try await streamWithDiarization(
                            audio: audio,
                            options: options,
                            diarizationRequest: diarizationRequest,
                            transcriber: transcriber,
                            streamingDiarizer: activeStreamingDiarizer,
                            continuation: continuation
                        )
                    } else {
                        try await streamTranscriptionOnly(
                            audio: audio,
                            options: options,
                            transcriber: transcriber,
                            continuation: continuation
                        )
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

private enum SpeechAnalysisSubResult: Sendable {
    case transcript(Transcript)
    case diarization(DiarizationResult)
}

private func makeSpeechAnalysisResult(
    transcript: Transcript?,
    diarization: DiarizationResult?,
    diarizationRequest: DiarizationRequest?
) -> SpeechAnalysisResult {
    var attributedResult: SpeakerAttributionMergeResult?
    if let transcript,
       let diarization,
       let diarizationRequest {
        attributedResult = SpeakerAttributionMerger.merge(
            transcript: transcript,
            diarization: diarization,
            policy: diarizationRequest.policy
        )
    }

    let diagnostics = (transcript?.backend != nil
        ? [SpeechDiagnostic(source: "analyzer", message: "Cooperative ASR finished")]
        : []
    ) + (diarization?.diagnostics ?? []) + (attributedResult?.diagnostics ?? [])

    return SpeechAnalysisResult(
        transcript: transcript,
        diarization: diarization,
        speakerAttributedTranscript: attributedResult?.transcript,
        diagnostics: diagnostics,
        diarizationStatus: diarizationRequest == nil ? .notRequested : .completed
    )
}

private func streamTranscriptionOnly(
    audio: AsyncThrowingStream<AudioChunk, Error>,
    options: StreamingSpeechAnalysisOptions,
    transcriber: any SpeechTranscriber,
    continuation: AsyncThrowingStream<StreamingSpeechAnalysisEvent, Error>.Continuation
) async throws {
    let state = StreamingSpeechAnalysisState(diarizationRequest: nil)
    let transcriptStream = transcriber.stream(audio: audio, options: options.transcription)

    for try await event in transcriptStream {
        for output in await state.recordTranscription(event) {
            continuation.yield(output)
        }
    }

    continuation.yield(await state.completed())
}

private func streamWithDiarization(
    audio: AsyncThrowingStream<AudioChunk, Error>,
    options: StreamingSpeechAnalysisOptions,
    diarizationRequest: StreamingDiarizationRequest,
    transcriber: any SpeechTranscriber,
    streamingDiarizer: any StreamingSpeakerDiarizer,
    continuation: AsyncThrowingStream<StreamingSpeechAnalysisEvent, Error>.Continuation
) async throws {
    let audioBroadcast = AudioStreamBroadcast.makeConsumerPair(
        bufferLimit: options.audioFanOutBufferLimit,
        backlogPolicy: options.backlogPolicy
    )
    let state = StreamingSpeechAnalysisState(diarizationRequest: diarizationRequest)

    do {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var reportedDroppedConsumers = Set<AudioStreamConsumer>()
                var broadcastError: Error?
                do {
                    for try await chunk in audio {
                        try Task.checkCancellation()
                        let result: AudioStreamBroadcastResult
                        do {
                            result = try await audioBroadcast.broadcaster.broadcast(chunk)
                        } catch {
                            broadcastError = error
                            throw error
                        }
                        for consumer in result.droppedConsumers where reportedDroppedConsumers.insert(consumer).inserted {
                            if consumer == .diarization {
                                if let diagnostic = await state.recordDiarizationDropped() {
                                    continuation.yield(.transcription(.diagnostic(diagnostic)))
                                }
                            } else {
                                continuation.yield(.transcription(.diagnostic(SpeechDiagnostic(
                                    source: "analyzer",
                                    message: "Dropped \(consumer.displayName) stream after it exceeded the real-time fan-out buffer limit; transcription will continue."
                                ))))
                            }
                        }
                        guard result.hasActiveConsumers else { break }
                    }
                    await audioBroadcast.broadcaster.finish()
                } catch is CancellationError {
                    await audioBroadcast.broadcaster.finish(throwing: CancellationError())
                    throw CancellationError()
                } catch {
                    await audioBroadcast.broadcaster.finish(throwing: error)
                    if broadcastError != nil {
                        throw error
                    }
                }
            }

            group.addTask {
                let transcriptStream = transcriber.stream(
                    audio: audioBroadcast.asr,
                    options: options.transcription
                )
                for try await event in transcriptStream {
                    for output in await state.recordTranscription(event) {
                        continuation.yield(output)
                    }
                }
            }

            group.addTask {
                do {
                    let diarizationStream = streamingDiarizer.stream(
                        audio: audioBroadcast.diarization,
                        options: diarizationRequest.streamingOptions
                    )
                    for try await snapshot in diarizationStream {
                        if options.backlogPolicy == .dropDiarization,
                           await state.diarizationWasDropped() {
                            return
                        }
                        for output in await state.recordDiarization(snapshot) {
                            continuation.yield(output)
                        }
                    }
                } catch is CancellationError {
                    if options.backlogPolicy == .dropDiarization,
                       await state.diarizationWasDropped() {
                        return
                    }
                    throw CancellationError()
                }
            }

            do {
                while try await group.next() != nil {}
            } catch {
                group.cancelAll()
                await audioBroadcast.broadcaster.finish(throwing: error)
                throw error
            }
        }
    } catch {
        await audioBroadcast.broadcaster.finish(throwing: error)
        throw error
    }

    continuation.yield(await state.completed())
}

private struct AudioStreamBroadcast: Sendable {
    var broadcaster: AudioStreamBroadcaster
    var asr: AsyncThrowingStream<AudioChunk, Error>
    var diarization: AsyncThrowingStream<AudioChunk, Error>

    static func makeConsumerPair(
        bufferLimit: Int,
        backlogPolicy: StreamingAudioBacklogPolicy
    ) -> AudioStreamBroadcast {
        let bufferLimit = max(1, bufferLimit)
        let asrSink = AudioStreamSink.make(bufferLimit: bufferLimit)
        let diarizationSink = AudioStreamSink.make(bufferLimit: bufferLimit)
        let broadcaster = AudioStreamBroadcaster(
            bufferLimit: bufferLimit,
            backlogPolicy: backlogPolicy,
            sinks: [
                AudioStreamBroadcaster.Sink(
                    id: asrSink.id,
                    consumer: .transcription,
                    continuation: asrSink.continuation
                ),
                AudioStreamBroadcaster.Sink(
                    id: diarizationSink.id,
                    consumer: .diarization,
                    continuation: diarizationSink.continuation
                )
            ]
        )

        return AudioStreamBroadcast(
            broadcaster: broadcaster,
            asr: asrSink.stream,
            diarization: diarizationSink.stream
        )
    }
}

private struct AudioStreamSink: Sendable {
    var id: UUID
    var stream: AsyncThrowingStream<AudioChunk, Error>
    var continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation

    static func make(bufferLimit: Int) -> AudioStreamSink {
        let id = UUID()
        var continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation!
        let stream = AsyncThrowingStream<AudioChunk, Error>(
            bufferingPolicy: .bufferingOldest(max(1, bufferLimit))
        ) { newContinuation in
            continuation = newContinuation
        }
        return AudioStreamSink(id: id, stream: stream, continuation: continuation)
    }
}

private enum AudioStreamBroadcastError: Error, LocalizedError, Sendable {
    case consumerBacklogExceeded(consumer: String, bufferLimit: Int)

    var errorDescription: String? {
        switch self {
        case .consumerBacklogExceeded(let consumer, let bufferLimit):
            return "Audio stream consumer '\(consumer)' fell behind the real-time fan-out buffer limit (\(bufferLimit) chunks)."
        }
    }
}

private enum AudioStreamConsumer: String, Sendable {
    case transcription
    case diarization

    var displayName: String { rawValue }
}

private struct AudioStreamBroadcastResult: Sendable {
    var hasActiveConsumers: Bool
    var droppedConsumers: [AudioStreamConsumer]
}

private actor AudioStreamBroadcaster {
    struct Sink: Sendable {
        var id: UUID
        var consumer: AudioStreamConsumer
        var continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation
    }

    private var sinks: [Sink]
    private let bufferLimit: Int
    private let backlogPolicy: StreamingAudioBacklogPolicy
    private var isFinished = false

    init(
        bufferLimit: Int,
        backlogPolicy: StreamingAudioBacklogPolicy,
        sinks: [Sink]
    ) {
        self.sinks = sinks
        self.bufferLimit = max(1, bufferLimit)
        self.backlogPolicy = backlogPolicy
    }

    @discardableResult
    func broadcast(_ chunk: AudioChunk) throws -> AudioStreamBroadcastResult {
        guard !isFinished, !sinks.isEmpty else {
            isFinished = true
            return AudioStreamBroadcastResult(hasActiveConsumers: false, droppedConsumers: [])
        }

        var activeSinks: [Sink] = []
        var droppedConsumers: [AudioStreamConsumer] = []
        for sink in sinks {
            switch sink.continuation.yield(chunk) {
            case .enqueued:
                activeSinks.append(sink)
            case .dropped:
                let error = AudioStreamBroadcastError.consumerBacklogExceeded(
                    consumer: sink.consumer.displayName,
                    bufferLimit: bufferLimit
                )
                if backlogPolicy == .dropDiarization, sink.consumer == .diarization {
                    sink.continuation.finish()
                    droppedConsumers.append(sink.consumer)
                } else {
                    finishLocked(throwing: error)
                    throw error
                }
            case .terminated:
                break
            @unknown default:
                activeSinks.append(sink)
            }
        }

        sinks = activeSinks
        if sinks.isEmpty {
            isFinished = true
            return AudioStreamBroadcastResult(
                hasActiveConsumers: false,
                droppedConsumers: droppedConsumers
            )
        }
        return AudioStreamBroadcastResult(
            hasActiveConsumers: true,
            droppedConsumers: droppedConsumers
        )
    }

    func finish() {
        guard !isFinished else { return }
        finishLocked()
    }

    func finish(throwing error: Error) {
        guard !isFinished else { return }
        finishLocked(throwing: error)
    }

    private func finishLocked(throwing error: Error? = nil) {
        isFinished = true
        let activeSinks = sinks
        sinks.removeAll()
        for sink in activeSinks {
            if let error {
                sink.continuation.finish(throwing: error)
            } else {
                sink.continuation.finish()
            }
        }
    }

}

private actor StreamingSpeechAnalysisState {
    private let diarizationRequest: StreamingDiarizationRequest?
    private var latestTranscriptSnapshot: StreamingTranscriptSnapshot?
    private var latestDiarizationSnapshot: StreamingDiarizationSnapshot?
    private var finalTranscript: Transcript?
    private var lockedStableAttributions: [UUID: LockedStableAttribution] = [:]
    private var diagnostics: [SpeechDiagnostic] = []
    private var diarizationStatus: SpeechAnalysisDiarizationStatus

    init(diarizationRequest: StreamingDiarizationRequest?) {
        self.diarizationRequest = diarizationRequest
        diarizationStatus = diarizationRequest == nil ? .notRequested : .completed
    }

    func recordTranscription(_ event: TranscriptEvent) -> [StreamingSpeechAnalysisEvent] {
        var outputs: [StreamingSpeechAnalysisEvent] = [.transcription(event)]

        switch event {
        case .snapshot(let snapshot):
            latestTranscriptSnapshot = snapshotByRestoringSpeakerAttribution(snapshot)
            if let attributed = speakerAttributedSnapshot() {
                outputs.append(.speakerAttributedSnapshot(attributed))
            }
        case .completed(let transcript):
            let restoredTranscript = transcriptByRestoringSpeakerAttribution(transcript)
            finalTranscript = restoredTranscript
            latestTranscriptSnapshot = StreamingTranscriptSnapshot(stable: restoredTranscript)
            if let attributed = speakerAttributedSnapshot() {
                outputs.append(.speakerAttributedSnapshot(attributed))
            }
        case .started, .audioLevel, .voiceActivity, .diagnostic, .progress, .stats:
            break
        }

        return outputs
    }

    func recordDiarization(_ snapshot: StreamingDiarizationSnapshot) -> [StreamingSpeechAnalysisEvent] {
        guard diarizationStatus != .dropped else { return [] }

        let retainedSnapshot = snapshotByRetainingStableDiarization(snapshot)
        latestDiarizationSnapshot = retainedSnapshot
        var outputs: [StreamingSpeechAnalysisEvent] = [.diarization(retainedSnapshot)]

        if let attributed = speakerAttributedSnapshot() {
            outputs.append(.speakerAttributedSnapshot(attributed))
        }

        return outputs
    }

    func recordDiarizationDropped() -> SpeechDiagnostic? {
        guard diarizationStatus != .dropped else { return nil }
        diarizationStatus = .dropped
        let diagnostic = SpeechDiagnostic(
            source: "analyzer",
            message: "Dropped diarization stream after it exceeded the real-time fan-out buffer limit; transcription will continue.",
            code: .diarizationDropped
        )
        diagnostics.append(diagnostic)
        return diagnostic
    }

    func diarizationWasDropped() -> Bool {
        diarizationStatus == .dropped
    }

    func completed() -> StreamingSpeechAnalysisEvent {
        let transcript = finalTranscript ?? latestTranscriptSnapshot?.transcript
        let diarization = diarizationStatus == .dropped ? nil : latestDiarizationSnapshot?.diarization
        let attributed = speakerAttributedTranscript(transcript: transcript, diarization: diarization)
        let diagnostics = diagnostics + (diarization?.diagnostics ?? []) + (attributed?.diagnostics ?? [])

        return .completed(SpeechAnalysisResult(
            transcript: transcript,
            diarization: diarization,
            speakerAttributedTranscript: attributed?.transcript,
            diagnostics: diagnostics,
            diarizationStatus: diarizationStatus
        ))
    }

    private func speakerAttributedSnapshot() -> StreamingTranscriptSnapshot? {
        guard let diarizationRequest,
              let transcriptSnapshot = latestTranscriptSnapshot,
              let diarizationSnapshot = latestDiarizationSnapshot
        else {
            return nil
        }

        let diarization = diarizationSnapshot.diarization
        guard !diarization.turns.isEmpty else { return nil }
        guard let horizon = attributionHorizon(
            transcriptSnapshot: transcriptSnapshot,
            diarizationSnapshot: diarizationSnapshot,
            request: diarizationRequest
        ) else {
            return nil
        }

        let windowStart = liveWindowStart(
            transcriptSnapshot: transcriptSnapshot,
            diarizationSnapshot: diarizationSnapshot,
            horizon: horizon,
            request: diarizationRequest
        )
        reconcileLockedSegments(with: transcriptSnapshot.stable.segments)
        if let lockBefore = lockBefore(
            transcriptSnapshot: transcriptSnapshot,
            diarizationSnapshot: diarizationSnapshot,
            windowStart: windowStart,
            request: diarizationRequest
        ) {
            lockStableSegments(
                before: lockBefore,
                from: transcriptSnapshot.stable,
                diarization: diarization,
                request: diarizationRequest
            )
        }

        let stable = attributedStableTranscript(
            from: transcriptSnapshot.stable,
            diarization: diarization,
            request: diarizationRequest,
            horizon: horizon,
            windowStart: windowStart
        )
        latestTranscriptSnapshot?.stable = stable
        let pruneBefore = lockedAttributionPruneBefore(horizon: horizon, request: diarizationRequest)
        pruneLockedStableAttributions(before: pruneBefore)
        pruneRetainedDiarization(before: pruneBefore)

        let volatile = transcriptSnapshot.volatile.map { transcript in
            attributedTranscript(
                from: transcript,
                segments: transcript.segments,
                diarization: diarization,
                request: diarizationRequest,
                horizon: horizon
            )
        }

        return StreamingTranscriptSnapshot(
            stable: stable,
            volatile: volatile,
            volatileRange: transcriptSnapshot.volatileRange
        )
    }

    private func speakerAttributedTranscript(
        transcript: Transcript?,
        diarization: DiarizationResult?
    ) -> SpeakerAttributionMergeResult? {
        guard let diarizationRequest,
              let transcript,
              let diarization,
              !diarization.turns.isEmpty
        else {
            return nil
        }

        return SpeakerAttributionMerger.merge(
            transcript: transcript,
            diarization: diarization,
            policy: diarizationRequest.attributionPolicy
        )
    }

    private func attributedStableTranscript(
        from transcript: Transcript,
        diarization: DiarizationResult,
        request: StreamingDiarizationRequest,
        horizon: TimeInterval,
        windowStart: TimeInterval
    ) -> Transcript {
        let unlockedSegments = transcript.segments.filter { lockedStableAttributions[$0.id] == nil }
        let liveSegments = unlockedSegments.filter {
            segmentOverlaps($0, start: windowStart, end: horizon)
        }
        let liveSegmentIDs = Set(liveSegments.map(\.id))
        let passthroughSegments = unlockedSegments.filter { segment in
            !liveSegmentIDs.contains(segment.id)
        }
        let attributedLive = attributedTranscript(
            from: transcript,
            segments: liveSegments,
            diarization: diarization,
            request: request,
            horizon: horizon
        )
        let lockedSegments = lockedStableAttributions.values
            .flatMap(\.attributedSegments)

        return Transcript(
            segments: (lockedSegments + attributedLive.segments + passthroughSegments).sorted(by: transcriptSegmentOrder),
            language: transcript.language,
            duration: transcript.duration,
            backend: transcript.backend
        )
    }

    private func attributedTranscript(
        from transcript: Transcript,
        segments: [TranscriptSegment],
        diarization: DiarizationResult,
        request: StreamingDiarizationRequest,
        horizon: TimeInterval
    ) -> Transcript {
        var output: [TranscriptSegment] = []
        var pendingMerge: [TranscriptSegment] = []

        func flushPendingMerge() {
            guard !pendingMerge.isEmpty else { return }
            let relevantDiarization = windowedDiarization(diarization, for: pendingMerge)
            let partialTranscript = Transcript(
                segments: pendingMerge,
                language: transcript.language,
                duration: transcript.duration,
                backend: transcript.backend
            )
            let merged = SpeakerAttributionMerger.merge(
                transcript: partialTranscript,
                diarization: relevantDiarization,
                policy: request.attributionPolicy
            ).transcript
            output.append(contentsOf: segmentsByRestoringSingleSegmentIdentities(
                merged.segments,
                sources: pendingMerge
            ))
            pendingMerge.removeAll(keepingCapacity: true)
        }

        for segment in segments.sorted(by: transcriptSegmentOrder) {
            if segment.endTime <= horizon {
                pendingMerge.append(segment)
            } else {
                flushPendingMerge()
                output.append(segment)
            }
        }
        flushPendingMerge()

        return Transcript(
            segments: output,
            language: transcript.language,
            duration: transcript.duration,
            backend: transcript.backend
        )
    }

    private func reconcileLockedSegments(with stableSegments: [TranscriptSegment]) {
        let currentFingerprints = Dictionary(
            uniqueKeysWithValues: stableSegments.map { ($0.id, TranscriptSegmentFingerprint(segment: $0)) }
        )

        let staleSegmentIDs = lockedStableAttributions.compactMap { segmentID, lockedAttribution in
            currentFingerprints[segmentID] == lockedAttribution.sourceFingerprint ? nil : segmentID
        }
        for segmentID in staleSegmentIDs {
            lockedStableAttributions.removeValue(forKey: segmentID)
        }
    }

    private func pruneLockedStableAttributions(before pruneBefore: TimeInterval?) {
        guard let pruneBefore else { return }
        let prunedSegmentIDs = lockedStableAttributions.compactMap { segmentID, lockedAttribution in
            lockedAttribution.sourceFingerprint.endTime <= pruneBefore ? segmentID : nil
        }
        for segmentID in prunedSegmentIDs {
            lockedStableAttributions.removeValue(forKey: segmentID)
        }
    }

    private func pruneRetainedDiarization(before pruneBefore: TimeInterval?) {
        guard let pruneBefore,
              let snapshot = latestDiarizationSnapshot
        else {
            return
        }

        latestDiarizationSnapshot = StreamingDiarizationSnapshot(
            stable: prunedDiarization(snapshot.stable, before: pruneBefore),
            volatile: snapshot.volatile,
            volatileRange: snapshot.volatileRange
        )
    }

    private func lockStableSegments(
        before lockBefore: TimeInterval,
        from transcript: Transcript,
        diarization: DiarizationResult,
        request: StreamingDiarizationRequest
    ) {
        let candidates = transcript.segments
            .filter {
                $0.endTime <= lockBefore
                    && lockedStableAttributions[$0.id] == nil
                    && !hasSpeakerAttribution($0)
            }
            .sorted(by: transcriptSegmentOrder)
        guard !candidates.isEmpty else { return }

        let relevantDiarization = windowedDiarization(diarization, for: candidates)
        let partialTranscript = Transcript(
            segments: candidates,
            language: transcript.language,
            duration: transcript.duration,
            backend: transcript.backend
        )
        let attributed = SpeakerAttributionMerger.merge(
            transcript: partialTranscript,
            diarization: relevantDiarization,
            policy: request.attributionPolicy
        ).transcript
        let attributedSegmentsWithSourceIDs = segmentsByRestoringSingleSegmentIdentities(
            attributed.segments,
            sources: candidates
        )

        for candidate in candidates {
            let attributedSegments = attributedSegmentsWithSourceIDs.filter {
                segmentOverlaps($0, source: candidate)
            }
            guard attributedSegments.contains(where: hasSpeakerAttribution) else {
                continue
            }
            lockedStableAttributions[candidate.id] = LockedStableAttribution(
                sourceFingerprint: TranscriptSegmentFingerprint(segment: candidate),
                attributedSegments: attributedSegments
            )
        }
    }

    private func attributionHorizon(
        transcriptSnapshot: StreamingTranscriptSnapshot,
        diarizationSnapshot: StreamingDiarizationSnapshot,
        request: StreamingDiarizationRequest
    ) -> TimeInterval? {
        guard let transcriptEnd = latestEnd(transcriptSnapshot),
              let diarizationEnd = latestEnd(diarizationSnapshot)
        else {
            return nil
        }

        let syncedEnd = min(transcriptEnd, diarizationEnd)
        let horizon = syncedEnd - effectiveJitterBufferDelay(request: request, syncedEnd: syncedEnd)
        return horizon >= 0 ? horizon : nil
    }

    private func liveWindowStart(
        transcriptSnapshot: StreamingTranscriptSnapshot,
        diarizationSnapshot: StreamingDiarizationSnapshot,
        horizon: TimeInterval,
        request: StreamingDiarizationRequest
    ) -> TimeInterval {
        let lookbackWindow = max(0, request.attributionLookbackWindow)
        let volatileStarts = [
            transcriptSnapshot.volatileRange?.startTime,
            diarizationSnapshot.volatileRange?.startTime
        ].compactMap { $0 }
        let anchor = volatileStarts.min().map { min($0, horizon) } ?? horizon
        return max(0, anchor - lookbackWindow)
    }

    private func lockBefore(
        transcriptSnapshot: StreamingTranscriptSnapshot,
        diarizationSnapshot: StreamingDiarizationSnapshot,
        windowStart: TimeInterval,
        request: StreamingDiarizationRequest
    ) -> TimeInterval? {
        guard let stableTranscriptEnd = latestEnd(transcriptSnapshot.stable),
              let stableDiarizationEnd = latestEnd(diarizationSnapshot.stable)
        else {
            return nil
        }

        let stableSyncedEnd = min(stableTranscriptEnd, stableDiarizationEnd)
        let stableSyncHorizon = stableSyncedEnd - effectiveJitterBufferDelay(
            request: request,
            syncedEnd: stableSyncedEnd
        )
        guard stableSyncHorizon > 0 else { return nil }
        return min(windowStart, stableSyncHorizon)
    }

    private func effectiveJitterBufferDelay(
        request: StreamingDiarizationRequest,
        syncedEnd: TimeInterval
    ) -> TimeInterval {
        let requestedDelay = max(0, request.attributionJitterBufferDelay)
        let configuredMaximum = request.maximumAttributionJitterBufferDelay.map { max(0, $0) } ?? requestedDelay
        let streamRelativeMaximum = max(0, syncedEnd / 2)
        return min(requestedDelay, configuredMaximum, streamRelativeMaximum)
    }

    private func lockedAttributionPruneBefore(
        horizon: TimeInterval,
        request: StreamingDiarizationRequest
    ) -> TimeInterval? {
        let retainedWindow = max(
            0,
            max(request.attributionLookbackWindow, request.attributionCacheRetentionWindow)
        )
        let pruneBefore = horizon - retainedWindow
        return pruneBefore > 0 ? pruneBefore : nil
    }

    private func windowedDiarization(
        _ diarization: DiarizationResult,
        for segments: [TranscriptSegment]
    ) -> DiarizationResult {
        guard let start = segments.map(\.startTime).min(),
              let end = segments.map(\.endTime).max()
        else {
            return DiarizationResult(
                turns: [],
                speakers: [],
                duration: 0,
                backend: diarization.backend,
                diagnostics: diarization.diagnostics
            )
        }

        let padding: TimeInterval = 0.25
        return windowedDiarization(
            diarization,
            start: max(0, start - padding),
            end: end + padding
        )
    }

    private func windowedDiarization(
        _ diarization: DiarizationResult,
        start: TimeInterval,
        end: TimeInterval
    ) -> DiarizationResult {
        let turns = diarization.turns.filter { overlaps($0, start: start, end: end) }
        let exclusiveTurns = diarization.exclusiveTurns.filter { overlaps($0, start: start, end: end) }
        let orderedSpeakerIDs = (turns + exclusiveTurns).reduce(into: [SpeakerID]()) { ids, turn in
            guard !ids.contains(turn.speaker) else { return }
            ids.append(turn.speaker)
        }
        var speakers = diarization.speakers.filter { orderedSpeakerIDs.contains($0.id) }
        for speakerID in orderedSpeakerIDs where !speakers.contains(where: { $0.id == speakerID }) {
            speakers.append(Speaker(id: speakerID))
        }

        return DiarizationResult(
            turns: turns,
            exclusiveTurns: exclusiveTurns,
            speakers: speakers,
            duration: max(turns.map(\.endTime).max() ?? 0, exclusiveTurns.map(\.endTime).max() ?? 0),
            backend: diarization.backend,
            diagnostics: diarization.diagnostics
        )
    }

    private func overlaps(_ turn: SpeakerTurn, start: TimeInterval, end: TimeInterval) -> Bool {
        turn.startTime < end && start < turn.endTime
    }

    private func segmentOverlaps(_ segment: TranscriptSegment, start: TimeInterval, end: TimeInterval) -> Bool {
        segment.startTime < end && start < segment.endTime
    }

    private func segmentOverlaps(_ attributed: TranscriptSegment, source: TranscriptSegment) -> Bool {
        attributed.startTime < source.endTime && source.startTime < attributed.endTime
    }

    private func segmentsByRestoringSingleSegmentIdentities(
        _ attributedSegments: [TranscriptSegment],
        sources: [TranscriptSegment]
    ) -> [TranscriptSegment] {
        var restored = attributedSegments
        for source in sources {
            let matchingIndices = restored.indices.filter { index in
                segmentOverlaps(restored[index], source: source)
            }
            guard matchingIndices.count == 1,
                  let index = matchingIndices.first
            else {
                continue
            }
            restored[index].id = source.id
        }
        return restored
    }

    private func hasSpeakerAttribution(_ segment: TranscriptSegment) -> Bool {
        segment.speaker != nil || segment.words.contains { $0.speaker != nil }
    }

    private func snapshotByRetainingStableDiarization(
        _ snapshot: StreamingDiarizationSnapshot
    ) -> StreamingDiarizationSnapshot {
        StreamingDiarizationSnapshot(
            stable: mergedDiarization(previous: latestDiarizationSnapshot?.stable, current: snapshot.stable),
            volatile: snapshot.volatile,
            volatileRange: snapshot.volatileRange
        )
    }

    private func mergedDiarization(
        previous: DiarizationResult?,
        current: DiarizationResult
    ) -> DiarizationResult {
        guard let previous else { return current }

        let turns = mergedTurns(previous.turns, current.turns)
        let exclusiveTurns = mergedTurns(previous.exclusiveTurns, current.exclusiveTurns)
        let orderedSpeakerIDs = (turns + exclusiveTurns).reduce(into: [SpeakerID]()) { ids, turn in
            guard !ids.contains(turn.speaker) else { return }
            ids.append(turn.speaker)
        }
        let speakersByID = Dictionary(
            (previous.speakers + current.speakers).map { ($0.id, $0) },
            uniquingKeysWith: { _, current in current }
        )
        let speakers = orderedSpeakerIDs.map { speakersByID[$0] ?? Speaker(id: $0) }

        return DiarizationResult(
            turns: turns,
            exclusiveTurns: exclusiveTurns,
            speakers: speakers,
            duration: max(previous.duration, current.duration),
            backend: current.backend ?? previous.backend,
            diagnostics: current.diagnostics
        )
    }

    private func mergedTurns(_ previous: [SpeakerTurn], _ current: [SpeakerTurn]) -> [SpeakerTurn] {
        var seen = Set<SpeakerTurnFingerprint>()
        var output: [SpeakerTurn] = []
        for turn in previous + current {
            let fingerprint = SpeakerTurnFingerprint(turn: turn)
            guard seen.insert(fingerprint).inserted else { continue }
            output.append(turn)
        }
        return output.sorted { lhs, rhs in
            if lhs.startTime == rhs.startTime {
                return lhs.endTime < rhs.endTime
            }
            return lhs.startTime < rhs.startTime
        }
    }

    private func prunedDiarization(_ diarization: DiarizationResult, before pruneBefore: TimeInterval) -> DiarizationResult {
        let turns = diarization.turns.filter { $0.endTime > pruneBefore }
        let exclusiveTurns = diarization.exclusiveTurns.filter { $0.endTime > pruneBefore }
        let orderedSpeakerIDs = (turns + exclusiveTurns).reduce(into: [SpeakerID]()) { ids, turn in
            guard !ids.contains(turn.speaker) else { return }
            ids.append(turn.speaker)
        }
        let speakers = orderedSpeakerIDs.map { speakerID in
            diarization.speakers.first { $0.id == speakerID } ?? Speaker(id: speakerID)
        }
        return DiarizationResult(
            turns: turns,
            exclusiveTurns: exclusiveTurns,
            speakers: speakers,
            duration: diarization.duration,
            backend: diarization.backend,
            diagnostics: diarization.diagnostics
        )
    }

    private func snapshotByRestoringSpeakerAttribution(
        _ snapshot: StreamingTranscriptSnapshot
    ) -> StreamingTranscriptSnapshot {
        var restored = snapshot
        restored.stable = transcriptByRestoringSpeakerAttribution(snapshot.stable)
        return restored
    }

    private func transcriptByRestoringSpeakerAttribution(_ transcript: Transcript) -> Transcript {
        guard let previousStable = latestTranscriptSnapshot?.stable else {
            return transcript
        }
        let previousSegmentsByID = Dictionary(uniqueKeysWithValues: previousStable.segments.map { ($0.id, $0) })
        let restorationOptions = diarizationRequest?.attributionRestorationOptions
            ?? SpeakerAttributionRestorationOptions()
        var restorationIndex: SpeakerAttributionRestorationIndex?
        var segments: [TranscriptSegment] = []
        segments.reserveCapacity(transcript.segments.count)

        for segment in transcript.segments {
            if let previous = previousSegmentsByID[segment.id],
               TranscriptSegmentFingerprint(segment: previous) == TranscriptSegmentFingerprint(segment: segment) {
                segments.append(segmentByRestoringSpeakerAttribution(segment, from: previous))
            } else {
                if restorationIndex == nil {
                    restorationIndex = SpeakerAttributionRestorationIndex(
                        previousSegments: previousStable.segments,
                        options: restorationOptions
                    )
                }
                segments.append(segmentByRestoringOverlappingSpeakerAttribution(
                    segment,
                    using: restorationIndex ?? SpeakerAttributionRestorationIndex(
                        previousSegments: [],
                        options: restorationOptions
                    )
                ))
            }
        }
        return Transcript(
            segments: segments,
            language: transcript.language,
            duration: transcript.duration,
            backend: transcript.backend
        )
    }

    private func segmentByRestoringSpeakerAttribution(
        _ segment: TranscriptSegment,
        from previous: TranscriptSegment
    ) -> TranscriptSegment {
        var restored = segment
        if restored.speaker == nil {
            restored.speaker = previous.speaker
        }
        if restored.words.count == previous.words.count {
            restored.words = zip(restored.words, previous.words).map { current, prior in
                var word = current
                if word.speaker == nil {
                    word.speaker = prior.speaker
                }
                return word
            }
        }
        return restored
    }

    private func segmentByRestoringOverlappingSpeakerAttribution(
        _ segment: TranscriptSegment,
        using restorationIndex: SpeakerAttributionRestorationIndex
    ) -> TranscriptSegment {
        guard !hasSpeakerAttribution(segment) else { return segment }
        guard !restorationIndex.isEmpty else { return segment }

        var restored = segment
        let segmentSpeaker = restorationIndex.bestSpeaker(for: segment)
        if !restored.words.isEmpty {
            restored.words = restored.words.map { word in
                var restoredWord = word
                restoredWord.speaker = restorationIndex.bestSpeaker(for: word) ?? segmentSpeaker
                return restoredWord
            }
        }
        restored.speaker = dominantSpeaker(in: restored.words)
            ?? segmentSpeaker
        return restored
    }

    private struct SpeakerAttributionRestorationIndex: Sendable {
        private let options: SpeakerAttributionRestorationOptions
        private var segmentReferences: [SegmentReference] = []
        private var wordReferences: [WordReference] = []
        private var segmentBuckets: [Int: [Int]] = [:]
        private var wordBuckets: [Int: [Int]] = [:]

        init(previousSegments: [TranscriptSegment], options: SpeakerAttributionRestorationOptions) {
            self.options = options

            for segment in previousSegments where Self.hasSpeakerAttribution(segment) {
                if let speaker = segment.speaker ?? Self.dominantSpeaker(in: segment.words) {
                    let reference = SegmentReference(
                        speaker: speaker,
                        startTime: segment.startTime,
                        endTime: segment.endTime
                    )
                    let index = segmentReferences.count
                    segmentReferences.append(reference)
                    insert(
                        index: index,
                        startTime: reference.startTime,
                        endTime: reference.endTime,
                        into: &segmentBuckets
                    )
                }

                for word in segment.words {
                    guard let speaker = word.speaker else { continue }
                    let reference = WordReference(
                        speaker: speaker,
                        startTime: word.startTime,
                        endTime: word.endTime
                    )
                    let index = wordReferences.count
                    wordReferences.append(reference)
                    insert(
                        index: index,
                        startTime: reference.startTime,
                        endTime: reference.endTime,
                        into: &wordBuckets
                    )
                }
            }
        }

        var isEmpty: Bool {
            segmentReferences.isEmpty && wordReferences.isEmpty
        }

        func bestSpeaker(for segment: TranscriptSegment) -> SpeakerID? {
            let candidates = segmentCandidateReferences(startTime: segment.startTime, endTime: segment.endTime)
            guard !candidates.isEmpty else { return nil }

            var bestBySpeaker: [SpeakerID: SpeakerScore] = [:]
            for candidate in candidates {
                guard let metrics = overlapMetrics(
                    currentStart: segment.startTime,
                    currentEnd: segment.endTime,
                    previousStart: candidate.startTime,
                    previousEnd: candidate.endTime
                ) else {
                    continue
                }
                guard metrics.currentCoverage >= options.minimumSegmentCoverage else { continue }
                let score = SpeakerScore(
                    speaker: candidate.speaker,
                    score: metrics.currentCoverage * 0.7 + min(metrics.previousCoverage, 1) * 0.3,
                    overlap: metrics.overlap,
                    previousCoverage: metrics.previousCoverage
                )
                if let existing = bestBySpeaker[candidate.speaker],
                   existing.score > score.score {
                    continue
                }
                bestBySpeaker[candidate.speaker] = score
            }

            var scores = Array(bestBySpeaker.values)
            if scores.count > 1 {
                scores.removeAll { $0.previousCoverage < 0.10 && $0.overlap < 0.5 }
            }
            return unambiguousSpeaker(from: scores)
        }

        func bestSpeaker(for word: TranscriptWord) -> SpeakerID? {
            let candidates = wordCandidateReferences(startTime: word.startTime, endTime: word.endTime)
            guard !candidates.isEmpty else { return nil }

            var overlapBySpeaker: [SpeakerID: TimeInterval] = [:]
            for candidate in candidates {
                let overlap = Self.intervalOverlap(
                    start: word.startTime,
                    end: word.endTime,
                    otherStart: candidate.startTime,
                    otherEnd: candidate.endTime
                )
                guard overlap > 0 else { continue }
                overlapBySpeaker[candidate.speaker, default: 0] += overlap
            }

            let duration = max(word.endTime - word.startTime, .ulpOfOne)
            let scores = overlapBySpeaker.map { speaker, overlap in
                SpeakerScore(
                    speaker: speaker,
                    score: overlap / duration,
                    overlap: overlap,
                    previousCoverage: 1
                )
            }.filter { score in
                score.score >= options.minimumWordCoverage
                    && score.overlap >= min(options.minimumOverlapDuration, duration * options.minimumWordCoverage)
            }

            return unambiguousSpeaker(from: scores)
        }

        private func insert(
            index: Int,
            startTime: TimeInterval,
            endTime: TimeInterval,
            into buckets: inout [Int: [Int]]
        ) {
            for bucket in bucketRange(startTime: startTime, endTime: endTime) {
                buckets[bucket, default: []].append(index)
            }
        }

        private func segmentCandidateReferences(
            startTime: TimeInterval,
            endTime: TimeInterval
        ) -> [SegmentReference] {
            candidateIndices(startTime: startTime, endTime: endTime, buckets: segmentBuckets).compactMap { index in
                guard segmentReferences.indices.contains(index) else { return nil }
                let reference = segmentReferences[index]
                return Self.intervalsOverlap(
                    start: startTime,
                    end: endTime,
                    otherStart: reference.startTime,
                    otherEnd: reference.endTime
                ) ? reference : nil
            }
        }

        private func wordCandidateReferences(
            startTime: TimeInterval,
            endTime: TimeInterval
        ) -> [WordReference] {
            candidateIndices(startTime: startTime, endTime: endTime, buckets: wordBuckets).compactMap { index in
                guard wordReferences.indices.contains(index) else { return nil }
                let reference = wordReferences[index]
                return Self.intervalsOverlap(
                    start: startTime,
                    end: endTime,
                    otherStart: reference.startTime,
                    otherEnd: reference.endTime
                ) ? reference : nil
            }
        }

        private func candidateIndices(
            startTime: TimeInterval,
            endTime: TimeInterval,
            buckets: [Int: [Int]]
        ) -> [Int] {
            var seen = Set<Int>()
            var output: [Int] = []
            for bucket in bucketRange(startTime: startTime, endTime: endTime) {
                for index in buckets[bucket] ?? [] where seen.insert(index).inserted {
                    output.append(index)
                }
            }
            return output
        }

        private func overlapMetrics(
            currentStart: TimeInterval,
            currentEnd: TimeInterval,
            previousStart: TimeInterval,
            previousEnd: TimeInterval
        ) -> OverlapMetrics? {
            let overlap = Self.intervalOverlap(
                start: currentStart,
                end: currentEnd,
                otherStart: previousStart,
                otherEnd: previousEnd
            )
            guard overlap > 0 else { return nil }

            let currentDuration = max(currentEnd - currentStart, .ulpOfOne)
            let previousDuration = max(previousEnd - previousStart, .ulpOfOne)
            return OverlapMetrics(
                overlap: overlap,
                currentCoverage: overlap / currentDuration,
                previousCoverage: overlap / previousDuration
            )
        }

        private func unambiguousSpeaker(from scores: [SpeakerScore]) -> SpeakerID? {
            let sorted = scores.sorted {
                if $0.score == $1.score {
                    return $0.overlap > $1.overlap
                }
                return $0.score > $1.score
            }
            guard let best = sorted.first else { return nil }
            if let competitor = sorted.dropFirst().first(where: { $0.speaker != best.speaker }),
               competitor.score >= best.score * options.ambiguityRatio {
                return nil
            }
            return best.speaker
        }

        private func bucketRange(startTime: TimeInterval, endTime: TimeInterval) -> ClosedRange<Int> {
            let start = min(startTime, endTime)
            let end = max(startTime, endTime)
            let first = Int(floor(start / options.timeBucketWidth))
            let adjustedEnd = end == start ? end : max(start, end - .ulpOfOne)
            let last = max(first, Int(floor(adjustedEnd / options.timeBucketWidth)))
            return first...last
        }

        private static func intervalsOverlap(
            start: TimeInterval,
            end: TimeInterval,
            otherStart: TimeInterval,
            otherEnd: TimeInterval
        ) -> Bool {
            start < otherEnd && otherStart < end
        }

        private static func intervalOverlap(
            start: TimeInterval,
            end: TimeInterval,
            otherStart: TimeInterval,
            otherEnd: TimeInterval
        ) -> TimeInterval {
            max(0, min(end, otherEnd) - max(start, otherStart))
        }

        private static func hasSpeakerAttribution(_ segment: TranscriptSegment) -> Bool {
            segment.speaker != nil || segment.words.contains { $0.speaker != nil }
        }

        private static func dominantSpeaker(in words: [TranscriptWord]) -> SpeakerID? {
            let durationsBySpeaker = words.reduce(into: [SpeakerID: TimeInterval]()) { durations, word in
                guard let speaker = word.speaker else { return }
                durations[speaker, default: 0] += max(0, word.endTime - word.startTime)
            }
            return durationsBySpeaker.max { lhs, rhs in lhs.value < rhs.value }?.key
        }

        private struct SegmentReference: Sendable {
            var speaker: SpeakerID
            var startTime: TimeInterval
            var endTime: TimeInterval
        }

        private struct WordReference: Sendable {
            var speaker: SpeakerID
            var startTime: TimeInterval
            var endTime: TimeInterval
        }

        private struct OverlapMetrics: Sendable {
            var overlap: TimeInterval
            var currentCoverage: Double
            var previousCoverage: Double
        }

        private struct SpeakerScore: Sendable {
            var speaker: SpeakerID
            var score: Double
            var overlap: TimeInterval
            var previousCoverage: Double
        }
    }

    private func dominantSpeaker(in words: [TranscriptWord]) -> SpeakerID? {
        let durationsBySpeaker = words.reduce(into: [SpeakerID: TimeInterval]()) { durations, word in
            guard let speaker = word.speaker else { return }
            durations[speaker, default: 0] += max(0, word.endTime - word.startTime)
        }
        return durationsBySpeaker.max { lhs, rhs in lhs.value < rhs.value }?.key
    }

    private func latestEnd(_ snapshot: StreamingTranscriptSnapshot) -> TimeInterval? {
        [
            latestEnd(snapshot.stable),
            latestEnd(snapshot.volatile),
            snapshot.volatileRange?.endTime
        ].compactMap { $0 }.max()
    }

    private func latestEnd(_ snapshot: StreamingDiarizationSnapshot) -> TimeInterval? {
        [
            latestEnd(snapshot.stable),
            latestEnd(snapshot.volatile),
            snapshot.volatileRange?.endTime
        ].compactMap { $0 }.max()
    }

    private func latestEnd(_ transcript: Transcript?) -> TimeInterval? {
        guard let transcript else { return nil }
        var ends = transcript.segments.map(\.endTime)
        if let duration = transcript.duration {
            ends.append(duration)
        }
        return ends.max()
    }

    private func latestEnd(_ diarization: DiarizationResult?) -> TimeInterval? {
        guard let diarization else { return nil }
        var ends = diarization.turns.map(\.endTime) + diarization.exclusiveTurns.map(\.endTime)
        ends.append(diarization.duration)
        return ends.max()
    }

    private func transcriptSegmentOrder(_ lhs: TranscriptSegment, _ rhs: TranscriptSegment) -> Bool {
        if lhs.startTime == rhs.startTime {
            return lhs.endTime < rhs.endTime
        }
        return lhs.startTime < rhs.startTime
    }

    private struct LockedStableAttribution: Sendable {
        var sourceFingerprint: TranscriptSegmentFingerprint
        var attributedSegments: [TranscriptSegment]
    }

    private struct TranscriptSegmentFingerprint: Hashable, Sendable {
        var text: String
        var startTime: TimeInterval
        var endTime: TimeInterval
        var words: [TranscriptWordFingerprint]
        var confidence: Double?

        init(segment: TranscriptSegment) {
            text = segment.text
            startTime = segment.startTime
            endTime = segment.endTime
            words = segment.words.map(TranscriptWordFingerprint.init)
            confidence = segment.confidence
        }
    }

    private struct TranscriptWordFingerprint: Hashable, Sendable {
        var text: String
        var startTime: TimeInterval
        var endTime: TimeInterval
        var confidence: Double?

        init(word: TranscriptWord) {
            text = word.text
            startTime = word.startTime
            endTime = word.endTime
            confidence = word.confidence
        }
    }

    private struct SpeakerTurnFingerprint: Hashable, Sendable {
        var speaker: SpeakerID
        var startTime: TimeInterval
        var endTime: TimeInterval
        var isExclusive: Bool
        var source: String?

        init(turn: SpeakerTurn) {
            speaker = turn.speaker
            startTime = turn.startTime
            endTime = turn.endTime
            isExclusive = turn.isExclusive
            source = turn.source
        }
    }
}
