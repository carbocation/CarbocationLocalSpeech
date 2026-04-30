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

    func testInstalledSelectionRoutesToWhisperProvider() async throws {
        let root = try makeTemporaryDirectory()
        let source = root.appendingPathComponent("ggml-base.en.bin")
        try Data("fake".utf8).write(to: source)

        let library = SpeechModelLibrary(root: root.appendingPathComponent("SpeechModels", isDirectory: true))
        let importResult = try await library.importFile(at: source, displayName: "Base")
        let model = importResult.model
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

    func testLoadDoesNotRefreshLibraryForInstalledSelection() async throws {
        let root = try makeTemporaryDirectory()
        let modelsRoot = root.appendingPathComponent("SpeechModels", isDirectory: true)
        let library = SpeechModelLibrary(root: modelsRoot)
        let id = try createMetadataFreeModel(in: modelsRoot)
        let engine = LocalSpeechEngine()

        do {
            _ = try await engine.load(
                selection: .installed(id),
                from: library,
                options: SpeechLoadOptions(preload: false)
            )
            XCTFail("Expected load to use the cached library state.")
        } catch LocalSpeechEngineError.installedModelNotFound(let missingID) {
            XCTAssertEqual(missingID, id)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCapabilitiesDifferentiateInstalledAndSystemProviders() async throws {
        let root = try makeTemporaryDirectory()
        let source = root.appendingPathComponent("ggml-base.en.bin")
        try Data("fake".utf8).write(to: source)
        let library = SpeechModelLibrary(root: root.appendingPathComponent("SpeechModels", isDirectory: true))
        let importResult = try await library.importFile(at: source, displayName: "Base")
        let model = importResult.model

        let installed = await LocalSpeechEngine.capabilities(for: .installed(model.id), in: library)
        let system = await LocalSpeechEngine.capabilities(for: .system(.appleSpeech), in: library)

        XCTAssertTrue(installed.supportsTranslation)
        XCTAssertTrue(installed.supportsWordTimestamps)
        XCTAssertFalse(system.supportsTranslation)
        XCTAssertFalse(system.supportsWordTimestamps)
    }

    func testLoadPlanReturnsNilForInvalidStorageValue() async throws {
        let root = try makeTemporaryDirectory()
        let library = SpeechModelLibrary(root: root.appendingPathComponent("SpeechModels", isDirectory: true))

        let plan = await LocalSpeechEngine.loadPlan(from: "bad", in: library)

        XCTAssertNil(plan)
    }

    func testLoadPlanRefreshesInstalledModelsOnDemand() async throws {
        let root = try makeTemporaryDirectory()
        let modelsRoot = root.appendingPathComponent("SpeechModels", isDirectory: true)
        let library = SpeechModelLibrary(root: modelsRoot)
        let id = try createMetadataFreeModel(in: modelsRoot)

        let plan = await LocalSpeechEngine.loadPlan(from: id.uuidString, in: library)

        XCTAssertEqual(plan?.selection, .installed(id))
        XCTAssertEqual(plan?.displayName, "ggml-base.en")
        XCTAssertEqual(plan?.availability, .available)
        XCTAssertEqual(plan?.capabilities, .whisperCppDefault)
    }

    func testLoadPlanCanUseCachedLibraryOnly() async throws {
        let root = try makeTemporaryDirectory()
        let modelsRoot = root.appendingPathComponent("SpeechModels", isDirectory: true)
        let library = SpeechModelLibrary(root: modelsRoot)
        let id = try createMetadataFreeModel(in: modelsRoot)

        let missing = await LocalSpeechEngine.loadPlan(
            from: id.uuidString,
            in: library,
            refreshingLibrary: false
        )
        XCTAssertNil(missing)

        _ = await library.refresh()
        let cached = await LocalSpeechEngine.loadPlan(
            from: id.uuidString,
            in: library,
            refreshingLibrary: false
        )
        XCTAssertEqual(cached?.selection, .installed(id))
    }

    func testLoadPlanReturnsNilForDeletedInstalledSelection() async throws {
        let root = try makeTemporaryDirectory()
        let source = root.appendingPathComponent("ggml-base.en.bin")
        try Data("fake".utf8).write(to: source)
        let modelsRoot = root.appendingPathComponent("SpeechModels", isDirectory: true)
        let library = SpeechModelLibrary(root: modelsRoot)
        let importResult = try await library.importFile(at: source, displayName: "Base")
        let model = importResult.model
        try FileManager.default.removeItem(at: modelsRoot.appendingPathComponent(model.id.uuidString, isDirectory: true))

        let plan = await LocalSpeechEngine.loadPlan(from: model.id.uuidString, in: library)

        XCTAssertNil(plan)
    }

    func testLoadPlanResolvesOnlyLoadPlannableSystemSelection() async throws {
        let root = try makeTemporaryDirectory()
        let library = SpeechModelLibrary(root: root.appendingPathComponent("SpeechModels", isDirectory: true))
        let locale = Locale(identifier: "en_US")
        let options = await LocalSpeechEngine.systemModelOptions(locale: locale)
        let option = options.first { $0.selection == .system(.appleSpeech) }

        let plan = await LocalSpeechEngine.loadPlan(
            from: SpeechSystemModelID.appleSpeech.rawValue,
            in: library,
            locale: locale
        )

        switch option?.availability {
        case .available, .unavailable(.assetDownloadRequired):
            XCTAssertEqual(plan?.selection, option?.selection)
            XCTAssertEqual(plan?.displayName, option?.displayName)
            XCTAssertEqual(plan?.capabilities, option?.capabilities)
            XCTAssertEqual(plan?.availability, option?.availability)
        case .unavailable, nil:
            XCTAssertNil(plan)
        }
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

    private func createMetadataFreeModel(in modelsRoot: URL, filename: String = "ggml-base.en.bin") throws -> UUID {
        let id = UUID()
        let directory = modelsRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("fake".utf8).write(to: directory.appendingPathComponent(filename))
        return id
    }
}
