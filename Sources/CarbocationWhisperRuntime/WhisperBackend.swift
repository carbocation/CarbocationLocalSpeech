import Foundation

public enum WhisperBackendStatus: Hashable, Sendable {
    case linked
    case missingSourceArtifact(expectedLibraryPath: String)
    case binaryArtifact

    public var isUsable: Bool {
        switch self {
        case .linked, .binaryArtifact:
            return true
        case .missingSourceArtifact:
            return false
        }
    }

    public var displayDescription: String {
        switch self {
        case .linked:
            return "whisper.cpp source artifact is present."
        case .binaryArtifact:
            return "whisper.cpp binary artifact is configured."
        case .missingSourceArtifact(let path):
#if os(iOS)
            _ = path
            return "whisper.cpp on iOS requires the package to be built with a whisper.xcframework binary artifact."
#else
            return "whisper.cpp source artifact is missing at \(path)."
#endif
        }
    }
}

public enum WhisperBackend {
    public static func ensureInitialized() -> WhisperBackendStatus {
#if CARBOCATION_HAS_WHISPER_BINARY_ARTIFACT
        return .binaryArtifact
#else
        let path = sourceArtifactLibraryPath()
#if CARBOCATION_HAS_WHISPER_C_API
        if FileManager.default.fileExists(atPath: path) {
            return .linked
        }
        return .binaryArtifact
#else
        return .missingSourceArtifact(expectedLibraryPath: path)
#endif
#endif
    }

    public static func sourceArtifactLibraryPath() -> String {
        let sourceURL = URL(fileURLWithPath: #filePath)
        let packageRoot = sourceURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return packageRoot
            .appendingPathComponent("Vendor/whisper-artifacts/current/lib/libwhisper-combined.a")
            .path
    }
}
