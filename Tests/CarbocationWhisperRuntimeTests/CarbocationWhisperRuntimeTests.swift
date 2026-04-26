import CarbocationLocalSpeech
import CarbocationWhisperRuntime
import XCTest

final class CarbocationWhisperRuntimeTests: XCTestCase {
    func testBackendStatusIsCallableWithoutArtifact() {
        let status = WhisperRuntimeSmoke.linkStatus()
        XCTAssertFalse(status.displayDescription.isEmpty)
    }

    @MainActor
    func testEngineLoadsInstalledModelMetadataWithoutRunningInference() async throws {
        let root = try makeTemporaryDirectory()
        let source = root.appendingPathComponent("ggml-base.en.bin")
        try Data("fake".utf8).write(to: source)

        let library = SpeechModelLibrary(root: root.appendingPathComponent("SpeechModels", isDirectory: true))
        let model = try library.importFile(at: source, displayName: "Base")
        let engine = WhisperEngine()
        let loaded = try await engine.load(model: model, from: library.root)
        let currentModelID = await engine.currentModelID()

        XCTAssertEqual(loaded.modelID, model.id)
        XCTAssertEqual(loaded.backend.kind, .whisperCpp)
        XCTAssertEqual(currentModelID, model.id)
    }

    func testTranscribeRequiresLoadedModel() async {
        let engine = WhisperEngine()
        do {
            _ = try await engine.transcribe(
                audio: PreparedAudio(samples: [], sampleRate: 16_000),
                options: TranscriptionOptions()
            )
            XCTFail("Expected no loaded model error.")
        } catch let error as WhisperEngineError {
            XCTAssertEqual(error.errorDescription, WhisperEngineError.noModelLoaded.errorDescription)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CarbocationWhisperRuntimeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
