# CarbocationLocalSpeech

Shared local-speech infrastructure for Carbocation macOS apps.

This package provides neutral speech model storage, Whisper model management,
provider selection, transcription types, a unified runtime facade for Whisper and
Apple Speech, and shared SwiftUI settings surfaces.

Host apps remain responsible for product behavior: hotkeys, paste/type behavior, dictation policy, command parsing, prompts, onboarding, and post-transcription cleanup.

## Consuming Apps

For normal app integration, use the `v0.1.0` release. Do not point shipping apps
at `main`.

The release tag's `Package.swift` points SwiftPM at the published
`whisper.xcframework.zip`, so your app does not need a sibling checkout,
`Vendor/whisper.cpp`, or any Whisper build script.

### Quick Start

1. Add the package URL in Xcode with `File > Add Package Dependencies...`:

```text
https://github.com/carbocation/CarbocationLocalSpeech.git
```

2. Choose `Exact Version` `0.1.0` while integrating. The Git tag is `v0.1.0`.

For a Swift package host app, add the dependency directly:

```swift
dependencies: [
    .package(
        url: "https://github.com/carbocation/CarbocationLocalSpeech.git",
        exact: "0.1.0"
    )
]
```

3. Add the products your app uses:

- `CarbocationLocalSpeechRuntime` for the unified Whisper/Apple Speech engine.
- `CarbocationLocalSpeechUI` if you want the built-in settings and model picker.
- `CarbocationLocalSpeech` when app code imports core model-library or transcript types directly.

Most apps start with these imports:

```swift
import CarbocationLocalSpeech
import CarbocationLocalSpeechRuntime
import CarbocationLocalSpeechUI
```

### Basic Wiring

Create one model library for your app. If the default shared App Group is not
available, this falls back to your app's Application Support folder.

```swift
@MainActor
func makeSpeechModelLibrary() -> SpeechModelLibrary {
    SpeechModelLibrary(
        root: SpeechModelStorage.modelsDirectory(appSupportFolderName: "YourApp")
    )
}
```

Drop the bundled settings view into your preferences window to let users import
or download Whisper models and pick Apple Speech when it is available:

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

When it is time to transcribe, restore the stored selection, load it, and send an
audio file to the shared engine:

```swift
let selection = try LocalSpeechEngine.selection(from: selectionStorageValue)

try await LocalSpeechEngine.shared.load(
    selection: selection,
    from: speechModelLibrary,
    options: SpeechLoadOptions(installSystemAssetsIfNeeded: true)
)

let transcript = try await LocalSpeechEngine.shared.transcribe(
    file: audioURL,
    options: TranscriptionOptions(useCase: .dictation, language: "en")
)

print(transcript.text)
```

If you do not use the bundled UI, import an existing whisper.cpp `.bin` model and
persist the resulting selection value:

```swift
let model = try speechModelLibrary.importFile(
    at: modelURL,
    displayName: "Whisper small.en"
)
let selectionStorageValue = SpeechModelSelection.installed(model.id).storageValue
```

### Requirements

- macOS 14 or newer for the package.
- Swift 5.9 or newer.
- Xcode command line tools.
- `NSMicrophoneUsageDescription` if your app captures microphone audio.
- `NSAudioCaptureUsageDescription` if your app captures macOS system audio.
- `NSSpeechRecognitionUsageDescription` if your app offers Apple Speech.
- Outgoing network access if a sandboxed app downloads Whisper models.
- An App Group entitlement if you want multiple apps to share the same installed speech models.

Apple Speech is exposed only when the current SDK, operating system, locale, permissions, and system speech assets support it. The package reports that state through `LocalSpeechEngine.systemModelOptions(locale:)`.

Whisper model weights are not bundled with the package. Apps can import local whisper.cpp `.bin` files, use the curated Hugging Face downloads, or provide their own download UI.

### Product Guide

- `CarbocationLocalSpeech`: core model-library, provider-selection, audio, transcript, streaming, VAD, and diarization types.
- `CarbocationLocalSpeechRuntime`: preferred facade for apps. It routes provider-aware selections to Whisper or Apple Speech.
- `CarbocationLocalSpeechUI`: SwiftUI settings, provider picker, model picker, permission/status, and diagnostics surfaces.
- `CarbocationWhisperRuntime`: lower-level whisper.cpp runtime.
- `CarbocationAppleSpeechRuntime`: lower-level Apple Speech runtime.
- `CLSSmoke`: local smoke-test app for package development.

Most apps should add `CarbocationLocalSpeechRuntime` and optionally
`CarbocationLocalSpeechUI` to the app target. Add `CarbocationLocalSpeech`
explicitly when host app code imports the core model-library or transcript types
directly. Apps that only need shared model storage or metadata can use
`CarbocationLocalSpeech` alone. Use `CarbocationWhisperRuntime` or
`CarbocationAppleSpeechRuntime` directly only when the host app needs
provider-specific control that is not exposed through the unified runtime.

Filesystem paths such as `../CarbocationLocalSpeech` should not appear in app
source or Xcode package dependencies for the binary-release path.

In `Package.swift`, target dependencies look like this:

```swift
dependencies: [
    .package(
        url: "https://github.com/carbocation/CarbocationLocalSpeech.git",
        exact: "0.1.0"
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

### What Xcode Should Build

For the `v0.1.0` release tag, Xcode should:

1. Resolve `CarbocationLocalSpeech` from GitHub at version `0.1.0`.
2. Download `whisper.xcframework.zip` from the release asset URL recorded in that tag's `Package.swift`.
3. Link the selected products into the host app target.
4. Build the app normally.

The host app should not add `Scripts/build-whisper-from-xcode.sh`, initialize
`Vendor/whisper.cpp`, set `CARBOCATION_LOCAL_SPEECH_BINARY_ARTIFACT_PATH`, or
prebuild `Vendor/whisper-artifacts/current`. Those steps are only for local
package development or temporary adjacent-checkout migration work.

The binary artifact is a static XCFramework. SwiftPM handles the package link
step, and the Whisper runtime declares its own system links for `Metal`,
`Accelerate`, `AVFoundation`, `CoreML`, `Foundation`, and `libc++`.

Apple Speech has no package artifact. When the app is built with a compatible SDK
and runs on an operating system, locale, permission state, and asset state that
support Apple Speech, `CarbocationLocalSpeechRuntime` exposes it as an available
system model.

For unreleased development, you can point at `branch: "main"`, but Whisper
inference requires either a stamped binary artifact, a local binary artifact, or
a locally built source artifact. Apple Speech and the core APIs can still be
developed without a Whisper artifact when the runtime reports Whisper as
unavailable.

### Create a Model Library

Use an App Group if multiple apps should see the same installed Whisper models. Each app target must have the same App Group entitlement, and each app must pass that same identifier to `SpeechModelStorage.modelsDirectory(sharedGroupIdentifier:appSupportFolderName:)`.

If the group identifier is omitted, the helper defaults to Carbocation's shared group (`group.com.carbocation.shared`). If the app is not entitled for that group, or for the group you pass, macOS returns no group container and the package falls back to a per-app Application Support folder.

```swift
import CarbocationLocalSpeech

@MainActor
func makeSpeechModelLibrary() -> SpeechModelLibrary {
    let modelsRoot = SpeechModelStorage.modelsDirectory(
        sharedGroupIdentifier: "group.com.example.shared",
        appSupportFolderName: "YourApp"
    )
    return SpeechModelLibrary(root: modelsRoot)
}
```

Installed Whisper models are stored as UUID directories under `SpeechModels/` with a `metadata.json` file and one or more assets.

For a completely custom location, bypass the helper and construct the library with the root URL you want:

```swift
let speechModelLibrary = SpeechModelLibrary(root: customModelsRoot)
```

### Choose a Provider

Persist `SpeechModelSelection.storageValue`, not just a model filename. Installed Whisper models use UUID storage values; system providers use stable strings such as `system.apple-speech`.

```swift
import CarbocationLocalSpeech
import CarbocationLocalSpeechRuntime

let systemOptions = await LocalSpeechEngine.systemModelOptions(locale: .current)
let installedModel = await MainActor.run { speechModelLibrary.models.first }

let selection: SpeechModelSelection
if let appleSpeech = systemOptions.first(where: { $0.availability.isAvailable }) {
    selection = appleSpeech.selection
} else if let installed = installedModel {
    selection = .installed(installed.id)
} else {
    throw LocalSpeechEngineError.invalidSelection("No speech provider is available.")
}

let valueToPersist = selection.storageValue
```

Restore a saved selection like this:

```swift
let selection = try LocalSpeechEngine.selection(from: valueFromPreferences)
```

### Transcribe a File

Load the selection once, then transcribe files or prepared audio through the shared engine:

```swift
import CarbocationLocalSpeech
import CarbocationLocalSpeechRuntime

let loaded = try await LocalSpeechEngine.shared.load(
    selection: selection,
    from: speechModelLibrary,
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

print(loaded.displayName)
print(transcript.text)
```

Apple Speech does not support every Whisper option. For example, translation and word timestamps are rejected for Apple Speech. Check `LocalSpeechEngine.capabilities(for:in:)` before exposing provider-specific controls.

Model-backed VAD is request-configurable with `TranscriptionOptions.voiceActivityDetection`. The default `.automatic` policy uses model VAD for live dictation-style streams and avoids it for file transcription; use `.enabled` or `.disabled` when the accuracy/power tradeoff should be explicit.

### Record Live Audio

Live recording is app-owned. Create a recorder for the file location and retention policy you want, then wrap the public `AudioChunk` stream before passing it into transcription:

```swift
import CarbocationLocalSpeech
import CarbocationLocalSpeechRuntime

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
print(recording?.duration ?? 0)
```

Use `.cafFloat32` to preserve captured float samples. Use `.wavPCM16` when another app needs WAV PCM; samples are clamped to `[-1, 1]` during conversion.

### Install a Whisper Model

The SwiftUI picker can import local `.bin` files, download curated Whisper models, resume interrupted downloads, and delete installed models. Use it directly in a settings surface:

```swift
import CarbocationLocalSpeech
import CarbocationLocalSpeechRuntime
import CarbocationLocalSpeechUI
import SwiftUI

@MainActor
struct SpeechSettingsPane: View {
    let library: SpeechModelLibrary
    @Binding var selectionStorageValue: String
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

If you are building your own UI, download and install a curated model with the core APIs:

```swift
let catalogModel = CuratedSpeechModelCatalog.entry(id: "small.en")!

let downloaded = try await SpeechModelDownloader.download(
    hfRepo: catalogModel.hfRepo!,
    hfFilename: catalogModel.hfFilename!,
    modelsRoot: speechModelLibrary.root,
    displayName: catalogModel.displayName,
    expectedSHA256: catalogModel.sha256
)
let vadModel = CuratedSpeechModelCatalog.recommendedVADModel
let downloadedVAD = try await SpeechModelDownloader.download(
    hfRepo: vadModel.hfRepo,
    hfFilename: vadModel.hfFilename,
    modelsRoot: speechModelLibrary.root,
    displayName: vadModel.displayName,
    expectedSHA256: vadModel.sha256
)

let installed = try await MainActor.run {
    try speechModelLibrary.add(
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

### App Architecture

Dictation apps usually compose this package with an LLM cleanup step:

```text
CarbocationLocalSpeechRuntime
  Apple Speech or Whisper -> transcript

CarbocationLocalLLMRuntime
  transcript -> cleanup, formatting, command classification

Host app
  hotkeys, Accessibility paste/type, settings policy, product UX
```

Meeting and file-transcription apps can add diarization after transcription:

```text
audio file
  -> provider transcription
  -> optional diarization
  -> speaker attribution merge
  -> host-owned notes/export workflow
```

## For Package Developers

### Clone and Build

Clone with the `whisper.cpp` submodule:

```sh
git clone --recurse-submodules https://github.com/carbocation/CarbocationLocalSpeech.git
cd CarbocationLocalSpeech
```

If you already cloned the repo:

```sh
git submodule update --init --recursive
```

Run the Swift tests:

```sh
swift test
```

The default test suite does not require a real Whisper model. Live inference tests are skipped unless `CARBOCATION_LOCAL_SPEECH_TEST_MODEL` points at an installed whisper.cpp `.bin` model.

### Build the Local Whisper Source Artifact

For local Whisper inference from this checkout, build the static source artifact:

```sh
Scripts/build-whisper-macos.sh
swift build
```

The script writes:

```text
Vendor/whisper-artifacts/current/lib/libwhisper-combined.a
Vendor/whisper-artifacts/current/include/
```

Those files are intentionally ignored by git.

Useful build overrides:

```sh
WHISPER_COREML=ON Scripts/build-whisper-macos.sh
MACOSX_DEPLOYMENT_TARGET=14.0 Scripts/build-whisper-macos.sh
```

The package's SwiftPM `whisper` module imports a checked-in copy of the
upstream public headers. After updating `Vendor/whisper.cpp`, sync and verify
that header bundle:

```sh
Scripts/sync-whisper-headers.sh
Scripts/sync-whisper-headers.sh --check
```

### Bump whisper.cpp

To move the vendored whisper.cpp submodule to the latest stable upstream tag
and sync the checked-in headers:

```sh
Scripts/bump-whisper-upstream.sh
```

To pin a specific tag:

```sh
Scripts/bump-whisper-upstream.sh vX.Y.Z
```

For a full local release-path validation after the bump:

```sh
Scripts/bump-whisper-upstream.sh vX.Y.Z --validate
```

The validation mode builds `whisper.xcframework` and runs `swift test` with
`CARBOCATION_LOCAL_SPEECH_BINARY_ARTIFACT_PATH` set. Use `--dry-run` to see the
tag that would be selected without changing the submodule.

### Use a Local Binary Artifact

To test the package as a binary-target consumer before publishing:

```sh
Scripts/build-whisper-xcframework.sh
CARBOCATION_LOCAL_SPEECH_BINARY_ARTIFACT_PATH=Vendor/whisper-artifacts/release/whisper.xcframework swift test
```

`Package.swift` switches to a local `.binaryTarget` when `CARBOCATION_LOCAL_SPEECH_BINARY_ARTIFACT_PATH` is set.

### Prepare a GitHub Release Artifact

Build, zip, and checksum the XCFramework:

```sh
Scripts/build-whisper-xcframework.sh
```

The packaging script emits:

```text
Vendor/whisper-artifacts/release/whisper.xcframework
Vendor/whisper-artifacts/release/whisper.xcframework.zip
Vendor/whisper-artifacts/release/whisper.xcframework.zip.checksum
```

To prepare a release manifest manually:

```sh
Scripts/set-whisper-binary-artifact.sh \
  "https://github.com/carbocation/CarbocationLocalSpeech/releases/download/v0.1.0/whisper.xcframework.zip" \
  "$(cat Vendor/whisper-artifacts/release/whisper.xcframework.zip.checksum)"
```

### Publish A Binary Release

The preferred release path is the `Publish Whisper Binary Artifact` GitHub workflow.

First run it with:

- `tag`: `v0.1.0` for the first public release; future releases use `vX.Y.Z`
- `prerelease`: `true` for shakedown releases
- `dry_run`: `true`

The dry run verifies synced headers, builds the artifact, stamps `Package.swift`,
and validates the package against the local XCFramework without pushing anything.

Then run the workflow again with the same tag and `dry_run=false`. The release run
creates a tag-only release commit with the binary URL/checksum, creates the tag,
uploads the release asset, and validates the published release from a clean
temporary consumer package.

Keeping the manifest change on the release tag lets `main` stay source-build
friendly while tagged consumers get the binary target.

### Validate A Published Release

After publishing, verify the release from a clean temporary consumer package:

```sh
Scripts/test-binary-release.sh v0.1.0
```

The release workflow runs the same smoke test after uploading the GitHub release
asset. This catches problems that local binary validation cannot see, including
tag resolution, checksum mismatch, release asset availability, downstream product
imports, and whisper symbol linkage from the published binary target.

### Runtime Modes

`Package.swift` supports these Whisper runtime modes:

- Source artifact: uses `Vendor/whisper-artifacts/current/lib/libwhisper-combined.a` when present.
- Forced source mode: set `CARBOCATION_LOCAL_SPEECH_FORCE_SOURCE_WHISPER=1`.
- Local binary validation: set `CARBOCATION_LOCAL_SPEECH_BINARY_ARTIFACT_PATH`.
- Published binary release: use non-empty `whisperBinaryArtifactURL` and `whisperBinaryArtifactChecksum`.
- No Whisper artifact: the package builds, but Whisper inference reports the missing source artifact at runtime.

### Package Layout

```text
Sources/
  CarbocationLocalSpeech/         Core models, audio, transcript, provider, VAD, diarization APIs
  CarbocationLocalSpeechRuntime/  Unified facade over Whisper and Apple Speech
  CarbocationWhisperRuntime/      whisper.cpp-backed runtime
  CarbocationAppleSpeechRuntime/  Apple Speech-backed runtime
  CarbocationLocalSpeechUI/       SwiftUI settings and picker views
  CLSSmoke/                       Xcode-friendly smoke app
  whisper/                        module map and synced C headers for whisper.cpp
Tests/
Scripts/
  bump-whisper-upstream.sh        Updates the whisper.cpp submodule tag and synced headers
Vendor/
  whisper.cpp/                    git submodule
```

### Ownership Boundaries

Keep shared speech infrastructure in this package:

- speech model download, import, deletion, and metadata
- provider-aware model selection
- Apple Speech availability and asset readiness
- microphone, system-audio capture, and file-audio preparation
- sample-rate conversion
- VAD, chunking, and emulated streaming windows
- stable transcript, word timestamp, and speaker-attribution types
- SwiftUI provider/model management surfaces
- smoke tests and diagnostics hooks

Keep product-specific behavior in host apps:

- app-specific prompts and LLM cleanup
- command parsing policy
- global hotkeys
- paste/type behavior through Accessibility APIs
- meeting, memo, or dictation UX policy
- onboarding text and migrations
- entitlement choices beyond documenting requirements
