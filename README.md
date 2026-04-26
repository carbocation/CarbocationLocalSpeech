# CarbocationLocalSpeech

`CarbocationLocalSpeech` is a Swift package for local speech transcription in Carbocation macOS apps. It provides shared model storage, Whisper model management, provider selection, transcription types, a unified runtime facade, and SwiftUI settings surfaces.

Host apps remain responsible for product behavior: hotkeys, paste/type behavior, dictation policy, command parsing, prompts, onboarding, and post-transcription cleanup.

## For App Developers

### Requirements

- macOS 14 or newer for the package.
- Swift 5.9 or newer.
- Xcode command line tools.
- `NSMicrophoneUsageDescription` if your app captures microphone audio.
- `NSSpeechRecognitionUsageDescription` if your app offers Apple Speech.
- Outgoing network access if a sandboxed app downloads Whisper models.
- An App Group entitlement if you want multiple apps to share the same installed speech models.

Apple Speech is exposed only when the current SDK, operating system, locale, permissions, and system speech assets support it. The package reports that state through `LocalSpeechEngine.systemModelOptions(locale:)`.

Whisper model weights are not bundled with the package. Apps can import local whisper.cpp `.bin` files, use the curated Hugging Face downloads, or provide their own download UI.

### Install

For app integration, prefer a tagged GitHub release. Release tags are expected to have `Package.swift` stamped with a SwiftPM binary artifact URL and checksum for the `whisper` XCFramework, so consumers do not need to build `whisper.cpp` locally.

In Xcode:

1. Open `File > Add Package Dependencies...`.
2. Add `https://github.com/carbocation/CarbocationLocalSpeech.git`.
3. Select a release tag.
4. Add `CarbocationLocalSpeechRuntime` to your app target.
5. Add `CarbocationLocalSpeechUI` if you want the shared SwiftUI picker/settings views.

In `Package.swift`:

```swift
dependencies: [
    .package(
        url: "https://github.com/carbocation/CarbocationLocalSpeech.git",
        from: "<release-version>"
    )
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "CarbocationLocalSpeechRuntime", package: "CarbocationLocalSpeech"),
            .product(name: "CarbocationLocalSpeechUI", package: "CarbocationLocalSpeech")
        ]
    )
]
```

For unreleased development, you can point at `branch: "main"`, but Whisper inference requires either a stamped binary artifact, a local binary artifact, or a locally built source artifact. Apple Speech and the core APIs can still be developed without a Whisper artifact when the runtime reports Whisper as unavailable.

### Products

- `CarbocationLocalSpeech`: core model-library, provider-selection, audio, transcript, streaming, VAD, and diarization types.
- `CarbocationLocalSpeechRuntime`: preferred facade for apps. It routes provider-aware selections to Whisper or Apple Speech.
- `CarbocationLocalSpeechUI`: SwiftUI settings, provider picker, model picker, permission/status, and diagnostics surfaces.
- `CarbocationWhisperRuntime`: lower-level whisper.cpp runtime.
- `CarbocationAppleSpeechRuntime`: lower-level Apple Speech runtime.
- `CLSSmoke`: local smoke-test app for package development.

Most apps should depend on `CarbocationLocalSpeechRuntime` and optionally `CarbocationLocalSpeechUI`.

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
let catalogModel = CuratedSpeechModelCatalog.entry(id: "base.en")!

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
Vendor/whisper-artifacts/current/include/whisper.h
```

Those files are intentionally ignored by git.

Useful build overrides:

```sh
WHISPER_COREML=ON Scripts/build-whisper-macos.sh
MACOSX_DEPLOYMENT_TARGET=14.0 Scripts/build-whisper-macos.sh
```

### Use a Local Binary Artifact

To test the package as a binary-target consumer before publishing:

```sh
Scripts/build-whisper-xcframework.sh
CARBOCATION_LOCAL_SPEECH_BINARY_ARTIFACT_PATH=Vendor/whisper-artifacts/whisper.xcframework swift test
```

`Package.swift` switches to a local `.binaryTarget` when `CARBOCATION_LOCAL_SPEECH_BINARY_ARTIFACT_PATH` is set.

### Prepare a GitHub Release Artifact

Build and zip the XCFramework:

```sh
Scripts/build-whisper-xcframework.sh
ditto -c -k --sequesterRsrc --keepParent Vendor/whisper-artifacts/whisper.xcframework CarbocationLocalSpeech-whisper.xcframework.zip
swift package compute-checksum CarbocationLocalSpeech-whisper.xcframework.zip
```

Upload the zip to the GitHub release, then stamp `Package.swift` with the release asset URL and checksum:

```sh
Scripts/set-whisper-binary-artifact.sh <artifact-url> <swiftpm-checksum>
```

Commit that stamped manifest on the release tag. Consumers that depend on that tag will have SwiftPM download the GitHub release artifact automatically.

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
  whisper/                        module map and C header for whisper.cpp
Tests/
Scripts/
Vendor/
  whisper.cpp/                    git submodule
```

### Ownership Boundaries

Keep shared speech infrastructure in this package:

- speech model download, import, deletion, and metadata
- provider-aware model selection
- Apple Speech availability and asset readiness
- microphone capture and file-audio preparation
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
