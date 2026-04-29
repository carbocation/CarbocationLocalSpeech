// swift-tools-version: 5.9

import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let whisperCombinedLibrary = "\(packageRoot)/Vendor/whisper-artifacts/current/lib/libwhisper-combined.a"
let whisperBinaryArtifactURL = "https://github.com/carbocation/CarbocationLocalSpeech/releases/download/v0.2.0/whisper.xcframework.zip"
let whisperBinaryArtifactChecksum = "e37fdbf0fcdc501102a450b3d5f39d79491d9f1feb487b04cbdd16149a715f00"
let whisperBinaryArtifactPath = ProcessInfo.processInfo.environment["CARBOCATION_LOCAL_SPEECH_BINARY_ARTIFACT_PATH"] ?? ""
let forceSourceWhisper = ProcessInfo.processInfo.environment["CARBOCATION_LOCAL_SPEECH_FORCE_SOURCE_WHISPER"] == "1"
let forceDisableModernSpeechSDK = ProcessInfo.processInfo.environment["CARBOCATION_LOCAL_SPEECH_FORCE_DISABLE_MODERN_SPEECH"] == "1"
let forceDisableSystemAudioTaps = ProcessInfo.processInfo.environment["CARBOCATION_LOCAL_SPEECH_FORCE_DISABLE_SYSTEM_AUDIO_TAPS"] == "1"
let sourceWhisperLibraryExists = FileManager.default.fileExists(atPath: whisperCombinedLibrary)
let whisperCAPIIsLinked = sourceWhisperLibraryExists || forceSourceWhisper || !whisperBinaryArtifactPath.isEmpty || (!whisperBinaryArtifactURL.isEmpty && !whisperBinaryArtifactChecksum.isEmpty)
let whisperRuntimeSwiftSettings: [SwiftSetting] = whisperCAPIIsLinked ? [.define("CARBOCATION_HAS_WHISPER_C_API")] : []
let modernSpeechSDKIsAvailable = !forceDisableModernSpeechSDK && macOSSDKContainsModernSpeechSymbols()
let appleSpeechRuntimeSwiftSettings: [SwiftSetting] = modernSpeechSDKIsAvailable ? [.define("CARBOCATION_HAS_MODERN_SPEECH")] : []
let systemAudioTapsAreAvailable = !forceDisableSystemAudioTaps && coreAudioSwiftOverlayContainsSystemAudioTapSymbols()
let localSpeechSwiftSettings: [SwiftSetting] = systemAudioTapsAreAvailable ? [.define("CARBOCATION_HAS_SYSTEM_AUDIO_TAPS")] : []
let clsSmokeInfoPlist = "\(packageRoot)/Sources/CLSSmoke/Info.plist"

// canImport(Speech) is true on older SDKs that lack the macOS 26 analyzer API.
func macOSSDKContainsModernSpeechSymbols() -> Bool {
    guard let sdkPath = activeMacOSSDKPath() else { return false }
    let speechModuleURL = URL(fileURLWithPath: sdkPath)
        .appendingPathComponent("System/Library/Frameworks/Speech.framework/Modules/Speech.swiftmodule")
    return swiftModule(at: speechModuleURL, containsAll: [
        "SpeechModule",
        "SpeechTranscriber",
        "SpeechAnalyzer",
        "SpeechDetector",
        "DictationTranscriber",
        "AnalyzerInput",
        "AssetInventory"
    ])
}

func activeMacOSSDKPath() -> String? {
    let environment = ProcessInfo.processInfo.environment
    if let sdkRoot = environment["SDKROOT"],
       !sdkRoot.isEmpty,
       FileManager.default.fileExists(atPath: sdkRoot) {
        return sdkRoot
    }
    if let developerDir = environment["DEVELOPER_DIR"],
       let sdkPath = macOSSDKPath(developerDir: developerDir) {
        return sdkPath
    }
    if let sdkPath = xcrunMacOSSDKPath() {
        return sdkPath
    }
    if let sdkPath = macOSSDKPath(developerDir: "/Applications/Xcode.app/Contents/Developer") {
        return sdkPath
    }
    for developerDir in installedXcodeDeveloperDirectories() {
        if let sdkPath = macOSSDKPath(developerDir: developerDir) {
            return sdkPath
        }
    }
    return nil
}

func macOSSDKPath(developerDir: String) -> String? {
    let sdkPath = URL(fileURLWithPath: developerDir)
        .appendingPathComponent("Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk")
        .path
    return FileManager.default.fileExists(atPath: sdkPath) ? sdkPath : nil
}

func installedXcodeDeveloperDirectories() -> [String] {
    guard let applications = try? FileManager.default.contentsOfDirectory(atPath: "/Applications") else {
        return []
    }

    return applications
        .filter { $0.hasPrefix("Xcode") && $0.hasSuffix(".app") }
        .sorted()
        .map { "/Applications/\($0)/Contents/Developer" }
}

func xcrunMacOSSDKPath() -> String? {
    guard let path = xcrunOutput(arguments: ["--sdk", "macosx", "--show-sdk-path"]),
          !path.isEmpty,
          FileManager.default.fileExists(atPath: path) else {
        return nil
    }
    return path
}

func xcrunOutput(arguments: [String]) -> String? {
    guard FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") else {
        return nil
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = arguments

    let output = Pipe()
    process.standardOutput = output
    process.standardError = Pipe()

    do {
        try process.run()
    } catch {
        return nil
    }

    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }

    let data = output.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func swiftCompilerPath() -> String? {
    guard let path = xcrunOutput(arguments: ["--find", "swiftc"]),
          !path.isEmpty,
          FileManager.default.fileExists(atPath: path) else {
        return nil
    }
    return path
}

func swiftResourcePath() -> String? {
    guard let swiftCompilerPath = swiftCompilerPath() else { return nil }
    let path = URL(fileURLWithPath: swiftCompilerPath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("lib/swift")
        .path
    return FileManager.default.fileExists(atPath: path) ? path : nil
}

func coreAudioSwiftOverlayContainsSystemAudioTapSymbols() -> Bool {
    guard let swiftResourcePath = swiftResourcePath() else { return false }
    let prebuiltModules = URL(fileURLWithPath: swiftResourcePath)
        .appendingPathComponent("macosx/prebuilt-modules", isDirectory: true)
    return swiftModule(at: prebuiltModules, containsAll: [
        "AudioHardwareSystem",
        "AudioHardwareTap",
        "AudioHardwareAggregateDevice",
        "makeProcessTap",
        "destroyProcessTap"
    ])
}

func swiftModule(at directory: URL, containsAll symbols: [String]) -> Bool {
    guard let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else {
        return false
    }

    var remainingSymbols = Set(symbols)
    for case let fileURL as URL in enumerator {
        guard ["swiftinterface", "swiftmodule"].contains(fileURL.pathExtension) else { continue }
        guard let data = try? Data(contentsOf: fileURL) else { continue }

        for symbol in Array(remainingSymbols) {
            if data.range(of: Data(symbol.utf8)) != nil {
                remainingSymbols.remove(symbol)
            }
        }

        if remainingSymbols.isEmpty {
            return true
        }
    }

    return false
}

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
            swiftSettings: localSpeechSwiftSettings,
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
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
            swiftSettings: whisperRuntimeSwiftSettings,
            linkerSettings: whisperUnsafeLinkerSettings + [
                .linkedLibrary("c++"),
                .linkedFramework("Accelerate"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreML"),
                .linkedFramework("Foundation"),
                .linkedFramework("Metal")
            ]
        ),
        .target(
            name: "CarbocationAppleSpeechRuntime",
            dependencies: ["CarbocationLocalSpeech"],
            swiftSettings: appleSpeechRuntimeSwiftSettings,
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
            ],
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", clsSmokeInfoPlist
                ])
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
