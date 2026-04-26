# CarbocationLocalSpeech

Shared local speech infrastructure for Carbocation macOS apps.

This package should do for local speech what `CarbocationLocalLLM` now does for local text generation: provide neutral model storage, model library management, provider-aware runtime selection, shared SwiftUI management UI, and a smoke-test app. Host apps should keep product-specific dictation policy, prompts, hotkeys, Accessibility paste/type behavior, onboarding, migrations, and workflows in the host app.

## Scope

`CarbocationLocalSpeech` is the durable abstraction. Whisper and Apple Speech are providers.

The package should centralize:

- speech model download, import, deletion, and metadata for user-managed models
- Apple system speech availability and asset readiness
- provider-aware model selection for installed and system speech providers
- microphone capture and file-audio preparation
- sample-rate conversion to provider-ready audio
- voice activity detection and chunking
- file transcription
- streaming-ish transcription for dictation and live capture
- stable transcript, word timestamp, and speaker-attribution types
- optional diarization interfaces and merge utilities
- SwiftUI model/provider and speech settings surfaces
- diagnostics, smoke tests, and benchmark hooks

The package should not own:

- app-specific prompts or LLM cleanup
- command parsing policy
- global hotkeys
- paste/type behavior through Accessibility APIs
- meeting, memo, or dictation UX policy
- product-specific onboarding text
- entitlement decisions beyond documenting requirements

Apple Intelligence belongs in the post-transcription LLM step through `CarbocationLocalLLMRuntime`. Transcription should use speech providers: `whisper.cpp` for user-managed local models and Apple Speech for system-managed speech recognition.

## Planned Products

The package should follow the current `CarbocationLocalLLM` product split:

```text
CarbocationLocalSpeech
  Core Swift models, model library, provider selection, audio pipeline,
  transcript types, protocols, and mock backends.

CarbocationWhisperRuntime
  Lower-level whisper.cpp-backed runtime and model probing.

CarbocationAppleSpeechRuntime
  Lower-level Apple Speech runtime backed by SpeechAnalyzer,
  SpeechTranscriber, DictationTranscriber, and AssetInventory.

CarbocationLocalSpeechRuntime
  Preferred unified facade for installed Whisper models and available
  Apple system speech providers.

CarbocationLocalSpeechUI
  Shared SwiftUI provider picker, model picker, permission/status surfaces,
  settings, and diagnostics.

CLSSmoke
  Xcode-friendly smoke app for provider selection, model download/import,
  file transcription, and mic capture diagnostics.
```

Later adapters can be added as separate runtime products if they prove useful:

```text
CarbocationWhisperKitRuntime
CarbocationSpeakerKitRuntime
```

## Target Package Shape

```text
Package.swift
Sources/
  CarbocationLocalSpeech/
    Audio/
    Diarization/
    Models/
    Providers/
    Transcription/
  CarbocationWhisperRuntime/
  CarbocationAppleSpeechRuntime/
  CarbocationLocalSpeechRuntime/
  CarbocationLocalSpeechUI/
  CLSSmoke/
  whisper/
    module.modulemap
Tests/
  CarbocationLocalSpeechTests/
  CarbocationWhisperRuntimeTests/
  CarbocationAppleSpeechRuntimeTests/
  CarbocationLocalSpeechRuntimeTests/
  CarbocationLocalSpeechUITests/
Scripts/
  build-whisper-macos.sh
  build-whisper-xcframework.sh
  build-whisper-from-xcode.sh
  set-whisper-binary-artifact.sh
  test-binary-release.sh
Vendor/
  whisper.cpp/
```

`Package.swift` should support the same whisper runtime modes as `CarbocationLocalLLM` uses for llama:

- source-build mode from `Vendor/whisper-artifacts/current`
- local binary validation mode via `CARBOCATION_LOCAL_SPEECH_BINARY_ARTIFACT_PATH`
- published binary mode via stamped artifact URL and checksum constants on release tags

Apple Speech has no package-owned model artifact. It is exposed as a system provider when the app is built with an SDK that includes the newer Speech APIs and the current device/locale can run them.

## Runtime Strategy

Host apps should use `CarbocationLocalSpeechRuntime` by default.

```swift
import CarbocationLocalSpeech
import CarbocationLocalSpeechRuntime

let selection = try LocalSpeechEngine.selection(from: storedSelectionID)
let loaded = try await LocalSpeechEngine.shared.load(
    selection: selection,
    from: speechModelLibrary,
    options: SpeechLoadOptions(locale: Locale.current)
)

let transcript = try await LocalSpeechEngine.shared.transcribe(
    file: audioURL,
    options: TranscriptionOptions(useCase: .general)
)
```

`CarbocationWhisperRuntime` should expose `WhisperEngine` for lower-level control over a loaded whisper.cpp model. `CarbocationAppleSpeechRuntime` should expose `AppleSpeechEngine` for lower-level control over Apple Speech availability, asset installation, and transcription behavior.

Live dictation should remain a shared audio pipeline over provider transcription, VAD, overlap windows, and partial/final text events. Do not promise true token streaming semantics: speech providers do not behave like LLM token streams.

## Provider Selection

Persist a provider-aware selection string, not just a UUID:

```swift
public enum SpeechModelSelection: Codable, Hashable, Sendable {
    case installed(UUID)
    case system(SpeechSystemModelID)
}
```

Installed selections point at user-managed model directories in `SpeechModelLibrary`. System selections point at provider options returned by:

```swift
await LocalSpeechEngine.systemModelOptions(locale: Locale.current)
```

The first system provider is:

```swift
SpeechSystemModelID.appleSpeech // storage value: "system.apple-speech"
```

Apple Speech should be labeled as built in, not as a model download. If it is unavailable, host apps should either hide it or show the availability reason in diagnostics/settings.

## Storage Model

Use the shared Carbocation App Group when available and fall back to per-app Application Support, mirroring `ModelStorage` from `CarbocationLocalLLM`.

Default root:

```text
~/Library/Group Containers/group.com.carbocation.shared/SpeechModels
```

Fallback root:

```text
~/Library/Application Support/<AppName>/SpeechModels
```

Each installed speech model should live in its own UUID directory:

```text
SpeechModels/
  <UUID>/
    metadata.json
    ggml-base.en.bin
    ggml-base.en-encoder.mlmodelc/       # optional
```

The metadata format must support multi-file model assets because whisper.cpp can use a primary GGML model plus optional acceleration assets. Apple Speech assets are system-managed through `AssetInventory` and must not be represented as installed speech models.

## Recommended App Wiring

Dictation-style host apps should compose this package with `CarbocationLocalLLMRuntime`:

```text
CarbocationLocalSpeechRuntime
  Apple Speech or Whisper -> partial/final transcript

CarbocationLocalLLMRuntime
  final transcript -> cleanup, formatting, command classification

Host app
  hotkeys, paste/type, product UX, prompts, settings policy
```

Meeting or file-transcription host apps can add diarization after transcription:

```text
file audio
  -> provider transcription
  -> optional diarization
  -> speaker attribution merge
  -> host-owned notes/export workflow
```

## Implementation Plan

The first useful version should include both provider abstraction and Apple Speech support:

1. Core transcript, audio, provider-selection, and model-library types.
2. `CarbocationAppleSpeechRuntime` with availability, asset readiness, and transcription through Apple Speech.
3. `CarbocationWhisperRuntime` with whisper.cpp source-build file transcription.
4. `CarbocationLocalSpeechRuntime` unified facade for installed and system providers.
5. SwiftUI provider/model picker and provider-aware smoke app.
6. Mic capture, resampling, VAD, chunking, and streaming-ish events.
7. Binary XCFramework release path for whisper.cpp.
8. Optional diarization interfaces and delayed speaker merge.

See [API Design](docs/API_DESIGN.md) and [Implementation Plan](docs/IMPLEMENTATION_PLAN.md) for the fuller design.
