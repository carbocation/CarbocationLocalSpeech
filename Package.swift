// swift-tools-version: 5.9

import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let whisperCombinedLibrary = "\(packageRoot)/Vendor/whisper-artifacts/current/lib/libwhisper-combined.a"
let whisperBinaryArtifactURL = "https://github.com/carbocation/CarbocationLocalSpeech/releases/download/v0.4.0/whisper.xcframework.zip"
let whisperBinaryArtifactChecksum = "5caf3506da1be159d6f3215f9a12b1ca2c1954678e93abe56b61c51e188d633c"
let defaultWhisperBinaryArtifactPath = "Vendor/whisper-artifacts/release/whisper.xcframework"
let configuredWhisperBinaryArtifactPath = ProcessInfo.processInfo.environment["CARBOCATION_LOCAL_SPEECH_BINARY_ARTIFACT_PATH"] ?? ""
let localWhisperBinaryArtifactPath = FileManager.default.fileExists(atPath: "\(packageRoot)/\(defaultWhisperBinaryArtifactPath)")
    ? defaultWhisperBinaryArtifactPath
    : ""
let whisperBinaryArtifactPath = configuredWhisperBinaryArtifactPath.isEmpty
    ? localWhisperBinaryArtifactPath
    : configuredWhisperBinaryArtifactPath
let forceSourceWhisper = ProcessInfo.processInfo.environment["CARBOCATION_LOCAL_SPEECH_FORCE_SOURCE_WHISPER"] == "1"
let forceDisableModernSpeechSDK = ProcessInfo.processInfo.environment["CARBOCATION_LOCAL_SPEECH_FORCE_DISABLE_MODERN_SPEECH"] == "1"
let forceDisableSystemAudioTaps = ProcessInfo.processInfo.environment["CARBOCATION_LOCAL_SPEECH_FORCE_DISABLE_SYSTEM_AUDIO_TAPS"] == "1"
let sourceWhisperLibraryExists = FileManager.default.fileExists(atPath: whisperCombinedLibrary)
let whisperBinaryArtifactIsConfigured = !whisperBinaryArtifactPath.isEmpty || (!whisperBinaryArtifactURL.isEmpty && !whisperBinaryArtifactChecksum.isEmpty)
let whisperSourceArtifactIsConfigured = sourceWhisperLibraryExists || forceSourceWhisper
let whisperRuntimeSwiftSettings: [SwiftSetting] = {
    if whisperBinaryArtifactIsConfigured {
        return [
            .define("CARBOCATION_HAS_WHISPER_C_API"),
            .define("CARBOCATION_HAS_WHISPER_BINARY_ARTIFACT")
        ]
    }
    if whisperSourceArtifactIsConfigured {
        return [.define("CARBOCATION_HAS_WHISPER_C_API", .when(platforms: [.macOS]))]
    }
    return []
}()
let appleSpeechRuntimeSwiftSettings: [SwiftSetting] = {
    guard !forceDisableModernSpeechSDK else { return [] }

    var settings: [SwiftSetting] = []
    if macOSSDKContainsModernSpeechSymbols() {
        settings.append(.define("CARBOCATION_HAS_MODERN_SPEECH", .when(platforms: [.macOS])))
    }
    if iOSSDKContainsModernSpeechSymbols() {
        settings.append(.define("CARBOCATION_HAS_MODERN_SPEECH", .when(platforms: [.iOS])))
    }
    return settings
}()
let systemAudioTapsAreAvailable = !forceDisableSystemAudioTaps && coreAudioSwiftOverlayContainsSystemAudioTapSymbols()
let localSpeechSwiftSettings: [SwiftSetting] = systemAudioTapsAreAvailable
    ? [.define("CARBOCATION_HAS_SYSTEM_AUDIO_TAPS", .when(platforms: [.macOS]))]
    : []

// canImport(Speech) is true on older SDKs that lack the platform 26 analyzer API.
func macOSSDKContainsModernSpeechSymbols() -> Bool {
    sdkContainsModernSpeechSymbols(sdkName: "macosx")
}

func iOSSDKContainsModernSpeechSymbols() -> Bool {
    let paths = ["iphoneos", "iphonesimulator"].compactMap { activeSDKPath(sdkName: $0) }
    guard !paths.isEmpty else { return false }
    return paths.allSatisfy { sdkContainsModernSpeechSymbols(sdkPath: $0) }
}

func sdkContainsModernSpeechSymbols(sdkName: String) -> Bool {
    guard let sdkPath = activeSDKPath(sdkName: sdkName) else { return false }
    return sdkContainsModernSpeechSymbols(sdkPath: sdkPath)
}

func sdkContainsModernSpeechSymbols(sdkPath: String) -> Bool {
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

func activeSDKPath(sdkName: String) -> String? {
    let environment = ProcessInfo.processInfo.environment
    if let sdkRoot = environment["SDKROOT"],
       !sdkRoot.isEmpty,
       sdkRootMatches(sdkRoot, sdkName: sdkName),
       FileManager.default.fileExists(atPath: sdkRoot) {
        return sdkRoot
    }
    if let sdkPath = xcrunSDKPath(sdkName: sdkName) {
        return sdkPath
    }
    if let developerDir = environment["DEVELOPER_DIR"],
       let sdkPath = developerSDKPath(developerDir: developerDir, sdkName: sdkName) {
        return sdkPath
    }
    if let sdkPath = developerSDKPath(developerDir: "/Applications/Xcode.app/Contents/Developer", sdkName: sdkName) {
        return sdkPath
    }
    for developerDir in installedXcodeDeveloperDirectories() {
        if let sdkPath = developerSDKPath(developerDir: developerDir, sdkName: sdkName) {
            return sdkPath
        }
    }
    return nil
}

func sdkRootMatches(_ sdkRoot: String, sdkName: String) -> Bool {
    let lowercased = sdkRoot.lowercased()
    switch sdkName {
    case "macosx":
        return lowercased.contains("/macosx.platform/")
    case "iphoneos":
        return lowercased.contains("/iphoneos.platform/")
    case "iphonesimulator":
        return lowercased.contains("/iphonesimulator.platform/")
    default:
        return false
    }
}

func developerSDKPath(developerDir: String, sdkName: String) -> String? {
    let platformPath: String
    let sdkDirectoryName: String
    switch sdkName {
    case "macosx":
        platformPath = "Platforms/MacOSX.platform/Developer/SDKs"
        sdkDirectoryName = "MacOSX.sdk"
    case "iphoneos":
        platformPath = "Platforms/iPhoneOS.platform/Developer/SDKs"
        sdkDirectoryName = "iPhoneOS.sdk"
    case "iphonesimulator":
        platformPath = "Platforms/iPhoneSimulator.platform/Developer/SDKs"
        sdkDirectoryName = "iPhoneSimulator.sdk"
    default:
        return nil
    }

    let sdkPath = URL(fileURLWithPath: developerDir)
        .appendingPathComponent(platformPath)
        .appendingPathComponent(sdkDirectoryName)
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

func xcrunSDKPath(sdkName: String) -> String? {
    guard let path = xcrunOutput(arguments: ["--sdk", sdkName, "--show-sdk-path"]),
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
    whisperUnsafeLinkerSettings = [.unsafeFlags([whisperCombinedLibrary], .when(platforms: [.macOS]))]
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
    whisperUnsafeLinkerSettings = sourceWhisperLibraryExists
        ? [.unsafeFlags([whisperCombinedLibrary], .when(platforms: [.macOS]))]
        : []
}

let package = Package(
    name: "CarbocationLocalSpeech",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "CarbocationLocalSpeech", targets: ["CarbocationLocalSpeech"]),
        .library(name: "CarbocationWhisperRuntime", targets: ["CarbocationWhisperRuntime"]),
        .library(name: "CarbocationAppleSpeechRuntime", targets: ["CarbocationAppleSpeechRuntime"]),
        .library(name: "CarbocationLocalSpeechRuntime", targets: ["CarbocationLocalSpeechRuntime"]),
        .library(name: "CarbocationLocalSpeechUI", targets: ["CarbocationLocalSpeechUI"])
    ],
    targets: [
        .target(
            name: "CarbocationLocalSpeech",
            swiftSettings: localSpeechSwiftSettings,
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio", .when(platforms: [.macOS])),
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
                .linkedFramework("AppKit", .when(platforms: [.macOS])),
                .linkedFramework("SwiftUI")
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
