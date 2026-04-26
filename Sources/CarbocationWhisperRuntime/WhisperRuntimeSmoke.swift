import Foundation

public enum WhisperRuntimeSmoke {
    public static func linkStatus() -> WhisperBackendStatus {
        WhisperBackend.ensureInitialized()
    }
}
