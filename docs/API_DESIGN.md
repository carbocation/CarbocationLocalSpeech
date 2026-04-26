# API Design

This document sketches the public API boundaries for `CarbocationLocalSpeech`. It mirrors the current `CarbocationLocalLLM` pattern: a lightweight core module, lower-level provider runtimes, a preferred unified runtime, and UI that can select either installed models or system providers.

## Design Principles

- Keep the core product free of heavy runtime dependencies.
- Model user-managed speech assets separately from system-managed Apple Speech assets.
- Persist provider-aware selections rather than assuming every selection is an installed file.
- Make live dictation explicit about partial, revised, and committed text.
- Treat diarization as optional enrichment, not the default dictation path.
- Keep Apple Intelligence in the LLM cleanup layer; use Apple Speech for transcription.

## Products And Dependency Direction

```text
CarbocationLocalSpeech
  depends on Foundation, AVFoundation, Accelerate where needed

CarbocationWhisperRuntime
  depends on CarbocationLocalSpeech and whisper

CarbocationAppleSpeechRuntime
  depends on CarbocationLocalSpeech and conditionally uses Speech

CarbocationLocalSpeechRuntime
  depends on CarbocationLocalSpeech, CarbocationWhisperRuntime,
  and CarbocationAppleSpeechRuntime

CarbocationLocalSpeechUI
  depends on CarbocationLocalSpeech and SwiftUI/AppKit

CLSSmoke
  depends on CarbocationLocalSpeechUI and CarbocationLocalSpeechRuntime
```

No app should need to import the C `whisper` module or the Apple Speech implementation target directly for normal use.

## Provider Selection

```swift
public enum SpeechSystemModelID: String, Codable, Hashable, Sendable {
    case appleSpeech = "system.apple-speech"
}

public enum SpeechModelSelection: Codable, Hashable, Sendable {
    case installed(UUID)
    case system(SpeechSystemModelID)

    public init?(storageValue: String)
    public var storageValue: String { get }
}

public enum SpeechProviderKind: String, Codable, Sendable {
    case whisperCpp
    case appleSpeech
    case whisperKit
    case mock
}

public struct SpeechSystemModelOption: Identifiable, Hashable, Sendable {
    public var selection: SpeechModelSelection
    public var displayName: String
    public var subtitle: String
    public var systemImageName: String
    public var capabilities: SpeechModelCapabilities
    public var availability: SpeechProviderAvailability

    public var id: String {
        selection.storageValue
    }
}

public enum SpeechProviderUnavailableReason: String, Codable, Hashable, Sendable {
    case sdkUnavailable
    case operatingSystemUnavailable
    case speechRecognitionDenied
    case localeUnsupported
    case assetDownloadRequired
    case assetNotReady
    case deviceNotEligible
    case unknown
}

public enum SpeechProviderAvailability: Hashable, Sendable {
    case available
    case unavailable(SpeechProviderUnavailableReason)

    public var isAvailable: Bool { get }
    public var shouldOfferModelOption: Bool { get }
}
```

`shouldOfferModelOption` should be `true` for `.available` and may also be `true` for repairable states such as `.assetDownloadRequired`, so the UI can offer installation. It should be `false` for hard failures such as missing SDK or unsupported OS.

## Models

Installed models are user-managed assets. System providers such as Apple Speech do not appear in `SpeechModelLibrary.models`.

```swift
public enum SpeechModelSource: String, Codable, Sendable {
    case curated
    case customURL
    case imported
    case bundled
}

public struct InstalledSpeechModel: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var displayName: String
    public var providerKind: SpeechProviderKind
    public var family: String
    public var variant: String?
    public var languageScope: SpeechLanguageScope
    public var quantization: String?
    public var assets: [SpeechModelAsset]
    public var source: SpeechModelSource
    public var sourceURL: URL?
    public var hfRepo: String?
    public var hfFilename: String?
    public var sha256: String?
    public var capabilities: SpeechModelCapabilities
    public var installedAt: Date
}

public struct SpeechModelAsset: Codable, Hashable, Sendable {
    public enum Role: String, Codable, Sendable {
        case primaryWeights
        case coreMLEncoder
        case vocabulary
        case configuration
        case diarizationWeights
        case other
    }

    public var role: Role
    public var relativePath: String
    public var sizeBytes: Int64
    public var sha256: String?
}

public enum SpeechLanguageScope: String, Codable, Sendable {
    case englishOnly
    case multilingual
    case languageSpecific
    case unknown
}

public struct SpeechLanguage: Codable, Hashable, Sendable {
    public var code: String
    public var displayName: String?
    public var probability: Double?
}

public struct SpeechModelCapabilities: Codable, Hashable, Sendable {
    public var supportsFileTranscription: Bool
    public var supportsLiveTranscription: Bool
    public var supportsDictationPreset: Bool
    public var supportsTranslation: Bool
    public var supportsWordTimestamps: Bool
    public var supportsLanguageDetection: Bool
    public var supportsDiarization: Bool
    public var supportsCoreMLAcceleration: Bool
    public var supportedLanguages: [String]
}

public struct SpeechBackendDescriptor: Codable, Hashable, Sendable {
    public var kind: SpeechProviderKind
    public var displayName: String
    public var version: String?
    public var selection: SpeechModelSelection?
}
```

Model storage should mirror LocalLLM naming where practical:

```swift
public enum SpeechModelStorage {
    public static let defaultSharedGroupID = "group.com.carbocation.shared"

    public static func modelsDirectory(
        sharedGroupIdentifier: String = defaultSharedGroupID,
        appSupportFolderName: String,
        fileManager: FileManager = .default
    ) -> URL
}

@MainActor
public final class SpeechModelLibrary {
    public private(set) var models: [InstalledSpeechModel]
    public private(set) var partials: [PartialSpeechModelDownload]
    public let root: URL

    public func refresh()
    public func model(id: UUID) -> InstalledSpeechModel?
    public func model(id: String) -> InstalledSpeechModel?
    public func importFile(at sourceURL: URL, displayName: String?) throws -> InstalledSpeechModel
    public func add(assetBundleAt temporaryDirectory: URL, metadata: InstalledSpeechModel) throws -> InstalledSpeechModel
    public func delete(id: UUID) throws
    public func deletePartial(_ partial: PartialSpeechModelDownload)
    public func totalDiskUsageBytes() -> Int64
}

public struct PartialSpeechModelDownload: Identifiable, Hashable, Sendable {
    public var id: String
    public var partialURL: URL
    public var sidecarURL: URL
    public var sourceURL: URL
    public var displayName: String
    public var totalBytes: Int64
    public var bytesOnDisk: Int64
}
```

## Audio

The core audio layer should use simple `Sendable` value types at API boundaries and hide AVFoundation details where possible.

```swift
public struct AudioChunk: Hashable, Sendable {
    public var samples: [Float]
    public var sampleRate: Double
    public var channelCount: Int
    public var startTime: TimeInterval
    public var duration: TimeInterval
}

public struct AudioCaptureConfiguration: Hashable, Sendable {
    public var preferredSampleRate: Double
    public var preferredChannelCount: Int
    public var frameDuration: TimeInterval
}

public protocol AudioCapturing: Sendable {
    func start(configuration: AudioCaptureConfiguration) -> AsyncThrowingStream<AudioChunk, Error>
    func stop()
}

public protocol AudioPreparing: Sendable {
    func prepareFile(at url: URL) async throws -> PreparedAudio
    func prepareChunk(_ chunk: AudioChunk) throws -> AudioChunk
}

public struct PreparedAudio: Hashable, Sendable {
    public var samples: [Float]
    public var sampleRate: Double
    public var duration: TimeInterval
}
```

First implementation targets:

- `AVAudioEngineCaptureSession`
- `AVAssetAudioFileReader`
- `AudioResampler16kMono`
- `AudioLevelMeter`

## Transcription

```swift
public struct Transcript: Codable, Hashable, Sendable {
    public var segments: [TranscriptSegment]
    public var language: SpeechLanguage?
    public var duration: TimeInterval?
    public var backend: SpeechBackendDescriptor?
}

public struct TranscriptSegment: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var text: String
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var words: [TranscriptWord]
    public var speaker: SpeakerID?
    public var confidence: Double?
}

public struct TranscriptWord: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var text: String
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var confidence: Double?
}

public enum TranscriptionUseCase: String, Codable, Sendable {
    case general
    case dictation
    case meeting
}

public enum TranscriptionTask: String, Codable, Sendable {
    case transcribe
    case translate
}

public enum TimestampMode: String, Codable, Sendable {
    case segments
    case words
}

public struct TranscriptionOptions: Hashable, Sendable {
    public var useCase: TranscriptionUseCase
    public var language: String?
    public var task: TranscriptionTask
    public var timestampMode: TimestampMode
    public var initialPrompt: String?
    public var contextualStrings: [String]
    public var suppressBlankAudio: Bool
    public var temperature: Double?
}

public struct StreamingTranscriptionOptions: Hashable, Sendable {
    public var transcription: TranscriptionOptions
    public var chunking: SpeechChunkingConfiguration
    public var partialCommitStrategy: PartialCommitStrategy
    public var latencyPreset: SpeechLatencyPreset
}

public enum SpeechLatencyPreset: String, Codable, CaseIterable, Sendable {
    case lowestLatency
    case balancedDictation
    case accuracy
    case fileQuality
}

public enum PartialCommitStrategy: String, Codable, Sendable {
    case silence
    case chunkBoundary
    case silenceOrChunkBoundary
}

public protocol SpeechTranscriber: Sendable {
    func transcribe(file url: URL, options: TranscriptionOptions) async throws -> Transcript

    func transcribe(
        audio: PreparedAudio,
        options: TranscriptionOptions
    ) async throws -> Transcript

    func stream(
        audio: AsyncThrowingStream<AudioChunk, Error>,
        options: StreamingTranscriptionOptions
    ) -> AsyncThrowingStream<TranscriptEvent, Error>
}
```

`TranscriptionOptions.task == .translate` should be supported by `WhisperEngine` only in v1. `AppleSpeechEngine` should fail with a provider-specific unsupported-feature error until translation is implemented by a real Apple provider.

## Transcript Events

Dictation host apps need to distinguish changing partials from committed text.

```swift
public enum TranscriptEvent: Sendable, Hashable {
    case started(SpeechBackendDescriptor)
    case audioLevel(AudioLevel)
    case voiceActivity(VoiceActivityEvent)
    case partial(TranscriptPartial)
    case revision(TranscriptRevision)
    case committed(TranscriptSegment)
    case progress(TranscriptionProgress)
    case stats(TranscriptionStats)
    case completed(Transcript)
}

public struct TranscriptPartial: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var text: String
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var stability: Double?
}

public struct TranscriptRevision: Hashable, Sendable {
    public var replacesPartialID: UUID
    public var replacement: TranscriptPartial
}

public struct AudioLevel: Hashable, Sendable {
    public var rms: Float
    public var peak: Float
    public var time: TimeInterval
}

public struct TranscriptionProgress: Hashable, Sendable {
    public var processedDuration: TimeInterval
    public var totalDuration: TimeInterval?
    public var fractionComplete: Double?
}

public struct TranscriptionStats: Hashable, Sendable {
    public var audioDuration: TimeInterval
    public var processingDuration: TimeInterval
    public var realTimeFactor: Double?
    public var segmentCount: Int
}
```

The shared streaming layer should emit:

- `partial` for text that may change
- `revision` when an overlap-window reprocess changes prior partial text
- `committed` when silence or chunk boundaries make text stable
- `completed` when the stream ends

## Voice Activity And Chunking

```swift
public enum VoiceActivityState: String, Codable, Sendable {
    case silence
    case speech
}

public struct VoiceActivityEvent: Hashable, Sendable {
    public var state: VoiceActivityState
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var confidence: Double?
}

public protocol VoiceActivityDetecting: Sendable {
    func analyze(_ chunk: AudioChunk) throws -> VoiceActivityEvent
}

public struct SpeechChunkingConfiguration: Hashable, Sendable {
    public var maximumChunkDuration: TimeInterval
    public var overlapDuration: TimeInterval
    public var silenceCommitDelay: TimeInterval
    public var minimumSpeechDuration: TimeInterval
}
```

Start with an energy-based VAD for provider-neutral streaming. Apple Speech may also use `SpeechDetector` internally once that behavior is verified.

## Unified Runtime

Host apps should use `LocalSpeechEngine` for normal transcription.

```swift
public struct SpeechLoadOptions: Hashable, Sendable {
    public var locale: Locale
    public var preload: Bool
    public var installSystemAssetsIfNeeded: Bool
}

public struct LocalSpeechLoadedModelInfo: Hashable, Sendable {
    public var selection: SpeechModelSelection
    public var displayName: String
    public var backend: SpeechBackendDescriptor
    public var capabilities: SpeechModelCapabilities
}

public enum LocalSpeechEngineError: Error, LocalizedError, Sendable {
    case invalidSelection(String)
    case installedModelNotFound(UUID)
    case noSelectionLoaded
    case unavailableSystemModel(SpeechSystemModelID)
    case unsupportedFeature(String)
    case providerFailed(String)
}

public actor LocalSpeechEngine: SpeechTranscriber {
    public static let shared = LocalSpeechEngine()

    public nonisolated static func systemModelOptions(locale: Locale) async -> [SpeechSystemModelOption]
    public nonisolated static func selection(from storageValue: String) throws -> SpeechModelSelection
    public nonisolated static func capabilities(
        for selection: SpeechModelSelection,
        in library: SpeechModelLibrary?
    ) async -> SpeechModelCapabilities

    public func load(
        selection: SpeechModelSelection,
        from library: SpeechModelLibrary,
        options: SpeechLoadOptions
    ) async throws -> LocalSpeechLoadedModelInfo

    public func unload() async
    public func currentSelection() -> SpeechModelSelection?
    public func currentLoadedModelInfo() -> LocalSpeechLoadedModelInfo?
}
```

Routing rules:

- `.installed(id)` loads `WhisperEngine` with the installed model from `SpeechModelLibrary`.
- `.system(.appleSpeech)` loads `AppleSpeechEngine` after checking availability and assets.
- `transcribe` and `stream` require a loaded selection.
- System providers are never deleted through `SpeechModelLibrary`.

## Apple Speech Runtime

`CarbocationAppleSpeechRuntime` should expose a lower-level `AppleSpeechEngine`.

```swift
public struct AppleSpeechEngineConfiguration: Hashable, Sendable {
    public var providerUnavailableBehavior: SystemProviderUnavailableBehavior
}

public enum AppleSpeechUnsupportedFeature: String, Codable, Hashable, Sendable {
    case translation
    case wordTimestamps
    case diarization
}

public actor AppleSpeechEngine: SpeechTranscriber {
    public static let shared = AppleSpeechEngine()
    public static let systemModelID = SpeechSystemModelID.appleSpeech
    public static let displayName = "Apple Speech"

    public nonisolated static var isBuiltWithModernSpeechSDK: Bool { get }
    public nonisolated static func availability(locale: Locale) async -> SpeechProviderAvailability
    public nonisolated static func systemModelOption(locale: Locale) async -> SpeechSystemModelOption?

    public func prepare(locale: Locale, installAssetsIfNeeded: Bool) async throws
}
```

Implementation expectations:

- Use `#if canImport(Speech)` and `#available(macOS 26.0, *)` around `SpeechAnalyzer`, `SpeechTranscriber`, `DictationTranscriber`, and `AssetInventory`.
- Return `.sdkUnavailable` or `.operatingSystemUnavailable` from stub builds instead of failing compilation.
- Use `SpeechTranscriber` for `.general` and `.meeting`.
- Use `DictationTranscriber` for `.dictation` and `balancedDictation`/`lowestLatency` live presets.
- Use `AssetInventory` to check, reserve, download, and install locale assets when requested.
- Expose asset-required states through availability so the UI can show an install action.

## Whisper Runtime

`CarbocationWhisperRuntime` should expose a lower-level actor similar to `LlamaEngine`.

```swift
public struct WhisperEngineConfiguration: Hashable, Sendable {
    public var useMetal: Bool
    public var useCoreML: Bool
    public var threadCount: Int32?
    public var heartbeatInterval: TimeInterval
}

public struct WhisperLoadConfiguration: Hashable, Sendable {
    public var language: String?
    public var useMetal: Bool
    public var useCoreML: Bool
}

public struct WhisperLoadedModelInfo: Hashable, Sendable {
    public var modelID: UUID?
    public var modelPath: String
    public var displayName: String?
    public var backend: SpeechBackendDescriptor
    public var capabilities: SpeechModelCapabilities
}

public actor WhisperEngine: SpeechTranscriber {
    public static let shared = WhisperEngine()

    public func currentModelID() -> UUID?
    public func currentLoadedModelInfo() -> WhisperLoadedModelInfo?

    public func load(
        model: InstalledSpeechModel,
        from root: URL,
        configuration: WhisperLoadConfiguration
    ) throws -> WhisperLoadedModelInfo

    public func unload()
}
```

## Diarization

Diarization should be protocol-first and optional.

```swift
public struct SpeakerID: RawRepresentable, Codable, Hashable, Sendable {
    public var rawValue: String
}

public struct SpeakerTurn: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var speaker: SpeakerID
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var confidence: Double?
}

public protocol SpeakerDiarizer: Sendable {
    func diarize(file url: URL, options: DiarizationOptions) async throws -> [SpeakerTurn]
}

public struct DiarizationOptions: Hashable, Sendable {
    public var minimumSpeakerCount: Int?
    public var maximumSpeakerCount: Int?
    public var minimumTurnDuration: TimeInterval
}

public enum SpeakerAttributionMerger {
    public static func merge(
        transcript: Transcript,
        speakerTurns: [SpeakerTurn],
        minimumOverlap: TimeInterval
    ) -> Transcript
}
```

The first implementation can ship only the merger and mock diarizer. Real diarization can be added later through SpeakerKit or another local model backend.

## UI

The UI target should begin with:

```swift
public struct SpeechModelLibraryPickerView: View
public struct SpeechModelPickerLabelPolicy: Sendable
public struct SpeechSettingsView: View
public struct MicrophonePermissionStatusView: View
public struct LiveTranscriptDebugView: View
```

`SpeechModelLibraryPickerView` should mirror the current LocalLLM picker:

- system providers section above installed models
- installed models
- total installed model disk usage
- curated downloads
- custom URL download
- local model import
- interrupted downloads
- delete, refresh, reveal folder
- provider-aware confirm callback returning `SpeechModelSelection`

Default labels:

- Apple Speech: `Built In`, secondary tone
- hardware-recommended curated Whisper model: `Recommended`, accent tone
- best installed curated Whisper fallback: `Best Installed`, positive tone

## Testing Strategy

Core tests should not require a real Whisper model or an Apple Speech-capable machine.

Unit tests:

- `SpeechModelSelection` round-trips installed UUIDs and `system.apple-speech`
- invalid selection strings fail cleanly
- installed and system capabilities differ as expected
- model metadata import/delete/synthesize
- system providers do not count toward model disk usage
- multi-asset model storage
- URL parsing and partial download listing
- VAD threshold behavior with generated sine/silence samples
- chunk overlap and commit behavior
- speaker attribution merge
- transcript event ordering with mock transcriber

Runtime tests:

- smoke-link the whisper C module
- Apple Speech stubs return SDK/OS unavailable when appropriate
- Apple Speech system option appears only when availability says it should
- `LocalSpeechEngine` routes installed selections to Whisper and system selections to Apple Speech
- live Apple Speech tests skip unless explicitly enabled by environment variable
- real Whisper tests skip unless `CARBOCATION_LOCAL_SPEECH_TEST_MODEL` and test audio are provided

Smoke app:

- select Apple Speech or an installed Whisper model
- install system speech assets when required
- transcribe a selected audio file
- observe mic input levels and VAD states
- run streaming-ish dictation into a debug transcript pane
