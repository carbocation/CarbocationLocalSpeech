import CarbocationAppleSpeechRuntime
import CarbocationLocalSpeech
import CarbocationWhisperRuntime
import Foundation

public struct SpeechLoadOptions: Hashable, Sendable {
    public var locale: Locale
    public var preload: Bool
    public var installSystemAssetsIfNeeded: Bool

    public init(
        locale: Locale = .current,
        preload: Bool = true,
        installSystemAssetsIfNeeded: Bool = false
    ) {
        self.locale = locale
        self.preload = preload
        self.installSystemAssetsIfNeeded = installSystemAssetsIfNeeded
    }
}

public struct LocalSpeechLoadedModelInfo: Hashable, Sendable {
    public var selection: SpeechModelSelection
    public var displayName: String
    public var backend: SpeechBackendDescriptor
    public var capabilities: SpeechModelCapabilities

    public init(
        selection: SpeechModelSelection,
        displayName: String,
        backend: SpeechBackendDescriptor,
        capabilities: SpeechModelCapabilities
    ) {
        self.selection = selection
        self.displayName = displayName
        self.backend = backend
        self.capabilities = capabilities
    }
}

public enum LocalSpeechEngineError: Error, LocalizedError, Sendable {
    case invalidSelection(String)
    case installedModelNotFound(UUID)
    case noSelectionLoaded
    case unavailableSystemModel(SpeechSystemModelID)
    case unsupportedFeature(String)
    case providerFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSelection(let value):
            return "Selected speech model identifier is not valid: \(value)"
        case .installedModelNotFound(let id):
            return "Installed speech model was not found: \(id.uuidString)"
        case .noSelectionLoaded:
            return "No speech model selection is loaded."
        case .unavailableSystemModel(let id):
            return "System speech model is unavailable: \(id.rawValue)"
        case .unsupportedFeature(let detail):
            return "Unsupported speech feature: \(detail)"
        case .providerFailed(let detail):
            return "Speech provider failed: \(detail)"
        }
    }
}

public actor LocalSpeechEngine: @preconcurrency CarbocationLocalSpeech.SpeechTranscriber {
    public static let shared = LocalSpeechEngine()

    private let whisperEngine: WhisperEngine
    private let appleSpeechEngine: AppleSpeechEngine
    private var loadedInfo: LocalSpeechLoadedModelInfo?

    public init(
        whisperEngine: WhisperEngine = WhisperEngine(),
        appleSpeechEngine: AppleSpeechEngine = AppleSpeechEngine()
    ) {
        self.whisperEngine = whisperEngine
        self.appleSpeechEngine = appleSpeechEngine
    }

    public nonisolated static func systemModelOptions(locale: Locale) async -> [SpeechSystemModelOption] {
        await AppleSpeechEngine.systemModelOption(locale: locale).map { [$0] } ?? []
    }

    public nonisolated static func selection(from storageValue: String) throws -> SpeechModelSelection {
        guard let selection = SpeechModelSelection(storageValue: storageValue) else {
            throw LocalSpeechEngineError.invalidSelection(storageValue)
        }
        return selection
    }

    public nonisolated static func capabilities(
        for selection: SpeechModelSelection,
        in library: SpeechModelLibrary?
    ) async -> SpeechModelCapabilities {
        switch selection {
        case .installed(let id):
            guard let library else { return .whisperCppDefault }
            return await MainActor.run {
                library.model(id: id)?.capabilities ?? .whisperCppDefault
            }
        case .system(.appleSpeech):
            return .appleSpeechDefault
        }
    }

    @discardableResult
    public func load(
        selection: SpeechModelSelection,
        from library: SpeechModelLibrary,
        options: SpeechLoadOptions = SpeechLoadOptions()
    ) async throws -> LocalSpeechLoadedModelInfo {
        switch selection {
        case .installed(let id):
            let model = await MainActor.run { library.model(id: id) }
            let root = await MainActor.run { library.root }
            guard let model else {
                throw LocalSpeechEngineError.installedModelNotFound(id)
            }
            let loaded = try await whisperEngine.load(
                model: model,
                from: root,
                configuration: WhisperLoadConfiguration(
                    language: options.locale.language.languageCode?.identifier,
                    useMetal: true,
                    useCoreML: true
                )
            )
            let info = LocalSpeechLoadedModelInfo(
                selection: selection,
                displayName: loaded.displayName ?? URL(fileURLWithPath: loaded.modelPath).lastPathComponent,
                backend: loaded.backend,
                capabilities: loaded.capabilities
            )
            loadedInfo = info
            return info
        case .system(.appleSpeech):
            do {
                try await appleSpeechEngine.prepare(
                    locale: options.locale,
                    installAssetsIfNeeded: options.installSystemAssetsIfNeeded
                )
                await whisperEngine.unload()
                let info = LocalSpeechLoadedModelInfo(
                    selection: selection,
                    displayName: AppleSpeechEngine.displayName,
                    backend: SpeechBackendDescriptor(
                        kind: .appleSpeech,
                        displayName: AppleSpeechEngine.displayName,
                        selection: selection
                    ),
                    capabilities: .appleSpeechDefault
                )
                loadedInfo = info
                return info
            } catch {
                throw LocalSpeechEngineError.unavailableSystemModel(.appleSpeech)
            }
        }
    }

    public func unload() async {
        loadedInfo = nil
        await whisperEngine.unload()
    }

    public func currentSelection() -> SpeechModelSelection? {
        loadedInfo?.selection
    }

    public func currentLoadedModelInfo() -> LocalSpeechLoadedModelInfo? {
        loadedInfo
    }

    public func transcribe(file url: URL, options: TranscriptionOptions) async throws -> Transcript {
        guard let loadedInfo else {
            throw LocalSpeechEngineError.noSelectionLoaded
        }
        switch loadedInfo.selection {
        case .installed:
            do {
                return try await whisperEngine.transcribe(file: url, options: options)
            } catch {
                throw LocalSpeechEngineError.providerFailed(error.localizedDescription)
            }
        case .system(.appleSpeech):
            do {
                return try await appleSpeechEngine.transcribe(file: url, options: options)
            } catch let error as AppleSpeechEngineError {
                if case .unsupportedFeatures(let features) = error {
                    throw LocalSpeechEngineError.unsupportedFeature(features.map(\.rawValue).sorted().joined(separator: ", "))
                }
                throw LocalSpeechEngineError.providerFailed(error.localizedDescription)
            } catch {
                throw LocalSpeechEngineError.providerFailed(error.localizedDescription)
            }
        }
    }

    public func transcribe(audio: PreparedAudio, options: TranscriptionOptions) async throws -> Transcript {
        guard let loadedInfo else {
            throw LocalSpeechEngineError.noSelectionLoaded
        }
        switch loadedInfo.selection {
        case .installed:
            do {
                return try await whisperEngine.transcribe(audio: audio, options: options)
            } catch {
                throw LocalSpeechEngineError.providerFailed(error.localizedDescription)
            }
        case .system(.appleSpeech):
            do {
                return try await appleSpeechEngine.transcribe(audio: audio, options: options)
            } catch let error as AppleSpeechEngineError {
                if case .unsupportedFeatures(let features) = error {
                    throw LocalSpeechEngineError.unsupportedFeature(features.map(\.rawValue).sorted().joined(separator: ", "))
                }
                throw LocalSpeechEngineError.providerFailed(error.localizedDescription)
            } catch {
                throw LocalSpeechEngineError.providerFailed(error.localizedDescription)
            }
        }
    }

    public func stream(
        audio: AsyncThrowingStream<AudioChunk, Error>,
        options: StreamingTranscriptionOptions
    ) -> AsyncThrowingStream<TranscriptEvent, Error> {
        guard let loadedInfo else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: LocalSpeechEngineError.noSelectionLoaded)
            }
        }

        switch loadedInfo.selection {
        case .installed:
            return AsyncThrowingStream { continuation in
                Task {
                    let providerStream = await whisperEngine.stream(audio: audio, options: options)
                    do {
                        for try await event in providerStream {
                            continuation.yield(event)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
        case .system(.appleSpeech):
            return AsyncThrowingStream { continuation in
                Task {
                    let providerStream = await appleSpeechEngine.stream(audio: audio, options: options)
                    do {
                        for try await event in providerStream {
                            continuation.yield(event)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
        }
    }
}
