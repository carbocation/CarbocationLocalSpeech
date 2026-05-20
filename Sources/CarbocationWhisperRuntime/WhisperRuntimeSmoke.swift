import CarbocationLocalSpeech
import Foundation
#if CARBOCATION_HAS_WHISPER_C_API
import whisper
#endif

public struct WhisperCoreMLExpectation: Codable, Hashable, Sendable {
    public var compiledIn: Bool
    public var requested: Bool
    public var modelDeclaresCoreMLEncoder: Bool
    public var expectedEncoderPath: String?
    public var expectedEncoderExists: Bool

    public init(
        compiledIn: Bool,
        requested: Bool = false,
        modelDeclaresCoreMLEncoder: Bool,
        expectedEncoderPath: String?,
        expectedEncoderExists: Bool
    ) {
        self.compiledIn = compiledIn
        self.requested = requested
        self.modelDeclaresCoreMLEncoder = modelDeclaresCoreMLEncoder
        self.expectedEncoderPath = expectedEncoderPath
        self.expectedEncoderExists = expectedEncoderExists
    }

    public var expectedActive: Bool {
        compiledIn && expectedEncoderExists
    }
}

public struct WhisperRuntimeDiagnostics: Codable, Hashable, Sendable {
    public var backendStatus: WhisperBackendStatus
    public var backendStatusDescription: String
    public var systemInfo: String
    public var coreML: WhisperCoreMLExpectation

    public init(
        backendStatus: WhisperBackendStatus,
        backendStatusDescription: String,
        systemInfo: String,
        coreML: WhisperCoreMLExpectation
    ) {
        self.backendStatus = backendStatus
        self.backendStatusDescription = backendStatusDescription
        self.systemInfo = systemInfo
        self.coreML = coreML
    }
}

public enum WhisperRuntimeSmoke {
    public static func linkStatus() -> WhisperBackendStatus {
        WhisperBackend.ensureInitialized()
    }

    public static func systemInfo() -> String {
#if CARBOCATION_HAS_WHISPER_C_API
        String(cString: whisper_print_system_info())
#else
        ""
#endif
    }

    public static func isCoreMLCompiledIn() -> Bool {
        systemInfo().contains("COREML = 1")
    }

    public static func diagnostics(
        model: InstalledSpeechModel? = nil,
        root: URL? = nil,
        coreMLRequested: Bool = false
    ) -> WhisperRuntimeDiagnostics {
        let status = linkStatus()
        let systemInfo = systemInfo()
        let expectedEncoderURL = model.flatMap { model in
            model.primaryWeightsURL(in: root ?? URL(fileURLWithPath: "/")).map(expectedCoreMLEncoderURL(forModelAt:))
        }
        let expectedEncoderExists = expectedEncoderURL.map {
            FileManager.default.fileExists(atPath: $0.path)
        } ?? false
        let modelDeclaresCoreMLEncoder = model.map {
            $0.assets.contains { $0.role == .coreMLEncoder }
        } ?? false

        let coreML = WhisperCoreMLExpectation(
            compiledIn: systemInfo.contains("COREML = 1"),
            requested: coreMLRequested,
            modelDeclaresCoreMLEncoder: modelDeclaresCoreMLEncoder,
            expectedEncoderPath: expectedEncoderURL?.path,
            expectedEncoderExists: expectedEncoderExists
        )

        return WhisperRuntimeDiagnostics(
            backendStatus: status,
            backendStatusDescription: status.displayDescription,
            systemInfo: systemInfo,
            coreML: coreML
        )
    }

    public static func expectedCoreMLEncoderURL(forModelAt modelURL: URL) -> URL {
        var stemURL = modelURL.deletingPathExtension()
        let filename = stemURL.lastPathComponent
        if filename.count >= 5 {
            let suffix = String(filename.suffix(5))
            let characters = Array(suffix)
            if characters.count == 5,
               characters[0] == "-",
               characters[1] == "q",
               characters[3] == "_" {
                let trimmed = String(filename.dropLast(5))
                stemURL = stemURL.deletingLastPathComponent().appendingPathComponent(trimmed)
            }
        }
        return stemURL.deletingLastPathComponent()
            .appendingPathComponent("\(stemURL.lastPathComponent)-encoder.mlmodelc", isDirectory: true)
    }
}
