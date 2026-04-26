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
            return "whisper.cpp source artifact is missing at \(path)."
        }
    }
}

public enum WhisperBackend {
    public static func ensureInitialized() -> WhisperBackendStatus {
        if ProcessInfo.processInfo.environment["CARBOCATION_LOCAL_SPEECH_BINARY_ARTIFACT_PATH"]?.isEmpty == false {
            return .binaryArtifact
        }

        let path = sourceArtifactLibraryPath()
        if FileManager.default.fileExists(atPath: path) {
            return .linked
        }
        return .missingSourceArtifact(expectedLibraryPath: path)
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
