import CarbocationLocalSpeech
import Foundation

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
        }
    }
}

public actor WhisperEngine: @preconcurrency CarbocationLocalSpeech.SpeechTranscriber {
    public static let shared = WhisperEngine()

    private let configuration: WhisperEngineConfiguration
    private var loadedInfo: WhisperLoadedModelInfo?

    public init(configuration: WhisperEngineConfiguration = WhisperEngineConfiguration()) {
        self.configuration = configuration
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
        loadedInfo = info
        _ = loadConfiguration
        return info
    }

    public func unload() {
        loadedInfo = nil
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

        throw WhisperEngineError.runtimeUnavailable(status)
    }

    public func stream(
        audio: AsyncThrowingStream<AudioChunk, Error>,
        options: StreamingTranscriptionOptions
    ) -> AsyncThrowingStream<TranscriptEvent, Error> {
        let loadedInfo = loadedInfo
        guard let loadedInfo else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: WhisperEngineError.noModelLoaded)
            }
        }

        let engine = self
        return SpeechChunkStreamingPipeline.stream(
            audio: audio,
            backend: loadedInfo.backend,
            options: options
        ) { audio, transcriptionOptions in
            try await engine.transcribe(audio: audio, options: transcriptionOptions)
        }
    }
}
