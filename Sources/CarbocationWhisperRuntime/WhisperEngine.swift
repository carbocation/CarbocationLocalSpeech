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
    public var vadModelPath: String?
    public var displayName: String?
    public var backend: SpeechBackendDescriptor
    public var capabilities: SpeechModelCapabilities

    public init(
        modelID: UUID?,
        modelPath: String,
        vadModelPath: String? = nil,
        displayName: String?,
        backend: SpeechBackendDescriptor,
        capabilities: SpeechModelCapabilities
    ) {
        self.modelID = modelID
        self.modelPath = modelPath
        self.vadModelPath = vadModelPath
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
    case unsupportedStreamingMode(String)

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
        case .unsupportedStreamingMode(let mode):
            return "Whisper does not support \(mode) streaming."
        }
    }
}

struct WhisperStreamingDecodeTuning: Hashable, Sendable {
    var singleSegment: Bool
    var maxTokens: Int32
    var audioContext: Int32
    var decoderContextTokenLimit: Int32

    static func resolve(for options: StreamingTranscriptionOptions) -> WhisperStreamingDecodeTuning {
        switch options.strategy {
        case .automatic, .balanced:
            return WhisperStreamingDecodeTuning(
                singleSegment: false,
                maxTokens: 0,
                audioContext: 0,
                decoderContextTokenLimit: 96
            )
        case .lowestLatency:
            return WhisperStreamingDecodeTuning(
                singleSegment: true,
                maxTokens: 32,
                audioContext: 256,
                decoderContextTokenLimit: 48
            )
        case .accurate:
            return WhisperStreamingDecodeTuning(
                singleSegment: false,
                maxTokens: 0,
                audioContext: 0,
                decoderContextTokenLimit: 160
            )
        case .fileQuality:
            return WhisperStreamingDecodeTuning(
                singleSegment: false,
                maxTokens: 0,
                audioContext: 0,
                decoderContextTokenLimit: 160
            )
        }
    }
}

struct WhisperVADTuning: Hashable, Sendable {
    var threshold: Float
    var minSpeechDurationMS: Int32
    var minSilenceDurationMS: Int32
    var speechPadMS: Int32
    var samplesOverlap: Float

    static func resolve(for sensitivity: VoiceActivityDetectionSensitivity) -> WhisperVADTuning {
        switch sensitivity {
        case .low:
            return WhisperVADTuning(
                threshold: 0.65,
                minSpeechDurationMS: 300,
                minSilenceDurationMS: 200,
                speechPadMS: 20,
                samplesOverlap: 0.05
            )
        case .medium:
            return WhisperVADTuning(
                threshold: 0.5,
                minSpeechDurationMS: 250,
                minSilenceDurationMS: 100,
                speechPadMS: 30,
                samplesOverlap: 0.1
            )
        case .high:
            return WhisperVADTuning(
                threshold: 0.35,
                minSpeechDurationMS: 150,
                minSilenceDurationMS: 80,
                speechPadMS: 60,
                samplesOverlap: 0.15
            )
        }
    }
}

enum WhisperInnerVADPolicy {
    static func shouldUseModelVAD(options: TranscriptionOptions, isStreaming: Bool) -> Bool {
        guard !isStreaming else {
            return false
        }

        switch options.voiceActivityDetection.mode {
        case .enabled:
            return true
        case .disabled, .automatic:
            return false
        }
    }
}

enum WhisperOuterVADSelection: Hashable, Sendable {
    case disabled
    case whisper
    case energyFallback(reason: String)

    static func resolve(
        mode: VoiceActivityDetectionMode,
        vadModelPath: String?
    ) -> WhisperOuterVADSelection {
        switch mode {
        case .disabled:
            return .disabled
        case .automatic, .enabled:
            guard vadModelPath != nil else {
                return .energyFallback(reason: "missing-vad-model")
            }
            return .whisper
        }
    }
}

struct WhisperStreamingOptionsResolver {
    static func resolve(_ options: StreamingTranscriptionOptions) -> StreamingTranscriptionOptions {
        var resolved = options

        if resolved.implementation == .automatic {
            switch resolved.transcription.voiceActivityDetection.mode {
            case .disabled:
                resolved.emulation = options.strategy.defaultEmulatedStreamingOptions
            case .automatic, .enabled:
                resolved.emulation = EmulatedStreamingOptions(
                    window: .vadUtterances(options.strategy.defaultChunkingConfiguration)
                )
            }
        }

        if resolved.commitment == .automatic {
            resolved.commitment = .localAgreement(iterations: 2)
        }

        return resolved
    }
}

private struct WhisperRunResult {
    var transcript: Transcript

    init(transcript: Transcript) {
        self.transcript = transcript
    }
}

private struct WhisperStreamingRunContext: Sendable {
    var chunkStartTime: TimeInterval
    var chunkDuration: TimeInterval
    var tuning: WhisperStreamingDecodeTuning
    var keepsDecoderContext: Bool
    var resetDecoderContext: Bool
    var sessionState: WhisperStreamingSessionState
    var eventSink: @Sendable (TranscriptEvent) -> Void
}

private final class WhisperStreamingSessionState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var hasStartedDecoderContext = false

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

    func claimDecoderContextReset() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !hasStartedDecoderContext else {
            return false
        }
        hasStartedDecoderContext = true
        return true
    }
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
        let resolvedVADModelURL = model.vadWeightsURL(in: root)
        let vadModelPath = resolvedVADModelURL.flatMap {
            FileManager.default.fileExists(atPath: $0.path) ? $0.path : nil
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
            vadModelPath: vadModelPath,
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
            vadModelPath: loadedInfo.vadModelPath,
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
                continuation.finish(throwing: WhisperEngineError.unsupportedStreamingMode("native"))
            }
        }

        let loadedInfo = loadedInfo
        guard let loadedInfo else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: WhisperEngineError.noModelLoaded)
            }
        }

        let resolvedOptions = WhisperStreamingOptionsResolver.resolve(options)

        let engine = self
        let streamingState = WhisperStreamingSessionState()
        let tuning = WhisperStreamingDecodeTuning.resolve(for: resolvedOptions)
        let keepsDecoderContext = Self.shouldKeepDecoderContext(for: resolvedOptions)
        let outerVAD = makeOuterVoiceActivityDetector(
            loadedInfo: loadedInfo,
            options: resolvedOptions
        )
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
                            keepsDecoderContext: keepsDecoderContext,
                            resetDecoderContext: streamingState.claimDecoderContextReset(),
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
                    },
                    voiceActivityDetector: outerVAD.detector,
                    startupDiagnostics: outerVAD.diagnostics)

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

    private func makeOuterVoiceActivityDetector(
        loadedInfo: WhisperLoadedModelInfo,
        options: StreamingTranscriptionOptions
    ) -> (detector: VoiceActivityDetecting?, diagnostics: [TranscriptionDiagnostic]) {
        var diagnostics: [TranscriptionDiagnostic] = [
            TranscriptionDiagnostic(
                source: "whisper.streaming",
                message: "inner_whisper_vad=false"
            )
        ]

        switch WhisperOuterVADSelection.resolve(
            mode: options.transcription.voiceActivityDetection.mode,
            vadModelPath: loadedInfo.vadModelPath
        ) {
        case .disabled:
            diagnostics.append(TranscriptionDiagnostic(
                source: "whisper.streaming",
                message: "outer_vad=disabled"
            ))
            return (nil, diagnostics)
        case .energyFallback(let reason):
            diagnostics.append(TranscriptionDiagnostic(
                source: "whisper.streaming",
                message: "outer_vad=energy-fallback reason=\(reason)"
            ))
            return (nil, diagnostics)
        case .whisper:
#if CARBOCATION_HAS_WHISPER_C_API
            guard let vadModelPath = loadedInfo.vadModelPath else {
                diagnostics.append(TranscriptionDiagnostic(
                    source: "whisper.streaming",
                    message: "outer_vad=energy-fallback reason=missing-vad-model"
                ))
                return (nil, diagnostics)
            }

            do {
                configureNativeLogging()
                let detector = try WhisperVoiceActivityDetector(
                    modelPath: vadModelPath,
                    sensitivity: options.transcription.voiceActivityDetection.sensitivity,
                    threadCount: threadCount(isStreaming: true)
                )
                diagnostics.append(TranscriptionDiagnostic(
                    source: "whisper.streaming",
                    message: "outer_vad=whisper"
                ))
                return (detector, diagnostics)
            } catch {
                diagnostics.append(TranscriptionDiagnostic(
                    source: "whisper.streaming",
                    message: "outer_vad=energy-fallback reason=init-failed"
                ))
                return (nil, diagnostics)
            }
#else
            diagnostics.append(TranscriptionDiagnostic(
                source: "whisper.streaming",
                message: "outer_vad=energy-fallback reason=runtime-unavailable"
            ))
            return (nil, diagnostics)
#endif
        }
    }

    private nonisolated static func shouldKeepDecoderContext(for options: StreamingTranscriptionOptions) -> Bool {
        switch options.emulation.window {
        case .rollingBuffer:
            return true
        case .vadUtterances:
            return false
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
            message: "chunk duration=\(audio.duration.formattedWhisperDebug)s audio_ctx=\(context.tuning.audioContext) max_tokens=\(context.tuning.maxTokens) single_segment=\(context.tuning.singleSegment) decoder_context=\(context.keepsDecoderContext)",
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
    private let eventSink: @Sendable (TranscriptEvent) -> Void
    private var lastProgressBucket = -1

    init(
        chunkStartTime: TimeInterval,
        chunkDuration: TimeInterval,
        eventSink: @escaping @Sendable (TranscriptEvent) -> Void
    ) {
        self.chunkStartTime = chunkStartTime
        self.chunkDuration = chunkDuration
        self.eventSink = eventSink
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
}

enum WhisperVoiceActivityDetectorError: Error, LocalizedError, Sendable {
    case failedToLoadModel(String)
    case detectionFailed

    var errorDescription: String? {
        switch self {
        case .failedToLoadModel(let path):
            return "whisper.cpp VAD could not load model at \(path)."
        case .detectionFailed:
            return "whisper.cpp VAD detection failed."
        }
    }
}

final class WhisperVoiceActivityDetector: VoiceActivityDetecting, VoiceActivityDetectionStateResetting, @unchecked Sendable {
    private let lock = NSLock()
    private let tuning: WhisperVADTuning
    private let resampler = AudioResampler16kMono(targetSampleRate: Double(WHISPER_SAMPLE_RATE))
    private var context: OpaquePointer?
    private var lastInputEndTime: TimeInterval?

    init(
        modelPath: String,
        sensitivity: VoiceActivityDetectionSensitivity,
        threadCount: Int32
    ) throws {
        self.tuning = WhisperVADTuning.resolve(for: sensitivity)

        var params = whisper_vad_default_context_params()
        params.n_threads = CInt(max(1, threadCount))
        params.use_gpu = false

        let context = modelPath.withCString { path in
            whisper_vad_init_from_file_with_params(path, params)
        }
        guard let context else {
            throw WhisperVoiceActivityDetectorError.failedToLoadModel(modelPath)
        }
        self.context = context
    }

    deinit {
        if let context {
            whisper_vad_free(context)
        }
    }

    func analyze(_ chunk: AudioChunk) throws -> VoiceActivityEvent {
        let prepared = try resampler.prepareChunk(chunk)
        let probability = try detectSpeechProbability(
            prepared,
            sourceStartTime: chunk.startTime,
            sourceDuration: chunk.duration
        )
        return VoiceActivityEvent(
            state: probability >= tuning.threshold ? .speech : .silence,
            startTime: chunk.startTime,
            endTime: chunk.startTime + chunk.duration,
            confidence: Double(probability)
        )
    }

    func resetVoiceActivityState() {
        lock.lock()
        defer { lock.unlock() }

        if let context {
            whisper_vad_reset_state(context)
        }
        lastInputEndTime = nil
    }

    private func detectSpeechProbability(
        _ chunk: AudioChunk,
        sourceStartTime: TimeInterval,
        sourceDuration: TimeInterval
    ) throws -> Float {
        guard !chunk.samples.isEmpty else {
            return 0
        }

        lock.lock()
        defer { lock.unlock() }

        guard let context else {
            throw WhisperVoiceActivityDetectorError.detectionFailed
        }

        resetStateAfterDiscontinuityIfNeeded(
            context: context,
            sourceStartTime: sourceStartTime,
            sourceDuration: sourceDuration
        )

        let succeeded = chunk.samples.withUnsafeBufferPointer { buffer in
            whisper_vad_detect_speech_no_reset(context, buffer.baseAddress, Int32(buffer.count))
        }
        guard succeeded else {
            throw WhisperVoiceActivityDetectorError.detectionFailed
        }

        let probabilityCount = max(0, Int(whisper_vad_n_probs(context)))
        guard probabilityCount > 0,
              let probabilities = whisper_vad_probs(context)
        else {
            return 0
        }

        var maximumProbability: Float = 0
        for index in 0..<probabilityCount {
            maximumProbability = max(maximumProbability, probabilities[index])
        }
        return maximumProbability
    }

    private func resetStateAfterDiscontinuityIfNeeded(
        context: OpaquePointer,
        sourceStartTime: TimeInterval,
        sourceDuration: TimeInterval
    ) {
        if let lastInputEndTime {
            let tolerance = max(0.25, min(1.0, max(0.05, sourceDuration) * 2))
            if sourceStartTime > lastInputEndTime + tolerance ||
                sourceStartTime + sourceDuration < lastInputEndTime - tolerance {
                whisper_vad_reset_state(context)
            }
        }
        lastInputEndTime = sourceStartTime + sourceDuration
    }
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

private let whisperStreamingEncoderBeginCallback: whisper_encoder_begin_callback = { _, _, userData in
    guard let userData else { return true }
    let state = Unmanaged<WhisperStreamingSessionState>.fromOpaque(userData).takeUnretainedValue()
    return !state.isCancelled
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
        vadModelPath: String?,
        streamingContext: WhisperStreamingRunContext?
    ) throws -> WhisperRunResult {
        let language = normalizedLanguage(options.language ?? loadedConfiguration?.language)
        let prompt = normalizedPrompt(options)

        return try withOptionalCString(language) { languagePointer in
            try withOptionalCString(prompt) { promptPointer in
                try withOptionalCString(vadModelPath) { vadModelPathPointer in
                    var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
                    params.n_threads = threadCount(isStreaming: streamingContext != nil)
                    params.translate = options.task == .translate
                    params.no_timestamps = false
                    params.token_timestamps = options.timestampMode == .words
                    params.print_special = false
                    params.print_progress = false
                    params.print_realtime = false
                    params.print_timestamps = false
                    params.suppress_blank = streamingContext != nil || options.suppressBlankAudio
                    params.suppress_nst = streamingContext != nil
                    params.language = languagePointer
                    params.detect_language = languagePointer == nil
                    params.initial_prompt = promptPointer
                    params.prompt_tokens = nil
                    params.prompt_n_tokens = 0
                    if let vadModelPathPointer,
                       shouldUseModelVAD(options: options, isStreaming: streamingContext != nil) {
                        params.vad = true
                        params.vad_model_path = vadModelPathPointer
                        applyVADTuning(
                            WhisperVADTuning.resolve(for: options.voiceActivityDetection.sensitivity),
                            to: &params
                        )
                    }
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
                            eventSink: $0.eventSink
                        )
                    }
                    if let callbackBox {
                        params.progress_callback = whisperStreamingProgressCallback
                        params.progress_callback_user_data = Unmanaged.passUnretained(callbackBox).toOpaque()
                    }
                    if let sessionState = streamingContext?.sessionState {
                        params.abort_callback = whisperStreamingAbortCallback
                        params.abort_callback_user_data = Unmanaged.passUnretained(sessionState).toOpaque()
                        params.encoder_begin_callback = whisperStreamingEncoderBeginCallback
                        params.encoder_begin_callback_user_data = Unmanaged.passUnretained(sessionState).toOpaque()
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

                    let decodedSegments = transcriptSegments(
                        context: context,
                        includeWords: options.timestampMode == .words
                    )
                    let transcript = Transcript(
                        segments: normalizedSegmentTimestamps(
                            decodedSegments,
                            fallbackDuration: params.no_timestamps ? audio.duration : nil
                        ),
                        language: detectedLanguage(context: context),
                        duration: audio.duration,
                        backend: backend
                    )
                    return WhisperRunResult(transcript: transcript)
                }
            }
        }
    }

    func normalizedSegmentTimestamps(
        _ segments: [TranscriptSegment],
        fallbackDuration: TimeInterval?
    ) -> [TranscriptSegment] {
        guard let fallbackDuration else {
            return segments
        }
        return segments.map { segment in
            TranscriptSegment(
                id: segment.id,
                text: segment.text,
                startTime: 0,
                endTime: fallbackDuration,
                words: segment.words,
                speaker: segment.speaker,
                confidence: segment.confidence
            )
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
        params.no_context = !streamingContext.keepsDecoderContext || streamingContext.resetDecoderContext
        params.n_max_text_ctx = streamingContext.keepsDecoderContext ? tuning.decoderContextTokenLimit : 0
        params.carry_initial_prompt = streamingContext.keepsDecoderContext
        params.audio_ctx = clampedAudioContext(tuning.audioContext, context: context)
        if includeWords {
            params.single_segment = false
        } else if tuning.singleSegment {
            params.no_timestamps = true
        }
    }

    func shouldUseModelVAD(options: TranscriptionOptions, isStreaming: Bool) -> Bool {
        WhisperInnerVADPolicy.shouldUseModelVAD(options: options, isStreaming: isStreaming)
    }

    func applyVADTuning(_ tuning: WhisperVADTuning, to params: inout whisper_full_params) {
        params.vad_params.threshold = tuning.threshold
        params.vad_params.min_speech_duration_ms = tuning.minSpeechDurationMS
        params.vad_params.min_silence_duration_ms = tuning.minSilenceDurationMS
        params.vad_params.speech_pad_ms = tuning.speechPadMS
        params.vad_params.samples_overlap = tuning.samplesOverlap
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

    func threadCount(isStreaming: Bool = false) -> Int32 {
        if let threadCount = configuration.threadCount {
            return max(1, threadCount)
        }
        let maximumDefaultThreadCount = isStreaming ? 4 : 8
        return Int32(max(1, min(maximumDefaultThreadCount, ProcessInfo.processInfo.activeProcessorCount - 1)))
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

}
#endif

private extension Double {
    var formattedWhisperDebug: String {
        String(format: "%.3f", self)
    }
}
