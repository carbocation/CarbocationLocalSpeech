import CarbocationLocalSpeech
import FluidAudio
import Foundation

public enum FluidAudioModelInstallPhase: Hashable, Sendable {
    case starting(StreamingDiarizationBackend?)
    case listing
    case downloading(completedFiles: Int, totalFiles: Int)
    case compiling(modelName: String)
    case finished(StreamingDiarizationBackend?)
}

public struct FluidAudioModelInstallProgress: Hashable, Sendable {
    public var fractionCompleted: Double
    public var phase: FluidAudioModelInstallPhase

    public init(fractionCompleted: Double, phase: FluidAudioModelInstallPhase) {
        self.fractionCompleted = min(1, max(0, fractionCompleted))
        self.phase = phase
    }
}

internal enum FluidAudioModelInstallFailureKind: Sendable {
    case downloadFailed
    case lowDiskSpace
    case compilationFailed
    case compilationTimeout
    case modelAssetsMissing
}

internal enum FluidAudioModelInstallDiagnostics {
    static func mapProgress(_ progress: DownloadUtils.DownloadProgress) -> FluidAudioModelInstallProgress {
        let phase: FluidAudioModelInstallPhase
        switch progress.phase {
        case .listing:
            phase = .listing
        case .downloading(let completedFiles, let totalFiles):
            phase = .downloading(completedFiles: completedFiles, totalFiles: totalFiles)
        case .compiling(let modelName):
            phase = .compiling(modelName: modelName)
        }
        return FluidAudioModelInstallProgress(
            fractionCompleted: progress.fractionCompleted,
            phase: phase
        )
    }

    static func classify(_ error: Error) -> (FluidAudioModelInstallFailureKind, String) {
        let detail = diagnosticDetail(for: error)
        let lowercased = detail.lowercased()

        if containsLowDiskSpace(error) || containsAny(lowercased, ["no space left", "disk full", "out of space"]) {
            return (.lowDiskSpace, detail)
        }

        if containsAny(lowercased, ["timed out", "timeout"]),
           containsAny(lowercased, ["compile", "compiling", "coreml", "mlmodel"]) {
            return (.compilationTimeout, detail)
        }

        if containsAny(lowercased, ["compile", "compiling", "coreml", "mlmodel", "model path is not a directory"]) {
            return (.compilationFailed, detail)
        }

        if containsAny(lowercased, [
            "download",
            "hugging face",
            "huggingface",
            "rate limit",
            "http",
            "network",
            "offline",
            "internet",
            "cannot connect",
            "connection",
            "not connected"
        ]) {
            return (.downloadFailed, detail)
        }

        return (.modelAssetsMissing, detail)
    }

    private static func containsAny(_ value: String, _ needles: [String]) -> Bool {
        needles.contains { value.contains($0) }
    }

    private static func diagnosticDetail(for error: Error) -> String {
        let nsError = error as NSError
        var details = [error.localizedDescription]
        if let failureReason = nsError.localizedFailureReason {
            details.append(failureReason)
        }
        if let recoverySuggestion = nsError.localizedRecoverySuggestion {
            details.append(recoverySuggestion)
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            details.append(diagnosticDetail(for: underlying))
        }
        return details
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func containsLowDiskSpace(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == 28 {
            return true
        }
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteOutOfSpaceError {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return containsLowDiskSpace(underlying)
        }
        return false
    }
}
