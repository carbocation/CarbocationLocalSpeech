@_spi(Internal) import CarbocationLocalSpeech
import Foundation
#if CARBOCATION_HAS_WHISPER_C_API
import whisper
#endif

public struct WhisperEngineConfiguration: Hashable, Sendable {
    public var useMetal: Bool
    public var useCoreML: Bool
    public var threadCount: Int32?
    public var heartbeatInterval: TimeInterval
    public var suppressNativeLogs: Bool

    public init(
        useMetal: Bool = true,
        useCoreML: Bool = true,
        threadCount: Int32? = nil,
        heartbeatInterval: TimeInterval = 2,
        suppressNativeLogs: Bool = true
    ) {
        self.useMetal = useMetal
        self.useCoreML = useCoreML
        self.threadCount = threadCount
        self.heartbeatInterval = heartbeatInterval
        self.suppressNativeLogs = suppressNativeLogs
    }
}

public struct WhisperLoadConfiguration: Hashable, Sendable {
    public var language: String?
    public var useMetal: Bool
    public var useCoreML: Bool

    public init(language: String? = nil, useMetal: Bool = true, useCoreML: Bool = true) {
        self.language = language
        self.useMetal = useMetal
        self.useCoreML = useCoreML
    }
}

public struct WhisperLoadedModelInfo: Hashable, Sendable {
    public var modelID: UUID?
    public var modelPath: String
    public var displayName: String?
    public var backend: SpeechBackendDescriptor
    public var capabilities: SpeechModelCapabilities

    public init(
        modelID: UUID?,
        modelPath: String,
        displayName: String?,
        backend: SpeechBackendDescriptor,
        capabilities: SpeechModelCapabilities
    ) {
        self.modelID = modelID
        self.modelPath = modelPath
        self.displayName = displayName
        self.backend = backend
        self.capabilities = capabilities
    }
}

public enum WhisperEngineError: Error, LocalizedError, Sendable {
    case noModelLoaded
    case missingPrimaryWeights(UUID)
    case modelFileMissing(URL)
    case runtimeUnavailable(WhisperBackendStatus)
    case failedToLoadModel(String)
    case invalidSampleCount(Int)
    case transcriptionFailed(Int32)
    case unsupportedStreamingImplementation(StreamingImplementationPreference)

    public var errorDescription: String? {
        switch self {
        case .noModelLoaded:
            return "No whisper.cpp model is loaded."
        case .missingPrimaryWeights(let id):
            return "Installed speech model has no primary weights: \(id.uuidString)"
        case .modelFileMissing(let url):
            return "Whisper model file is missing: \(url.path)"
        case .runtimeUnavailable(let status):
            return status.displayDescription
        case .failedToLoadModel(let path):
            return "whisper.cpp could not load model at \(path)."
        case .invalidSampleCount(let count):
            return "Whisper audio buffer has too many samples: \(count)."
        case .transcriptionFailed(let code):
            return "whisper.cpp transcription failed with code \(code)."
        case .unsupportedStreamingImplementation(let implementation):
            return "Whisper does not support \(implementation.rawValue) streaming."
        }
    }
}

struct WhisperStreamingDecodeTuning: Hashable, Sendable {
    var singleSegment: Bool
    var maxTokens: Int32
    var audioContext: Int32

    static func resolve(for options: StreamingTranscriptionOptions) -> WhisperStreamingDecodeTuning {
        switch options.latencyPreset {
        case .lowestLatency:
            return WhisperStreamingDecodeTuning(singleSegment: true, maxTokens: 48, audioContext: 256)
        case .balancedDictation:
            return WhisperStreamingDecodeTuning(singleSegment: true, maxTokens: 96, audioContext: 512)
        case .accuracy:
            return WhisperStreamingDecodeTuning(singleSegment: false, maxTokens: 0, audioContext: 768)
        case .fileQuality:
            return WhisperStreamingDecodeTuning(singleSegment: false, maxTokens: 0, audioContext: 0)
        }
    }
}

private struct WhisperRunResult {
    var transcript: Transcript
#if CARBOCATION_HAS_WHISPER_C_API
    var promptTokens: [whisper_token]
#endif

#if CARBOCATION_HAS_WHISPER_C_API
    init(transcript: Transcript, promptTokens: [whisper_token] = []) {
        self.transcript = transcript
        self.promptTokens = promptTokens
    }
#else
    init(transcript: Transcript) {
        self.transcript = transcript
    }
#endif
}

private struct WhisperStreamingRunContext: Sendable {
    var chunkStartTime: TimeInterval
    var chunkDuration: TimeInterval
    var tuning: WhisperStreamingDecodeTuning
    var sessionState: WhisperStreamingSessionState
    var eventSink: @Sendable (TranscriptEvent) -> Void
}

private final class WhisperStreamingSessionState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
#if CARBOCATION_HAS_WHISPER_C_API
    private var promptTokens: [whisper_token] = []
#endif

    var promptTokenCount: Int {
#if CARBOCATION_HAS_WHISPER_C_API
        lock.lock()
        defer { lock.unlock() }
        return promptTokens.count
#else
        return 0
#endif
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

#if CARBOCATION_HAS_WHISPER_C_API
    func currentPromptTokens() -> [whisper_token] {
        lock.lock()
        defer { lock.unlock() }
        return promptTokens
    }

    func updatePromptTokens(_ tokens: [whisper_token], limit: Int) {
        guard !tokens.isEmpty else { return }
        lock.lock()
        promptTokens = Array(tokens.suffix(max(1, limit)))
        lock.unlock()
    }
#endif
}

public actor WhisperEngine: @preconcurrency CarbocationLocalSpeech.SpeechTranscriber {
    public static let shared = WhisperEngine()

    private let configuration: WhisperEngineConfiguration
    private var loadedInfo: WhisperLoadedModelInfo?
    private var loadedConfiguration: WhisperLoadConfiguration?
#if CARBOCATION_HAS_WHISPER_C_API
    private var context: OpaquePointer?
    private var contextModelPath: String?
#endif

    public init(configuration: WhisperEngineConfiguration = WhisperEngineConfiguration()) {
        self.configuration = configuration
    }

    deinit {
#if CARBOCATION_HAS_WHISPER_C_API
        if let context {
            whisper_free(context)
        }
#endif
    }

    public func currentModelID() -> UUID? {
        loadedInfo?.modelID
    }

    public func currentLoadedModelInfo() -> WhisperLoadedModelInfo? {
        loadedInfo
    }

    public func preload() throws {
        guard let loadedInfo else {
            throw WhisperEngineError.noModelLoaded
        }

        let status = WhisperBackend.ensureInitialized()
        guard status.isUsable else {
            throw WhisperEngineError.runtimeUnavailable(status)
        }

#if CARBOCATION_HAS_WHISPER_C_API
        _ = try ensureContext(for: loadedInfo)
#else
        throw WhisperEngineError.runtimeUnavailable(status)
#endif
    }

    @discardableResult
    public func load(
        model: InstalledSpeechModel,
        from root: URL,
        configuration loadConfiguration: WhisperLoadConfiguration = WhisperLoadConfiguration()
    ) throws -> WhisperLoadedModelInfo {
        guard let modelURL = model.primaryWeightsURL(in: root) else {
            throw WhisperEngineError.missingPrimaryWeights(model.id)
        }
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw WhisperEngineError.modelFileMissing(modelURL)
        }

        let backend = SpeechBackendDescriptor(
            kind: .whisperCpp,
            displayName: "whisper.cpp",
            version: nil,
            selection: .installed(model.id)
        )
        let info = WhisperLoadedModelInfo(
            modelID: model.id,
            modelPath: modelURL.path,
            displayName: model.displayName,
            backend: backend,
            capabilities: model.capabilities
        )
#if CARBOCATION_HAS_WHISPER_C_API
        if contextModelPath != modelURL.path {
            freeContext()
        }
#endif
        loadedInfo = info
        loadedConfiguration = loadConfiguration
        _ = loadConfiguration
        return info
    }

    public func unload() {
#if CARBOCATION_HAS_WHISPER_C_API
        freeContext()
#endif
        loadedInfo = nil
        loadedConfiguration = nil
    }

    public func transcribe(file url: URL, options: TranscriptionOptions) async throws -> Transcript {
        let status = WhisperBackend.ensureInitialized()
        guard status.isUsable else {
            throw WhisperEngineError.runtimeUnavailable(status)
        }
        let prepared = try await AudioResampler16kMono().prepareFile(at: url)
        return try await transcribe(audio: prepared, options: options)
    }

    public func transcribe(audio: PreparedAudio, options: TranscriptionOptions) async throws -> Transcript {
        try transcribePreparedAudio(audio, options: options, streamingContext: nil).transcript
    }

    private func transcribePreparedAudio(
        _ audio: PreparedAudio,
        options: TranscriptionOptions,
        streamingContext: WhisperStreamingRunContext?
    ) throws -> WhisperRunResult {
        guard let loadedInfo else {
            throw WhisperEngineError.noModelLoaded
        }

        if options.suppressBlankAudio,
           AudioLevelMeter.measure(samples: audio.samples).peak < 0.000_01 {
            let transcript = Transcript(
                segments: [],
                duration: audio.duration,
                backend: loadedInfo.backend
            )
            if let streamingContext {
                streamingContext.eventSink(.diagnostic(TranscriptionDiagnostic(
                    source: "whisper.streaming",
                    message: "suppressed blank chunk",
                    time: streamingContext.chunkStartTime
                )))
            }
            return WhisperRunResult(transcript: transcript)
        }

        let status = WhisperBackend.ensureInitialized()
        guard status.isUsable else {
            throw WhisperEngineError.runtimeUnavailable(status)
        }

#if CARBOCATION_HAS_WHISPER_C_API
        let normalizedAudio = try normalizeAudio(audio)
        guard !normalizedAudio.samples.isEmpty else {
            return WhisperRunResult(transcript: Transcript(
                segments: [],
                duration: normalizedAudio.duration,
                backend: loadedInfo.backend
            ))
        }
        guard normalizedAudio.samples.count <= Int(Int32.max) else {
            throw WhisperEngineError.invalidSampleCount(normalizedAudio.samples.count)
        }

        let context = try ensureContext(for: loadedInfo)
        return try runWhisper(
            context: context,
            audio: normalizedAudio,
            options: options,
            backend: loadedInfo.backend,
            streamingContext: streamingContext
        )
#else
        _ = streamingContext
        throw WhisperEngineError.runtimeUnavailable(status)
#endif
    }

    public func stream(
        audio: AsyncThrowingStream<AudioChunk, Error>,
        options: StreamingTranscriptionOptions
    ) -> AsyncThrowingStream<TranscriptEvent, Error> {
        guard options.implementation != .native else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: WhisperEngineError.unsupportedStreamingImplementation(.native))
            }
        }

        let loadedInfo = loadedInfo
        guard let loadedInfo else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: WhisperEngineError.noModelLoaded)
            }
        }

        var effectiveOptions = options
        if effectiveOptions.commitment == .automatic {
            effectiveOptions.commitment = .localAgreement(iterations: 2)
        }
        let resolvedOptions = effectiveOptions

        let engine = self
        let streamingState = WhisperStreamingSessionState()
        let tuning = WhisperStreamingDecodeTuning.resolve(for: resolvedOptions)
        return AsyncThrowingStream { continuation in
            let task = Task {
                let pipelineStream = SpeechChunkStreamingPipeline.stream(
                    audio: audio,
                    backend: loadedInfo.backend,
                    options: resolvedOptions,
                    transcribeTimed: { emitted, transcriptionOptions in
                        let context = WhisperStreamingRunContext(
                            chunkStartTime: emitted.startTime,
                            chunkDuration: emitted.audio.duration,
                            tuning: tuning,
                            sessionState: streamingState,
                            eventSink: { event in
                                continuation.yield(event)
                            }
                        )
                        return try await engine.transcribeStreamingChunk(
                            emitted.audio,
                            options: transcriptionOptions,
                            context: context
                        )
                    })

                do {
                    for try await event in pipelineStream {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                streamingState.cancel()
                task.cancel()
            }
        }
    }

    private func transcribeStreamingChunk(
        _ audio: PreparedAudio,
        options: TranscriptionOptions,
        context: WhisperStreamingRunContext
    ) throws -> Transcript {
        try Task.checkCancellation()
        context.eventSink(.diagnostic(TranscriptionDiagnostic(
            source: "whisper.streaming",
            message: "chunk duration=\(audio.duration.formattedWhisperDebug)s audio_ctx=\(context.tuning.audioContext) max_tokens=\(context.tuning.maxTokens) single_segment=\(context.tuning.singleSegment) prompt_tokens=\(context.sessionState.promptTokenCount)",
            time: context.chunkStartTime
        )))
        return try transcribePreparedAudio(audio, options: options, streamingContext: context).transcript
    }
}

#if CARBOCATION_HAS_WHISPER_C_API
private final class WhisperStreamingCallbackBox: @unchecked Sendable {
    private let lock = NSLock()
    private let chunkStartTime: TimeInterval
    private let chunkDuration: TimeInterval
    private let includeWords: Bool
    private let eventSink: @Sendable (TranscriptEvent) -> Void
    private var deliveredSegmentCount = 0
    private var pendingPartialID: UUID?
    private var lastProgressBucket = -1

    init(
        chunkStartTime: TimeInterval,
        chunkDuration: TimeInterval,
        includeWords: Bool,
        eventSink: @escaping @Sendable (TranscriptEvent) -> Void
    ) {
        self.chunkStartTime = chunkStartTime
        self.chunkDuration = chunkDuration
        self.includeWords = includeWords
        self.eventSink = eventSink
    }

    func emitNewSegments(context: OpaquePointer, state: OpaquePointer, nNew: Int32) {
        let total = max(0, Int(whisper_full_n_segments_from_state(state)))
        let requestedStart = max(0, total - max(0, Int(nNew)))

        let event: TranscriptEvent?
        lock.lock()
        let start = max(deliveredSegmentCount, requestedStart)
        guard start < total else {
            lock.unlock()
            return
        }
        let segments = (start..<total).compactMap { segmentIndex in
            Self.segment(
                context: context,
                state: state,
                index: segmentIndex,
                includeWords: includeWords,
                offset: chunkStartTime
            )
        }
        deliveredSegmentCount = total
        guard let first = segments.first,
              let last = segments.last else {
            lock.unlock()
            return
        }
        let partial = TranscriptPartial(
            text: segments.map(\.text).joined(separator: " "),
            startTime: first.startTime,
            endTime: last.endTime,
            stability: 0.35
        )
        if let pendingPartialID {
            event = .revision(TranscriptRevision(
                replacesPartialID: pendingPartialID,
                replacement: partial
            ))
        } else {
            event = .partial(partial)
        }
        pendingPartialID = partial.id
        lock.unlock()

        if let event {
            eventSink(event)
        }
    }

    func emitProgress(_ progress: Int32) {
        let bucket = Int(progress / 10)
        let event: TranscriptEvent?
        lock.lock()
        guard bucket > lastProgressBucket || progress >= 100 else {
            lock.unlock()
            return
        }
        lastProgressBucket = bucket
        let processed = chunkStartTime + chunkDuration * min(1, max(0, Double(progress) / 100))
        event = .progress(TranscriptionProgress(processedDuration: processed))
        lock.unlock()

        if let event {
            eventSink(event)
        }
    }

    private static func segment(
        context: OpaquePointer,
        state: OpaquePointer,
        index: Int,
        includeWords: Bool,
        offset: TimeInterval
    ) -> TranscriptSegment? {
        let textPointer = whisper_full_get_segment_text_from_state(state, Int32(index))
        let text = textPointer.map { String(cString: $0) } ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let startTime = whisperTimeToSeconds(whisper_full_get_segment_t0_from_state(state, Int32(index))) + offset
        let endTime = whisperTimeToSeconds(whisper_full_get_segment_t1_from_state(state, Int32(index))) + offset
        return TranscriptSegment(
            text: text,
            startTime: startTime,
            endTime: max(startTime, endTime),
            words: includeWords ? words(context: context, state: state, segmentIndex: index, offset: offset) : [],
            confidence: averageConfidence(state: state, segmentIndex: index)
        )
    }

    private static func words(
        context: OpaquePointer,
        state: OpaquePointer,
        segmentIndex: Int,
        offset: TimeInterval
    ) -> [TranscriptWord] {
        let count = max(0, Int(whisper_full_n_tokens_from_state(state, Int32(segmentIndex))))
        var words: [TranscriptWord] = []
        words.reserveCapacity(count)

        for tokenIndex in 0..<count {
            let data = whisper_full_get_token_data_from_state(state, Int32(segmentIndex), Int32(tokenIndex))
            guard data.t0 >= 0, data.t1 >= data.t0 else { continue }

            let textPointer = whisper_full_get_token_text_from_state(context, state, Int32(segmentIndex), Int32(tokenIndex))
            let text = textPointer.map { String(cString: $0) } ?? ""
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            words.append(TranscriptWord(
                text: text,
                startTime: whisperTimeToSeconds(data.t0) + offset,
                endTime: whisperTimeToSeconds(data.t1) + offset,
                confidence: Double(data.p)
            ))
        }

        return words
    }

    private static func averageConfidence(state: OpaquePointer, segmentIndex: Int) -> Double? {
        let count = max(0, Int(whisper_full_n_tokens_from_state(state, Int32(segmentIndex))))
        guard count > 0 else { return nil }

        var total: Float = 0
        for tokenIndex in 0..<count {
            total += whisper_full_get_token_p_from_state(state, Int32(segmentIndex), Int32(tokenIndex))
        }
        return Double(total / Float(count))
    }

    private static func whisperTimeToSeconds(_ value: Int64) -> TimeInterval {
        Double(value) / 100
    }
}

private let whisperStreamingNewSegmentCallback: whisper_new_segment_callback = { context, state, nNew, userData in
    guard let context, let state, let userData else { return }
    let box = Unmanaged<WhisperStreamingCallbackBox>.fromOpaque(userData).takeUnretainedValue()
    box.emitNewSegments(context: context, state: state, nNew: nNew)
}

private let whisperStreamingProgressCallback: whisper_progress_callback = { _, _, progress, userData in
    guard let userData else { return }
    let box = Unmanaged<WhisperStreamingCallbackBox>.fromOpaque(userData).takeUnretainedValue()
    box.emitProgress(progress)
}

private let whisperStreamingAbortCallback: ggml_abort_callback = { userData in
    guard let userData else { return false }
    let state = Unmanaged<WhisperStreamingSessionState>.fromOpaque(userData).takeUnretainedValue()
    return state.isCancelled
}

private extension WhisperEngine {
    func ensureContext(for loadedInfo: WhisperLoadedModelInfo) throws -> OpaquePointer {
        if let context, contextModelPath == loadedInfo.modelPath {
            return context
        }

        freeContext()
        configureNativeLogging()
        var params = whisper_context_default_params()
        params.use_gpu = loadedConfiguration?.useMetal ?? configuration.useMetal

        guard let context = loadedInfo.modelPath.withCString({ modelPath in
            whisper_init_from_file_with_params(modelPath, params)
        }) else {
            throw WhisperEngineError.failedToLoadModel(loadedInfo.modelPath)
        }

        self.context = context
        contextModelPath = loadedInfo.modelPath
        return context
    }

    func freeContext() {
        if let context {
            whisper_free(context)
        }
        context = nil
        contextModelPath = nil
    }

    func configureNativeLogging() {
        if configuration.suppressNativeLogs {
            whisper_log_set({ _, _, _ in }, nil)
        } else {
            whisper_log_set(nil, nil)
        }
    }

    func normalizeAudio(_ audio: PreparedAudio) throws -> PreparedAudio {
        guard abs(audio.sampleRate - Double(WHISPER_SAMPLE_RATE)) > 0.0001 else {
            return audio
        }

        let chunk = AudioChunk(
            samples: audio.samples,
            sampleRate: audio.sampleRate,
            channelCount: 1,
            startTime: 0,
            duration: audio.duration
        )
        let resampled = try AudioResampler16kMono(targetSampleRate: Double(WHISPER_SAMPLE_RATE)).prepareChunk(chunk)
        return PreparedAudio(
            samples: resampled.samples,
            sampleRate: resampled.sampleRate,
            duration: resampled.duration
        )
    }

    func runWhisper(
        context: OpaquePointer,
        audio: PreparedAudio,
        options: TranscriptionOptions,
        backend: SpeechBackendDescriptor,
        streamingContext: WhisperStreamingRunContext?
    ) throws -> WhisperRunResult {
        let language = normalizedLanguage(options.language ?? loadedConfiguration?.language)
        let prompt = normalizedPrompt(options)
        let streamingPromptTokens = streamingContext.map {
            promptTokens(
                context: context,
                prompt: prompt,
                streamingContext: $0
            )
        }

        return try withOptionalCString(language) { languagePointer in
            try withOptionalCString(streamingPromptTokens?.isEmpty == false ? nil : prompt) { promptPointer in
                try withPromptTokens(streamingPromptTokens ?? []) { promptTokenPointer, promptTokenCount in
                    var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
                    params.n_threads = threadCount()
                    params.translate = options.task == .translate
                    params.no_timestamps = false
                    params.token_timestamps = options.timestampMode == .words
                    params.print_special = false
                    params.print_progress = false
                    params.print_realtime = false
                    params.print_timestamps = false
                    params.suppress_blank = options.suppressBlankAudio
                    params.language = languagePointer
                    params.detect_language = languagePointer == nil
                    params.initial_prompt = promptPointer
                    params.prompt_tokens = promptTokenPointer
                    params.prompt_n_tokens = promptTokenCount
                    if let temperature = options.temperature {
                        params.temperature = Float(temperature)
                    }
                    applyStreamingContext(
                        streamingContext,
                        to: &params,
                        context: context,
                        includeWords: options.timestampMode == .words
                    )

                    let callbackBox = streamingContext.map {
                        WhisperStreamingCallbackBox(
                            chunkStartTime: $0.chunkStartTime,
                            chunkDuration: audio.duration,
                            includeWords: options.timestampMode == .words,
                            eventSink: $0.eventSink
                        )
                    }
                    if let callbackBox {
                        params.new_segment_callback = whisperStreamingNewSegmentCallback
                        params.new_segment_callback_user_data = Unmanaged.passUnretained(callbackBox).toOpaque()
                        params.progress_callback = whisperStreamingProgressCallback
                        params.progress_callback_user_data = Unmanaged.passUnretained(callbackBox).toOpaque()
                    }
                    if let sessionState = streamingContext?.sessionState {
                        params.abort_callback = whisperStreamingAbortCallback
                        params.abort_callback_user_data = Unmanaged.passUnretained(sessionState).toOpaque()
                    }

                    let result = withExtendedLifetime(callbackBox) {
                        withExtendedLifetime(streamingContext?.sessionState) {
                            audio.samples.withUnsafeBufferPointer { buffer in
                                whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
                            }
                        }
                    }
                    guard result == 0 else {
                        if streamingContext?.sessionState.isCancelled == true {
                            throw CancellationError()
                        }
                        throw WhisperEngineError.transcriptionFailed(result)
                    }

                    let transcript = Transcript(
                        segments: transcriptSegments(
                            context: context,
                            includeWords: options.timestampMode == .words
                        ),
                        language: detectedLanguage(context: context),
                        duration: audio.duration,
                        backend: backend
                    )
                    let promptTokens = decodedPromptTokens(context: context)
                    streamingContext?.sessionState.updatePromptTokens(
                        promptTokens,
                        limit: promptTokenLimit(context: context)
                    )
                    return WhisperRunResult(transcript: transcript, promptTokens: promptTokens)
                }
            }
        }
    }

    func applyStreamingContext(
        _ streamingContext: WhisperStreamingRunContext?,
        to params: inout whisper_full_params,
        context: OpaquePointer,
        includeWords: Bool
    ) {
        guard let streamingContext else { return }
        let tuning = streamingContext.tuning
        params.single_segment = tuning.singleSegment
        params.max_tokens = tuning.maxTokens
        params.no_context = true
        params.carry_initial_prompt = false
        params.audio_ctx = clampedAudioContext(tuning.audioContext, context: context)
        if includeWords {
            params.single_segment = false
        }
    }

    func transcriptSegments(context: OpaquePointer, includeWords: Bool) -> [TranscriptSegment] {
        let count = max(0, Int(whisper_full_n_segments(context)))
        var segments: [TranscriptSegment] = []
        segments.reserveCapacity(count)

        for index in 0..<count {
            let textPointer = whisper_full_get_segment_text(context, Int32(index))
            let text = textPointer.map { String(cString: $0) } ?? ""
            let startTime = whisperTimeToSeconds(whisper_full_get_segment_t0(context, Int32(index)))
            let endTime = whisperTimeToSeconds(whisper_full_get_segment_t1(context, Int32(index)))
            let words = includeWords ? transcriptWords(context: context, segmentIndex: index) : []

            segments.append(
                TranscriptSegment(
                    text: text,
                    startTime: startTime,
                    endTime: endTime,
                    words: words,
                    confidence: averageConfidence(context: context, segmentIndex: index)
                )
            )
        }

        return segments
    }

    func decodedPromptTokens(context: OpaquePointer) -> [whisper_token] {
        let segmentCount = max(0, Int(whisper_full_n_segments(context)))
        let eot = whisper_token_eot(context)
        var tokens: [whisper_token] = []

        for segmentIndex in 0..<segmentCount {
            let tokenCount = max(0, Int(whisper_full_n_tokens(context, Int32(segmentIndex))))
            for tokenIndex in 0..<tokenCount {
                let id = whisper_full_get_token_id(context, Int32(segmentIndex), Int32(tokenIndex))
                guard id >= 0, id < eot else { continue }
                tokens.append(id)
            }
        }

        return tokens
    }

    func transcriptWords(context: OpaquePointer, segmentIndex: Int) -> [TranscriptWord] {
        let count = max(0, Int(whisper_full_n_tokens(context, Int32(segmentIndex))))
        var words: [TranscriptWord] = []
        words.reserveCapacity(count)

        for tokenIndex in 0..<count {
            let data = whisper_full_get_token_data(context, Int32(segmentIndex), Int32(tokenIndex))
            guard data.t0 >= 0, data.t1 >= data.t0 else { continue }

            let textPointer = whisper_full_get_token_text(context, Int32(segmentIndex), Int32(tokenIndex))
            let text = textPointer.map { String(cString: $0) } ?? ""
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            words.append(
                TranscriptWord(
                    text: text,
                    startTime: whisperTimeToSeconds(data.t0),
                    endTime: whisperTimeToSeconds(data.t1),
                    confidence: Double(data.p)
                )
            )
        }

        return words
    }

    func averageConfidence(context: OpaquePointer, segmentIndex: Int) -> Double? {
        let count = max(0, Int(whisper_full_n_tokens(context, Int32(segmentIndex))))
        guard count > 0 else { return nil }

        var total: Float = 0
        for tokenIndex in 0..<count {
            total += whisper_full_get_token_p(context, Int32(segmentIndex), Int32(tokenIndex))
        }
        return Double(total / Float(count))
    }

    func detectedLanguage(context: OpaquePointer) -> SpeechLanguage? {
        let languageID = whisper_full_lang_id(context)
        guard languageID >= 0, let codePointer = whisper_lang_str(languageID) else {
            return nil
        }
        let code = String(cString: codePointer)
        return SpeechLanguage(code: code)
    }

    func threadCount() -> Int32 {
        if let threadCount = configuration.threadCount {
            return max(1, threadCount)
        }
        return Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 1)))
    }

    func normalizedLanguage(_ language: String?) -> String? {
        guard let language = language?.trimmingCharacters(in: .whitespacesAndNewlines),
              !language.isEmpty,
              language.lowercased() != "auto"
        else {
            return nil
        }
        return language
    }

    func normalizedPrompt(_ options: TranscriptionOptions) -> String? {
        var pieces: [String] = []
        if let initialPrompt = options.initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !initialPrompt.isEmpty {
            pieces.append(initialPrompt)
        }
        if !options.contextualStrings.isEmpty {
            pieces.append(options.contextualStrings.joined(separator: "\n"))
        }
        guard !pieces.isEmpty else { return nil }
        return pieces.joined(separator: "\n")
    }

    func promptTokens(
        context: OpaquePointer,
        prompt: String?,
        streamingContext: WhisperStreamingRunContext
    ) -> [whisper_token] {
        let explicitPromptTokens = prompt.map { tokenizePrompt($0, context: context) } ?? []
        let previousTokens = streamingContext.sessionState.currentPromptTokens()
        let combined = explicitPromptTokens + previousTokens
        guard !combined.isEmpty else { return [] }
        return Array(combined.suffix(promptTokenLimit(context: context)))
    }

    func tokenizePrompt(_ prompt: String, context: OpaquePointer) -> [whisper_token] {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        func tokenize(capacity: Int) -> (needed: Int32, tokens: [whisper_token]) {
            var tokens = Array(repeating: whisper_token(0), count: capacity)
            let needed = trimmed.withCString { pointer in
                whisper_tokenize(context, pointer, &tokens, Int32(tokens.count))
            }
            return (needed, tokens)
        }

        var result = tokenize(capacity: 256)
        if result.needed < 0 {
            result = tokenize(capacity: Int(-result.needed))
        }
        guard result.needed > 0 else { return [] }
        return Array(result.tokens.prefix(Int(result.needed)))
    }

    func promptTokenLimit(context: OpaquePointer) -> Int {
        max(1, Int(whisper_n_text_ctx(context)) / 2 - 1)
    }

    func clampedAudioContext(_ requested: Int32, context: OpaquePointer) -> Int32 {
        guard requested > 0 else { return 0 }
        return min(requested, Int32(max(0, whisper_n_audio_ctx(context))))
    }

    func whisperTimeToSeconds(_ value: Int64) -> TimeInterval {
        Double(value) / 100
    }

    func withOptionalCString<Result>(
        _ value: String?,
        _ body: (UnsafePointer<CChar>?) throws -> Result
    ) rethrows -> Result {
        guard let value else {
            return try body(nil)
        }
        return try value.withCString { pointer in
            try body(pointer)
        }
    }

    func withPromptTokens<Result>(
        _ tokens: [whisper_token],
        _ body: (UnsafePointer<whisper_token>?, Int32) throws -> Result
    ) rethrows -> Result {
        guard !tokens.isEmpty else {
            return try body(nil, 0)
        }
        return try tokens.withUnsafeBufferPointer { buffer in
            try body(buffer.baseAddress, Int32(buffer.count))
        }
    }
}
#endif

private extension Double {
    var formattedWhisperDebug: String {
        String(format: "%.3f", self)
    }
}
