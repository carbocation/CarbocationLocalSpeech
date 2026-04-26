// swift-tools-version: 5.9

import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let whisperCombinedLibrary = "\(packageRoot)/Vendor/whisper-artifacts/current/lib/libwhisper-combined.a"
let whisperBinaryArtifactURL = ""
let whisperBinaryArtifactChecksum = ""
let whisperBinaryArtifactPath = ProcessInfo.processInfo.environment["CARBOCATION_LOCAL_SPEECH_BINARY_ARTIFACT_PATH"] ?? ""
let forceSourceWhisper = ProcessInfo.processInfo.environment["CARBOCATION_LOCAL_SPEECH_FORCE_SOURCE_WHISPER"] == "1"
let sourceWhisperLibraryExists = FileManager.default.fileExists(atPath: whisperCombinedLibrary)

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
    whisperUnsafeLinkerSettings = sourceWhisperLibraryExists ? [.unsafeFlags([whisperCombinedLibrary])] : []
}

let package = Package(
    name: "CarbocationLocalSpeech",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "CarbocationLocalSpeech", targets: ["CarbocationLocalSpeech"]),
        .library(name: "CarbocationWhisperRuntime", targets: ["CarbocationWhisperRuntime"]),
        .library(name: "CarbocationAppleSpeechRuntime", targets: ["CarbocationAppleSpeechRuntime"]),
        .library(name: "CarbocationLocalSpeechRuntime", targets: ["CarbocationLocalSpeechRuntime"]),
        .library(name: "CarbocationLocalSpeechUI", targets: ["CarbocationLocalSpeechUI"]),
        .executable(name: "CLSSmoke", targets: ["CLSSmoke"])
    ],
    targets: [
        .target(
            name: "CarbocationLocalSpeech",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("Accelerate")
            ]
        ),
        whisperTarget,
        .target(
            name: "CarbocationWhisperRuntime",
            dependencies: [
                "CarbocationLocalSpeech",
                "whisper"
            ],
            linkerSettings: whisperUnsafeLinkerSettings + [
                .linkedLibrary("c++"),
                .linkedFramework("Accelerate"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Foundation"),
                .linkedFramework("Metal")
            ]
        ),
        .target(
            name: "CarbocationAppleSpeechRuntime",
            dependencies: ["CarbocationLocalSpeech"],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("Speech")
            ]
        ),
        .target(
            name: "CarbocationLocalSpeechRuntime",
            dependencies: [
                "CarbocationLocalSpeech",
                "CarbocationWhisperRuntime",
                "CarbocationAppleSpeechRuntime"
            ]
        ),
        .target(
            name: "CarbocationLocalSpeechUI",
            dependencies: ["CarbocationLocalSpeech"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .executableTarget(
            name: "CLSSmoke",
            dependencies: [
                "CarbocationLocalSpeechUI",
                "CarbocationLocalSpeechRuntime"
            ]
        ),
        .testTarget(
            name: "CarbocationLocalSpeechTests",
            dependencies: ["CarbocationLocalSpeech"]
        ),
        .testTarget(
            name: "CarbocationWhisperRuntimeTests",
            dependencies: ["CarbocationWhisperRuntime"]
        ),
        .testTarget(
            name: "CarbocationAppleSpeechRuntimeTests",
            dependencies: ["CarbocationAppleSpeechRuntime"]
        ),
        .testTarget(
            name: "CarbocationLocalSpeechRuntimeTests",
            dependencies: ["CarbocationLocalSpeechRuntime"]
        ),
        .testTarget(
            name: "CarbocationLocalSpeechUITests",
            dependencies: ["CarbocationLocalSpeechUI"]
        )
    ]
)
