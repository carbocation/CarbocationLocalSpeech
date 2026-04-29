import AVFoundation
import XCTest
@_spi(Internal)
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
        XCTAssertFalse(SpeechProviderAvailability.unavailable(.deviceNotEligible).shouldOfferModelOption)
    }

    func testProviderAvailabilityDisplayPolicy() {
        XCTAssertTrue(SpeechProviderAvailability.available.shouldDisplayModelOption)
        XCTAssertTrue(SpeechProviderAvailability.unavailable(.assetDownloadRequired).shouldDisplayModelOption)
        XCTAssertTrue(SpeechProviderAvailability.unavailable(.assetNotReady).shouldDisplayModelOption)
        XCTAssertTrue(SpeechProviderAvailability.unavailable(.deviceNotEligible).shouldDisplayModelOption)
        XCTAssertTrue(SpeechProviderAvailability.unavailable(.speechRecognitionDenied).shouldDisplayModelOption)
        XCTAssertTrue(SpeechProviderAvailability.unavailable(.localeUnsupported).shouldDisplayModelOption)
        XCTAssertFalse(SpeechProviderAvailability.unavailable(.sdkUnavailable).shouldDisplayModelOption)
        XCTAssertFalse(SpeechProviderAvailability.unavailable(.operatingSystemUnavailable).shouldDisplayModelOption)
    }

    func testOperatingSystemUnavailableMessageMentionsMacOSAndIOS() {
        XCTAssertEqual(
            SpeechProviderUnavailableReason.operatingSystemUnavailable.displayMessage,
            "Apple Speech requires macOS 26 or iOS 26 or newer."
        )
    }

    func testAudioCaptureConfigurationDefaultsToManagingApplicationAudioSession() {
        XCTAssertTrue(AudioCaptureConfiguration().configuresApplicationAudioSession)
        XCTAssertFalse(AudioCaptureConfiguration(configuresApplicationAudioSession: false).configuresApplicationAudioSession)
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
        try Data("vad".utf8).write(to: bundle.appendingPathComponent("ggml-silero-v6.2.0.bin"))
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
                SpeechModelAsset(role: .vadWeights, relativePath: "ggml-silero-v6.2.0.bin", sizeBytes: 3),
                SpeechModelAsset(role: .coreMLEncoder, relativePath: "ggml-small.en-encoder.mlmodelc", sizeBytes: 6)
            ],
            source: .imported
        )
        let library = SpeechModelLibrary(root: root.appendingPathComponent("SpeechModels", isDirectory: true))
        let installed = try library.add(assetBundleAt: bundle, metadata: metadata)

        XCTAssertEqual(installed.id, id)
        XCTAssertEqual(library.models.first?.assets.count, 3)
        XCTAssertEqual(library.totalDiskUsageBytes(), 16)
    }

    @MainActor
    func testModelLibrarySynthesizesVADAssetForMetadataFreeFolders() throws {
        let root = try makeTemporaryDirectory()
        let modelsRoot = root.appendingPathComponent("SpeechModels", isDirectory: true)
        let modelDirectory = modelsRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: modelDirectory.appendingPathComponent("ggml-base.en.bin"))
        try Data("vad".utf8).write(to: modelDirectory.appendingPathComponent("ggml-silero-v6.2.0.bin"))

        let library = SpeechModelLibrary(root: modelsRoot)
        let model = try XCTUnwrap(library.models.first)

        XCTAssertEqual(model.primaryWeightsAsset?.relativePath, "ggml-base.en.bin")
        XCTAssertEqual(model.vadWeightsAsset?.relativePath, "ggml-silero-v6.2.0.bin")
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
        XCTAssertEqual(
            CuratedSpeechModelCatalog.all.map(\.id),
            ["tiny.en", "small.en", "large-v2", "large-v3-turbo"]
        )
        XCTAssertNil(CuratedSpeechModelCatalog.entry(id: "base.en"))
        XCTAssertNil(CuratedSpeechModelCatalog.entry(id: "medium.en"))

        for model in CuratedSpeechModelCatalog.all {
            let url = try XCTUnwrap(model.downloadURL, "\(model.id) should have a download URL")
            let hfRepo = try XCTUnwrap(model.hfRepo)
            XCTAssertEqual(url.host(), "huggingface.co")
            XCTAssertTrue(url.path.contains("/\(hfRepo)/resolve/main/"))
            XCTAssertTrue(url.lastPathComponent.hasSuffix(".bin"))
        }

        let small = try XCTUnwrap(CuratedSpeechModelCatalog.entry(id: "small.en"))
        XCTAssertEqual(small.displayName, "Whisper small.en (English-only)")
        XCTAssertEqual(small.hfFilename, "ggml-small.en.bin")
        XCTAssertEqual(small.languageScope, .englishOnly)
        XCTAssertEqual(small.recommendation, .bestLiveEnglish)
        XCTAssertEqual(
            small.downloadURL?.absoluteString,
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin"
        )

        let largeV2 = try XCTUnwrap(CuratedSpeechModelCatalog.entry(id: "large-v2"))
        XCTAssertEqual(largeV2.displayName, "Whisper large-v2 (multilingual)")
        XCTAssertEqual(largeV2.hfFilename, "ggml-large-v2.bin")
        XCTAssertEqual(largeV2.languageScope, .multilingual)
        XCTAssertEqual(largeV2.recommendation, .bestFile)

        let turbo = try XCTUnwrap(CuratedSpeechModelCatalog.entry(id: "large-v3-turbo"))
        XCTAssertEqual(turbo.displayName, "Whisper large-v3 turbo (multilingual)")
        XCTAssertEqual(turbo.languageScope, .multilingual)
        XCTAssertEqual(turbo.recommendation, .bestLiveMultilingual)

        let vad = CuratedSpeechModelCatalog.recommendedVADModel
        XCTAssertEqual(vad.hfRepo, "ggml-org/whisper-vad")
        XCTAssertEqual(vad.hfFilename, "ggml-silero-v6.2.0.bin")
        XCTAssertEqual(
            vad.downloadURL?.absoluteString,
            "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin"
        )
    }

    func testRecommendedCuratedModelsUseManualCatalogRoles() throws {
        let recommended = CuratedSpeechModelCatalog.recommendedModels()

        XCTAssertEqual(recommended.map(\.id), ["small.en", "large-v3-turbo", "large-v2"])
        XCTAssertEqual(CuratedSpeechModelCatalog.bestLiveEnglishModel()?.id, "small.en")
        XCTAssertEqual(CuratedSpeechModelCatalog.bestLiveMultilingualModel()?.id, "large-v3-turbo")
        XCTAssertEqual(CuratedSpeechModelCatalog.bestFileModel()?.id, "large-v2")
        XCTAssertEqual(CuratedSpeechModelCatalog.bestEnglishModel()?.id, "small.en")
        XCTAssertEqual(CuratedSpeechModelCatalog.bestMultilingualModel()?.id, "large-v3-turbo")
        XCTAssertEqual(
            CuratedSpeechModelCatalog.recommendedModel(forPhysicalMemoryBytes: 1)?.id,
            "small.en"
        )
    }

    func testInstalledSpeechModelInfersDistilLargeV2AsEnglishOnly() {
        XCTAssertEqual(
            InstalledSpeechModel.inferLanguageScope(from: "ggml-distil-large-v2.bin"),
            .englishOnly
        )
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

    func testVoiceActivityDetectionOptionsDefaultToAutomaticMediumSensitivity() {
        let defaults = TranscriptionOptions().voiceActivityDetection
        XCTAssertEqual(defaults.mode, .automatic)
        XCTAssertEqual(defaults.sensitivity, .medium)

        let disabled = TranscriptionOptions(voiceActivityDetection: .disabled)
        XCTAssertEqual(disabled.voiceActivityDetection.mode, .disabled)
    }

    func testAudioFileReaderPreparesLocalAudioFileAsMonoSamples() async throws {
        let root = try makeTemporaryDirectory()
        let url = root.appendingPathComponent("stereo.wav")
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4) else {
            XCTFail("Could not create test audio buffer.")
            return
        }

        buffer.frameLength = 4
        let left: [Float] = [0.2, 0.4, -0.2, -0.4]
        let right: [Float] = [0.6, 0.2, 0.2, -0.2]
        for frame in 0..<4 {
            buffer.floatChannelData?[0][frame] = left[frame]
            buffer.floatChannelData?[1][frame] = right[frame]
        }

        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            try file.write(from: buffer)
        }

        let prepared = try await AVAssetAudioFileReader().prepareFile(at: url)

        XCTAssertEqual(prepared.sampleRate, 48_000, accuracy: 0.01)
        XCTAssertEqual(prepared.samples.count, 4)
        XCTAssertEqual(prepared.samples[0], 0.4, accuracy: 0.000_1)
        XCTAssertEqual(prepared.samples[1], 0.3, accuracy: 0.000_1)
        XCTAssertEqual(prepared.samples[2], 0.0, accuracy: 0.000_1)
        XCTAssertEqual(prepared.samples[3], -0.3, accuracy: 0.000_1)
        XCTAssertEqual(prepared.duration, Double(4) / 48_000, accuracy: 0.000_1)
    }

    func testCAFRecorderWritesMonoFloat32Samples() async throws {
        let root = try makeTemporaryDirectory()
        let url = root.appendingPathComponent("mono.caf")
        let recorder = AudioChunkFileRecorder(configuration: AudioRecordingConfiguration(fileURL: url))
        let chunk = AudioChunk(
            samples: [0, 0.25, -0.5, 0.75],
            sampleRate: 8_000,
            channelCount: 1,
            startTime: 0
        )

        try await recorder.record(chunk)
        let maybeSummary = try await recorder.finish()
        let summary = try XCTUnwrap(maybeSummary)
        let recorded = try readPCMFile(at: url)

        XCTAssertEqual(summary.fileURL, url)
        XCTAssertEqual(summary.sampleRate, 8_000, accuracy: 0.01)
        XCTAssertEqual(summary.channelCount, 1)
        XCTAssertEqual(summary.frameCount, 4)
        XCTAssertEqual(summary.duration, 4.0 / 8_000.0, accuracy: 0.000_001)
        XCTAssertEqual(recorded.sampleRate, 8_000, accuracy: 0.01)
        XCTAssertEqual(recorded.channelCount, 1)
        XCTAssertEqual(recorded.frameCount, 4)
        XCTAssertSamplesEqual(recorded.samples, chunk.samples)
    }

    func testWAVRecorderWritesPCM16AndClampsSamples() async throws {
        let root = try makeTemporaryDirectory()
        let url = root.appendingPathComponent("clamped.wav")
        let recorder = AudioChunkFileRecorder(configuration: AudioRecordingConfiguration(
            fileURL: url,
            format: .wavPCM16
        ))
        let chunk = AudioChunk(
            samples: [-2, -1, -0.5, 0, 0.5, 1, 2],
            sampleRate: 16_000,
            channelCount: 1,
            startTime: 0
        )

        try await recorder.record(chunk)
        let maybeSummary = try await recorder.finish()
        let summary = try XCTUnwrap(maybeSummary)
        let recorded = try readPCMFile(at: url)

        XCTAssertEqual(summary.frameCount, 7)
        XCTAssertEqual(recorded.sampleRate, 16_000, accuracy: 0.01)
        XCTAssertEqual(recorded.channelCount, 1)
        XCTAssertEqual(recorded.frameCount, 7)
        XCTAssertEqual(recorded.samples[0], -1, accuracy: 0.000_1)
        XCTAssertEqual(recorded.samples[1], -1, accuracy: 0.000_1)
        XCTAssertEqual(recorded.samples[2], -0.5, accuracy: 0.001)
        XCTAssertEqual(recorded.samples[3], 0, accuracy: 0.001)
        XCTAssertEqual(recorded.samples[4], 0.5, accuracy: 0.001)
        XCTAssertEqual(recorded.samples[5], 1, accuracy: 0.000_1)
        XCTAssertEqual(recorded.samples[6], 1, accuracy: 0.000_1)
    }

    func testRecorderWritesStereoInterleavedChunks() async throws {
        let root = try makeTemporaryDirectory()
        let url = root.appendingPathComponent("stereo.caf")
        let recorder = AudioChunkFileRecorder(configuration: AudioRecordingConfiguration(fileURL: url))
        let samples: [Float] = [
            0.1, 0.2,
            0.3, 0.4,
            -0.1, -0.2
        ]
        let chunk = AudioChunk(
            samples: samples,
            sampleRate: 44_100,
            channelCount: 2,
            startTime: 0
        )

        try await recorder.record(chunk)
        let maybeSummary = try await recorder.finish()
        let summary = try XCTUnwrap(maybeSummary)
        let recorded = try readPCMFile(at: url)

        XCTAssertEqual(summary.channelCount, 2)
        XCTAssertEqual(summary.frameCount, 3)
        XCTAssertEqual(recorded.channelCount, 2)
        XCTAssertEqual(recorded.frameCount, 3)
        XCTAssertSamplesEqual(recorded.samples, samples)
    }

    func testRecorderRejectsFormatChangesAfterCreation() async throws {
        let root = try makeTemporaryDirectory()
        let url = root.appendingPathComponent("format-change.caf")
        let recorder = AudioChunkFileRecorder(configuration: AudioRecordingConfiguration(fileURL: url))

        try await recorder.record(AudioChunk(
            samples: [0, 0.1],
            sampleRate: 16_000,
            channelCount: 1,
            startTime: 0
        ))

        do {
            try await recorder.record(AudioChunk(
                samples: [0, 0.1],
                sampleRate: 48_000,
                channelCount: 1,
                startTime: 0.1
            ))
            XCTFail("Expected format change to throw.")
        } catch AudioRecordingError.formatChanged(
            let expectedSampleRate,
            let actualSampleRate,
            let expectedChannelCount,
            let actualChannelCount
        ) {
            XCTAssertEqual(expectedSampleRate, 16_000, accuracy: 0.01)
            XCTAssertEqual(actualSampleRate, 48_000, accuracy: 0.01)
            XCTAssertEqual(expectedChannelCount, 1)
            XCTAssertEqual(actualChannelCount, 1)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRecorderRejectsUnalignedFrames() async throws {
        let root = try makeTemporaryDirectory()
        let url = root.appendingPathComponent("unaligned.caf")
        let recorder = AudioChunkFileRecorder(configuration: AudioRecordingConfiguration(fileURL: url))

        do {
            try await recorder.record(AudioChunk(
                samples: [0, 0.1, 0.2],
                sampleRate: 16_000,
                channelCount: 2,
                startTime: 0
            ))
            XCTFail("Expected invalid frame count to throw.")
        } catch AudioRecordingError.invalidFrameCount(let sampleCount, let channelCount) {
            XCTAssertEqual(sampleCount, 3)
            XCTAssertEqual(channelCount, 2)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRecorderFinishIsIdempotentAndEmptyRecordingReturnsNil() async throws {
        let root = try makeTemporaryDirectory()
        let url = root.appendingPathComponent("empty.caf")
        let recorder = AudioChunkFileRecorder(configuration: AudioRecordingConfiguration(fileURL: url))

        let firstFinish = try await recorder.finish()
        let secondFinish = try await recorder.finish()
        XCTAssertNil(firstFinish)
        XCTAssertNil(secondFinish)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testRecorderRejectsRecordAfterFinish() async throws {
        let root = try makeTemporaryDirectory()
        let url = root.appendingPathComponent("finished.caf")
        let recorder = AudioChunkFileRecorder(configuration: AudioRecordingConfiguration(fileURL: url))

        let summary = try await recorder.finish()
        XCTAssertNil(summary)
        do {
            try await recorder.record(AudioChunk(
                samples: [0.1],
                sampleRate: 16_000,
                channelCount: 1,
                startTime: 0
            ))
            XCTFail("Expected record after finish to throw.")
        } catch AudioRecordingError.recordingFinished {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRecorderExistingFileBehavior() async throws {
        let root = try makeTemporaryDirectory()
        let url = root.appendingPathComponent("existing.caf")
        try Data("existing".utf8).write(to: url)
        let chunk = AudioChunk(
            samples: [0.1, -0.1],
            sampleRate: 16_000,
            channelCount: 1,
            startTime: 0
        )

        let defaultRecorder = AudioChunkFileRecorder(configuration: AudioRecordingConfiguration(fileURL: url))
        do {
            try await defaultRecorder.record(chunk)
            XCTFail("Expected existing file to throw.")
        } catch AudioRecordingError.fileAlreadyExists(let existingURL) {
            XCTAssertEqual(existingURL, url)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let overwriteRecorder = AudioChunkFileRecorder(configuration: AudioRecordingConfiguration(
            fileURL: url,
            overwriteExistingFile: true
        ))
        try await overwriteRecorder.record(chunk)
        let maybeSummary = try await overwriteRecorder.finish()
        let summary = try XCTUnwrap(maybeSummary)
        XCTAssertEqual(summary.frameCount, 2)
        XCTAssertEqual(try readPCMFile(at: url).samples.count, 2)
    }

    func testRecordingStreamForwardsChunksAndWritesSameAudio() async throws {
        let root = try makeTemporaryDirectory()
        let url = root.appendingPathComponent("stream.caf")
        let chunks = [
            AudioChunk(samples: [0.1, 0.2], sampleRate: 16_000, channelCount: 1, startTime: 0),
            AudioChunk(samples: [0.3, 0.4], sampleRate: 16_000, channelCount: 1, startTime: 0.000_125)
        ]
        let source = AsyncThrowingStream<AudioChunk, Error> { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
        let recorder = AudioChunkFileRecorder(configuration: AudioRecordingConfiguration(fileURL: url))
        let stream = AudioChunkStreams.recording(source, recorder: recorder)

        var forwarded: [AudioChunk] = []
        for try await chunk in stream {
            forwarded.append(chunk)
        }

        let maybeSummary = try await recorder.finish()
        let summary = try XCTUnwrap(maybeSummary)
        let recorded = try readPCMFile(at: url)
        XCTAssertEqual(forwarded, chunks)
        XCTAssertEqual(summary.frameCount, 4)
        XCTAssertSamplesEqual(recorded.samples, chunks.flatMap(\.samples))
    }

    func testRecordingStreamPropagatesSourceErrors() async throws {
        let root = try makeTemporaryDirectory()
        let url = root.appendingPathComponent("source-error.caf")
        let chunk = AudioChunk(samples: [0.1, 0.2], sampleRate: 16_000, channelCount: 1, startTime: 0)
        let source = AsyncThrowingStream<AudioChunk, Error> { continuation in
            continuation.yield(chunk)
            continuation.finish(throwing: AudioRecordingStreamTestError.source)
        }
        let recorder = AudioChunkFileRecorder(configuration: AudioRecordingConfiguration(fileURL: url))
        let stream = AudioChunkStreams.recording(source, recorder: recorder)

        var forwarded: [AudioChunk] = []
        do {
            for try await emitted in stream {
                forwarded.append(emitted)
            }
            XCTFail("Expected source error.")
        } catch AudioRecordingStreamTestError.source {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let maybeSummary = try await recorder.finish()
        let summary = try XCTUnwrap(maybeSummary)
        XCTAssertEqual(forwarded, [chunk])
        XCTAssertEqual(summary.frameCount, 2)
    }

    func testRecordingStreamPropagatesRecorderErrorsBeforeForwardingChunk() async throws {
        let root = try makeTemporaryDirectory()
        let url = root.appendingPathComponent("recorder-error.caf")
        let first = AudioChunk(samples: [0.1, 0.2], sampleRate: 16_000, channelCount: 1, startTime: 0)
        let changed = AudioChunk(samples: [0.3, 0.4], sampleRate: 48_000, channelCount: 1, startTime: 0.1)
        let source = AsyncThrowingStream<AudioChunk, Error> { continuation in
            continuation.yield(first)
            continuation.yield(changed)
            continuation.finish()
        }
        let recorder = AudioChunkFileRecorder(configuration: AudioRecordingConfiguration(fileURL: url))
        let stream = AudioChunkStreams.recording(source, recorder: recorder)

        var forwarded: [AudioChunk] = []
        do {
            for try await emitted in stream {
                forwarded.append(emitted)
            }
            XCTFail("Expected recorder error.")
        } catch AudioRecordingError.formatChanged(_, _, _, _) {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let maybeSummary = try await recorder.finish()
        let summary = try XCTUnwrap(maybeSummary)
        XCTAssertEqual(forwarded, [first])
        XCTAssertEqual(summary.frameCount, 2)
    }

    func testAudioChunkTapErrorsBeforeForwardingFailingChunk() async throws {
        let chunks = [
            AudioChunk(samples: [0.1], sampleRate: 16_000, channelCount: 1, startTime: 0),
            AudioChunk(samples: [0.2], sampleRate: 16_000, channelCount: 1, startTime: 0.000_0625)
        ]
        let source = AsyncThrowingStream<AudioChunk, Error> { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
        let stream = AudioChunkStreams.tap(source) { chunk in
            if chunk.samples[0] == 0.2 {
                throw AudioRecordingStreamTestError.tap
            }
        }

        var forwarded: [AudioChunk] = []
        do {
            for try await chunk in stream {
                forwarded.append(chunk)
            }
            XCTFail("Expected tap error.")
        } catch AudioRecordingStreamTestError.tap {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(forwarded, [chunks[0]])
    }

    @MainActor
    func testModelLibraryAddsDownloadedPartialUsingRequestedFilename() throws {
        let root = try makeTemporaryDirectory()
        let partial = root.appendingPathComponent("cls-partial-abcdef.bin")
        try Data("downloaded whisper weights".utf8).write(to: partial)
        let vadPartial = root.appendingPathComponent("cls-partial-vad.bin")
        try Data("downloaded vad weights".utf8).write(to: vadPartial)

        let library = SpeechModelLibrary(root: root.appendingPathComponent("SpeechModels", isDirectory: true))
        let model = try library.add(
            primaryAssetAt: partial,
            displayName: "Base English",
            filename: "ggml-base.en.bin",
            source: .curated,
            hfRepo: "ggerganov/whisper.cpp",
            hfFilename: "ggml-base.en.bin",
            vadAssetAt: vadPartial,
            vadFilename: "ggml-silero-v6.2.0.bin"
        )

        XCTAssertEqual(model.primaryWeightsAsset?.relativePath, "ggml-base.en.bin")
        XCTAssertEqual(model.vadWeightsAsset?.relativePath, "ggml-silero-v6.2.0.bin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.primaryWeightsURL(in: library.root)!.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.vadWeightsURL(in: library.root)!.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: vadPartial.path))
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

    func testEnergyVADAppliesSensitivityThresholds() throws {
        let borderline = AudioChunk(samples: Array(repeating: 0.01, count: 160), sampleRate: 16_000, channelCount: 1, startTime: 0)

        XCTAssertEqual(try EnergyVoiceActivityDetector(sensitivity: .low).analyze(borderline).state, .silence)
        XCTAssertEqual(try EnergyVoiceActivityDetector(sensitivity: .medium).analyze(borderline).state, .silence)
        XCTAssertEqual(try EnergyVoiceActivityDetector(sensitivity: .high).analyze(borderline).state, .speech)
    }

    func testSmoothedVADRequiresSustainedTransitions() throws {
        let detector = SmoothedVoiceActivityDetector(
            detector: SequenceVoiceActivityDetector(states: [
                .speech,
                .silence,
                .speech,
                .speech,
                .silence,
                .silence,
                .speech,
                .silence,
                .silence,
                .silence,
                .silence,
                .silence,
                .silence
            ]),
            configuration: VoiceActivitySmoothingConfiguration(
                enterSpeechDuration: 0.25,
                exitSpeechDuration: 0.75
            )
        )
        let duration = 0.125

        let analyses = try (0..<13).map { index in
            try detector.analyzeWithDiagnostics(AudioChunk(
                samples: Array(repeating: 0.05, count: 1_000),
                sampleRate: 8_000,
                channelCount: 1,
                startTime: TimeInterval(index) * duration,
                duration: duration
            ))
        }

        XCTAssertEqual(analyses[0].rawActivity.state, .speech)
        XCTAssertEqual(analyses[0].activity.state, .silence)
        XCTAssertEqual(analyses[3].activity.state, .speech)
        XCTAssertEqual(analyses[3].activity.startTime, 0.25, accuracy: 0.000_1)
        XCTAssertEqual(analyses[4].activity.state, .speech)
        XCTAssertEqual(analyses[5].activity.state, .speech)
        XCTAssertEqual(analyses[6].activity.state, .speech)
        XCTAssertEqual(analyses[11].activity.state, .speech)
        XCTAssertEqual(analyses[12].activity.state, .silence)
        XCTAssertEqual(analyses[12].activity.startTime, 0.875, accuracy: 0.000_1)

        XCTAssertTrue(analyses[0].diagnostics.contains { diagnostic in
            diagnostic.message.contains("raw_vad=speech smoothed_vad=silence")
        })
        XCTAssertTrue(analyses[3].diagnostics.contains { diagnostic in
            diagnostic.message.contains("smoothed_vad_transition=speech")
        })
        XCTAssertTrue(analyses[12].diagnostics.contains { diagnostic in
            diagnostic.message.contains("smoothed_vad_transition=silence")
        })
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

    func testSpeechChunkerResetsOverlapAfterSilenceFinal() throws {
        var chunker = SpeechChunker(configuration: SpeechChunkingConfiguration(
            maximumChunkDuration: 10.0,
            overlapDuration: 0.25,
            silenceCommitDelay: 0.2,
            minimumSpeechDuration: 0.1
        ))

        XCTAssertTrue(chunker.append(
            AudioChunk(
                samples: Array(repeating: 0.1, count: 400),
                sampleRate: 1_000,
                channelCount: 1,
                startTime: 0,
                duration: 0.4
            ),
            activity: VoiceActivityEvent(state: .speech, startTime: 0, endTime: 0.4)
        ).isEmpty)

        let final = chunker.append(
            AudioChunk(
                samples: Array(repeating: 0, count: 250),
                sampleRate: 1_000,
                channelCount: 1,
                startTime: 0.4,
                duration: 0.25
            ),
            activity: VoiceActivityEvent(state: .silence, startTime: 0.4, endTime: 0.65)
        )
        XCTAssertEqual(final.count, 1)
        XCTAssertTrue(final[0].isFinal)

        XCTAssertTrue(chunker.append(
            AudioChunk(
                samples: Array(repeating: 0.1, count: 400),
                sampleRate: 1_000,
                channelCount: 1,
                startTime: 0.65,
                duration: 0.4
            ),
            activity: VoiceActivityEvent(state: .speech, startTime: 0.65, endTime: 1.05)
        ).isEmpty)

        let next = try XCTUnwrap(chunker.finish().first)
        XCTAssertEqual(next.startTime, 0.65, accuracy: 0.000_1)
        XCTAssertEqual(next.audio.duration, 0.4, accuracy: 0.000_1)
    }

    func testSpeechChunkerResetsAfterInputGap() throws {
        var chunker = SpeechChunker(configuration: SpeechChunkingConfiguration(
            maximumChunkDuration: 2.0,
            overlapDuration: 0.25,
            silenceCommitDelay: 0.5,
            minimumSpeechDuration: 0.1
        ))

        let first = AudioChunk(
            samples: Array(repeating: 0.1, count: 500),
            sampleRate: 1_000,
            channelCount: 1,
            startTime: 0,
            duration: 0.5
        )
        XCTAssertTrue(chunker.append(
            first,
            activity: VoiceActivityEvent(state: .speech, startTime: 0, endTime: 0.5)
        ).isEmpty)

        let afterGap = AudioChunk(
            samples: Array(repeating: 0.1, count: 1_000),
            sampleRate: 1_000,
            channelCount: 1,
            startTime: 10,
            duration: 1.0
        )
        XCTAssertTrue(chunker.append(
            afterGap,
            activity: VoiceActivityEvent(state: .speech, startTime: 10, endTime: 11)
        ).isEmpty)

        let final = try XCTUnwrap(chunker.finish().first)
        XCTAssertEqual(final.startTime, 10, accuracy: 0.000_1)
        XCTAssertEqual(final.audio.duration, 1.0, accuracy: 0.000_1)
    }

    func testSpeechRollingWindowEmitsOnlyNewAudioPlusOverlap() {
        var window = SpeechRollingWindow(
            maximumBufferDuration: 4.0,
            updateInterval: 1.0,
            overlapDuration: 0.25
        )

        func chunk(index: Int) -> AudioChunk {
            AudioChunk(
                samples: Array(repeating: 0.05, count: 500),
                sampleRate: 1_000,
                channelCount: 1,
                startTime: TimeInterval(index) * 0.5,
                duration: 0.5
            )
        }

        XCTAssertTrue(window.append(chunk(index: 0)).isEmpty)

        let first = window.append(chunk(index: 1))
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].startTime, 0, accuracy: 0.000_1)
        XCTAssertEqual(first[0].audio.duration, 1.0, accuracy: 0.000_1)

        XCTAssertTrue(window.append(chunk(index: 2)).isEmpty)

        let second = window.append(chunk(index: 3))
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second[0].startTime, 0.75, accuracy: 0.000_1)
        XCTAssertEqual(second[0].audio.duration, 1.25, accuracy: 0.000_1)
    }

    func testSpeechRollingWindowResetsAfterInputGap() {
        var window = SpeechRollingWindow(
            maximumBufferDuration: 4.0,
            updateInterval: 1.0,
            overlapDuration: 0.25
        )

        let first = AudioChunk(
            samples: Array(repeating: 0.05, count: 1_000),
            sampleRate: 1_000,
            channelCount: 1,
            startTime: 0,
            duration: 1.0
        )
        XCTAssertEqual(window.append(first).count, 1)

        let afterGap = AudioChunk(
            samples: Array(repeating: 0.05, count: 500),
            sampleRate: 1_000,
            channelCount: 1,
            startTime: 10,
            duration: 0.5
        )
        XCTAssertTrue(window.append(afterGap).isEmpty)

        let continuation = AudioChunk(
            samples: Array(repeating: 0.05, count: 500),
            sampleRate: 1_000,
            channelCount: 1,
            startTime: 10.5,
            duration: 0.5
        )
        let emitted = window.append(continuation)
        XCTAssertEqual(emitted.count, 1)
        XCTAssertEqual(emitted[0].startTime, 10, accuracy: 0.000_1)
        XCTAssertEqual(emitted[0].audio.duration, 1.0, accuracy: 0.000_1)
    }

    func testSpeechRollingWindowDownmixesMultichannelInput() {
        var window = SpeechRollingWindow(
            maximumBufferDuration: 4.0,
            updateInterval: 1.0,
            overlapDuration: 0
        )

        let stereoFrames = Array(repeating: [Float(1), Float(0)], count: 1_000).flatMap { $0 }
        let emitted = window.append(AudioChunk(
            samples: stereoFrames,
            sampleRate: 1_000,
            channelCount: 2,
            startTime: 0
        ))

        XCTAssertEqual(emitted.count, 1)
        XCTAssertEqual(emitted[0].audio.samples.count, 1_000)
        XCTAssertEqual(emitted[0].audio.duration, 1.0, accuracy: 0.000_1)
        XCTAssertEqual(emitted[0].audio.samples.first ?? 0, 0.5, accuracy: 0.000_1)
    }

    func testSpeechContextualRollingWindowEmitsFullRetainedContext() throws {
        var window = SpeechContextualRollingWindow(
            maximumBufferDuration: 2.0,
            updateInterval: 1.0,
            finalSilenceDelay: 1.0
        )

        func chunk(index: Int) -> AudioChunk {
            AudioChunk(
                samples: Array(repeating: 0.05, count: 500),
                sampleRate: 1_000,
                channelCount: 1,
                startTime: TimeInterval(index) * 0.5,
                duration: 0.5
            )
        }

        XCTAssertTrue(window.append(chunk(index: 0), activity: nil).chunks.isEmpty)

        let first = window.append(chunk(index: 1), activity: nil).chunks
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].startTime, 0, accuracy: 0.000_1)
        XCTAssertEqual(first[0].audio.duration, 1.0, accuracy: 0.000_1)

        XCTAssertTrue(window.append(chunk(index: 2), activity: nil).chunks.isEmpty)

        let second = window.append(chunk(index: 3), activity: nil).chunks
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second[0].startTime, 0, accuracy: 0.000_1)
        XCTAssertEqual(second[0].audio.duration, 2.0, accuracy: 0.000_1)

        XCTAssertTrue(window.append(chunk(index: 4), activity: nil).chunks.isEmpty)

        let final = try XCTUnwrap(window.finish().first)
        XCTAssertTrue(final.isFinal)
        XCTAssertEqual(final.startTime, 0.5, accuracy: 0.000_1)
        XCTAssertEqual(final.audio.duration, 2.0, accuracy: 0.000_1)
    }

    func testSpeechContextualRollingWindowTrimsCommittedAudioAfterFrontier() throws {
        var window = SpeechContextualRollingWindow(
            maximumBufferDuration: 30.0,
            updateInterval: 1.0,
            finalSilenceDelay: 0.5,
            voiceActivityMode: .leadingSilence
        )

        _ = window.append(
            AudioChunk(
                samples: Array(repeating: 0.05, count: 20 * 16_000),
                sampleRate: 16_000,
                channelCount: 1,
                startTime: 0,
                duration: 20
            ),
            activity: nil
        )

        let trimmed = try XCTUnwrap(window.trimCommittedAudio(before: 18.0))
        XCTAssertEqual(trimmed, 17.5, accuracy: 0.001)

        let final = try XCTUnwrap(window.finish().first)
        XCTAssertEqual(final.startTime, 17.5, accuracy: 0.001)
        XCTAssertEqual(final.audio.duration, 2.5, accuracy: 0.001)
    }

    func testSpeechContextualRollingWindowFinalizesAfterSilence() throws {
        var window = SpeechContextualRollingWindow(
            maximumBufferDuration: 10.0,
            updateInterval: 5.0,
            finalSilenceDelay: 0.5
        )

        XCTAssertTrue(window.append(
            AudioChunk(
                samples: Array(repeating: 0.05, count: 500),
                sampleRate: 1_000,
                channelCount: 1,
                startTime: 0,
                duration: 0.5
            ),
            activity: VoiceActivityEvent(state: .speech, startTime: 0, endTime: 0.5)
        ).chunks.isEmpty)

        let emitted = window.append(
            AudioChunk(
                samples: Array(repeating: 0, count: 500),
                sampleRate: 1_000,
                channelCount: 1,
                startTime: 0.5,
                duration: 0.5
            ),
            activity: VoiceActivityEvent(state: .silence, startTime: 0.5, endTime: 1.0)
        ).chunks

        XCTAssertEqual(emitted.count, 1)
        XCTAssertTrue(emitted[0].isFinal)
        XCTAssertEqual(emitted[0].startTime, 0, accuracy: 0.000_1)
        XCTAssertEqual(emitted[0].audio.duration, 1.0, accuracy: 0.000_1)
    }

    func testSpeechContextualRollingWindowTrimsLeadingVADSilenceBeforeFirstSpeech() throws {
        var window = SpeechContextualRollingWindow(
            maximumBufferDuration: 10.0,
            updateInterval: 0.5,
            finalSilenceDelay: 0.5,
            preSpeechPaddingDuration: 0.5
        )

        for index in 0..<3 {
            let result = window.append(
                AudioChunk(
                    samples: Array(repeating: 0, count: 500),
                    sampleRate: 1_000,
                    channelCount: 1,
                    startTime: TimeInterval(index) * 0.5,
                    duration: 0.5
                ),
                activity: VoiceActivityEvent(
                    state: .silence,
                    startTime: TimeInterval(index) * 0.5,
                    endTime: TimeInterval(index + 1) * 0.5
                )
            )
            XCTAssertTrue(result.chunks.isEmpty)
        }

        let speech = window.append(
            AudioChunk(
                samples: Array(repeating: 0.05, count: 500),
                sampleRate: 1_000,
                channelCount: 1,
                startTime: 1.5,
                duration: 0.5
            ),
            activity: VoiceActivityEvent(state: .speech, startTime: 1.5, endTime: 2.0)
        )

        XCTAssertEqual(speech.speechStartTime, 1.5)
        XCTAssertEqual(try XCTUnwrap(speech.leadingSilenceTrimmed), 1.0, accuracy: 0.000_1)
        XCTAssertEqual(speech.chunks.count, 1)
        XCTAssertEqual(speech.chunks[0].startTime, 1.0, accuracy: 0.000_1)
        XCTAssertEqual(speech.chunks[0].audio.duration, 1.0, accuracy: 0.000_1)
    }

    func testSpeechContextualRollingWindowKeepsContextAfterVADTurnFinal() throws {
        var window = SpeechContextualRollingWindow(
            maximumBufferDuration: 10.0,
            updateInterval: 0.5,
            finalSilenceDelay: 0.5
        )

        _ = window.append(
            AudioChunk(
                samples: Array(repeating: 0.05, count: 1_000),
                sampleRate: 1_000,
                channelCount: 1,
                startTime: 0,
                duration: 1.0
            ),
            activity: VoiceActivityEvent(state: .speech, startTime: 0, endTime: 1.0)
        )

        let final = window.append(
            AudioChunk(
                samples: Array(repeating: 0, count: 500),
                sampleRate: 1_000,
                channelCount: 1,
                startTime: 1.0,
                duration: 0.5
            ),
            activity: VoiceActivityEvent(state: .silence, startTime: 1.0, endTime: 1.5)
        )
        XCTAssertEqual(final.chunks.count, 1)
        XCTAssertTrue(final.chunks[0].isFinal)
        XCTAssertEqual(final.turnFinalTime, 1.5)

        let nextSpeech = window.append(
            AudioChunk(
                samples: Array(repeating: 0.05, count: 500),
                sampleRate: 1_000,
                channelCount: 1,
                startTime: 1.5,
                duration: 0.5
            ),
            activity: VoiceActivityEvent(state: .speech, startTime: 1.5, endTime: 2.0)
        )

        XCTAssertEqual(nextSpeech.speechStartTime, 1.5)
        XCTAssertEqual(nextSpeech.chunks.count, 1)
        XCTAssertFalse(nextSpeech.chunks[0].isFinal)
        XCTAssertEqual(nextSpeech.chunks[0].startTime, 0, accuracy: 0.000_1)
        XCTAssertEqual(nextSpeech.chunks[0].audio.duration, 2.0, accuracy: 0.000_1)
    }

    func testSpeechContextualRollingWindowLeadingSilenceModeDoesNotFinalizeOnVADSilence() throws {
        var window = SpeechContextualRollingWindow(
            maximumBufferDuration: 10.0,
            updateInterval: 0.5,
            finalSilenceDelay: 0.5,
            voiceActivityMode: .leadingSilence
        )

        _ = window.append(
            AudioChunk(
                samples: Array(repeating: 0.05, count: 500),
                sampleRate: 1_000,
                channelCount: 1,
                startTime: 0,
                duration: 0.5
            ),
            activity: VoiceActivityEvent(state: .speech, startTime: 0, endTime: 0.5)
        )

        let silence = window.append(
            AudioChunk(
                samples: Array(repeating: 0, count: 500),
                sampleRate: 1_000,
                channelCount: 1,
                startTime: 0.5,
                duration: 0.5
            ),
            activity: VoiceActivityEvent(state: .silence, startTime: 0.5, endTime: 1.0)
        )

        XCTAssertNil(silence.turnFinalTime)
        XCTAssertEqual(silence.chunks.count, 1)
        XCTAssertFalse(silence.chunks[0].isFinal)
        XCTAssertEqual(silence.chunks[0].startTime, 0, accuracy: 0.000_1)
        XCTAssertEqual(silence.chunks[0].audio.duration, 1.0, accuracy: 0.000_1)
        XCTAssertEqual(silence.silenceFlushTime, 1.0)

        XCTAssertTrue(window.finish().isEmpty)
    }

    func testSpeechContextualRollingWindowDoesNotBackCountSmoothedSilenceForFlush() throws {
        var window = SpeechContextualRollingWindow(
            maximumBufferDuration: 10.0,
            updateInterval: 10.0,
            finalSilenceDelay: 0.5,
            voiceActivityMode: .leadingSilence
        )

        _ = window.append(
            AudioChunk(
                samples: Array(repeating: 0.05, count: 1_000),
                sampleRate: 1_000,
                channelCount: 1,
                startTime: 0,
                duration: 1.0
            ),
            activity: VoiceActivityEvent(state: .speech, startTime: 0, endTime: 1.0)
        )

        let smoothedTransition = window.append(
            AudioChunk(
                samples: Array(repeating: 0, count: 100),
                sampleRate: 1_000,
                channelCount: 1,
                startTime: 1.0,
                duration: 0.1
            ),
            activity: VoiceActivityEvent(state: .silence, startTime: 0.3, endTime: 1.1)
        )

        XCTAssertTrue(smoothedTransition.chunks.isEmpty)
        XCTAssertNil(smoothedTransition.silenceFlushTime)

        for index in 1..<4 {
            let result = window.append(
                AudioChunk(
                    samples: Array(repeating: 0, count: 100),
                    sampleRate: 1_000,
                    channelCount: 1,
                    startTime: 1.0 + TimeInterval(index) * 0.1,
                    duration: 0.1
                ),
                activity: VoiceActivityEvent(
                    state: .silence,
                    startTime: 1.0 + TimeInterval(index) * 0.1,
                    endTime: 1.1 + TimeInterval(index) * 0.1
                )
            )
            XCTAssertNil(result.silenceFlushTime)
        }

        let sustainedSilence = window.append(
            AudioChunk(
                samples: Array(repeating: 0, count: 100),
                sampleRate: 1_000,
                channelCount: 1,
                startTime: 1.4,
                duration: 0.1
            ),
            activity: VoiceActivityEvent(state: .silence, startTime: 1.4, endTime: 1.5)
        )

        XCTAssertEqual(sustainedSilence.silenceFlushTime, 1.5)
        XCTAssertEqual(sustainedSilence.chunks.count, 1)
        XCTAssertFalse(sustainedSilence.chunks[0].isFinal)
        XCTAssertEqual(sustainedSilence.chunks[0].audio.duration, 1.5, accuracy: 0.000_1)
    }

    func testSpeechContextualRollingWindowEmitsFinalBeforeInputGap() throws {
        var window = SpeechContextualRollingWindow(
            maximumBufferDuration: 10.0,
            updateInterval: 5.0,
            finalSilenceDelay: 1.0
        )

        XCTAssertTrue(window.append(
            AudioChunk(
                samples: Array(repeating: 0.05, count: 1_000),
                sampleRate: 1_000,
                channelCount: 1,
                startTime: 0,
                duration: 1.0
            ),
            activity: nil
        ).chunks.isEmpty)

        let result = window.append(
            AudioChunk(
                samples: Array(repeating: 0.05, count: 500),
                sampleRate: 1_000,
                channelCount: 1,
                startTime: 10,
                duration: 0.5
            ),
            activity: nil
        )

        XCTAssertEqual(try XCTUnwrap(result.audioGap), 9.0, accuracy: 0.000_1)
        XCTAssertEqual(result.chunks.count, 1)
        XCTAssertTrue(result.chunks[0].isFinal)
        XCTAssertEqual(result.chunks[0].startTime, 0, accuracy: 0.000_1)
        XCTAssertEqual(result.chunks[0].audio.duration, 1.0, accuracy: 0.000_1)

        let final = try XCTUnwrap(window.finish().first)
        XCTAssertEqual(final.startTime, 10, accuracy: 0.000_1)
        XCTAssertEqual(final.audio.duration, 0.5, accuracy: 0.000_1)
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
        let volatile = Transcript(segments: [TranscriptSegment(text: "hel", startTime: 0, endTime: 0.2)])
        let transcriber = MockSpeechTranscriber(
            transcript: Transcript(segments: [TranscriptSegment(text: "hello", startTime: 0, endTime: 0.5)]),
            streamEvents: [.snapshot(StreamingTranscriptSnapshot(volatile: volatile))]
        )
        let audio = AsyncThrowingStream<AudioChunk, Error> { continuation in
            continuation.finish()
        }

        var events: [TranscriptEvent] = []
        for try await event in transcriber.stream(audio: audio, options: StreamingTranscriptionOptions()) {
            events.append(event)
        }

        XCTAssertTrue(events.contains { event in
            if case .snapshot(let snapshot) = event {
                return snapshot.volatile?.text == "hel"
            }
            return false
        })
        XCTAssertTrue(events.contains { event in
            if case .completed = event { return true }
            return false
        })
    }

    func testSpeechChunkStreamingPipelineTranscribesCommittedChunks() async throws {
        let audio = AsyncThrowingStream<AudioChunk, Error> { continuation in
            continuation.yield(AudioChunk(
                samples: Array(repeating: 0.05, count: 1_600),
                sampleRate: 16_000,
                channelCount: 1,
                startTime: 0,
                duration: 0.1
            ))
            continuation.finish()
        }
        let backend = SpeechBackendDescriptor(kind: .mock, displayName: "Mock")
        let options = StreamingTranscriptionOptions(
            transcription: TranscriptionOptions(useCase: .dictation),
            commitment: .immediate,
            strategy: .lowestLatency,
            emulation: EmulatedStreamingOptions(
                window: .vadUtterances(SpeechChunkingConfiguration(
                    maximumChunkDuration: 0.1,
                    overlapDuration: 0,
                    silenceCommitDelay: 0.2,
                    minimumSpeechDuration: 0.01
                ))
            )
        )

        var events: [TranscriptEvent] = []
        let stream = SpeechChunkStreamingPipeline.stream(
            audio: audio,
            backend: backend,
            options: options,
            transcribe: { audio, _ in
                Transcript(segments: [
                    TranscriptSegment(text: "hello", startTime: 0, endTime: audio.duration)
                ])
            })

        for try await event in stream {
            events.append(event)
        }

        XCTAssertTrue(events.contains { event in
            if case .snapshot(let snapshot) = event {
                return snapshot.stable.text == "hello"
            }
            return false
        })
        XCTAssertTrue(events.contains { event in
            if case .completed(let transcript) = event {
                return transcript.text == "hello"
            }
            return false
        })
    }

    func testSpeechChunkStreamingPipelineTimedTranscriptionReceivesChunkStartTime() async throws {
        let audio = AsyncThrowingStream<AudioChunk, Error> { continuation in
            continuation.yield(AudioChunk(
                samples: Array(repeating: 0.05, count: 1_600),
                sampleRate: 16_000,
                channelCount: 1,
                startTime: 2.0,
                duration: 0.1
            ))
            continuation.finish()
        }
        let backend = SpeechBackendDescriptor(kind: .mock, displayName: "Mock")
        let options = StreamingTranscriptionOptions(
            commitment: .immediate,
            strategy: .lowestLatency,
            emulation: EmulatedStreamingOptions(
                window: .vadUtterances(SpeechChunkingConfiguration(
                    maximumChunkDuration: 0.1,
                    overlapDuration: 0,
                    silenceCommitDelay: 0.2,
                    minimumSpeechDuration: 0.01
                ))
            )
        )
        let observedStart = SpeechChunkStreamingPipelineStartRecorder()

        let stream = SpeechChunkStreamingPipeline.stream(
            audio: audio,
            backend: backend,
            options: options,
            transcribeTimed: { chunk, _ in
                await observedStart.record(chunk.startTime)
                return Transcript(segments: [
                    TranscriptSegment(text: "hello", startTime: 0, endTime: chunk.audio.duration)
                ])
            }
        )

        for try await _ in stream {}

        let recordedStartValue = await observedStart.recordedValue()
        let recordedStart = try XCTUnwrap(recordedStartValue)
        XCTAssertEqual(recordedStart, 2.0, accuracy: 0.000_1)
    }

    func testSpeechChunkStreamingPipelineDoesNotReportVADWhenDisabled() async throws {
        let audio = AsyncThrowingStream<AudioChunk, Error> { continuation in
            continuation.yield(AudioChunk(
                samples: Array(repeating: 0.05, count: 1_600),
                sampleRate: 16_000,
                channelCount: 1,
                startTime: 0,
                duration: 0.1
            ))
            continuation.finish()
        }
        let backend = SpeechBackendDescriptor(kind: .mock, displayName: "Mock")
        let options = StreamingTranscriptionOptions(
            transcription: TranscriptionOptions(voiceActivityDetection: .disabled),
            commitment: .immediate,
            strategy: .balanced,
            implementation: .emulated,
            emulation: EmulatedStreamingOptions(
                window: .rollingBuffer(maxDuration: 1.0, updateInterval: 0.05, overlap: 0)
            )
        )

        var events: [TranscriptEvent] = []
        let stream = SpeechChunkStreamingPipeline.stream(
            audio: audio,
            backend: backend,
            options: options,
            transcribe: { audio, _ in
                Transcript(segments: [
                    TranscriptSegment(text: "hello", startTime: 0, endTime: audio.duration)
                ])
            })

        for try await event in stream {
            events.append(event)
        }

        XCTAssertFalse(events.contains { event in
            if case .voiceActivity = event { return true }
            return false
        })
        XCTAssertTrue(events.contains { event in
            if case .completed(let transcript) = event {
                return transcript.text == "hello"
            }
            return false
        })
    }

    func testSpeechChunkStreamingPipelineUsesInjectedVoiceActivityDetector() async throws {
        let audio = AsyncThrowingStream<AudioChunk, Error> { continuation in
            continuation.yield(AudioChunk(
                samples: Array(repeating: 0, count: 1_600),
                sampleRate: 16_000,
                channelCount: 1,
                startTime: 0,
                duration: 0.1
            ))
            continuation.yield(AudioChunk(
                samples: Array(repeating: 0, count: 1_600),
                sampleRate: 16_000,
                channelCount: 1,
                startTime: 0.1,
                duration: 0.1
            ))
            continuation.finish()
        }
        let backend = SpeechBackendDescriptor(kind: .mock, displayName: "Mock")
        let options = StreamingTranscriptionOptions(
            transcription: TranscriptionOptions(useCase: .dictation),
            commitment: .providerFinals,
            strategy: .balanced,
            implementation: .emulated,
            emulation: EmulatedStreamingOptions(
                window: .vadUtterances(SpeechChunkingConfiguration(
                    maximumChunkDuration: 2.0,
                    overlapDuration: 0,
                    silenceCommitDelay: 0.1,
                    minimumSpeechDuration: 0.01
                ))
            )
        )
        let detector = SequenceVoiceActivityDetector(states: [.speech, .silence])

        var events: [TranscriptEvent] = []
        let stream = SpeechChunkStreamingPipeline.stream(
            audio: audio,
            backend: backend,
            options: options,
            transcribeTimed: { chunk, _ in
                Transcript(segments: [
                    TranscriptSegment(text: "injected", startTime: 0, endTime: chunk.audio.duration)
                ])
            },
            voiceActivityDetector: detector
        )

        for try await event in stream {
            events.append(event)
        }

        XCTAssertTrue(events.contains { event in
            if case .voiceActivity(let activity) = event {
                return activity.state == .speech
            }
            return false
        })
        XCTAssertTrue(events.contains { event in
            if case .completed(let transcript) = event {
                return transcript.text == "injected"
            }
            return false
        })
    }

    func testSpeechChunkStreamingPipelineCoalescesContextualNonFinalJobs() async throws {
        let audio = AsyncThrowingStream<AudioChunk, Error> { continuation in
            for index in 0..<6 {
                continuation.yield(AudioChunk(
                    samples: Array(repeating: 0.05, count: 8_000),
                    sampleRate: 16_000,
                    channelCount: 1,
                    startTime: TimeInterval(index) * 0.5,
                    duration: 0.5
                ))
            }
            continuation.finish()
        }
        let backend = SpeechBackendDescriptor(kind: .mock, displayName: "Mock")
        let options = StreamingTranscriptionOptions(
            transcription: TranscriptionOptions(voiceActivityDetection: .disabled),
            commitment: .immediate,
            strategy: .balanced,
            implementation: .emulated,
            emulation: EmulatedStreamingOptions(
                window: .contextualRollingBuffer(maxDuration: 10.0, updateInterval: 0.5, finalSilenceDelay: 1.0)
            )
        )
        let callCounter = SpeechChunkStreamingPipelineCallCounter()

        var events: [TranscriptEvent] = []
        let stream = SpeechChunkStreamingPipeline.stream(
            audio: audio,
            backend: backend,
            options: options,
            transcribeTimed: { chunk, _ in
                _ = await callCounter.next()
                try await Task.sleep(nanoseconds: 30_000_000)
                guard chunk.isFinal else {
                    return Transcript()
                }
                return Transcript(segments: [
                    TranscriptSegment(text: "final context", startTime: 0, endTime: chunk.audio.duration)
                ])
            }
        )

        for try await event in stream {
            events.append(event)
        }

        let audioLevelCount = events.filter { event in
            if case .audioLevel = event { return true }
            return false
        }.count
        let transcriptionCallCount = await callCounter.current()

        XCTAssertEqual(audioLevelCount, 6)
        XCTAssertLessThan(transcriptionCallCount, 6)
        XCTAssertTrue(events.contains { event in
            if case .completed(let transcript) = event {
                return transcript.text == "final context"
            }
            return false
        })
    }

    func testSpeechChunkStreamingPipelineUsesStrictLocalAgreementForContextualWindows() async throws {
        let audio = AsyncThrowingStream<AudioChunk, Error> { continuation in
            Task {
                for index in 0..<2 {
                    continuation.yield(AudioChunk(
                        samples: Array(repeating: 0.05, count: 8_000),
                        sampleRate: 16_000,
                        channelCount: 1,
                        startTime: TimeInterval(index) * 0.5,
                        duration: 0.5
                    ))
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                continuation.finish()
            }
        }
        let backend = SpeechBackendDescriptor(kind: .mock, displayName: "Mock")
        let options = StreamingTranscriptionOptions(
            transcription: TranscriptionOptions(voiceActivityDetection: .disabled),
            commitment: .localAgreement(iterations: 2),
            strategy: .balanced,
            implementation: .emulated,
            emulation: EmulatedStreamingOptions(
                window: .contextualRollingBuffer(maxDuration: 10.0, updateInterval: 0.5, finalSilenceDelay: 1.0)
            )
        )
        let callCounter = SpeechChunkStreamingPipelineCallCounter()

        var events: [TranscriptEvent] = []
        let stream = SpeechChunkStreamingPipeline.stream(
            audio: audio,
            backend: backend,
            options: options,
            transcribeTimed: { chunk, _ in
                let callIndex = await callCounter.next()
                let text: String
                switch callIndex {
                case 1:
                    text = "government warning"
                case 2:
                    text = "women should not drink"
                default:
                    text = chunk.isFinal ? "women should not drink alcoholic beverages" : "women should not drink"
                }
                return Transcript(segments: [
                    TranscriptSegment(text: text, startTime: 0, endTime: chunk.audio.duration)
                ])
            }
        )

        for try await event in stream {
            events.append(event)
        }

        XCTAssertFalse(events.contains { event in
            if case .snapshot(let snapshot) = event {
                return snapshot.stable.text == "government warning"
            }
            return false
        })
        XCTAssertTrue(events.contains { event in
            if case .snapshot(let snapshot) = event {
                return snapshot.stable.text.isEmpty
                    && snapshot.volatile?.text == "women should not drink"
            }
            return false
        })
    }

    func testSpeechChunkStreamingPipelineCommitsExpiredPrefixForShiftedContextualWindows() async throws {
        let audio = AsyncThrowingStream<AudioChunk, Error> { continuation in
            Task {
                for index in 0..<3 {
                    continuation.yield(AudioChunk(
                        samples: Array(repeating: 0.05, count: 8_000),
                        sampleRate: 16_000,
                        channelCount: 1,
                        startTime: TimeInterval(index) * 0.5,
                        duration: 0.5
                    ))
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
                continuation.finish()
            }
        }
        let backend = SpeechBackendDescriptor(kind: .mock, displayName: "Mock")
        let options = StreamingTranscriptionOptions(
            transcription: TranscriptionOptions(voiceActivityDetection: .disabled),
            commitment: .localAgreement(iterations: 2),
            strategy: .balanced,
            implementation: .emulated,
            emulation: EmulatedStreamingOptions(
                window: .contextualRollingBuffer(maxDuration: 10.0, updateInterval: 0.5, finalSilenceDelay: 1.0)
            )
        )
        let callCounter = SpeechChunkStreamingPipelineCallCounter()

        var events: [TranscriptEvent] = []
        let stream = SpeechChunkStreamingPipeline.stream(
            audio: audio,
            backend: backend,
            options: options,
            transcribeTimed: { _, _ in
                let callIndex = await callCounter.next()
                let text: String
                switch callIndex {
                case 1:
                    text = "alpha beta gamma delta"
                case 2:
                    text = "gamma delta epsilon zeta"
                default:
                    text = "epsilon zeta eta theta"
                }
                return Transcript(segments: [
                    TranscriptSegment(text: text, startTime: 0, endTime: 1)
                ])
            }
        )

        for try await event in stream {
            events.append(event)
        }

        XCTAssertTrue(events.contains { event in
            if case .snapshot(let snapshot) = event {
                return snapshot.stable.text == "alpha beta"
                    && snapshot.volatile?.text == "gamma delta epsilon zeta"
            }
            return false
        })
        XCTAssertTrue(events.contains { event in
            if case .snapshot(let snapshot) = event {
                return snapshot.stable.text == "alpha beta gamma delta"
                    && snapshot.volatile?.text == "epsilon zeta eta theta"
            }
            return false
        })
        XCTAssertFalse(events.contains { event in
            if case .snapshot(let snapshot) = event {
                return snapshot.transcript.text.contains("gamma delta gamma delta")
                    || snapshot.transcript.text.contains("epsilon zeta epsilon zeta")
            }
            return false
        })
    }

    func testSpeechChunkStreamingPipelineContextualWindowsRemoveCommittedPrefixAfterRevision() async throws {
        let audio = AsyncThrowingStream<AudioChunk, Error> { continuation in
            Task {
                for index in 0..<3 {
                    continuation.yield(AudioChunk(
                        samples: Array(repeating: 0.05, count: 8_000),
                        sampleRate: 16_000,
                        channelCount: 1,
                        startTime: TimeInterval(index) * 0.5,
                        duration: 0.5
                    ))
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                continuation.finish()
            }
        }
        let backend = SpeechBackendDescriptor(kind: .mock, displayName: "Mock")
        let options = StreamingTranscriptionOptions(
            transcription: TranscriptionOptions(voiceActivityDetection: .disabled),
            commitment: .localAgreement(iterations: 2),
            strategy: .balanced,
            implementation: .emulated,
            emulation: EmulatedStreamingOptions(
                window: .contextualRollingBuffer(maxDuration: 10.0, updateInterval: 0.5, finalSilenceDelay: 1.0)
            )
        )
        let callCounter = SpeechChunkStreamingPipelineCallCounter()

        var events: [TranscriptEvent] = []
        let stream = SpeechChunkStreamingPipeline.stream(
            audio: audio,
            backend: backend,
            options: options,
            transcribeTimed: { _, _ in
                let callIndex = await callCounter.next()
                let text: String
                switch callIndex {
                case 1:
                    text = "Government Warning. According to the Surgeon General, women should not drink"
                case 2:
                    text = "Government Warning. According to the Surgeon General, women should not drink alcoholic beverages"
                default:
                    text = "Government Warning. women should not drink alcoholic beverages during pregnancy"
                }
                return Transcript(segments: [
                    TranscriptSegment(text: text, startTime: 0, endTime: 1)
                ])
            }
        )

        for try await event in stream {
            events.append(event)
        }

        XCTAssertFalse(events.contains { event in
            if case .snapshot(let snapshot) = event {
                return snapshot.transcript.text.contains("women should not drink women should not drink")
                    || snapshot.transcript.text.contains("Government Warning. According to the Surgeon General, women should not drink Government Warning")
            }
            return false
        })
        XCTAssertTrue(events.contains { event in
            if case .snapshot(let snapshot) = event {
                return snapshot.transcript.text.contains("alcoholic beverages during pregnancy")
            }
            return false
        })
    }

    func testSpeechChunkStreamingPipelineContextualWindowsDropHallucinatedLeadInBeforeCommittedReplay() async throws {
        let audio = AsyncThrowingStream<AudioChunk, Error> { continuation in
            Task {
                for index in 0..<4 {
                    continuation.yield(AudioChunk(
                        samples: Array(repeating: 0.05, count: 8_000),
                        sampleRate: 16_000,
                        channelCount: 1,
                        startTime: TimeInterval(index) * 0.5,
                        duration: 0.5
                    ))
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                continuation.finish()
            }
        }
        let backend = SpeechBackendDescriptor(kind: .mock, displayName: "Mock")
        let options = StreamingTranscriptionOptions(
            transcription: TranscriptionOptions(voiceActivityDetection: .disabled),
            commitment: .localAgreement(iterations: 2),
            strategy: .balanced,
            implementation: .emulated,
            emulation: EmulatedStreamingOptions(
                window: .contextualRollingBuffer(maxDuration: 10.0, updateInterval: 0.5, finalSilenceDelay: 1.0)
            )
        )
        let callCounter = SpeechChunkStreamingPipelineCallCounter()

        var events: [TranscriptEvent] = []
        let stream = SpeechChunkStreamingPipeline.stream(
            audio: audio,
            backend: backend,
            options: options,
            transcribeTimed: { _, _ in
                let callIndex = await callCounter.next()
                let text: String
                switch callIndex {
                case 1:
                    text = "Government Warning. According to the Surgeon General, women should not drink alcoholic beverages during pregnancy."
                case 2:
                    text = "Government Warning. According to the Surgeon General, women should not drink alcoholic beverages during pregnancy because of the risk of birth defects."
                case 3:
                    text = "In general, women should not drink alcoholic beverages during pregnancy because of the risk of birth defects. Consumption of alcoholic beverages impairs your ability"
                default:
                    text = "In general, women should not drink alcoholic beverages during pregnancy because of the risk of birth defects. Consumption of alcoholic beverages impairs your ability to drive a car or operate machinery and may cause health problems."
                }
                return Transcript(segments: [
                    TranscriptSegment(text: text, startTime: 0, endTime: 1)
                ])
            }
        )

        for try await event in stream {
            events.append(event)
        }

        let completedText = events.compactMap { event -> String? in
            if case .completed(let transcript) = event {
                return transcript.text
            }
            return nil
        }.last ?? ""

        XCTAssertFalse(completedText.contains("In general"))
        XCTAssertFalse(completedText.contains("birth defects. In general"))
        XCTAssertEqual(
            completedText,
            "Government Warning. According to the Surgeon General, women should not drink alcoholic beverages during pregnancy because of the risk of birth defects. Consumption of alcoholic beverages impairs your ability to drive a car or operate machinery and may cause health problems."
        )
    }

    func testSpeechChunkStreamingPipelineContextualWindowsSuppressCommittedReplayWithDigitWords() async throws {
        let audio = AsyncThrowingStream<AudioChunk, Error> { continuation in
            Task {
                for index in 0..<4 {
                    continuation.yield(AudioChunk(
                        samples: Array(repeating: 0.05, count: 8_000),
                        sampleRate: 16_000,
                        channelCount: 1,
                        startTime: TimeInterval(index) * 0.5,
                        duration: 0.5
                    ))
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                continuation.finish()
            }
        }
        let backend = SpeechBackendDescriptor(kind: .mock, displayName: "Mock")
        let options = StreamingTranscriptionOptions(
            transcription: TranscriptionOptions(voiceActivityDetection: .disabled),
            commitment: .localAgreement(iterations: 2),
            strategy: .balanced,
            implementation: .emulated,
            emulation: EmulatedStreamingOptions(
                window: .contextualRollingBuffer(maxDuration: 10.0, updateInterval: 0.5, finalSilenceDelay: 1.0)
            )
        )
        let callCounter = SpeechChunkStreamingPipelineCallCounter()

        var events: [TranscriptEvent] = []
        let stream = SpeechChunkStreamingPipeline.stream(
            audio: audio,
            backend: backend,
            options: options,
            transcribeTimed: { _, _ in
                let callIndex = await callCounter.next()
                let text: String
                switch callIndex {
                case 1, 2:
                    text = "Dietary fiber, less than one gram. Total sugars, eighteen grams. Include seventeen grams added sugars."
                default:
                    text = "1 gram. Total sugars, 18 grams. Include 17 grams added sugars."
                }
                return Transcript(segments: [
                    TranscriptSegment(text: text, startTime: 0, endTime: 1)
                ])
            }
        )

        for try await event in stream {
            events.append(event)
        }

        XCTAssertFalse(events.contains { event in
            if case .snapshot(let snapshot) = event {
                return snapshot.volatile?.text == "1 gram. Total sugars, 18 grams. Include 17 grams added sugars."
            }
            return false
        })

        let completedText = events.compactMap { event -> String? in
            if case .completed(let transcript) = event {
                return transcript.text
            }
            return nil
        }.last ?? ""
        XCTAssertEqual(
            completedText,
            "Dietary fiber, less than one gram. Total sugars, eighteen grams. Include seventeen grams added sugars."
        )
    }

    func testSpeechChunkStreamingPipelineContextualRejectsRepeatedLoopHypothesis() async throws {
        let audio = AsyncThrowingStream<AudioChunk, Error> { continuation in
            Task {
                for index in 0..<4 {
                    continuation.yield(AudioChunk(
                        samples: Array(repeating: 0.05, count: 8_000),
                        sampleRate: 16_000,
                        channelCount: 1,
                        startTime: TimeInterval(index) * 0.5,
                        duration: 0.5
                    ))
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                continuation.finish()
            }
        }
        let backend = SpeechBackendDescriptor(kind: .mock, displayName: "Mock")
        let options = StreamingTranscriptionOptions(
            transcription: TranscriptionOptions(voiceActivityDetection: .disabled),
            commitment: .localAgreement(iterations: 2),
            strategy: .balanced,
            implementation: .emulated,
            emulation: EmulatedStreamingOptions(
                window: .contextualRollingBuffer(maxDuration: 10.0, updateInterval: 0.5, finalSilenceDelay: 1.0)
            )
        )
        let callCounter = SpeechChunkStreamingPipelineCallCounter()

        var events: [TranscriptEvent] = []
        let stream = SpeechChunkStreamingPipeline.stream(
            audio: audio,
            backend: backend,
            options: options,
            transcribeTimed: { _, _ in
                let callIndex = await callCounter.next()
                let text: String
                switch callIndex {
                case 1:
                    text = "Speaking during a school visit"
                case 2:
                    text = "Speaking during a school visit in western Germany"
                default:
                    text = "The U.S. is now being attacked by Iran. The U.S. is now being attacked by Iran. The U.S. is now being attacked by Iran. The U.S. is now being attacked by Iran."
                }
                return Transcript(segments: [
                    TranscriptSegment(text: text, startTime: 0, endTime: 1)
                ])
            }
        )

        for try await event in stream {
            events.append(event)
        }

        XCTAssertTrue(events.contains { event in
            if case .diagnostic(let diagnostic) = event {
                return diagnostic.message == "hypothesis_rejected=repetition"
            }
            return false
        })
        XCTAssertFalse(events.contains { event in
            if case .snapshot(let snapshot) = event {
                return snapshot.transcript.text.contains("attacked by Iran")
            }
            return false
        })

        let completedText = events.compactMap { event -> String? in
            if case .completed(let transcript) = event {
                return transcript.text
            }
            return nil
        }.last ?? ""
        XCTAssertEqual(completedText, "Speaking during a school visit in western Germany")
    }

    func testSpeechChunkStreamingPipelineQuarantinesNoVADStaleReplayDuringIdleFrontier() async throws {
        let audio = AsyncThrowingStream<AudioChunk, Error> { continuation in
            Task {
                for index in 0..<6 {
                    continuation.yield(AudioChunk(
                        samples: Array(repeating: index < 4 ? 0.05 : 0, count: 8_000),
                        sampleRate: 16_000,
                        channelCount: 1,
                        startTime: TimeInterval(index) * 0.5,
                        duration: 0.5
                    ))
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                continuation.finish()
            }
        }
        let backend = SpeechBackendDescriptor(kind: .mock, displayName: "Mock")
        let options = StreamingTranscriptionOptions(
            transcription: TranscriptionOptions(voiceActivityDetection: .disabled),
            commitment: .localAgreement(iterations: 2),
            strategy: .balanced,
            implementation: .emulated,
            emulation: EmulatedStreamingOptions(
                window: .contextualRollingBuffer(maxDuration: 10.0, updateInterval: 1.0, finalSilenceDelay: 1.0)
            )
        )
        let callCounter = SpeechChunkStreamingPipelineCallCounter()
        let stableText = "Merz said Washington quite obviously went into this war without any strategy"
        let replayText = "Mersut said Washington quite obviously went into this war without any strategy"

        var events: [TranscriptEvent] = []
        let stream = SpeechChunkStreamingPipeline.stream(
            audio: audio,
            backend: backend,
            options: options,
            transcribeTimed: { chunk, _ in
                let callIndex = await callCounter.next()
                let text: String
                if chunk.isFinal {
                    text = ""
                } else {
                    text = callIndex <= 2 ? stableText : replayText
                }
                return Transcript(segments: text.isEmpty ? [] : [
                    TranscriptSegment(text: text, startTime: 0, endTime: chunk.audio.duration)
                ])
            }
        )

        for try await event in stream {
            events.append(event)
        }

        XCTAssertTrue(events.contains { event in
            if case .diagnostic(let diagnostic) = event {
                return diagnostic.message.contains("hypothesis_rejected=stale_replay")
                    && diagnostic.message.contains("frontier_idle=")
            }
            return false
        })
        XCTAssertFalse(events.contains { event in
            if case .snapshot(let snapshot) = event {
                return snapshot.volatile?.text.contains("Mersut said Washington") ?? false
            }
            return false
        })
        XCTAssertTrue(events.contains { event in
            if case .completed(let transcript) = event {
                return transcript.text == stableText
            }
            return false
        })
    }

    func testSpeechChunkStreamingPipelineKeepsNoVADIdleCandidateWithNewSuffix() async throws {
        let audio = AsyncThrowingStream<AudioChunk, Error> { continuation in
            Task {
                for index in 0..<6 {
                    continuation.yield(AudioChunk(
                        samples: Array(repeating: index < 4 ? 0.05 : 0, count: 8_000),
                        sampleRate: 16_000,
                        channelCount: 1,
                        startTime: TimeInterval(index) * 0.5,
                        duration: 0.5
                    ))
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                continuation.finish()
            }
        }
        let backend = SpeechBackendDescriptor(kind: .mock, displayName: "Mock")
        let options = StreamingTranscriptionOptions(
            transcription: TranscriptionOptions(voiceActivityDetection: .disabled),
            commitment: .localAgreement(iterations: 2),
            strategy: .balanced,
            implementation: .emulated,
            emulation: EmulatedStreamingOptions(
                window: .contextualRollingBuffer(maxDuration: 10.0, updateInterval: 1.0, finalSilenceDelay: 1.0)
            )
        )
        let callCounter = SpeechChunkStreamingPipelineCallCounter()
        let stableText = "Merz said Washington quite obviously went into this war"
        let extendedText = "Merz said Washington quite obviously went into this war without any strategy and had new detail"

        var events: [TranscriptEvent] = []
        let stream = SpeechChunkStreamingPipeline.stream(
            audio: audio,
            backend: backend,
            options: options,
            transcribeTimed: { chunk, _ in
                let callIndex = await callCounter.next()
                let text: String
                if chunk.isFinal {
                    text = ""
                } else {
                    text = callIndex <= 2 ? stableText : extendedText
                }
                return Transcript(segments: text.isEmpty ? [] : [
                    TranscriptSegment(text: text, startTime: 0, endTime: chunk.audio.duration)
                ])
            }
        )

        for try await event in stream {
            events.append(event)
        }

        XCTAssertFalse(events.contains { event in
            if case .diagnostic(let diagnostic) = event {
                return diagnostic.message.contains("hypothesis_rejected=stale_replay")
            }
            return false
        })
        XCTAssertTrue(events.contains { event in
            if case .snapshot(let snapshot) = event {
                return snapshot.volatile?.text.contains("without any strategy and had new detail") ?? false
            }
            return false
        })
    }

    func testSpeechChunkStreamingPipelineDoesNotRejectNoVADLowEnergyUnrelatedCandidate() async throws {
        let audio = AsyncThrowingStream<AudioChunk, Error> { continuation in
            Task {
                for index in 0..<6 {
                    continuation.yield(AudioChunk(
                        samples: Array(repeating: index < 4 ? 0.05 : 0, count: 8_000),
                        sampleRate: 16_000,
                        channelCount: 1,
                        startTime: TimeInterval(index) * 0.5,
                        duration: 0.5
                    ))
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                continuation.finish()
            }
        }
        let backend = SpeechBackendDescriptor(kind: .mock, displayName: "Mock")
        let options = StreamingTranscriptionOptions(
            transcription: TranscriptionOptions(voiceActivityDetection: .disabled),
            commitment: .localAgreement(iterations: 2),
            strategy: .balanced,
            implementation: .emulated,
            emulation: EmulatedStreamingOptions(
                window: .contextualRollingBuffer(maxDuration: 10.0, updateInterval: 1.0, finalSilenceDelay: 1.0)
            )
        )
        let callCounter = SpeechChunkStreamingPipelineCallCounter()
        let stableText = "alpha beta gamma delta epsilon zeta eta theta"
        let unrelatedText = "completely different words arrive now with fresh material"

        var events: [TranscriptEvent] = []
        let stream = SpeechChunkStreamingPipeline.stream(
            audio: audio,
            backend: backend,
            options: options,
            transcribeTimed: { chunk, _ in
                let callIndex = await callCounter.next()
                let text: String
                if chunk.isFinal {
                    text = ""
                } else {
                    text = callIndex <= 2 ? stableText : unrelatedText
                }
                return Transcript(segments: text.isEmpty ? [] : [
                    TranscriptSegment(text: text, startTime: 0, endTime: chunk.audio.duration)
                ])
            }
        )

        for try await event in stream {
            events.append(event)
        }

        XCTAssertFalse(events.contains { event in
            if case .diagnostic(let diagnostic) = event {
                return diagnostic.message.contains("hypothesis_rejected=stale_replay")
            }
            return false
        })
        XCTAssertTrue(events.contains { event in
            if case .snapshot(let snapshot) = event {
                return snapshot.volatile?.text.contains(unrelatedText) ?? false
            }
            return false
        })
    }

    func testSpeechChunkStreamingPipelineContextualFinalRequiresAgreementBeforeCommittingTail() async throws {
        let audio = AsyncThrowingStream<AudioChunk, Error> { continuation in
            Task {
                for index in 0..<2 {
                    continuation.yield(AudioChunk(
                        samples: Array(repeating: 0.05, count: 8_000),
                        sampleRate: 16_000,
                        channelCount: 1,
                        startTime: TimeInterval(index) * 0.5,
                        duration: 0.5
                    ))
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                continuation.finish()
            }
        }
        let backend = SpeechBackendDescriptor(kind: .mock, displayName: "Mock")
        let options = StreamingTranscriptionOptions(
            transcription: TranscriptionOptions(voiceActivityDetection: .disabled),
            commitment: .localAgreement(iterations: 2),
            strategy: .balanced,
            implementation: .emulated,
            emulation: EmulatedStreamingOptions(
                window: .contextualRollingBuffer(maxDuration: 10.0, updateInterval: 0.5, finalSilenceDelay: 1.0)
            )
        )
        let callCounter = SpeechChunkStreamingPipelineCallCounter()

        var events: [TranscriptEvent] = []
        let stream = SpeechChunkStreamingPipeline.stream(
            audio: audio,
            backend: backend,
            options: options,
            transcribeTimed: { _, _ in
                let callIndex = await callCounter.next()
                let text: String
                switch callIndex {
                case 1:
                    text = "Consumption of alcoholic beverages impairs your ability to drive a car"
                case 2:
                    text = "Consumption of alcoholic beverages impairs your ability to drive a car or operate machinery"
                default:
                    text = "Consumption of alcoholic beverages impairs your ability to drive a car or operate machinery. When you are in a car, you may have to take a car to the hospital."
                }
                return Transcript(segments: [
                    TranscriptSegment(text: text, startTime: 0, endTime: 1)
                ])
            }
        )

        for try await event in stream {
            events.append(event)
        }

        let completedText = events.compactMap { event -> String? in
            if case .completed(let transcript) = event {
                return transcript.text
            }
            return nil
        }.last ?? ""

        XCTAssertEqual(
            completedText,
            "Consumption of alcoholic beverages impairs your ability to drive a car or operate machinery."
        )
        XCTAssertFalse(completedText.contains("hospital"))
    }

    func testSpeechChunkStreamingPipelineContextualWordAlignmentDoesNotDuplicateCommittedReplay() async throws {
        let audio = contextualTestAudio(chunkCount: 4)
        let backend = SpeechBackendDescriptor(kind: .mock, displayName: "Mock")
        let options = StreamingTranscriptionOptions(
            transcription: TranscriptionOptions(timestampMode: .words, voiceActivityDetection: .disabled),
            commitment: .localAgreement(iterations: 2),
            strategy: .balanced,
            implementation: .emulated,
            emulation: EmulatedStreamingOptions(
                window: .contextualRollingBuffer(maxDuration: 10.0, updateInterval: 0.5, finalSilenceDelay: 1.0)
            )
        )
        let callCounter = SpeechChunkStreamingPipelineCallCounter()

        var events: [TranscriptEvent] = []
        let stream = SpeechChunkStreamingPipeline.stream(
            audio: audio,
            backend: backend,
            options: options,
            transcribeTimedResult: { _, _ in
                let callIndex = await callCounter.next()
                let text: String
                switch callIndex {
                case 1:
                    text = "alpha beta gamma"
                case 2:
                    text = "alpha beta gamma delta epsilon"
                default:
                    text = "alpha beta gamma delta epsilon zeta"
                }
                return timedWordResult(text, step: 0.20)
            }
        )

        for try await event in stream {
            events.append(event)
        }

        let completedText = completedTranscriptText(in: events)
        XCTAssertFalse(hasRepeatedNormalizedNGram(completedText, size: 4))
        XCTAssertEqual(completedText, "alpha beta gamma delta epsilon zeta")
        XCTAssertTrue(events.contains { event in
            if case .diagnostic(let diagnostic) = event {
                return diagnostic.message == "alignment=words"
            }
            return false
        })
    }

    func testSpeechChunkStreamingPipelineContextualWordAlignmentMatchesBackendCompoundSplit() async throws {
        let audio = contextualTestAudio(chunkCount: 3)
        let backend = SpeechBackendDescriptor(kind: .mock, displayName: "Mock")
        let options = StreamingTranscriptionOptions(
            transcription: TranscriptionOptions(timestampMode: .words, voiceActivityDetection: .disabled),
            commitment: .localAgreement(iterations: 2),
            strategy: .balanced,
            implementation: .emulated,
            emulation: EmulatedStreamingOptions(
                window: .contextualRollingBuffer(maxDuration: 10.0, updateInterval: 0.5, finalSilenceDelay: 1.0)
            )
        )
        let callCounter = SpeechChunkStreamingPipelineCallCounter()

        var events: [TranscriptEvent] = []
        let stream = SpeechChunkStreamingPipeline.stream(
            audio: audio,
            backend: backend,
            options: options,
            transcribeTimedResult: { _, _ in
                let callIndex = await callCounter.next()
                switch callIndex {
                case 1:
                    return timedWordResult("users call backend", step: 0.20)
                default:
                    return timedWordResult("users call back end API", step: 0.20)
                }
            }
        )

        for try await event in stream {
            events.append(event)
        }

        XCTAssertEqual(completedTranscriptText(in: events), "users call back end API")
    }

    func testSpeechChunkStreamingPipelineContextualWordAlignmentDropsChangedTextBeforeFrontier() async throws {
        let audio = contextualTestAudio(chunkCount: 4)
        let backend = SpeechBackendDescriptor(kind: .mock, displayName: "Mock")
        let options = StreamingTranscriptionOptions(
            transcription: TranscriptionOptions(timestampMode: .words, voiceActivityDetection: .disabled),
            commitment: .localAgreement(iterations: 2),
            strategy: .balanced,
            implementation: .emulated,
            emulation: EmulatedStreamingOptions(
                window: .contextualRollingBuffer(maxDuration: 10.0, updateInterval: 0.5, finalSilenceDelay: 1.0)
            )
        )
        let callCounter = SpeechChunkStreamingPipelineCallCounter()

        var events: [TranscriptEvent] = []
        let stream = SpeechChunkStreamingPipeline.stream(
            audio: audio,
            backend: backend,
            options: options,
            transcribeTimedResult: { _, _ in
                let callIndex = await callCounter.next()
                switch callIndex {
                case 1:
                    return timedWordResult("alpha beta gamma delta", step: 0.20)
                case 2:
                    return timedWordResult("alpha beta gamma delta epsilon", step: 0.20)
                default:
                    return timedWordResult([
                        ("wrong", 0.00, 0.10),
                        ("old", 0.10, 0.20),
                        ("words", 0.20, 0.30),
                        ("epsilon", 0.80, 1.00),
                        ("zeta", 1.00, 1.20)
                    ])
                }
            }
        )

        for try await event in stream {
            events.append(event)
        }

        let completedText = completedTranscriptText(in: events)
        XCTAssertEqual(completedText, "alpha beta gamma delta epsilon zeta")
        XCTAssertFalse(completedText.contains("wrong old words"))
        XCTAssertTrue(events.contains { event in
            if case .diagnostic(let diagnostic) = event {
                return diagnostic.message.contains("frontier_drop=3")
            }
            return false
        })
    }

    func testSpeechChunkStreamingPipelineContextualWordAlignmentFinalFlushCommitsOnlyPendingAfterFrontier() async throws {
        let audio = contextualTestAudio(chunkCount: 3)
        let backend = SpeechBackendDescriptor(kind: .mock, displayName: "Mock")
        let options = StreamingTranscriptionOptions(
            transcription: TranscriptionOptions(timestampMode: .words, voiceActivityDetection: .disabled),
            commitment: .localAgreement(iterations: 2),
            strategy: .balanced,
            implementation: .emulated,
            emulation: EmulatedStreamingOptions(
                window: .contextualRollingBuffer(maxDuration: 10.0, updateInterval: 0.5, finalSilenceDelay: 1.0)
            )
        )
        let callCounter = SpeechChunkStreamingPipelineCallCounter()

        var events: [TranscriptEvent] = []
        let stream = SpeechChunkStreamingPipeline.stream(
            audio: audio,
            backend: backend,
            options: options,
            transcribeTimedResult: { chunk, _ in
                let callIndex = await callCounter.next()
                switch callIndex {
                case 1:
                    return timedWordResult("drive a car", step: 0.20)
                case 2:
                    return timedWordResult("drive a car or operate machinery", step: 0.20)
                default:
                    let text = chunk.isFinal
                        ? "drive a car or operate machinery hospital hallucination"
                        : "drive a car or operate machinery"
                    return timedWordResult(text, step: 0.20)
                }
            }
        )

        for try await event in stream {
            events.append(event)
        }

        let completedText = completedTranscriptText(in: events)
        XCTAssertEqual(completedText, "drive a car or operate machinery")
        XCTAssertFalse(completedText.contains("hospital"))
        XCTAssertFalse(completedText.contains("hallucination"))
    }

    func testSpeechChunkStreamingPipelineContextualWordAlignmentSilenceFlushClosesTailOnce() async throws {
        let audio = AsyncThrowingStream<AudioChunk, Error> { continuation in
            Task {
                for index in 0..<3 {
                    continuation.yield(AudioChunk(
                        samples: Array(repeating: index == 2 ? 0 : 0.05, count: 8_000),
                        sampleRate: 16_000,
                        channelCount: 1,
                        startTime: TimeInterval(index) * 0.5,
                        duration: 0.5
                    ))
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                continuation.finish()
            }
        }
        let backend = SpeechBackendDescriptor(kind: .mock, displayName: "Mock")
        let options = StreamingTranscriptionOptions(
            transcription: TranscriptionOptions(timestampMode: .words, voiceActivityDetection: .enabled),
            commitment: .localAgreement(iterations: 2),
            strategy: .balanced,
            implementation: .emulated,
            emulation: EmulatedStreamingOptions(
                window: .contextualRollingBuffer(maxDuration: 10.0, updateInterval: 0.5, finalSilenceDelay: 0.5)
            )
        )
        let detector = SequenceVoiceActivityDetector(states: [.speech, .speech, .silence])
        let callCounter = SpeechChunkStreamingPipelineCallCounter()

        var events: [TranscriptEvent] = []
        let stream = SpeechChunkStreamingPipeline.stream(
            audio: audio,
            backend: backend,
            options: options,
            transcribeTimedResult: { _, _ in
                let callIndex = await callCounter.next()
                switch callIndex {
                case 1:
                    return timedWordResult("alpha beta", step: 0.50)
                case 2:
                    return timedWordResult("alpha beta gamma", step: 0.50)
                default:
                    return timedWordResult([
                        ("gamma", 1.00, 1.50),
                        ("delta", 1.50, 2.00)
                    ])
                }
            },
            voiceActivityDetector: detector
        )

        for try await event in stream {
            events.append(event)
        }

        XCTAssertEqual(completedTranscriptText(in: events), "alpha beta gamma delta")
        XCTAssertFalse(events.contains { event in
            if case .snapshot(let snapshot) = event {
                return snapshot.transcript.text.contains("gamma gamma")
                    || snapshot.transcript.text.contains("delta delta")
            }
            return false
        })
    }

    func testSpeechChunkStreamingPipelineContextualInternalWordsDoNotLeakForSegmentTimestampMode() async throws {
        let audio = contextualTestAudio(chunkCount: 3)
        let backend = SpeechBackendDescriptor(kind: .mock, displayName: "Mock")
        let options = StreamingTranscriptionOptions(
            transcription: TranscriptionOptions(timestampMode: .segments, voiceActivityDetection: .disabled),
            commitment: .localAgreement(iterations: 2),
            strategy: .balanced,
            implementation: .emulated,
            emulation: EmulatedStreamingOptions(
                window: .contextualRollingBuffer(maxDuration: 10.0, updateInterval: 0.5, finalSilenceDelay: 1.0)
            )
        )
        let callCounter = SpeechChunkStreamingPipelineCallCounter()

        var events: [TranscriptEvent] = []
        let stream = SpeechChunkStreamingPipeline.stream(
            audio: audio,
            backend: backend,
            options: options,
            transcribeTimedResult: { _, _ in
                let callIndex = await callCounter.next()
                let text = callIndex == 1 ? "stable alpha" : "stable alpha beta"
                return timedWordResult(text, step: 0.20)
            }
        )

        for try await event in stream {
            events.append(event)
        }

        for event in events {
            switch event {
            case .snapshot(let snapshot):
                XCTAssertTrue(snapshot.stable.segments.allSatisfy { $0.words.isEmpty })
                XCTAssertTrue(snapshot.volatile?.segments.allSatisfy { $0.words.isEmpty } ?? true)
            case .completed(let transcript):
                XCTAssertTrue(transcript.segments.allSatisfy { $0.words.isEmpty })
            default:
                continue
            }
        }
    }

    func testSpeechChunkStreamingPipelineContextualWordAlignmentDoesNotUsePublicWordsAsAlignmentMetadata() async throws {
        let audio = contextualTestAudio(chunkCount: 3)
        let backend = SpeechBackendDescriptor(kind: .mock, displayName: "Mock")
        let options = StreamingTranscriptionOptions(
            transcription: TranscriptionOptions(timestampMode: .words, voiceActivityDetection: .disabled),
            commitment: .localAgreement(iterations: 2),
            strategy: .balanced,
            implementation: .emulated,
            emulation: EmulatedStreamingOptions(
                window: .contextualRollingBuffer(maxDuration: 10.0, updateInterval: 0.5, finalSilenceDelay: 1.0)
            )
        )
        let callCounter = SpeechChunkStreamingPipelineCallCounter()

        var events: [TranscriptEvent] = []
        let stream = SpeechChunkStreamingPipeline.stream(
            audio: audio,
            backend: backend,
            options: options,
            transcribeTimedResult: { _, _ in
                let callIndex = await callCounter.next()
                let text = callIndex == 1 ? "stable alpha" : "stable alpha beta"
                let transcript = Transcript(segments: [
                    TranscriptSegment(
                        text: text,
                        startTime: 0,
                        endTime: 0.4,
                        words: [
                            TranscriptWord(text: "stable", startTime: 0.0, endTime: 0.2),
                            TranscriptWord(text: "alpha", startTime: 0.2, endTime: 0.4)
                        ]
                    )
                ])
                return SpeechChunkStreamingPipeline.StreamingChunkTranscriptionResult(
                    transcript: transcript,
                    alignmentWords: []
                )
            }
        )

        for try await event in stream {
            events.append(event)
        }

        XCTAssertTrue(events.contains { event in
            if case .diagnostic(let diagnostic) = event {
                return diagnostic.message == "alignment=text-fallback"
            }
            return false
        })
        XCTAssertFalse(events.contains { event in
            if case .diagnostic(let diagnostic) = event {
                return diagnostic.message == "alignment=words"
            }
            return false
        })
    }

    func testSpeechChunkStreamingPipelineContextualWordAlignmentTrimsCommittedStableSuffixFromVolatile() async throws {
        let audio = contextualTestAudio(chunkCount: 4)
        let backend = SpeechBackendDescriptor(kind: .mock, displayName: "Mock")
        let options = StreamingTranscriptionOptions(
            transcription: TranscriptionOptions(timestampMode: .words, voiceActivityDetection: .disabled),
            commitment: .localAgreement(iterations: 2),
            strategy: .balanced,
            implementation: .emulated,
            emulation: EmulatedStreamingOptions(
                window: .contextualRollingBuffer(maxDuration: 10.0, updateInterval: 0.5, finalSilenceDelay: 1.0)
            )
        )
        let callCounter = SpeechChunkStreamingPipelineCallCounter()

        var events: [TranscriptEvent] = []
        let stream = SpeechChunkStreamingPipeline.stream(
            audio: audio,
            backend: backend,
            options: options,
            transcribeTimedResult: { _, _ in
                let callIndex = await callCounter.next()
                switch callIndex {
                case 1, 2:
                    return textOnlyResult("alpha beta")
                default:
                    return timedWordResult("alpha beta gamma delta", step: 0.20)
                }
            }
        )

        for try await event in stream {
            events.append(event)
        }

        let volatileTranscripts = events.compactMap { event -> Transcript? in
            if case .snapshot(let snapshot) = event {
                return snapshot.volatile
            }
            return nil
        }
        XCTAssertTrue(volatileTranscripts.contains { $0.text == "gamma delta" })
        XCTAssertFalse(volatileTranscripts.contains { $0.text == "alpha beta gamma delta" })
        XCTAssertEqual(
            volatileTranscripts.first { $0.text == "gamma delta" }?.segments.first?.words.map(\.text),
            ["gamma", "delta"]
        )
        XCTAssertTrue(events.contains { event in
            if case .diagnostic(let diagnostic) = event {
                return diagnostic.message == "volatile_trim=2"
            }
            return false
        })
    }

    func testSpeechChunkStreamingPipelineContextualWordAlignmentFiltersWhisperSpecialMarkersFromText() async throws {
        let audio = contextualTestAudio(chunkCount: 3)
        let backend = SpeechBackendDescriptor(kind: .mock, displayName: "Mock")
        let options = StreamingTranscriptionOptions(
            transcription: TranscriptionOptions(timestampMode: .segments, voiceActivityDetection: .disabled),
            commitment: .localAgreement(iterations: 2),
            strategy: .balanced,
            implementation: .emulated,
            emulation: EmulatedStreamingOptions(
                window: .contextualRollingBuffer(maxDuration: 10.0, updateInterval: 0.5, finalSilenceDelay: 1.0)
            )
        )
        let callCounter = SpeechChunkStreamingPipelineCallCounter()

        var events: [TranscriptEvent] = []
        let stream = SpeechChunkStreamingPipeline.stream(
            audio: audio,
            backend: backend,
            options: options,
            transcribeTimedResult: { _, _ in
                let callIndex = await callCounter.next()
                let words: [(text: String, startTime: TimeInterval, endTime: TimeInterval)]
                switch callIndex {
                case 1:
                    words = [
                        ("[_BEG_]", 0.00, 0.00),
                        ("What", 0.00, 0.10),
                        ("if", 0.10, 0.20),
                        ("there", 0.20, 0.30),
                        ("'s", 0.30, 0.40),
                        ("no", 0.40, 0.50),
                        ("bubbles", 0.50, 0.60),
                        ("[_TT_50]", 0.60, 0.60)
                    ]
                default:
                    words = [
                        ("[_BEG_]", 0.00, 0.00),
                        ("What", 0.00, 0.10),
                        ("if", 0.10, 0.20),
                        ("there", 0.20, 0.30),
                        ("'s", 0.30, 0.40),
                        ("no", 0.40, 0.50),
                        ("bubbles", 0.50, 0.60),
                        ("in", 0.60, 0.70),
                        ("water", 0.70, 0.80),
                        ("you", 0.80, 0.90),
                        ("'re", 0.90, 1.00),
                        ("done", 1.00, 1.10),
                        ("[_TT_110]", 1.10, 1.10)
                    ]
                }
                return timedWordResult(words)
            }
        )

        for try await event in stream {
            events.append(event)
        }

        let completedText = completedTranscriptText(in: events)
        XCTAssertEqual(completedText, "What if there's no bubbles in water you're done")
        XCTAssertFalse(completedText.contains("[_"))
        XCTAssertFalse(completedText.contains("_]"))

        for event in events {
            if case .snapshot(let snapshot) = event {
                XCTAssertFalse(snapshot.transcript.text.contains("[_"))
                XCTAssertFalse(snapshot.volatile?.text.contains("[_") ?? false)
            }
        }
    }

    func testSpeechChunkStreamingPipelineContextualWordAlignmentCommitsExpiredPrefixAfterWindowShift() async throws {
        let audio = contextualTestAudio(chunkCount: 6)
        let backend = SpeechBackendDescriptor(kind: .mock, displayName: "Mock")
        let options = StreamingTranscriptionOptions(
            transcription: TranscriptionOptions(timestampMode: .words, voiceActivityDetection: .disabled),
            commitment: .localAgreement(iterations: 2),
            strategy: .balanced,
            implementation: .emulated,
            emulation: EmulatedStreamingOptions(
                window: .contextualRollingBuffer(maxDuration: 10.0, updateInterval: 0.5, finalSilenceDelay: 1.0)
            )
        )
        let callCounter = SpeechChunkStreamingPipelineCallCounter()

        var events: [TranscriptEvent] = []
        let stream = SpeechChunkStreamingPipeline.stream(
            audio: audio,
            backend: backend,
            options: options,
            transcribeTimedResult: { _, _ in
                let callIndex = await callCounter.next()
                switch callIndex {
                case 1:
                    return timedWordResult("alpha beta", step: 0.20)
                case 2:
                    return timedWordResult("alpha beta one two three four", step: 0.20)
                case 3:
                    return timedWordResult("three four five six", step: 0.20)
                default:
                    return timedWordResult("five six seven eight", step: 0.20)
                }
            }
        )

        for try await event in stream {
            events.append(event)
        }

        XCTAssertEqual(
            completedTranscriptText(in: events),
            "alpha beta one two three four five six"
        )
    }

    func testSpeechChunkStreamingPipelineContextualSparklingWaterRegressionHasNoRepeatedStableNGrams() async throws {
        let audio = contextualTestAudio(chunkCount: 5)
        let backend = SpeechBackendDescriptor(kind: .mock, displayName: "Mock")
        let options = StreamingTranscriptionOptions(
            transcription: TranscriptionOptions(timestampMode: .words, voiceActivityDetection: .disabled),
            commitment: .localAgreement(iterations: 2),
            strategy: .balanced,
            implementation: .emulated,
            emulation: EmulatedStreamingOptions(
                window: .contextualRollingBuffer(maxDuration: 20.0, updateInterval: 0.5, finalSilenceDelay: 1.0)
            )
        )
        let callCounter = SpeechChunkStreamingPipelineCallCounter()

        var events: [TranscriptEvent] = []
        let stream = SpeechChunkStreamingPipeline.stream(
            audio: audio,
            backend: backend,
            options: options,
            transcribeTimedResult: { _, _ in
                let callIndex = await callCounter.next()
                switch callIndex {
                case 1:
                    return timedWordResult("users will call the backend", step: 0.20)
                case 2:
                    return timedWordResult("users will call the back end to order food", step: 0.20)
                case 3:
                    return timedWordResult([
                        ("users", 0.00, 0.20),
                        ("will", 0.20, 0.40),
                        ("call", 0.40, 0.60),
                        ("the", 0.60, 0.80),
                        ("API", 0.80, 1.00),
                        ("to", 1.00, 1.20),
                        ("order", 1.20, 1.40),
                        ("food", 1.40, 1.60),
                        ("okay", 1.60, 1.80),
                        ("if", 1.80, 2.00),
                        ("you", 2.00, 2.20),
                        ("really", 2.20, 2.40),
                        ("think", 2.40, 2.60)
                    ])
                default:
                    return timedWordResult([
                        ("users", 0.00, 0.20),
                        ("will", 0.20, 0.40),
                        ("call", 0.40, 0.60),
                        ("the", 0.60, 0.80),
                        ("API", 0.80, 1.00),
                        ("to", 1.00, 1.20),
                        ("order", 1.20, 1.40),
                        ("food", 1.40, 1.60),
                        ("okay", 1.60, 1.80),
                        ("if", 1.80, 2.00),
                        ("you", 2.00, 2.20),
                        ("really", 2.20, 2.40),
                        ("think", 2.40, 2.60),
                        ("we", 2.60, 2.80),
                        ("have", 2.80, 3.00),
                        ("to", 3.00, 3.20),
                        ("build", 3.20, 3.40),
                        ("a", 3.40, 3.60),
                        ("frontend", 3.60, 3.80)
                    ])
                }
            }
        )

        for try await event in stream {
            events.append(event)
        }

        let completedText = completedTranscriptText(in: events)
        XCTAssertFalse(hasRepeatedNormalizedNGram(completedText, size: 4), completedText)
        XCTAssertFalse(events.contains { event in
            if case .snapshot(let snapshot) = event,
               !snapshot.stable.text.isEmpty,
               let volatileText = snapshot.volatile?.text {
                return volatileText.hasPrefix(snapshot.stable.text)
            }
            return false
        })
    }

    func testSpeechChunkStreamingPipelineContextualFlushesPendingTailWhenFinalRegresses() async throws {
        let audio = AsyncThrowingStream<AudioChunk, Error> { continuation in
            Task {
                for index in 0..<3 {
                    continuation.yield(AudioChunk(
                        samples: Array(repeating: 0.05, count: 8_000),
                        sampleRate: 16_000,
                        channelCount: 1,
                        startTime: TimeInterval(index) * 0.5,
                        duration: 0.5
                    ))
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                continuation.finish()
            }
        }
        let backend = SpeechBackendDescriptor(kind: .mock, displayName: "Mock")
        let options = StreamingTranscriptionOptions(
            transcription: TranscriptionOptions(voiceActivityDetection: .disabled),
            commitment: .localAgreement(iterations: 2),
            strategy: .balanced,
            implementation: .emulated,
            emulation: EmulatedStreamingOptions(
                window: .contextualRollingBuffer(maxDuration: 10.0, updateInterval: 0.5, finalSilenceDelay: 1.0)
            )
        )
        let callCounter = SpeechChunkStreamingPipelineCallCounter()

        var events: [TranscriptEvent] = []
        let stream = SpeechChunkStreamingPipeline.stream(
            audio: audio,
            backend: backend,
            options: options,
            transcribeTimed: { _, _ in
                let callIndex = await callCounter.next()
                let text: String
                switch callIndex {
                case 1:
                    text = "Consumption of alcoholic beverages impairs your ability to"
                case 2:
                    text = "Consumption of alcoholic beverages impairs your ability to drive a car or to operate machinery and may cause"
                default:
                    text = "Consumption of alcoholic beverages impairs your ability to"
                }
                return Transcript(segments: [
                    TranscriptSegment(text: text, startTime: 0, endTime: 1)
                ])
            }
        )

        for try await event in stream {
            events.append(event)
        }

        let completedText = events.compactMap { event -> String? in
            if case .completed(let transcript) = event {
                return transcript.text
            }
            return nil
        }.last ?? ""

        XCTAssertEqual(
            completedText,
            "Consumption of alcoholic beverages impairs your ability to drive a car or to operate machinery and may cause"
        )
    }

    func testSpeechChunkStreamingPipelineContextualFlushesPendingTailOnSustainedVADSilence() async throws {
        let audio = AsyncThrowingStream<AudioChunk, Error> { continuation in
            Task {
                for index in 0..<3 {
                    continuation.yield(AudioChunk(
                        samples: Array(repeating: index == 2 ? 0 : 0.05, count: 8_000),
                        sampleRate: 16_000,
                        channelCount: 1,
                        startTime: TimeInterval(index) * 0.5,
                        duration: 0.5
                    ))
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                continuation.finish()
            }
        }
        let backend = SpeechBackendDescriptor(kind: .mock, displayName: "Mock")
        let options = StreamingTranscriptionOptions(
            transcription: TranscriptionOptions(voiceActivityDetection: .enabled),
            commitment: .localAgreement(iterations: 2),
            strategy: .balanced,
            implementation: .emulated,
            emulation: EmulatedStreamingOptions(
                window: .contextualRollingBuffer(maxDuration: 10.0, updateInterval: 0.5, finalSilenceDelay: 0.5)
            )
        )
        let detector = SequenceVoiceActivityDetector(states: [.speech, .speech, .silence])
        let callCounter = SpeechChunkStreamingPipelineCallCounter()

        var events: [TranscriptEvent] = []
        let stream = SpeechChunkStreamingPipeline.stream(
            audio: audio,
            backend: backend,
            options: options,
            transcribeTimed: { _, _ in
                let callIndex = await callCounter.next()
                let text: String
                switch callIndex {
                case 1:
                    text = "Friedrich Murs said the U.S."
                default:
                    text = "Friedrich Murs said the U.S.-Israel war on the regime in Iran hurts growth"
                }
                return Transcript(segments: [
                    TranscriptSegment(text: text, startTime: 0, endTime: 1)
                ])
            },
            voiceActivityDetector: detector
        )

        for try await event in stream {
            events.append(event)
        }

        XCTAssertTrue(events.contains { event in
            if case .diagnostic(let diagnostic) = event {
                return diagnostic.message.hasPrefix("contextual_silence_flush=")
            }
            return false
        })
        XCTAssertTrue(events.contains { event in
            if case .snapshot(let snapshot) = event {
                return snapshot.stable.text.contains("Israel war on the regime in Iran hurts growth")
                    && (snapshot.volatile?.text.isEmpty ?? true)
            }
            return false
        })
    }

    func testSpeechChunkStreamingPipelineContextualSilenceFlushTrimsCommittedReplayBeforeStableCommit() async throws {
        let audio = AsyncThrowingStream<AudioChunk, Error> { continuation in
            Task {
                for index in 0..<3 {
                    continuation.yield(AudioChunk(
                        samples: Array(repeating: index == 2 ? 0 : 0.05, count: 8_000),
                        sampleRate: 16_000,
                        channelCount: 1,
                        startTime: TimeInterval(index) * 0.5,
                        duration: 0.5
                    ))
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                continuation.finish()
            }
        }
        let backend = SpeechBackendDescriptor(kind: .mock, displayName: "Mock")
        let options = StreamingTranscriptionOptions(
            transcription: TranscriptionOptions(voiceActivityDetection: .enabled),
            commitment: .localAgreement(iterations: 2),
            strategy: .balanced,
            implementation: .emulated,
            emulation: EmulatedStreamingOptions(
                window: .contextualRollingBuffer(maxDuration: 10.0, updateInterval: 0.5, finalSilenceDelay: 0.5)
            )
        )
        let detector = SequenceVoiceActivityDetector(states: [.speech, .speech, .silence])
        let callCounter = SpeechChunkStreamingPipelineCallCounter()
        let intro = "It comes as the world is grappling with its biggest energy crisis in decades"
        let frontier = "triggered by the US-Israeli war against Iran and the Islamic Republic's closure of the Strait of Hormuz, through which about a"
        let replayTail = "U.S.-Israeli war against Iran and the Islamic Republic's closure of the Strait of Hormuz, through which about a fifth of the world's oil normally passes."

        var events: [TranscriptEvent] = []
        let stream = SpeechChunkStreamingPipeline.stream(
            audio: audio,
            backend: backend,
            options: options,
            transcribeTimed: { _, _ in
                let callIndex = await callCounter.next()
                let text: String
                switch callIndex {
                case 1:
                    text = intro
                case 2:
                    text = "\(intro), \(frontier)"
                default:
                    text = "\(frontier) \(replayTail)"
                }
                return Transcript(segments: [
                    TranscriptSegment(text: text, startTime: 0, endTime: 1)
                ])
            },
            voiceActivityDetector: detector
        )

        for try await event in stream {
            events.append(event)
        }

        let completedText = events.compactMap { event -> String? in
            if case .completed(let transcript) = event {
                return transcript.text
            }
            return nil
        }.last ?? ""

        XCTAssertEqual(
            completedText,
            "\(intro), \(frontier) fifth of the world's oil normally passes."
        )
        XCTAssertFalse(completedText.contains("about a U.S.-Israeli war"))
        XCTAssertTrue(events.contains { event in
            if case .diagnostic(let diagnostic) = event {
                return diagnostic.message.hasPrefix("contextual_silence_flush=")
            }
            return false
        })
    }

    func testSpeechChunkStreamingPipelineContextualSilenceFlushPreservesNewRepeatedTail() async throws {
        let audio = AsyncThrowingStream<AudioChunk, Error> { continuation in
            Task {
                for index in 0..<3 {
                    continuation.yield(AudioChunk(
                        samples: Array(repeating: index == 2 ? 0 : 0.05, count: 8_000),
                        sampleRate: 16_000,
                        channelCount: 1,
                        startTime: TimeInterval(index) * 0.5,
                        duration: 0.5
                    ))
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                continuation.finish()
            }
        }
        let backend = SpeechBackendDescriptor(kind: .mock, displayName: "Mock")
        let options = StreamingTranscriptionOptions(
            transcription: TranscriptionOptions(voiceActivityDetection: .enabled),
            commitment: .localAgreement(iterations: 2),
            strategy: .balanced,
            implementation: .emulated,
            emulation: EmulatedStreamingOptions(
                window: .contextualRollingBuffer(maxDuration: 10.0, updateInterval: 0.5, finalSilenceDelay: 0.5)
            )
        )
        let detector = SequenceVoiceActivityDetector(states: [.speech, .speech, .silence])
        let callCounter = SpeechChunkStreamingPipelineCallCounter()

        var events: [TranscriptEvent] = []
        let stream = SpeechChunkStreamingPipeline.stream(
            audio: audio,
            backend: backend,
            options: options,
            transcribeTimed: { _, _ in
                let callIndex = await callCounter.next()
                let text: String
                switch callIndex {
                case 1:
                    text = "alpha beta"
                case 2:
                    text = "alpha beta gamma"
                default:
                    text = "gamma delta delta tail"
                }
                return Transcript(segments: [
                    TranscriptSegment(text: text, startTime: 0, endTime: 1)
                ])
            },
            voiceActivityDetector: detector
        )

        for try await event in stream {
            events.append(event)
        }

        XCTAssertTrue(events.contains { event in
            if case .completed(let transcript) = event {
                return transcript.text == "alpha beta gamma delta delta tail"
            }
            return false
        })
    }

    func testSpeechChunkStreamingPipelineDoesNotFlushContextualWindowForBriefSmoothedSilence() async throws {
        let audio = AsyncThrowingStream<AudioChunk, Error> { continuation in
            Task {
                for index in 0..<7 {
                    continuation.yield(AudioChunk(
                        samples: Array(repeating: index >= 2 && index <= 4 ? 0 : 0.05, count: 1_600),
                        sampleRate: 16_000,
                        channelCount: 1,
                        startTime: TimeInterval(index) * 0.1,
                        duration: 0.1
                    ))
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
                continuation.finish()
            }
        }
        let backend = SpeechBackendDescriptor(kind: .mock, displayName: "Mock")
        let options = StreamingTranscriptionOptions(
            transcription: TranscriptionOptions(voiceActivityDetection: .enabled),
            commitment: .immediate,
            strategy: .balanced,
            implementation: .emulated,
            emulation: EmulatedStreamingOptions(
                window: .contextualRollingBuffer(maxDuration: 2.0, updateInterval: 0.1, finalSilenceDelay: 0.3)
            )
        )
        let detector = SmoothedVoiceActivityDetector(
            detector: SequenceVoiceActivityDetector(states: [
                .speech,
                .speech,
                .silence,
                .silence,
                .silence,
                .speech,
                .speech
            ]),
            configuration: VoiceActivitySmoothingConfiguration(
                enterSpeechDuration: 0.2,
                exitSpeechDuration: 0.5
            )
        )

        var events: [TranscriptEvent] = []
        let stream = SpeechChunkStreamingPipeline.stream(
            audio: audio,
            backend: backend,
            options: options,
            transcribeTimed: { chunk, _ in
                Transcript(segments: [
                    TranscriptSegment(text: "context", startTime: 0, endTime: chunk.audio.duration)
                ])
            },
            voiceActivityDetector: detector
        )

        for try await event in stream {
            events.append(event)
        }

        XCTAssertFalse(events.contains { event in
            if case .diagnostic(let diagnostic) = event {
                return diagnostic.message.hasPrefix("contextual_silence_flush=")
            }
            return false
        })
        XCTAssertTrue(events.contains { event in
            if case .diagnostic(let diagnostic) = event {
                return diagnostic.message.contains("raw_vad=silence smoothed_vad=speech")
            }
            return false
        })
    }

    func testSpeechChunkStreamingPipelineFlushesEndpointDecodeAfterSustainedSmoothedSilence() async throws {
        let audio = AsyncThrowingStream<AudioChunk, Error> { continuation in
            Task {
                for index in 0..<13 {
                    continuation.yield(AudioChunk(
                        samples: Array(repeating: index < 6 ? 0.05 : 0, count: 100),
                        sampleRate: 1_000,
                        channelCount: 1,
                        startTime: TimeInterval(index) * 0.1,
                        duration: 0.1
                    ))
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
                continuation.finish()
            }
        }
        let backend = SpeechBackendDescriptor(kind: .mock, displayName: "Mock")
        let options = StreamingTranscriptionOptions(
            transcription: TranscriptionOptions(voiceActivityDetection: .enabled),
            commitment: .localAgreement(iterations: 2),
            strategy: .balanced,
            implementation: .emulated,
            emulation: EmulatedStreamingOptions(
                window: .contextualRollingBuffer(maxDuration: 5.0, updateInterval: 0.3, finalSilenceDelay: 0.3)
            )
        )
        let detector = SmoothedVoiceActivityDetector(
            detector: SequenceVoiceActivityDetector(states: [
                .speech,
                .speech,
                .speech,
                .speech,
                .speech,
                .speech,
                .silence,
                .silence,
                .silence,
                .silence,
                .silence,
                .silence,
                .silence
            ]),
            configuration: VoiceActivitySmoothingConfiguration(
                enterSpeechDuration: 0.2,
                exitSpeechDuration: 0.3
            )
        )
        let callCounter = SpeechChunkStreamingPipelineCallCounter()

        var events: [TranscriptEvent] = []
        let stream = SpeechChunkStreamingPipeline.stream(
            audio: audio,
            backend: backend,
            options: options,
            transcribeTimed: { _, _ in
                let callIndex = await callCounter.next()
                let text = callIndex < 4 ? "alpha" : "alpha beta tail"
                return Transcript(segments: [
                    TranscriptSegment(text: text, startTime: 0, endTime: 1)
                ])
            },
            voiceActivityDetector: detector
        )

        for try await event in stream {
            events.append(event)
        }

        let completedText = events.compactMap { event -> String? in
            if case .completed(let transcript) = event {
                return transcript.text
            }
            return nil
        }.last ?? ""
        let transcriptionCallCount = await callCounter.current()

        XCTAssertEqual(transcriptionCallCount, 4)
        XCTAssertEqual(completedText, "alpha beta tail")
        XCTAssertTrue(events.contains { event in
            if case .diagnostic(let diagnostic) = event {
                return diagnostic.message.hasPrefix("contextual_silence_flush=")
            }
            return false
        })
    }

    func testSpeechChunkStreamingPipelinePreservesSilenceFlushWhenDecodeConsumerFallsBehind() async throws {
        let audio = AsyncThrowingStream<AudioChunk, Error> { continuation in
            Task {
                for index in 0..<6 {
                    continuation.yield(AudioChunk(
                        samples: Array(repeating: index == 2 || index == 3 ? 0 : 0.05, count: 100),
                        sampleRate: 1_000,
                        channelCount: 1,
                        startTime: TimeInterval(index) * 0.1,
                        duration: 0.1
                    ))
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }

                try? await Task.sleep(nanoseconds: 200_000_000)
                continuation.finish()
            }
        }
        let backend = SpeechBackendDescriptor(kind: .mock, displayName: "Mock")
        let options = StreamingTranscriptionOptions(
            transcription: TranscriptionOptions(voiceActivityDetection: .enabled),
            commitment: .localAgreement(iterations: 2),
            strategy: .balanced,
            implementation: .emulated,
            emulation: EmulatedStreamingOptions(
                window: .contextualRollingBuffer(maxDuration: 5.0, updateInterval: 0.1, finalSilenceDelay: 0.2)
            )
        )
        let detector = SequenceVoiceActivityDetector(states: [
            .speech,
            .speech,
            .silence,
            .silence,
            .speech,
            .speech
        ])
        let callCounter = SpeechChunkStreamingPipelineCallCounter()

        var events: [TranscriptEvent] = []
        let stream = SpeechChunkStreamingPipeline.stream(
            audio: audio,
            backend: backend,
            options: options,
            transcribeTimed: { chunk, _ in
                let callIndex = await callCounter.next()
                if callIndex == 1 {
                    try await Task.sleep(nanoseconds: 120_000_000)
                    return Transcript(segments: [
                        TranscriptSegment(text: "alpha beta", startTime: 0, endTime: chunk.audio.duration)
                    ])
                }

                let text: String
                if chunk.isFinal {
                    text = ""
                } else if chunk.audio.duration <= 0.45 {
                    text = "alpha beta gamma"
                } else {
                    text = "delta epsilon"
                }
                return Transcript(segments: text.isEmpty ? [] : [
                    TranscriptSegment(text: text, startTime: 0, endTime: chunk.audio.duration)
                ])
            },
            voiceActivityDetector: detector
        )

        for try await event in stream {
            events.append(event)
        }

        let completedText = events.compactMap { event -> String? in
            if case .completed(let transcript) = event {
                return transcript.text
            }
            return nil
        }.last ?? ""

        XCTAssertEqual(completedText, "alpha beta gamma delta epsilon")
    }

    func testSpeechChunkStreamingPipelineTrimsCommittedOverlap() async throws {
        let audio = AsyncThrowingStream<AudioChunk, Error> { continuation in
            continuation.yield(AudioChunk(
                samples: Array(repeating: 0.05, count: 16_000),
                sampleRate: 16_000,
                channelCount: 1,
                startTime: 0,
                duration: 1.0
            ))
            continuation.yield(AudioChunk(
                samples: Array(repeating: 0.05, count: 12_000),
                sampleRate: 16_000,
                channelCount: 1,
                startTime: 1.0,
                duration: 0.75
            ))
            continuation.finish()
        }
        let backend = SpeechBackendDescriptor(kind: .mock, displayName: "Mock")
        let options = StreamingTranscriptionOptions(
            transcription: TranscriptionOptions(useCase: .dictation),
            commitment: .immediate,
            strategy: .lowestLatency,
            emulation: EmulatedStreamingOptions(
                window: .vadUtterances(SpeechChunkingConfiguration(
                    maximumChunkDuration: 1.0,
                    overlapDuration: 0.25,
                    silenceCommitDelay: 2.0,
                    minimumSpeechDuration: 0.01
                ))
            )
        )
        let callCounter = SpeechChunkStreamingPipelineCallCounter()

        var events: [TranscriptEvent] = []
        let stream = SpeechChunkStreamingPipeline.stream(
            audio: audio,
            backend: backend,
            options: options,
            transcribe: { audio, _ in
                if audio.duration < 0.5 {
                    return Transcript()
                }

                let callIndex = await callCounter.next()
                let text = callIndex == 1 ? "apple speech." : "speech provider."
                return Transcript(segments: [
                    TranscriptSegment(text: text, startTime: 0, endTime: audio.duration)
                ])
            })

        for try await event in stream {
            events.append(event)
        }

        let committedText = events.compactMap { event -> String? in
            if case .snapshot(let snapshot) = event {
                return snapshot.stable.text
            }
            return nil
        }.last ?? ""

        XCTAssertEqual(committedText, "apple speech. provider.")
        XCTAssertTrue(events.contains { event in
            if case .completed(let transcript) = event {
                return transcript.text == "apple speech. provider."
            }
            return false
        })
    }

    func testSpeechChunkStreamingPipelineDoesNotCarryVolatileTextIntoLaterPrompts() async throws {
        let audio = AsyncThrowingStream<AudioChunk, Error> { continuation in
            continuation.yield(AudioChunk(
                samples: Array(repeating: 0.05, count: 8_000),
                sampleRate: 16_000,
                channelCount: 1,
                startTime: 0,
                duration: 0.5
            ))
            continuation.yield(AudioChunk(
                samples: Array(repeating: 0.05, count: 8_000),
                sampleRate: 16_000,
                channelCount: 1,
                startTime: 0.5,
                duration: 0.5
            ))
            continuation.finish()
        }
        let backend = SpeechBackendDescriptor(kind: .mock, displayName: "Mock")
        let options = StreamingTranscriptionOptions(
            transcription: TranscriptionOptions(
                useCase: .dictation,
                initialPrompt: "User prompt",
                voiceActivityDetection: .disabled
            ),
            commitment: .localAgreement(iterations: 2),
            strategy: .lowestLatency,
            emulation: EmulatedStreamingOptions(
                window: .rollingBuffer(maxDuration: 4.0, updateInterval: 0.5, overlap: 0)
            )
        )
        let callCounter = SpeechChunkStreamingPipelineCallCounter()
        let promptRecorder = TranscriptionPromptRecorder()

        let stream = SpeechChunkStreamingPipeline.stream(
            audio: audio,
            backend: backend,
            options: options,
            transcribe: { _, options in
                await promptRecorder.record(options)
                let callIndex = await callCounter.next()
                let text = callIndex == 1 ? "wrong provisional" : "correct transcript"
                return Transcript(segments: [
                    TranscriptSegment(text: text, startTime: 0, endTime: 1)
                ])
            })

        for try await _ in stream {}

        let prompts = await promptRecorder.prompts()
        XCTAssertGreaterThanOrEqual(prompts.count, 2)
        XCTAssertEqual(prompts[0], "User prompt")
        XCTAssertEqual(prompts[1], "User prompt")
        XCTAssertFalse(prompts[1]?.contains("wrong provisional") ?? false)
    }

    func testSpeechChunkStreamingPipelineCarriesOnlyStableTextIntoLaterPrompts() async throws {
        let audio = AsyncThrowingStream<AudioChunk, Error> { continuation in
            continuation.yield(AudioChunk(
                samples: Array(repeating: 0.05, count: 8_000),
                sampleRate: 16_000,
                channelCount: 1,
                startTime: 0,
                duration: 0.5
            ))
            continuation.yield(AudioChunk(
                samples: Array(repeating: 0.05, count: 8_000),
                sampleRate: 16_000,
                channelCount: 1,
                startTime: 0.5,
                duration: 0.5
            ))
            continuation.finish()
        }
        let backend = SpeechBackendDescriptor(kind: .mock, displayName: "Mock")
        let options = StreamingTranscriptionOptions(
            transcription: TranscriptionOptions(
                useCase: .dictation,
                initialPrompt: "User prompt",
                contextualStrings: ["Friedrich Merz"],
                voiceActivityDetection: .disabled
            ),
            commitment: .immediate,
            strategy: .lowestLatency,
            emulation: EmulatedStreamingOptions(
                window: .rollingBuffer(maxDuration: 4.0, updateInterval: 0.5, overlap: 0)
            )
        )
        let callCounter = SpeechChunkStreamingPipelineCallCounter()
        let promptRecorder = TranscriptionPromptRecorder()

        let stream = SpeechChunkStreamingPipeline.stream(
            audio: audio,
            backend: backend,
            options: options,
            transcribe: { _, options in
                await promptRecorder.record(options)
                let callIndex = await callCounter.next()
                let text = callIndex == 1 ? "stable alpha" : "stable alpha beta"
                return Transcript(segments: [
                    TranscriptSegment(text: text, startTime: 0, endTime: 1)
                ])
            })

        for try await _ in stream {}

        let prompts = await promptRecorder.prompts()
        let contextualStrings = await promptRecorder.contextualStrings()
        XCTAssertGreaterThanOrEqual(prompts.count, 2)
        XCTAssertEqual(prompts[0], "User prompt")
        XCTAssertEqual(prompts[1], "User prompt\nPrevious stable transcript:\nstable alpha")
        XCTAssertEqual(contextualStrings[1], ["Friedrich Merz"])
    }

    func testSpeechChunkStreamingPipelineUsesLocalAgreementForRollingBuffer() async throws {
        let audio = AsyncThrowingStream<AudioChunk, Error> { continuation in
            continuation.yield(AudioChunk(
                samples: Array(repeating: 0.05, count: 8_000),
                sampleRate: 16_000,
                channelCount: 1,
                startTime: 0,
                duration: 0.5
            ))
            continuation.yield(AudioChunk(
                samples: Array(repeating: 0.05, count: 8_000),
                sampleRate: 16_000,
                channelCount: 1,
                startTime: 0.5,
                duration: 0.5
            ))
            continuation.finish()
        }
        let backend = SpeechBackendDescriptor(kind: .mock, displayName: "Mock")
        let options = StreamingTranscriptionOptions(
            transcription: TranscriptionOptions(useCase: .dictation),
            commitment: .localAgreement(iterations: 2),
            strategy: .lowestLatency,
            emulation: EmulatedStreamingOptions(
                window: .rollingBuffer(maxDuration: 4.0, updateInterval: 0.5, overlap: 0.25)
            )
        )
        let callCounter = SpeechChunkStreamingPipelineCallCounter()

        var events: [TranscriptEvent] = []
        let stream = SpeechChunkStreamingPipeline.stream(
            audio: audio,
            backend: backend,
            options: options,
            transcribe: { _, _ in
                let callIndex = await callCounter.next()
                let text = callIndex == 1 ? "hello speech" : "hello speech provider"
                return Transcript(segments: [
                    TranscriptSegment(text: text, startTime: 0, endTime: 1)
                ])
            })

        for try await event in stream {
            events.append(event)
        }

        let committedText = events.compactMap { event -> String? in
            if case .completed(let transcript) = event {
                return transcript.text
            }
            return nil
        }.last ?? ""

        XCTAssertEqual(committedText, "hello speech provider")
        XCTAssertTrue(events.contains { event in
            if case .snapshot(let snapshot) = event {
                return snapshot.stable.text == "hello speech"
                    && snapshot.volatile?.text == "provider"
            }
            return false
        })
    }

    func testSpeechChunkStreamingPipelineKeepsVADUtteranceLocalAgreementFlushBehavior() async throws {
        let audio = AsyncThrowingStream<AudioChunk, Error> { continuation in
            for index in 0..<2 {
                continuation.yield(AudioChunk(
                    samples: Array(repeating: 0.05, count: 8_000),
                    sampleRate: 16_000,
                    channelCount: 1,
                    startTime: TimeInterval(index) * 0.5,
                    duration: 0.5
                ))
            }
            continuation.finish()
        }
        let backend = SpeechBackendDescriptor(kind: .mock, displayName: "Mock")
        let options = StreamingTranscriptionOptions(
            transcription: TranscriptionOptions(voiceActivityDetection: .disabled),
            commitment: .localAgreement(iterations: 2),
            strategy: .lowestLatency,
            emulation: EmulatedStreamingOptions(
                window: .vadUtterances(SpeechChunkingConfiguration(
                    maximumChunkDuration: 0.5,
                    overlapDuration: 0,
                    silenceCommitDelay: 2.0,
                    minimumSpeechDuration: 0.01
                ))
            )
        )
        let callCounter = SpeechChunkStreamingPipelineCallCounter()

        var events: [TranscriptEvent] = []
        let stream = SpeechChunkStreamingPipeline.stream(
            audio: audio,
            backend: backend,
            options: options,
            transcribe: { _, _ in
                let callIndex = await callCounter.next()
                let text = callIndex == 1 ? "alpha beta" : "alpha beta gamma"
                return Transcript(segments: [
                    TranscriptSegment(text: text, startTime: 0, endTime: 1)
                ])
            })

        for try await event in stream {
            events.append(event)
        }

        XCTAssertTrue(events.contains { event in
            if case .completed(let transcript) = event {
                return transcript.text == "alpha beta gamma"
            }
            return false
        })
    }

    func testSpeechChunkStreamingPipelineFlushesPendingLocalAgreementOnFinalWindow() async throws {
        let audio = AsyncThrowingStream<AudioChunk, Error> { continuation in
            continuation.yield(AudioChunk(
                samples: Array(repeating: 0.05, count: 8_000),
                sampleRate: 16_000,
                channelCount: 1,
                startTime: 0,
                duration: 0.5
            ))
            continuation.yield(AudioChunk(
                samples: Array(repeating: 0.05, count: 8_000),
                sampleRate: 16_000,
                channelCount: 1,
                startTime: 0.5,
                duration: 0.5
            ))
            continuation.finish()
        }
        let backend = SpeechBackendDescriptor(kind: .mock, displayName: "Mock")
        let options = StreamingTranscriptionOptions(
            transcription: TranscriptionOptions(useCase: .dictation),
            commitment: .localAgreement(iterations: 2),
            strategy: .lowestLatency,
            emulation: EmulatedStreamingOptions(
                window: .rollingBuffer(maxDuration: 1.0, updateInterval: 0.5, overlap: 0.25)
            )
        )
        let callCounter = SpeechChunkStreamingPipelineCallCounter()

        var events: [TranscriptEvent] = []
        let stream = SpeechChunkStreamingPipeline.stream(
            audio: audio,
            backend: backend,
            options: options,
            transcribe: { _, _ in
                let callIndex = await callCounter.next()
                let text: String
                switch callIndex {
                case 1:
                    text = "alpha beta"
                case 2:
                    text = "alpha beta gamma delta epsilon"
                default:
                    text = "epsilon zeta"
                }
                return Transcript(segments: [
                    TranscriptSegment(text: text, startTime: 0, endTime: 1)
                ])
            })

        for try await event in stream {
            events.append(event)
        }

        XCTAssertTrue(events.contains { event in
            if case .completed(let transcript) = event {
                return transcript.text == "alpha beta gamma delta epsilon zeta"
            }
            return false
        })
    }

    func testSpeechChunkStreamingPipelineCommitsExpiredLocalAgreementPrefix() async throws {
        let audio = AsyncThrowingStream<AudioChunk, Error> { continuation in
            for index in 0..<3 {
                continuation.yield(AudioChunk(
                    samples: Array(repeating: 0.05, count: 8_000),
                    sampleRate: 16_000,
                    channelCount: 1,
                    startTime: TimeInterval(index) * 0.5,
                    duration: 0.5
                ))
            }
            continuation.finish()
        }
        let backend = SpeechBackendDescriptor(kind: .mock, displayName: "Mock")
        let options = StreamingTranscriptionOptions(
            transcription: TranscriptionOptions(useCase: .dictation),
            commitment: .localAgreement(iterations: 2),
            strategy: .lowestLatency,
            emulation: EmulatedStreamingOptions(
                window: .rollingBuffer(maxDuration: 1.0, updateInterval: 0.5, overlap: 0.25)
            )
        )
        let callCounter = SpeechChunkStreamingPipelineCallCounter()

        var events: [TranscriptEvent] = []
        let stream = SpeechChunkStreamingPipeline.stream(
            audio: audio,
            backend: backend,
            options: options,
            transcribe: { _, _ in
                let callIndex = await callCounter.next()
                let text: String
                switch callIndex {
                case 1:
                    text = "alpha beta"
                case 2:
                    text = "alpha beta gamma delta epsilon"
                case 3:
                    text = "delta epsilon zeta"
                default:
                    text = "zeta eta"
                }
                return Transcript(segments: [
                    TranscriptSegment(text: text, startTime: 0, endTime: 1)
                ])
            })

        for try await event in stream {
            events.append(event)
        }

        XCTAssertTrue(events.contains { event in
            if case .snapshot(let snapshot) = event {
                return snapshot.stable.text.split(separator: " ").contains("gamma")
            }
            return false
        })
    }

    func testSpeechChunkStreamingPipelineDoesNotDuplicateInternalOverlapAfterWindowShift() async throws {
        let audio = AsyncThrowingStream<AudioChunk, Error> { continuation in
            for index in 0..<2 {
                continuation.yield(AudioChunk(
                    samples: Array(repeating: 0.05, count: 8_000),
                    sampleRate: 16_000,
                    channelCount: 1,
                    startTime: TimeInterval(index) * 0.5,
                    duration: 0.5
                ))
            }
            continuation.finish()
        }
        let backend = SpeechBackendDescriptor(kind: .mock, displayName: "Mock")
        let options = StreamingTranscriptionOptions(
            transcription: TranscriptionOptions(useCase: .dictation),
            commitment: .localAgreement(iterations: 2),
            strategy: .lowestLatency,
            emulation: EmulatedStreamingOptions(
                window: .rollingBuffer(maxDuration: 1.0, updateInterval: 0.5, overlap: 0.25)
            )
        )
        let callCounter = SpeechChunkStreamingPipelineCallCounter()

        var events: [TranscriptEvent] = []
        let stream = SpeechChunkStreamingPipeline.stream(
            audio: audio,
            backend: backend,
            options: options,
            transcribe: { _, _ in
                let callIndex = await callCounter.next()
                let text: String
                switch callIndex {
                case 1:
                    text = "he finds himself confronting a painful memory and"
                case 2:
                    text = "painful memory embodied in the physical likeness"
                default:
                    return Transcript()
                }
                return Transcript(segments: [
                    TranscriptSegment(text: text, startTime: 0, endTime: 1)
                ])
            })

        for try await event in stream {
            events.append(event)
        }

        XCTAssertTrue(events.contains { event in
            if case .completed(let transcript) = event {
                return transcript.text == "he finds himself confronting a painful memory embodied in the physical likeness"
            }
            return false
        })
        XCTAssertFalse(events.contains { event in
            if case .snapshot(let snapshot) = event {
                return snapshot.transcript.text.contains("painful memory and painful memory")
            }
            return false
        })
    }

    func testSpeechChunkStreamingPipelineTreatsPluralOverlapAsDuplicate() async throws {
        let audio = AsyncThrowingStream<AudioChunk, Error> { continuation in
            for index in 0..<2 {
                continuation.yield(AudioChunk(
                    samples: Array(repeating: 0.05, count: 8_000),
                    sampleRate: 16_000,
                    channelCount: 1,
                    startTime: TimeInterval(index) * 0.5,
                    duration: 0.5
                ))
            }
            continuation.finish()
        }
        let backend = SpeechBackendDescriptor(kind: .mock, displayName: "Mock")
        let options = StreamingTranscriptionOptions(
            transcription: TranscriptionOptions(useCase: .dictation),
            commitment: .localAgreement(iterations: 2),
            strategy: .lowestLatency,
            emulation: EmulatedStreamingOptions(
                window: .rollingBuffer(maxDuration: 1.0, updateInterval: 0.5, overlap: 0.25)
            )
        )
        let callCounter = SpeechChunkStreamingPipelineCallCounter()

        var events: [TranscriptEvent] = []
        let stream = SpeechChunkStreamingPipeline.stream(
            audio: audio,
            backend: backend,
            options: options,
            transcribe: { _, _ in
                let callIndex = await callCounter.next()
                let text: String
                switch callIndex {
                case 1:
                    text = "scientists speculate that the oceans"
                case 2:
                    text = "The ocean may be a massive neural center"
                default:
                    return Transcript()
                }
                return Transcript(segments: [
                    TranscriptSegment(text: text, startTime: 0, endTime: 1)
                ])
            })

        for try await event in stream {
            events.append(event)
        }

        XCTAssertTrue(events.contains { event in
            if case .completed(let transcript) = event {
                return transcript.text == "scientists speculate that The ocean may be a massive neural center"
            }
            return false
        })
        XCTAssertFalse(events.contains { event in
            if case .snapshot(let snapshot) = event {
                return snapshot.transcript.text.contains("oceans The ocean")
            }
            return false
        })
    }

    func testSpeechChunkStreamingPipelineCommitsPreviousLocalAgreementWhenWindowTextDoesNotOverlap() async throws {
        let audio = AsyncThrowingStream<AudioChunk, Error> { continuation in
            for index in 0..<2 {
                continuation.yield(AudioChunk(
                    samples: Array(repeating: 0.05, count: 8_000),
                    sampleRate: 16_000,
                    channelCount: 1,
                    startTime: TimeInterval(index) * 0.5,
                    duration: 0.5
                ))
            }
            continuation.finish()
        }
        let backend = SpeechBackendDescriptor(kind: .mock, displayName: "Mock")
        let options = StreamingTranscriptionOptions(
            transcription: TranscriptionOptions(useCase: .dictation),
            commitment: .localAgreement(iterations: 2),
            strategy: .lowestLatency,
            emulation: EmulatedStreamingOptions(
                window: .rollingBuffer(maxDuration: 1.0, updateInterval: 0.5, overlap: 0.25)
            )
        )
        let callCounter = SpeechChunkStreamingPipelineCallCounter()

        var events: [TranscriptEvent] = []
        let stream = SpeechChunkStreamingPipeline.stream(
            audio: audio,
            backend: backend,
            options: options,
            transcribe: { _, _ in
                let callIndex = await callCounter.next()
                let text: String
                switch callIndex {
                case 1:
                    text = "alpha beta"
                case 2:
                    text = "gamma delta"
                default:
                    text = "delta epsilon"
                }
                return Transcript(segments: [
                    TranscriptSegment(text: text, startTime: 0, endTime: 1)
                ])
            })

        for try await event in stream {
            events.append(event)
        }

        XCTAssertTrue(events.contains { event in
            if case .completed(let transcript) = event {
                return transcript.text == "alpha beta gamma delta epsilon"
            }
            return false
        })
    }

    func testSpeechChunkStreamingPipelineDoesNotDuplicateCommittedPrefixAfterRevision() async throws {
        let audio = AsyncThrowingStream<AudioChunk, Error> { continuation in
            for index in 0..<3 {
                continuation.yield(AudioChunk(
                    samples: Array(repeating: 0.05, count: 8_000),
                    sampleRate: 16_000,
                    channelCount: 1,
                    startTime: TimeInterval(index) * 0.5,
                    duration: 0.5
                ))
            }
            continuation.finish()
        }
        let backend = SpeechBackendDescriptor(kind: .mock, displayName: "Mock")
        let options = StreamingTranscriptionOptions(
            transcription: TranscriptionOptions(useCase: .dictation),
            commitment: .localAgreement(iterations: 2),
            strategy: .lowestLatency,
            emulation: EmulatedStreamingOptions(
                window: .rollingBuffer(maxDuration: 1.0, updateInterval: 0.5, overlap: 0.25)
            )
        )
        let callCounter = SpeechChunkStreamingPipelineCallCounter()

        var events: [TranscriptEvent] = []
        let stream = SpeechChunkStreamingPipeline.stream(
            audio: audio,
            backend: backend,
            options: options,
            transcribe: { _, _ in
                let callIndex = await callCounter.next()
                let text: String
                let startTime: TimeInterval
                switch callIndex {
                case 1:
                    text = "alpha beta"
                    startTime = 0
                case 2:
                    text = "alpha beta gamma"
                    startTime = 0
                case 3:
                    text = "alpha beta gamma delta"
                    startTime = 10
                default:
                    text = "alpha beta gamma delta epsilon"
                    startTime = 10
                }
                return Transcript(segments: [
                    TranscriptSegment(text: text, startTime: startTime, endTime: startTime + 0.1)
                ])
            })

        for try await event in stream {
            events.append(event)
        }

        XCTAssertTrue(events.contains { event in
            if case .completed(let transcript) = event {
                return transcript.text == "alpha beta gamma delta epsilon"
            }
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

private actor SpeechChunkStreamingPipelineCallCounter {
    private var value = 0

    func next() -> Int {
        value += 1
        return value
    }

    func current() -> Int {
        value
    }
}

private actor SpeechChunkStreamingPipelineStartRecorder {
    private var value: TimeInterval?

    func record(_ value: TimeInterval) {
        self.value = value
    }

    func recordedValue() -> TimeInterval? {
        value
    }
}

private func contextualTestAudio(chunkCount: Int) -> AsyncThrowingStream<AudioChunk, Error> {
    AsyncThrowingStream { continuation in
        Task {
            for index in 0..<chunkCount {
                continuation.yield(AudioChunk(
                    samples: Array(repeating: 0.05, count: 8_000),
                    sampleRate: 16_000,
                    channelCount: 1,
                    startTime: TimeInterval(index) * 0.5,
                    duration: 0.5
                ))
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            continuation.finish()
        }
    }
}

private func textOnlyResult(_ text: String) -> SpeechChunkStreamingPipeline.StreamingChunkTranscriptionResult {
    SpeechChunkStreamingPipeline.StreamingChunkTranscriptionResult(
        transcript: Transcript(segments: [
            TranscriptSegment(text: text, startTime: 0, endTime: 0)
        ])
    )
}

private func timedWordResult(
    _ text: String,
    startTime: TimeInterval = 0,
    step: TimeInterval
) -> SpeechChunkStreamingPipeline.StreamingChunkTranscriptionResult {
    let parts = text.split(separator: " ").map(String.init)
    let words = parts.enumerated().map { index, part in
        (
            text: part,
            startTime: startTime + TimeInterval(index) * step,
            endTime: startTime + TimeInterval(index + 1) * step
        )
    }
    return timedWordResult(words)
}

private func timedWordResult(
    _ words: [(text: String, startTime: TimeInterval, endTime: TimeInterval)]
) -> SpeechChunkStreamingPipeline.StreamingChunkTranscriptionResult {
    let alignmentWords = words.map { word in
        SpeechChunkStreamingPipeline.StreamingAlignmentWord(
            text: word.text,
            startTime: word.startTime,
            endTime: word.endTime
        )
    }
    let publicWords = words.filter { !isWhisperSpecialMarker($0.text) }
    let transcript = Transcript(segments: [
        TranscriptSegment(
            text: publicWords.map(\.text).joined(separator: " "),
            startTime: alignmentWords.first?.startTime ?? 0,
            endTime: alignmentWords.last?.endTime ?? 0,
            words: []
        )
    ])
    return SpeechChunkStreamingPipeline.StreamingChunkTranscriptionResult(
        transcript: transcript,
        alignmentWords: alignmentWords
    )
}

private func isWhisperSpecialMarker(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.hasPrefix("[_") && trimmed.hasSuffix("]")
}

private func completedTranscriptText(in events: [TranscriptEvent]) -> String {
    events.compactMap { event -> String? in
        if case .completed(let transcript) = event {
            return transcript.text
        }
        return nil
    }.last ?? ""
}

private enum AudioRecordingStreamTestError: Error {
    case source
    case tap
}

private struct RecordedPCMFile {
    var samples: [Float]
    var sampleRate: Double
    var channelCount: Int
    var frameCount: Int
}

private enum RecordedPCMReadError: Error {
    case couldNotCreateBuffer
    case unsupportedFormat
}

private func readPCMFile(at url: URL) throws -> RecordedPCMFile {
    let file = try AVAudioFile(forReading: url)
    let frameCapacity = AVAudioFrameCount(max(0, min(Int64(UInt32.max), file.length)))
    guard let buffer = AVAudioPCMBuffer(
        pcmFormat: file.processingFormat,
        frameCapacity: frameCapacity
    ) else {
        throw RecordedPCMReadError.couldNotCreateBuffer
    }

    try file.read(into: buffer)
    let channelCount = Int(buffer.format.channelCount)
    let frameCount = Int(buffer.frameLength)
    var samples: [Float] = []
    samples.reserveCapacity(frameCount * channelCount)

    if let channels = buffer.floatChannelData {
        appendSamples(
            from: channels,
            frameCount: frameCount,
            channelCount: channelCount,
            isInterleaved: buffer.format.isInterleaved,
            to: &samples
        )
    } else if let channels = buffer.int16ChannelData {
        appendSamples(
            from: channels,
            frameCount: frameCount,
            channelCount: channelCount,
            isInterleaved: buffer.format.isInterleaved,
            to: &samples
        )
    } else {
        throw RecordedPCMReadError.unsupportedFormat
    }

    return RecordedPCMFile(
        samples: samples,
        sampleRate: buffer.format.sampleRate,
        channelCount: channelCount,
        frameCount: frameCount
    )
}

private func appendSamples(
    from channels: UnsafePointer<UnsafeMutablePointer<Float>>,
    frameCount: Int,
    channelCount: Int,
    isInterleaved: Bool,
    to samples: inout [Float]
) {
    for frame in 0..<frameCount {
        for channel in 0..<channelCount {
            let sourceChannel = isInterleaved ? 0 : channel
            let sampleIndex = isInterleaved ? frame * channelCount + channel : frame
            samples.append(channels[sourceChannel][sampleIndex])
        }
    }
}

private func appendSamples(
    from channels: UnsafePointer<UnsafeMutablePointer<Int16>>,
    frameCount: Int,
    channelCount: Int,
    isInterleaved: Bool,
    to samples: inout [Float]
) {
    for frame in 0..<frameCount {
        for channel in 0..<channelCount {
            let sourceChannel = isInterleaved ? 0 : channel
            let sampleIndex = isInterleaved ? frame * channelCount + channel : frame
            let sample = channels[sourceChannel][sampleIndex]
            samples.append(Float(sample) / Float(Int16.max))
        }
    }
}

private func XCTAssertSamplesEqual(
    _ actual: [Float],
    _ expected: [Float],
    accuracy: Float = 0.000_1,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(actual.count, expected.count, file: file, line: line)
    for index in 0..<min(actual.count, expected.count) {
        XCTAssertEqual(
            Double(actual[index]),
            Double(expected[index]),
            accuracy: Double(accuracy),
            "sample \(index)",
            file: file,
            line: line
        )
    }
}

private func hasRepeatedNormalizedNGram(_ text: String, size: Int) -> Bool {
    let tokens = text
        .lowercased()
        .split { !$0.isLetter && !$0.isNumber && $0 != "'" }
        .map(String.init)
    guard tokens.count >= size * 2 else { return false }

    var seen: Set<String> = []
    for index in 0...(tokens.count - size) {
        let ngram = tokens[index..<(index + size)].joined(separator: " ")
        if seen.contains(ngram) {
            return true
        }
        seen.insert(ngram)
    }
    return false
}

private actor TranscriptionPromptRecorder {
    private var recordedPrompts: [String?] = []
    private var recordedContextualStrings: [[String]] = []

    func record(_ options: TranscriptionOptions) {
        recordedPrompts.append(options.initialPrompt)
        recordedContextualStrings.append(options.contextualStrings)
    }

    func prompts() -> [String?] {
        recordedPrompts
    }

    func contextualStrings() -> [[String]] {
        recordedContextualStrings
    }
}

private final class SequenceVoiceActivityDetector: VoiceActivityDetecting, @unchecked Sendable {
    private let lock = NSLock()
    private var states: [VoiceActivityState]
    private var index = 0

    init(states: [VoiceActivityState]) {
        self.states = states
    }

    func analyze(_ chunk: AudioChunk) throws -> VoiceActivityEvent {
        lock.lock()
        let state = states.isEmpty ? VoiceActivityState.silence : states[min(index, states.count - 1)]
        index += 1
        lock.unlock()

        return VoiceActivityEvent(
            state: state,
            startTime: chunk.startTime,
            endTime: chunk.startTime + chunk.duration,
            confidence: state == .speech ? 1 : 0
        )
    }
}
