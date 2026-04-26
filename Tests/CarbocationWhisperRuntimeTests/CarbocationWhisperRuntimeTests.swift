import CarbocationLocalSpeech
import CarbocationWhisperRuntime
import Foundation
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

    @MainActor
    func testLiveWhisperCppTranscribesPreparedAudioWhenModelIsProvided() async throws {
        guard let modelPath = ProcessInfo.processInfo.environment["CARBOCATION_LOCAL_SPEECH_TEST_MODEL"],
              !modelPath.isEmpty
        else {
            throw XCTSkip("Set CARBOCATION_LOCAL_SPEECH_TEST_MODEL to a local whisper.cpp .bin model to run live inference.")
        }

        let modelURL = URL(fileURLWithPath: modelPath)
        let modelDirectory = modelURL.deletingLastPathComponent()
        guard let modelID = UUID(uuidString: modelDirectory.lastPathComponent) else {
            throw XCTSkip("Live inference test expects the model path to be rooted as SpeechModels/<UUID>/<model>.bin.")
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: modelURL.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let model = InstalledSpeechModel(
            id: modelID,
            displayName: modelURL.deletingPathExtension().lastPathComponent,
            assets: [
                SpeechModelAsset(
                    role: .primaryWeights,
                    relativePath: modelURL.lastPathComponent,
                    sizeBytes: size
                )
            ],
            source: .imported
        )

        let engine = WhisperEngine(configuration: WhisperEngineConfiguration(useCoreML: false, threadCount: 2))
        _ = try await engine.load(model: model, from: modelDirectory.deletingLastPathComponent())

        let sampleRate = 16_000.0
        let samples = (0..<Int(sampleRate)).map { index in
            Float(sin(2.0 * Double.pi * 440.0 * Double(index) / sampleRate) * 0.05)
        }
        let transcript: Transcript
        do {
            transcript = try await engine.transcribe(
                audio: PreparedAudio(samples: samples, sampleRate: sampleRate),
                options: TranscriptionOptions(language: "en", suppressBlankAudio: false)
            )
        } catch {
            await engine.unload()
            throw error
        }
        await engine.unload()

        XCTAssertEqual(transcript.backend?.kind, .whisperCpp)
        XCTAssertEqual(transcript.duration, 1)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CarbocationWhisperRuntimeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
