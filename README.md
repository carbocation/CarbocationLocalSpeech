# CarbocationLocalSpeech

CarbocationLocalSpeech gives macOS and iOS apps local, on-device speech-to-text — Whisper or Apple Speech, behind one Swift API. It handles model storage, downloads, provider selection, and ships a SwiftUI settings pane. You bring the hotkeys, paste behavior, and product UX.

The package owns shared speech infrastructure: neutral model storage, Whisper model management, provider selection, transcript types, a unified runtime facade, and SwiftUI surfaces. Host apps own product behavior: hotkeys, paste/type policy, dictation rules, command parsing, prompts, onboarding, and post-transcription cleanup.

> **Who is this for?** If you are wiring this package into an app, start with [Quick Start](#quick-start). If you are working on the package itself, jump to [For Package Developers](#for-package-developers).

## Contents

- [Quick Start](#quick-start)
- [Integration Guide](#integration-guide)
- [Requirements](#requirements)
- [Reference](#reference)
- [For Package Developers](#for-package-developers)

## Quick Start

Add the package, pick the products you need, and call the runtime. Published release tags ship a prebuilt `whisper.xcframework` for macOS, iOS devices, and iOS simulators — no submodules, no build scripts in consuming apps.

### Add the package

In Xcode, use `File > Add Package Dependencies…` with this URL:

```text
https://github.com/carbocation/CarbocationLocalSpeech.git
```

Choose the latest published exact version, for example `0.3.0` after the `v0.3.0` binary release is published. Pin shipping apps to a tag — do not point them at `main`.

For a SwiftPM host package:

```swift
dependencies: [
    .package(
        url: "https://github.com/carbocation/CarbocationLocalSpeech.git",
        exact: "0.3.0"
    )
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "CarbocationLocalSpeech", package: "CarbocationLocalSpeech"),
            .product(name: "CarbocationLocalSpeechRuntime", package: "CarbocationLocalSpeech"),
            .product(name: "CarbocationLocalSpeechUI", package: "CarbocationLocalSpeech")
        ]
    )
]
```

### Pick your products

Most apps only need these three:

```swift
import CarbocationLocalSpeech         // core types
import CarbocationLocalSpeechRuntime  // unified Whisper + Apple Speech engine
import CarbocationLocalSpeechUI       // built-in settings + model picker
```

See [Products](#products) for the full list.

### Minimal working integration

Build a model library once at startup, then load a saved selection and transcribe a file:

```swift
@MainActor
func makeLibrary() -> SpeechModelLibrary {
    SpeechModelLibrary(
        root: SpeechModelStorage.modelsDirectory(appSupportFolderName: "YourApp")
    )
}

func transcribe(
    _ audioURL: URL,
    using library: SpeechModelLibrary,
    storedSelection: String
) async throws -> String {
    let selection = try LocalSpeechEngine.selection(from: storedSelection)

    try await LocalSpeechEngine.shared.load(
        selection: selection,
        from: library,
        options: SpeechLoadOptions(installSystemAssetsIfNeeded: true)
    )

    let transcript = try await LocalSpeechEngine.shared.transcribe(
        file: audioURL,
        options: TranscriptionOptions(useCase: .dictation, language: "en")
    )

    return transcript.text
}
```

`storedSelection` is whatever you persisted in `@AppStorage` or `UserDefaults`. See [Pick and persist a provider](#pick-and-persist-a-provider) for how to produce that value.

## Integration Guide

### Set up a model library

Each app creates one `SpeechModelLibrary`. The default helper writes models into a shared App Group (`group.com.carbocation.shared`) and falls back to your app's Application Support folder if the group is unavailable.

```swift
@MainActor
func makeLibrary() -> SpeechModelLibrary {
    SpeechModelLibrary(
        root: SpeechModelStorage.modelsDirectory(appSupportFolderName: "YourApp")
    )
}
```

To share installed Whisper models across multiple of your apps, give them the same App Group entitlement and pass that identifier explicitly:

```swift
let modelsRoot = SpeechModelStorage.modelsDirectory(
    sharedGroupIdentifier: "group.com.example.shared",
    appSupportFolderName: "YourApp"
)
let library = SpeechModelLibrary(root: modelsRoot)
```

For a fully custom location, bypass the helper:

```swift
let library = SpeechModelLibrary(root: customModelsRoot)
```

Installed Whisper models live in UUID directories under `SpeechModels/`, each with a `metadata.json` and one or more asset files.

### Pick and persist a provider

Persist `SpeechModelSelection.storageValue`, not a model filename. Installed Whisper models use UUID storage values; system providers use stable strings like `system.apple-speech`.

```swift
let systemOptions = await LocalSpeechEngine.systemModelOptions(locale: .current)
let installed = await MainActor.run { library.models.first }

let selection: SpeechModelSelection
if let appleSpeech = systemOptions.first(where: { $0.availability.isAvailable }) {
    selection = appleSpeech.selection
} else if let model = installed {
    selection = .installed(model.id)
} else {
    throw LocalSpeechEngineError.invalidSelection("No speech provider is available.")
}

let valueToPersist = selection.storageValue
```

Restore later with:

```swift
let selection = try LocalSpeechEngine.selection(from: valueFromPreferences)
```

### Transcribe a file

```swift
let loaded = try await LocalSpeechEngine.shared.load(
    selection: selection,
    from: library,
    options: SpeechLoadOptions(
        locale: .current,
        preload: true,
        installSystemAssetsIfNeeded: true
    )
)

let transcript = try await LocalSpeechEngine.shared.transcribe(
    file: audioURL,
    options: TranscriptionOptions(
        useCase: .dictation,
        language: "en",
        timestampMode: .segments
    )
)
```

Apple Speech does not accept every Whisper option — translation and word timestamps are rejected for it. Check `LocalSpeechEngine.capabilities(for:in:)` before exposing provider-specific controls.

`TranscriptionOptions.voiceActivityDetection` defaults to `.automatic`, which uses model VAD for live dictation streams and skips it for file transcription. Use `.enabled` or `.disabled` when you want to make the accuracy/power tradeoff explicit.

### Record live audio

Live recording is app-owned. Build a capture session, optionally wrap it with a recorder, and stream it through the engine:

```swift
let capture = AVAudioEngineCaptureSession()
let audio = capture.start(configuration: AudioCaptureConfiguration(
    preferredSampleRate: 16_000,
    preferredChannelCount: 1,
    frameDuration: 0.1
))

let recordingsDirectory = SpeechModelStorage
    .appSupportDirectory(appSupportFolderName: "YourApp")
    .appendingPathComponent("Recordings", isDirectory: true)

let recorder = AudioChunkFileRecorder(configuration: AudioRecordingConfiguration(
    fileURL: recordingsDirectory.appendingPathComponent("live-session.caf"),
    format: .cafFloat32,
    overwriteExistingFile: false,
    createParentDirectories: true
))
let recordedAudio = AudioChunkStreams.recording(audio, recorder: recorder)

let events = LocalSpeechEngine.shared.stream(
    audio: recordedAudio,
    options: StreamingTranscriptionOptions()
)

for try await event in events {
    // Update app UI with transcript events.
}

let recording = try await recorder.finish()
```

Use `.cafFloat32` to preserve captured float samples. Use `.wavPCM16` when another app needs WAV PCM — samples are clamped to `[-1, 1]` during conversion.

### Install a Whisper model

The bundled SwiftUI picker handles `.bin` imports, curated downloads, resume, and deletion. Drop it into a settings pane:

```swift
import CarbocationLocalSpeech
import CarbocationLocalSpeechRuntime
import CarbocationLocalSpeechUI
import SwiftUI

@MainActor
struct SpeechSettingsPane: View {
    let library: SpeechModelLibrary
    @AppStorage("SpeechModelSelection") private var selectionStorageValue = ""
    @State private var systemOptions: [SpeechSystemModelOption] = []

    var body: some View {
        SpeechSettingsView(
            library: library,
            selectionStorageValue: $selectionStorageValue,
            systemOptions: systemOptions
        )
        .task {
            systemOptions = await LocalSpeechEngine.systemModelOptions(locale: .current)
        }
    }
}
```

If you build your own UI, install a curated model with the core APIs:

```swift
let catalogModel = CuratedSpeechModelCatalog.entry(id: "small.en")!
let downloaded = try await SpeechModelDownloader.download(
    hfRepo: catalogModel.hfRepo!,
    hfFilename: catalogModel.hfFilename!,
    modelsRoot: library.root,
    displayName: catalogModel.displayName,
    expectedSHA256: catalogModel.sha256
)

let vadModel = CuratedSpeechModelCatalog.recommendedVADModel
let downloadedVAD = try await SpeechModelDownloader.download(
    hfRepo: vadModel.hfRepo,
    hfFilename: vadModel.hfFilename,
    modelsRoot: library.root,
    displayName: vadModel.displayName,
    expectedSHA256: vadModel.sha256
)

let installed = try await MainActor.run {
    try library.add(
        primaryAssetAt: downloaded.tempURL,
        displayName: catalogModel.displayName,
        filename: catalogModel.hfFilename,
        source: .curated,
        sourceURL: catalogModel.downloadURL,
        hfRepo: catalogModel.hfRepo,
        hfFilename: catalogModel.hfFilename,
        sha256: downloaded.sha256,
        capabilities: catalogModel.capabilities,
        vadAssetAt: downloadedVAD.tempURL,
        vadFilename: vadModel.hfFilename,
        vadSHA256: downloadedVAD.sha256
    )
}

let selection = SpeechModelSelection.installed(installed.id)
```

Whisper model weights are not bundled. Apps either import local `.bin` files, use the curated Hugging Face downloads, or ship their own download UI.

### How it fits with an LLM cleanup step

Dictation apps usually compose this package with an LLM cleanup step:

```text
CarbocationLocalSpeechRuntime
  Apple Speech or Whisper -> transcript

CarbocationLocalLLMRuntime
  transcript -> cleanup, formatting, command classification

Host app
  hotkeys, Accessibility paste/type, settings policy, product UX
```

Meeting and file-transcription apps add diarization after transcription:

```text
audio file
  -> provider transcription
  -> optional diarization
  -> speaker attribution merge
  -> host-owned notes/export workflow
```

## Requirements

**Build**

- macOS 14 or newer
- iOS 17 or newer for iOS apps
- Swift 5.9 or newer
- Xcode command line tools

**Permissions and entitlements**

Add the keys you actually use to your app's `Info.plist`:

| Key | When you need it |
| --- | --- |
| `NSMicrophoneUsageDescription` | Capturing microphone audio |
| `NSAudioCaptureUsageDescription` | Capturing macOS system audio |
| `NSSpeechRecognitionUsageDescription` | Offering Apple Speech |

You also need outgoing network access if a sandboxed app downloads Whisper models, and an App Group entitlement if you want multiple of your apps to share installed models.

Apple Speech is exposed only when the SDK, OS, locale, permissions, and on-device assets all support it. The modern Apple Speech path requires macOS 26 or iOS 26 at runtime. The package reports availability through `LocalSpeechEngine.systemModelOptions(locale:)`.

## Reference

### Products

| Product | Purpose | Add when |
| --- | --- | --- |
| `CarbocationLocalSpeech` | Core model library, provider selection, audio, transcript, streaming, VAD, diarization types. | App code imports core types directly, or you only need shared model storage. |
| `CarbocationLocalSpeechRuntime` | Unified facade that routes selections to Whisper or Apple Speech. | Most apps. This is the entry point. |
| `CarbocationLocalSpeechUI` | SwiftUI settings, provider picker, model picker, status, diagnostics. | You want the bundled UI surfaces. |
| `CarbocationWhisperRuntime` | Lower-level whisper.cpp runtime. | You need provider-specific control the unified runtime does not expose. |
| `CarbocationAppleSpeechRuntime` | Lower-level Apple Speech runtime. | Same as above, for Apple Speech. |

### How the binary release works

The **Publish Whisper Binary Artifact** workflow is the path that makes the package directly importable by ordinary macOS and iOS apps. It builds `Vendor/whisper-artifacts/release/whisper.xcframework`, zips it, computes the SwiftPM checksum, writes that release URL/checksum into `Package.swift`, creates the tag, uploads `whisper.xcframework.zip`, and validates the published tag from a clean consumer package.

For a published tag such as `v0.3.0`, Xcode resolves the package from GitHub, downloads `whisper.xcframework.zip` from the release asset URL recorded in that tag's `Package.swift`, links the products you chose, and builds your app.

The binary artifact is a static XCFramework with macOS, iOS device, and iOS simulator slices. SwiftPM handles the link step; the Whisper runtime declares its own system links for `Metal`, `Accelerate`, `AVFoundation`, `CoreML`, `Foundation`, and `libc++`. Apple Speech has no package artifact — when the SDK, OS, locale, and assets line up, the runtime exposes it as an available system model.

> **Heads up.** As a binary-target consumer your app does not need a sibling checkout, a `Vendor/whisper.cpp` submodule, the `Scripts/build-whisper-from-xcode.sh` build phase, the `CARBOCATION_LOCAL_SPEECH_BINARY_ARTIFACT_PATH` env var, a prebuilt `Vendor/whisper-artifacts/current` directory, or `../CarbocationLocalSpeech` in any path. Those exist only for local package development.

For unreleased work you can point at `branch: "main"`, but Whisper inference then needs a stamped, local, or source-built artifact. Local source-built Whisper artifacts are macOS-only; iOS Whisper consumers need a local or published XCFramework. Apple Speech and core APIs still work without a Whisper artifact — the runtime simply reports Whisper as unavailable.

| Consumer state | macOS | iOS device | iOS simulator |
| --- | --- | --- | --- |
| Published binary tag | Imports the package and runs Whisper through the downloaded XCFramework. | Imports the package and runs Whisper through the downloaded XCFramework. | Imports the package and runs Whisper through the downloaded XCFramework; Metal is disabled by default for simulator runtime safety. |
| `main` without a local binary artifact | Builds core/UI/Apple Speech surfaces; Whisper reports unavailable unless a local macOS source artifact exists. | Builds core/UI/Apple Speech surfaces; Whisper reports unavailable. | Builds core/UI/Apple Speech surfaces; Whisper reports unavailable. |
| `main` plus `Vendor/whisper-artifacts/release/whisper.xcframework` | Imports and runs against the local XCFramework. | Imports and runs against the local XCFramework. | Imports and runs against the local XCFramework; Metal is disabled by default for simulator runtime safety. |

---

## For Package Developers

### Clone and build

Clone with the `whisper.cpp` submodule:

```sh
git clone --recurse-submodules https://github.com/carbocation/CarbocationLocalSpeech.git
cd CarbocationLocalSpeech
```

If you already cloned without the submodule:

```sh
git submodule update --init --recursive
```

Run the tests:

```sh
swift test
```

The default suite skips live inference. Set `CARBOCATION_LOCAL_SPEECH_TEST_MODEL` to the path of an installed `.bin` model to enable it.

### Build the local Whisper source artifact

For local Whisper inference from this checkout:

```sh
Scripts/build-whisper-macos.sh
swift build
```

The script writes:

```text
Vendor/whisper-artifacts/current/lib/libwhisper-combined.a
Vendor/whisper-artifacts/current/include/
```

Both paths are gitignored.

Useful overrides:

```sh
WHISPER_COREML=ON Scripts/build-whisper-macos.sh
MACOSX_DEPLOYMENT_TARGET=14.0 Scripts/build-whisper-macos.sh
```

The package's `whisper` SwiftPM module imports a checked-in copy of the upstream public headers. After updating `Vendor/whisper.cpp`, sync and verify them:

```sh
Scripts/sync-whisper-headers.sh
Scripts/sync-whisper-headers.sh --check
```

### Run the CLSSmoke developer app

`CLSSmoke` is a standalone local app for package development. It is intentionally outside the root Swift package product list so package consumers only see the SDK/runtime/UI libraries.

Open `Apps/Apps.xcodeproj`, then run the paired `CLSSmoke-iOS` or `CLSSmoke-macOS` scheme. The shared apps project references this checkout as a local package dependency via `..`, matching the dependency direction of a consuming app.

### Bump whisper.cpp

Move the submodule to the latest stable upstream tag and resync headers:

```sh
Scripts/bump-whisper-upstream.sh
```

Pin a specific tag:

```sh
Scripts/bump-whisper-upstream.sh vX.Y.Z
```

Full local release-path validation:

```sh
Scripts/bump-whisper-upstream.sh vX.Y.Z --validate
```

Validation builds `whisper.xcframework`, runs `swift test`, and validates a clean iOS consumer against the generated binary artifact. `--dry-run` shows the tag that would be selected without changing the submodule.

### Use a local binary artifact

To test the package as a binary-target consumer before publishing:

```sh
Scripts/build-whisper-xcframework.sh
swift test
Scripts/test-local-binary-artifact.sh
```

`Package.swift` switches to a local `.binaryTarget` automatically when `Vendor/whisper-artifacts/release/whisper.xcframework` exists. `CARBOCATION_LOCAL_SPEECH_BINARY_ARTIFACT_PATH` can still point at a different local XCFramework. The local smoke script creates a temporary clean iOS consumer package and builds it against `Vendor/whisper-artifacts/release/whisper.xcframework`.
The generated XCFramework includes macOS, iOS device, and iOS simulator slices. Use `IOS_DEPLOYMENT_TARGET=17.0` to override the default iOS deployment target if needed.

### Prepare a release artifact

Build, zip, and checksum the XCFramework:

```sh
Scripts/build-whisper-xcframework.sh
```

The script emits:

```text
Vendor/whisper-artifacts/release/whisper.xcframework
Vendor/whisper-artifacts/release/whisper.xcframework.zip
Vendor/whisper-artifacts/release/whisper.xcframework.zip.checksum
```

To prepare a release manifest manually:

```sh
Scripts/set-whisper-binary-artifact.sh \
  "https://github.com/carbocation/CarbocationLocalSpeech/releases/download/v0.3.0/whisper.xcframework.zip" \
  "$(cat Vendor/whisper-artifacts/release/whisper.xcframework.zip.checksum)"
```

### Publish a binary release

Use the **Publish Whisper Binary Artifact** GitHub workflow.

First run with:

- `tag`: `v0.3.0` for the next public release; future releases use `vX.Y.Z`
- `prerelease`: `true` for shakedown releases
- `dry_run`: `true`

The dry run verifies synced headers, builds the artifact, stamps `Package.swift`, validates the package against the local XCFramework, and builds a clean iOS consumer against the same local artifact without pushing.

Then run the workflow again with the same tag and `dry_run=false`. The release run creates a tag-only release commit with the binary URL/checksum, creates the tag, uploads the release asset, and validates the published release from a clean temporary consumer package.

Keeping the manifest change on the release tag lets `main` stay source-build friendly while tagged consumers get the binary target.

After the release run succeeds, downstream macOS and iOS projects should add the package by exact version, not by branch. SwiftPM then imports the same public products from the tag and downloads the release XCFramework automatically.

### Validate a published release

```sh
Scripts/test-binary-release.sh v0.3.0
```

The release workflow runs the same smoke test after uploading the GitHub release asset. This catches problems local validation cannot: tag resolution, checksum mismatch, asset availability, downstream product imports, and Whisper symbol linkage from the published binary target.

### Smoke-test iOS Whisper on device

The automated release smoke builds an iOS simulator consumer, but performance and Metal behavior still need a real-device check before promoting an iOS-capable release. Use a tiny or small whisper.cpp model, install it through `SpeechModelLibraryPickerView` or a host-app import flow, then run file and live microphone transcription on a physical iPhone with a Release build.

### Runtime modes

`Package.swift` supports these Whisper runtime modes:

- **Source artifact** — uses `Vendor/whisper-artifacts/current/lib/libwhisper-combined.a` when present.
- **Forced source mode** — set `CARBOCATION_LOCAL_SPEECH_FORCE_SOURCE_WHISPER=1`.
- **Local binary artifact** — uses `Vendor/whisper-artifacts/release/whisper.xcframework` when present, or `CARBOCATION_LOCAL_SPEECH_BINARY_ARTIFACT_PATH` when set.
- **Published binary release** — non-empty `whisperBinaryArtifactURL` and `whisperBinaryArtifactChecksum`.
- **No Whisper artifact** — the package builds, but Whisper inference reports the missing macOS source artifact or the missing iOS binary artifact at runtime.

### Package layout

```text
Apps/
  Apps.xcodeproj/                 Shared Xcode project for local developer apps
  CLSSmoke/                       Standalone local smoke-test app sources and resources
Sources/
  CarbocationLocalSpeech/         Core models, audio, transcript, provider, VAD, diarization APIs
  CarbocationLocalSpeechRuntime/  Unified facade over Whisper and Apple Speech
  CarbocationWhisperRuntime/      whisper.cpp-backed runtime
  CarbocationAppleSpeechRuntime/  Apple Speech-backed runtime
  CarbocationLocalSpeechUI/       SwiftUI settings and picker views
  whisper/                        module map and synced C headers for whisper.cpp
Tests/
Scripts/
  bump-whisper-upstream.sh        Updates the whisper.cpp submodule tag and synced headers
Vendor/
  whisper.cpp/                    git submodule
```

### Ownership boundaries

Stays in this package:

- speech model download, import, deletion, metadata
- provider-aware model selection
- Apple Speech availability and asset readiness
- microphone, system-audio capture, file-audio preparation
- sample-rate conversion
- VAD, chunking, emulated streaming windows
- stable transcript, word timestamp, speaker-attribution types
- SwiftUI provider/model management surfaces
- smoke tests and diagnostics hooks

Stays in host apps:

- app-specific prompts and LLM cleanup
- command parsing policy
- global hotkeys
- paste/type behavior through Accessibility APIs
- meeting, memo, dictation UX policy
- onboarding text and migrations
- entitlement choices beyond documenting requirements
