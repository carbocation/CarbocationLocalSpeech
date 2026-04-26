import XCTest
@testable import CarbocationLocalSpeech

final class CarbocationLocalSpeechTests: XCTestCase {
    func testSelectionStorageRoundTripsInstalledAndSystemProviders() throws {
        let id = UUID()
        XCTAssertEqual(SpeechModelSelection(storageValue: id.uuidString), .installed(id))
        XCTAssertEqual(SpeechModelSelection(storageValue: "system.apple-speech"), .system(.appleSpeech))
        XCTAssertNil(SpeechModelSelection(storageValue: "not-a-selection"))

        let encoded = try JSONEncoder().encode(SpeechModelSelection.system(.appleSpeech))
        XCTAssertEqual(String(data: encoded, encoding: .utf8), "\"system.apple-speech\"")
        XCTAssertEqual(try JSONDecoder().decode(SpeechModelSelection.self, from: encoded), .system(.appleSpeech))
    }

    func testProviderAvailabilityOfferPolicy() {
        XCTAssertTrue(SpeechProviderAvailability.available.shouldOfferModelOption)
        XCTAssertTrue(SpeechProviderAvailability.unavailable(.assetDownloadRequired).shouldOfferModelOption)
        XCTAssertTrue(SpeechProviderAvailability.unavailable(.assetNotReady).shouldOfferModelOption)
        XCTAssertFalse(SpeechProviderAvailability.unavailable(.sdkUnavailable).shouldOfferModelOption)
        XCTAssertFalse(SpeechProviderAvailability.unavailable(.operatingSystemUnavailable).shouldOfferModelOption)
    }

    func testSpeechModelStorageUsesSharedGroupWhenAvailable() throws {
        let groupRoot = try makeTemporaryDirectory()
        var requestedIdentifier: String?

        let directory = SpeechModelStorage.modelsDirectory(
            sharedGroupIdentifier: "group.com.example.shared",
            appSupportFolderName: "ExampleApp",
            sharedGroupRootResolver: { identifier, _ in
                requestedIdentifier = identifier
                return groupRoot
            }
        )

        XCTAssertEqual(requestedIdentifier, "group.com.example.shared")
        XCTAssertEqual(
            directory.standardizedFileURL.path,
            groupRoot.appendingPathComponent("SpeechModels", isDirectory: true).standardizedFileURL.path
        )
    }

    @MainActor
    func testModelLibraryImportsRefreshesAndDeletesBinModels() throws {
        let root = try makeTemporaryDirectory()
        let source = root.appendingPathComponent("ggml-base.en.bin")
        try Data("fake whisper weights".utf8).write(to: source)
        let modelsRoot = root.appendingPathComponent("SpeechModels", isDirectory: true)

        let library = SpeechModelLibrary(root: modelsRoot)
        let model = try library.importFile(at: source, displayName: "Base English")

        XCTAssertEqual(library.models.count, 1)
        XCTAssertEqual(model.displayName, "Base English")
        XCTAssertEqual(model.providerKind, .whisperCpp)
        XCTAssertEqual(model.languageScope, .englishOnly)
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.primaryWeightsURL(in: modelsRoot)!.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.metadataURL(in: modelsRoot).path))
        XCTAssertEqual(library.totalDiskUsageBytes(), Int64("fake whisper weights".utf8.count))

        try library.delete(id: model.id)
        XCTAssertTrue(library.models.isEmpty)
    }

    @MainActor
    func testModelLibrarySupportsMultiAssetBundles() throws {
        let root = try makeTemporaryDirectory()
        let bundle = root.appendingPathComponent("bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: bundle.appendingPathComponent("ggml-small.en.bin"))
        let coreML = bundle.appendingPathComponent("ggml-small.en-encoder.mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(at: coreML, withIntermediateDirectories: true)
        try Data("coreml".utf8).write(to: coreML.appendingPathComponent("model"))

        let id = UUID()
        let metadata = InstalledSpeechModel(
            id: id,
            displayName: "Small English",
            variant: "small.en",
            languageScope: .englishOnly,
            assets: [
                SpeechModelAsset(role: .primaryWeights, relativePath: "ggml-small.en.bin", sizeBytes: 7),
                SpeechModelAsset(role: .coreMLEncoder, relativePath: "ggml-small.en-encoder.mlmodelc", sizeBytes: 6)
            ],
            source: .imported
        )
        let library = SpeechModelLibrary(root: root.appendingPathComponent("SpeechModels", isDirectory: true))
        let installed = try library.add(assetBundleAt: bundle, metadata: metadata)

        XCTAssertEqual(installed.id, id)
        XCTAssertEqual(library.models.first?.assets.count, 2)
        XCTAssertEqual(library.totalDiskUsageBytes(), 13)
    }

    func testHuggingFaceSpeechURLParsesExpectedForms() {
        let resolved = HuggingFaceSpeechModelURL.parse("https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin?download=true")
        XCTAssertEqual(resolved?.repo, "ggerganov/whisper.cpp")
        XCTAssertEqual(resolved?.filename, "ggml-base.en.bin")

        let nested = HuggingFaceSpeechModelURL.parse("https://huggingface.co/org/repo/blob/main/models/ggml-small.en.bin")
        XCTAssertEqual(nested?.repo, "org/repo")
        XCTAssertEqual(nested?.filename, "models/ggml-small.en.bin")

        let compact = HuggingFaceSpeechModelURL.parse("org/repo/ggml-medium.en.bin")
        XCTAssertEqual(compact?.repo, "org/repo")
        XCTAssertEqual(compact?.filename, "ggml-medium.en.bin")

        XCTAssertNil(HuggingFaceSpeechModelURL.parse("https://huggingface.co/org/repo/blob/main/README.md"))
    }

    func testCuratedCatalogEntriesHaveDownloadURLs() throws {
        for model in CuratedSpeechModelCatalog.all {
            let url = try XCTUnwrap(model.downloadURL, "\(model.id) should have a download URL")
            XCTAssertEqual(url.host(), "huggingface.co")
            XCTAssertTrue(url.path.contains("/ggerganov/whisper.cpp/resolve/main/"))
            XCTAssertTrue(url.lastPathComponent.hasSuffix(".bin"))
        }

        let base = try XCTUnwrap(CuratedSpeechModelCatalog.entry(id: "base.en"))
        XCTAssertEqual(base.hfFilename, "ggml-base.en.bin")
        XCTAssertEqual(
            base.downloadURL?.absoluteString,
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin"
        )
    }

    func testRecommendedCuratedModelPrefersLargerModelWhenRAMTierTies() throws {
        let recommended = CuratedSpeechModelCatalog.recommendedModel(
            forPhysicalMemoryBytes: 48 * 1_073_741_824
        )

        XCTAssertEqual(recommended?.id, "large-v3-turbo")
    }

    func testSpeechModelDownloadConfigurationNormalizesUnsafeValues() {
        let defaults = SpeechModelDownloadConfiguration.default
        XCTAssertEqual(defaults.parallelConnections, SpeechModelDownloadConfiguration.defaultParallelConnections)
        XCTAssertEqual(defaults.chunkSize, SpeechModelDownloadConfiguration.defaultChunkSize)

        let normalized = SpeechModelDownloadConfiguration(
            parallelConnections: 0,
            chunkSize: 1,
            requestTimeout: 1
        )
        XCTAssertEqual(normalized.parallelConnections, 1)
        XCTAssertEqual(normalized.chunkSize, 1_024 * 1_024)
        XCTAssertEqual(normalized.requestTimeout, 30)

        let capped = SpeechModelDownloadConfiguration(
            parallelConnections: SpeechModelDownloadConfiguration.maximumParallelConnections + 1
        )
        XCTAssertEqual(capped.parallelConnections, SpeechModelDownloadConfiguration.maximumParallelConnections)
    }

    @MainActor
    func testModelLibraryAddsDownloadedPartialUsingRequestedFilename() throws {
        let root = try makeTemporaryDirectory()
        let partial = root.appendingPathComponent("cls-partial-abcdef.bin")
        try Data("downloaded whisper weights".utf8).write(to: partial)

        let library = SpeechModelLibrary(root: root.appendingPathComponent("SpeechModels", isDirectory: true))
        let model = try library.add(
            primaryAssetAt: partial,
            displayName: "Base English",
            filename: "ggml-base.en.bin",
            source: .curated,
            hfRepo: "ggerganov/whisper.cpp",
            hfFilename: "ggml-base.en.bin"
        )

        XCTAssertEqual(model.primaryWeightsAsset?.relativePath, "ggml-base.en.bin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.primaryWeightsURL(in: library.root)!.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    func testPartialDownloadListingAndDeletion() throws {
        let root = try makeTemporaryDirectory()
        let partialsRoot = try SpeechModelDownloader.partialsDirectory(in: root)
        let stem = "cls-partial-abcdef"
        let partialURL = partialsRoot.appendingPathComponent("\(stem).bin")
        let sidecarURL = partialsRoot.appendingPathComponent("\(stem).json")

        FileManager.default.createFile(atPath: partialURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: partialURL)
        try handle.truncate(atOffset: 100)
        try handle.close()
        let sidecar = #"""
        {
          "url": "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin",
          "totalBytes": 100,
          "displayName": "Base",
          "schemaVersion": 2,
          "chunkSize": 10,
          "doneChunks": [0, 2, 3]
        }
        """#
        try Data(sidecar.utf8).write(to: sidecarURL)

        let partial = try XCTUnwrap(SpeechModelDownloader.listPartials(in: root).first)
        XCTAssertEqual(partial.id, "abcdef")
        XCTAssertEqual(partial.displayName, "Base")
        XCTAssertEqual(partial.hfRepo, "ggerganov/whisper.cpp")
        XCTAssertEqual(partial.hfFilename, "ggml-base.en.bin")
        XCTAssertEqual(partial.bytesOnDisk, 30)
        XCTAssertEqual(partial.fractionComplete, 0.3, accuracy: 0.000_1)

        SpeechModelDownloader.deletePartial(partial)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partialURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarURL.path))
    }

    func testEnergyVADSeparatesSilenceAndSpeech() throws {
        let detector = EnergyVoiceActivityDetector(speechRMSThreshold: 0.01, minimumPeakThreshold: 0.02)
        let silence = AudioChunk(samples: Array(repeating: 0, count: 160), sampleRate: 16_000, channelCount: 1, startTime: 0)
        let speech = AudioChunk(samples: Array(repeating: 0.05, count: 160), sampleRate: 16_000, channelCount: 1, startTime: 0.01)

        XCTAssertEqual(try detector.analyze(silence).state, .silence)
        XCTAssertEqual(try detector.analyze(speech).state, .speech)
    }

    func testSpeechChunkerEmitsOnChunkBoundaryAndKeepsOverlap() throws {
        var chunker = SpeechChunker(configuration: SpeechChunkingConfiguration(
            maximumChunkDuration: 1.0,
            overlapDuration: 0.25,
            silenceCommitDelay: 0.5,
            minimumSpeechDuration: 0.1
        ))

        let first = AudioChunk(samples: Array(repeating: 0.1, count: 8_000), sampleRate: 8_000, channelCount: 1, startTime: 0, duration: 1.0)
        let outputs = chunker.append(
            first,
            activity: VoiceActivityEvent(state: .speech, startTime: 0, endTime: 1)
        )

        XCTAssertEqual(outputs.count, 1)
        XCTAssertFalse(outputs[0].isFinal)
        XCTAssertEqual(outputs[0].audio.duration, 1.0, accuracy: 0.000_1)

        let final = chunker.finish()
        XCTAssertEqual(try XCTUnwrap(final.first?.audio.duration), 0.25, accuracy: 0.000_1)
    }

    func testSpeakerAttributionMergerUsesLargestOverlap() {
        let transcript = Transcript(segments: [
            TranscriptSegment(text: "hello", startTime: 0, endTime: 1),
            TranscriptSegment(text: "world", startTime: 1, endTime: 2)
        ])
        let merged = SpeakerAttributionMerger.merge(
            transcript: transcript,
            speakerTurns: [
                SpeakerTurn(speaker: SpeakerID(rawValue: "A"), startTime: 0, endTime: 1.2),
                SpeakerTurn(speaker: SpeakerID(rawValue: "B"), startTime: 1.2, endTime: 2.0)
            ],
            minimumOverlap: 0.1
        )

        XCTAssertEqual(merged.segments[0].speaker, SpeakerID(rawValue: "A"))
        XCTAssertEqual(merged.segments[1].speaker, SpeakerID(rawValue: "B"))
    }

    func testMockTranscriberEmitsConfiguredEventsAndCompletion() async throws {
        let partial = TranscriptPartial(text: "hel", startTime: 0, endTime: 0.2)
        let transcriber = MockSpeechTranscriber(
            transcript: Transcript(segments: [TranscriptSegment(text: "hello", startTime: 0, endTime: 0.5)]),
            streamEvents: [.partial(partial)]
        )
        let audio = AsyncThrowingStream<AudioChunk, Error> { continuation in
            continuation.finish()
        }

        var events: [TranscriptEvent] = []
        for try await event in transcriber.stream(audio: audio, options: StreamingTranscriptionOptions()) {
            events.append(event)
        }

        XCTAssertTrue(events.contains(.partial(partial)))
        XCTAssertTrue(events.contains { event in
            if case .completed = event { return true }
            return false
        })
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CarbocationLocalSpeechTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
