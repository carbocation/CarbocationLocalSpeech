# Implementation Plan

This plan assumes an empty `CarbocationLocalSpeech` folder and a sibling `CarbocationLocalLLM` package used as the local pattern.

## Current LocalLLM Pattern To Reuse

Useful patterns from current `CarbocationLocalLLM`:

- product split into core, lower-level provider runtimes, unified runtime, UI, and smoke app
- macOS 14 minimum deployment target with provider-specific availability gates
- shared App Group storage with Application Support fallback
- per-model UUID directories with `metadata.json`
- `@MainActor` model library object
- installed-vs-system selection through a persisted `storageValue`
- system model options surfaced separately from installed models
- provider capabilities used by host apps and smoke tests
- UI label policy for recommended installed models and system providers
- release tags that point SwiftPM at an XCFramework artifact
- `main` branch that stays source-build friendly
- smoke app that validates the unified runtime through SwiftUI

Speech-specific differences:

- Whisper model assets can be multi-file, not just one `.gguf`.
- Apple Speech assets are system-managed through `AssetInventory`, not package-owned files.
- Audio capture and resampling are shared product infrastructure.
- Live transcription is chunked or analyzer-driven inference with revisions, not token streaming.
- Diarization should be optional enrichment.

## Milestone 0: Package Skeleton

Create:

```text
Package.swift
.gitignore
.gitmodules
Sources/CarbocationLocalSpeech/
Sources/CarbocationWhisperRuntime/
Sources/CarbocationAppleSpeechRuntime/
Sources/CarbocationLocalSpeechRuntime/
Sources/CarbocationLocalSpeechUI/
Sources/CLSSmoke/
Sources/whisper/module.modulemap
Tests/CarbocationLocalSpeechTests/
Tests/CarbocationWhisperRuntimeTests/
Tests/CarbocationAppleSpeechRuntimeTests/
Tests/CarbocationLocalSpeechRuntimeTests/
Tests/CarbocationLocalSpeechUITests/
Scripts/
Vendor/whisper.cpp/
```

Initial products:

```swift
.library(name: "CarbocationLocalSpeech", targets: ["CarbocationLocalSpeech"])
.library(name: "CarbocationWhisperRuntime", targets: ["CarbocationWhisperRuntime"])
.library(name: "CarbocationAppleSpeechRuntime", targets: ["CarbocationAppleSpeechRuntime"])
.library(name: "CarbocationLocalSpeechRuntime", targets: ["CarbocationLocalSpeechRuntime"])
.library(name: "CarbocationLocalSpeechUI", targets: ["CarbocationLocalSpeechUI"])
.executable(name: "CLSSmoke", targets: ["CLSSmoke"])
```

Manifest expectations:

- `CarbocationLocalSpeech` has no dependency on provider implementation targets.
- `CarbocationAppleSpeechRuntime` links the system `Speech` framework and compiles fallback code when modern Speech APIs are unavailable.
- `CarbocationLocalSpeechRuntime` depends on `CarbocationWhisperRuntime` and `CarbocationAppleSpeechRuntime`.
- `CLSSmoke` depends on `CarbocationLocalSpeechUI` and `CarbocationLocalSpeechRuntime`.

Whisper target shape should mirror LocalLLM:

```swift
let whisperTarget: Target
let whisperUnsafeLinkerSettings: [LinkerSetting]

if forceSourceWhisper {
    whisperTarget = .systemLibrary(name: "whisper", path: "Sources/whisper")
    whisperUnsafeLinkerSettings = [.unsafeFlags([whisperCombinedLibrary])]
} else if !whisperBinaryArtifactPath.isEmpty {
    whisperTarget = .binaryTarget(name: "whisper", path: whisperBinaryArtifactPath)
    whisperUnsafeLinkerSettings = []
} else if !whisperBinaryArtifactURL.isEmpty && !whisperBinaryArtifactChecksum.isEmpty {
    whisperTarget = .binaryTarget(
        name: "whisper",
        url: whisperBinaryArtifactURL,
        checksum: whisperBinaryArtifactChecksum
    )
    whisperUnsafeLinkerSettings = []
} else {
    whisperTarget = .systemLibrary(name: "whisper", path: "Sources/whisper")
    whisperUnsafeLinkerSettings = [.unsafeFlags([whisperCombinedLibrary])]
}
```

Initial non-goals:

- no WhisperKit adapter
- no real diarization backend
- no app-specific dictation commands
- no dependency on `CarbocationLocalLLM`

## Milestone 1: Core Types And Model Library

Implement:

- `SpeechModelSelection`
- `SpeechSystemModelID`
- `SpeechSystemModelOption`
- `SpeechProviderAvailability`
- `SpeechModelCapabilities`
- `InstalledSpeechModel`
- `SpeechModelAsset`
- `SpeechModelStorage`
- `SpeechModelLibrary`
- `CuratedSpeechModelCatalog`
- `SpeechModelDownloader`
- `MockSpeechTranscriber`
- transcript, audio, and diarization value types

Acceptance criteria:

- `swift test` passes without a real speech model
- installed UUID and `system.apple-speech` selections round-trip through `storageValue`
- import/delete/refresh works for `.bin` files
- metadata supports multi-file assets
- partial download listing and deletion works
- system providers are not represented in installed model disk usage
- core module has no dependency on whisper.cpp or Apple Speech implementation code

Implementation choice:

- Copy and specialize the LocalLLM downloader for now. Extracting a shared Carbocation downloader should wait until a third package needs the same machinery.

## Milestone 2: Apple Speech Runtime

Implement `CarbocationAppleSpeechRuntime` before or alongside whisper.cpp so the unified provider shape is exercised early.

Implement:

- `AppleSpeechEngine`
- `AppleSpeechEngineConfiguration`
- `AppleSpeechUnsupportedFeature`
- availability mapping to `SpeechProviderAvailability`
- system provider option for `SpeechSystemModelID.appleSpeech`
- asset status/install helpers through `AssetInventory`
- file transcription through `SpeechAnalyzer` and `SpeechTranscriber`
- dictation-oriented live transcription through `DictationTranscriber`
- stubs for builds without modern Speech APIs

Availability/compatibility rules:

- Package minimum remains macOS 14.
- Real Apple Speech implementation is gated by `#available(macOS 26.0, *)`.
- Source that references `SpeechAnalyzer`, `SpeechTranscriber`, `DictationTranscriber`, and `AssetInventory` must compile only when the SDK exposes those symbols.
- Stub builds return `.sdkUnavailable` or `.operatingSystemUnavailable`; they must not fail compilation.

Acceptance criteria:

- tests pass on unsupported SDK/OS by exercising stubs
- system option appears only when availability says it should be offered
- asset-download-required state is represented without crashing
- unsupported translation/diarization/word-timestamp options fail clearly
- live Apple Speech test is skipped unless explicitly enabled by environment variable

## Milestone 3: whisper.cpp Source Runtime

Add `Vendor/whisper.cpp` as a submodule and build local artifacts:

```text
Vendor/whisper-artifacts/current/include
Vendor/whisper-artifacts/current/lib/libwhisper-combined.a
```

Implement scripts parallel to LocalLLM:

- `build-whisper-macos.sh`
- `build-whisper-from-xcode.sh`
- `build-whisper-xcframework.sh`
- `set-whisper-binary-artifact.sh`
- `test-binary-release.sh`

Implement:

- `WhisperBackend.ensureInitialized()`
- `WhisperEngineConfiguration`
- `WhisperEngine`
- `WhisperRuntimeSmoke`
- `WhisperRuntimeModelProbe`

First runtime behavior:

- load/unload model
- transcribe a file prepared by the core audio reader
- transcribe a prepared PCM buffer
- return segment timestamps
- optionally return word timestamps
- emit request, progress, stats, and done events
- support cancellation

Acceptance criteria:

- runtime tests can import and call the C module
- `CLSSmoke` can transcribe a local audio file with a manually installed model
- tests skip real inference unless explicit env vars provide a model and fixture audio

Implementation note:

- Verify current whisper.cpp CMake flags before coding the scripts. The planning assumption is a static macOS build with Metal and Accelerate enabled, plus optional Core ML support when the toolchain and model assets support it.

## Milestone 4: Unified Runtime

Implement `CarbocationLocalSpeechRuntime`.

Implement:

- `LocalSpeechEngine`
- `SpeechLoadOptions`
- `LocalSpeechLoadedModelInfo`
- `LocalSpeechEngineError`
- `LocalSpeechEngine.systemModelOptions(locale:)`
- `LocalSpeechEngine.selection(from:)`
- `LocalSpeechEngine.capabilities(for:in:)`
- provider routing for `transcribe(file:)`, `transcribe(audio:)`, and `stream(audio:)`

Routing rules:

- `.installed(id)` loads and delegates to `WhisperEngine`.
- `.system(.appleSpeech)` prepares and delegates to `AppleSpeechEngine`.
- `transcribe` and `stream` throw `noSelectionLoaded` before a successful `load`.
- deleting an installed model is still host-owned cleanup; system providers cannot be deleted.

Acceptance criteria:

- installed and system selections route to the expected provider
- current selection and loaded info report provider capabilities
- unavailable system providers fail with a typed error
- unsupported provider features fail before long-running work starts

## Milestone 5: SwiftUI Provider And Model Management

Implement:

- `SpeechModelLibraryPickerView`
- `SpeechModelPickerLabelPolicy`
- system provider section
- curated download rows for common Whisper sizes
- custom URL sheet
- local import
- interrupted download resume/delete
- delete confirmation
- reveal folder
- selected model binding using `SpeechModelSelection.storageValue`

Acceptance criteria:

- UI mirrors current LocalLLM picker behavior
- UI accepts app-provided system provider options
- UI accepts app-provided curated catalog
- default Apple Speech label is `Built In`
- recommended and best-installed labels apply only to curated installed Whisper models
- UI does not import provider runtime targets
- deleting a model calls a host-provided cleanup hook

Recommended first curated catalog:

```text
tiny.en
base.en
small.en
medium.en
large-v3-turbo
```

Keep exact URLs, sizes, checksums, and source repositories out of the API until verified during implementation.

## Milestone 6: Audio Capture And File Preparation

Implement:

- `AVAudioEngineCaptureSession`
- `AVAssetAudioFileReader`
- `AudioResampler16kMono`
- `AudioLevelMeter`
- microphone permission helper

Acceptance criteria:

- can read common audio/video file formats supported by AVFoundation
- can capture mic into `AsyncThrowingStream<AudioChunk, Error>`
- chunks include stable sample timing
- generated test audio can validate duration and sample-rate conversion
- Apple Speech can request or receive the audio format it needs without leaking Speech framework types into core APIs

Entitlements to document for host apps:

- microphone usage description
- speech recognition usage description
- sandbox file access for user-selected files
- network client if downloading models or Apple speech assets
- App Group if shared speech model storage is desired

## Milestone 7: VAD, Chunking, And Streaming-ish Dictation

Implement:

- `EnergyVoiceActivityDetector`
- `SpeechChunker`
- `StreamingTranscriber`
- `TranscriptEvent` partial/revision/committed/completed behavior
- latency presets

Acceptance criteria:

- silence does not repeatedly trigger hallucinated Whisper transcription
- overlap windows can revise unstable partials
- committed text is monotonic and suitable for host paste/type flows
- Apple Speech analyzer-driven partials map into the same event model
- unit tests cover partial, revision, and commit ordering

Suggested defaults:

```text
lowestLatency:       1.5s chunk, 0.25s overlap
balancedDictation:   3.0s chunk, 0.50s overlap
accuracy:            8.0s chunk, 1.00s overlap
fileQuality:         whole file or large windows
```

Tune these with the smoke app.

## Milestone 8: Binary Release Path

Mirror the LocalLLM release model for whisper.cpp:

- keep `main` source-build friendly
- generate `whisper.xcframework`
- stamp release-tag `Package.swift` with binary artifact URL and checksum
- publish GitHub release asset
- validate from a clean temporary consumer package

Acceptance criteria:

- consuming apps can use a version tag without a sibling checkout
- consuming apps do not need to build whisper.cpp
- runtime product links on Apple Silicon and Intel macOS if universal support is still desired
- Apple Speech provider works without any binary artifact

## Milestone 9: Diarization Interfaces

Start with backend-neutral support:

- `SpeakerID`
- `SpeakerTurn`
- `SpeakerDiarizer`
- `SpeakerAttributionMerger`
- mock diarizer
- transcript merge tests

Only add real diarization once a host app needs it. Candidate implementations:

- SpeakerKit adapter
- pyannote-style Core ML pipeline
- external C++ pipeline

Acceptance criteria:

- diarization can be applied after file transcription
- live dictation does not pay diarization cost by default
- host apps can hide diarization entirely

## Suggested File Breakdown

```text
Sources/CarbocationLocalSpeech/
  Audio/
  Diarization/
  Models/
  Providers/
  Transcription/

Sources/CarbocationAppleSpeechRuntime/
  AppleSpeechEngine.swift
  AppleSpeechAvailability.swift
  AppleSpeechAssetManager.swift

Sources/CarbocationWhisperRuntime/
  WhisperBackend.swift
  WhisperEngine.swift
  WhisperRuntimeSmoke.swift
  WhisperRuntimeModelProbe.swift

Sources/CarbocationLocalSpeechRuntime/
  LocalSpeechEngine.swift

Sources/CarbocationLocalSpeechUI/
  SpeechModelLibraryPickerView.swift
  SpeechModelPickerLabelPolicy.swift
  SpeechSettingsView.swift
  MicrophonePermissionStatusView.swift
  LiveTranscriptDebugView.swift

Sources/CLSSmoke/
  CLSSmokeApp.swift
```

## Test Matrix

Always-on tests:

- selection storage round-trips installed and system providers
- provider capabilities and availability mapping
- model metadata import/delete/synthesize
- system providers excluded from installed disk usage
- multi-asset model storage
- URL parsing
- partial downloads
- VAD thresholding on generated silence/speech samples
- chunk overlap and commit semantics
- speaker attribution merge
- transcript event ordering
- mock transcriber cancellation
- UI label policy for Apple Speech, recommended curated models, and best installed models

Conditional tests:

- whisper runtime file transcription with `CARBOCATION_LOCAL_SPEECH_TEST_MODEL`
- Core ML acceleration smoke with `CARBOCATION_LOCAL_SPEECH_TEST_COREML_MODEL`
- Apple Speech live transcription with `CARBOCATION_RUN_APPLE_SPEECH_LIVE_TEST=1`
- microphone capture should remain a manual smoke-app workflow, not a normal CI test

## Defaults Chosen

- Apple system provider target name: `CarbocationAppleSpeechRuntime`.
- Unified runtime target name: `CarbocationLocalSpeechRuntime`.
- Preferred host-app runtime: `LocalSpeechEngine`.
- Persisted Apple Speech selection value: `system.apple-speech`.
- First Apple provider label: `Built In`.
- First release should support Apple Speech as a v1 provider, not just document it as future work.
- Apple Intelligence should be used through `CarbocationLocalLLMRuntime` after transcription, not as the transcription provider.
