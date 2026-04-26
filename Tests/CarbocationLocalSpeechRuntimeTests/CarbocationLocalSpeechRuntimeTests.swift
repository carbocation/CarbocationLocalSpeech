import CarbocationLocalSpeech
import CarbocationLocalSpeechRuntime
import XCTest

final class CarbocationLocalSpeechRuntimeTests: XCTestCase {
    func testSelectionParsing() throws {
        let id = UUID()
        XCTAssertEqual(try LocalSpeechEngine.selection(from: id.uuidString), .installed(id))
        XCTAssertEqual(try LocalSpeechEngine.selection(from: "system.apple-speech"), .system(.appleSpeech))
        XCTAssertThrowsError(try LocalSpeechEngine.selection(from: "bad"))
    }

    func testTranscribeRequiresLoadedSelection() async {
        let engine = LocalSpeechEngine()
        do {
            _ = try await engine.transcribe(
                audio: PreparedAudio(samples: [], sampleRate: 16_000),
                options: TranscriptionOptions()
            )
            XCTFail("Expected no loaded selection error.")
        } catch let error as LocalSpeechEngineError {
            XCTAssertEqual(error.errorDescription, LocalSpeechEngineError.noSelectionLoaded.errorDescription)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testInstalledSelectionRoutesToWhisperProvider() async throws {
        let root = try makeTemporaryDirectory()
        let source = root.appendingPathComponent("ggml-base.en.bin")
        try Data("fake".utf8).write(to: source)

        let library = SpeechModelLibrary(root: root.appendingPathComponent("SpeechModels", isDirectory: true))
        let model = try library.importFile(at: source, displayName: "Base")
        let engine = LocalSpeechEngine()
        let loaded = try await engine.load(
            selection: .installed(model.id),
            from: library,
            options: SpeechLoadOptions(preload: false)
        )
        let currentSelection = await engine.currentSelection()

        XCTAssertEqual(loaded.selection, .installed(model.id))
        XCTAssertEqual(loaded.backend.kind, .whisperCpp)
        XCTAssertEqual(currentSelection, .installed(model.id))
    }

    @MainActor
    func testCapabilitiesDifferentiateInstalledAndSystemProviders() async throws {
        let root = try makeTemporaryDirectory()
        let source = root.appendingPathComponent("ggml-base.en.bin")
        try Data("fake".utf8).write(to: source)
        let library = SpeechModelLibrary(root: root.appendingPathComponent("SpeechModels", isDirectory: true))
        let model = try library.importFile(at: source, displayName: "Base")

        let installed = await LocalSpeechEngine.capabilities(for: .installed(model.id), in: library)
        let system = await LocalSpeechEngine.capabilities(for: .system(.appleSpeech), in: library)

        XCTAssertTrue(installed.supportsTranslation)
        XCTAssertTrue(installed.supportsWordTimestamps)
        XCTAssertFalse(system.supportsTranslation)
        XCTAssertFalse(system.supportsWordTimestamps)
    }

    func testSystemModelOptionsUseStorageIDs() async {
        let options = await LocalSpeechEngine.systemModelOptions(locale: Locale(identifier: "en_US"))
        for option in options {
            XCTAssertEqual(option.id, option.selection.storageValue)
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CarbocationLocalSpeechRuntimeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
