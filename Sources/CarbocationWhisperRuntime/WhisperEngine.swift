import CarbocationLocalSpeech
import Foundation
#if CARBOCATION_HAS_WHISPER_C_API
import whisper
#endif

public struct WhisperEngineConfiguration: Hashable, Sendable {
    public var useMetal: Bool
    public var useCoreML: Bool
    public var threadCount: Int32?
    public var heartbeatInterval: TimeInterval

    public init(
        useMetal: Bool = true,
        useCoreML: Bool = true,
        threadCount: Int32? = nil,
        heartbeatInterval: TimeInterval = 2
    ) {
        self.useMetal = useMetal
        self.useCoreML = useCoreML
        self.threadCount = threadCount
        self.heartbeatInterval = heartbeatInterval
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
        guard let loadedInfo else {
            throw WhisperEngineError.noModelLoaded
        }

        if options.suppressBlankAudio,
           AudioLevelMeter.measure(samples: audio.samples).peak < 0.000_01 {
            return Transcript(
                segments: [],
                duration: audio.duration,
                backend: loadedInfo.backend
            )
        }

        let status = WhisperBackend.ensureInitialized()
        guard status.isUsable else {
            throw WhisperEngineError.runtimeUnavailable(status)
        }

#if CARBOCATION_HAS_WHISPER_C_API
        let normalizedAudio = try normalizeAudio(audio)
        guard !normalizedAudio.samples.isEmpty else {
            return Transcript(
                segments: [],
                duration: normalizedAudio.duration,
                backend: loadedInfo.backend
            )
        }
        guard normalizedAudio.samples.count <= Int(Int32.max) else {
            throw WhisperEngineError.invalidSampleCount(normalizedAudio.samples.count)
        }

        let context = try ensureContext(for: loadedInfo)
        let transcript = try runWhisper(
            context: context,
            audio: normalizedAudio,
            options: options,
            backend: loadedInfo.backend
        )
        return transcript
#else
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

        let engine = self
        return SpeechChunkStreamingPipeline.stream(
            audio: audio,
            backend: loadedInfo.backend,
            options: effectiveOptions
        ) { audio, transcriptionOptions in
            try await engine.transcribe(audio: audio, options: transcriptionOptions)
        }
    }
}

#if CARBOCATION_HAS_WHISPER_C_API
private extension WhisperEngine {
    func ensureContext(for loadedInfo: WhisperLoadedModelInfo) throws -> OpaquePointer {
        if let context, contextModelPath == loadedInfo.modelPath {
            return context
        }

        freeContext()
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
        backend: SpeechBackendDescriptor
    ) throws -> Transcript {
        let language = normalizedLanguage(options.language ?? loadedConfiguration?.language)
        let prompt = normalizedPrompt(options)

        return try withOptionalCString(language) { languagePointer in
            try withOptionalCString(prompt) { promptPointer in
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
                if let temperature = options.temperature {
                    params.temperature = Float(temperature)
                }

                let result = audio.samples.withUnsafeBufferPointer { buffer in
                    whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
                }
                guard result == 0 else {
                    throw WhisperEngineError.transcriptionFailed(result)
                }

                return Transcript(
                    segments: transcriptSegments(
                        context: context,
                        includeWords: options.timestampMode == .words
                    ),
                    language: detectedLanguage(context: context),
                    duration: audio.duration,
                    backend: backend
                )
            }
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
