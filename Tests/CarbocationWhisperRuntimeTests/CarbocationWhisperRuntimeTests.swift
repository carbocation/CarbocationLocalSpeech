@_spi(Internal) import CarbocationLocalSpeech
@testable import CarbocationWhisperRuntime
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
        let vadSource = root.appendingPathComponent("ggml-silero-v6.2.0.bin")
        try Data("fake vad".utf8).write(to: vadSource)

        let library = SpeechModelLibrary(root: root.appendingPathComponent("SpeechModels", isDirectory: true))
        let model = try library.add(
            primaryAssetAt: source,
            displayName: "Base",
            filename: "ggml-base.en.bin",
            source: .imported,
            vadAssetAt: vadSource,
            vadFilename: "ggml-silero-v6.2.0.bin"
        )
        let engine = WhisperEngine()
        let loaded = try await engine.load(model: model, from: library.root)
        let currentModelID = await engine.currentModelID()

        XCTAssertEqual(loaded.modelID, model.id)
        XCTAssertEqual(loaded.vadModelPath, model.vadWeightsURL(in: library.root)?.path)
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

    func testStreamingDecodeTuningFollowsStrategy() {
        let balanced = WhisperStreamingDecodeTuning.resolve(for: StreamingTranscriptionOptions(
            strategy: .balanced
        ))
        let lowestLatency = WhisperStreamingDecodeTuning.resolve(for: StreamingTranscriptionOptions(
            strategy: .lowestLatency
        ))
        let fileQuality = WhisperStreamingDecodeTuning.resolve(for: StreamingTranscriptionOptions(
            strategy: .fileQuality
        ))

        XCTAssertFalse(balanced.singleSegment)
        XCTAssertEqual(balanced.maxTokens, 0)
        XCTAssertEqual(balanced.audioContext, 0)
        XCTAssertGreaterThan(balanced.decoderContextTokenLimit, lowestLatency.decoderContextTokenLimit)
        XCTAssertTrue(lowestLatency.singleSegment)
        XCTAssertGreaterThan(lowestLatency.maxTokens, 0)
        XCTAssertGreaterThan(lowestLatency.audioContext, 0)
        XCTAssertFalse(fileQuality.singleSegment)
        XCTAssertEqual(fileQuality.maxTokens, 0)
        XCTAssertEqual(fileQuality.audioContext, 0)
        XCTAssertGreaterThan(fileQuality.decoderContextTokenLimit, balanced.decoderContextTokenLimit)
    }

    func testWhisperVADTuningFollowsSensitivity() {
        let low = WhisperVADTuning.resolve(for: .low)
        let medium = WhisperVADTuning.resolve(for: .medium)
        let high = WhisperVADTuning.resolve(for: .high)

        XCTAssertGreaterThan(low.threshold, medium.threshold)
        XCTAssertGreaterThan(medium.threshold, high.threshold)
        XCTAssertGreaterThan(low.minSpeechDurationMS, high.minSpeechDurationMS)
        XCTAssertGreaterThan(high.speechPadMS, low.speechPadMS)
        XCTAssertGreaterThan(high.samplesOverlap, low.samplesOverlap)
    }

    func testWhisperTokenWordGroupingMergesSubwordPieces() {
        let words = WhisperTokenWordGrouping.transcriptWords(from: [
            WhisperDecodedTokenPiece(text: " What", startTime: 0.0, endTime: 0.1, confidence: 0.9),
            WhisperDecodedTokenPiece(text: " if", startTime: 0.1, endTime: 0.2, confidence: 0.8),
            WhisperDecodedTokenPiece(text: " there", startTime: 0.2, endTime: 0.3, confidence: 0.8),
            WhisperDecodedTokenPiece(text: "'s", startTime: 0.3, endTime: 0.4, confidence: 0.8),
            WhisperDecodedTokenPiece(text: " no", startTime: 0.4, endTime: 0.5, confidence: 0.8),
            WhisperDecodedTokenPiece(text: " Door", startTime: 0.5, endTime: 0.6, confidence: 0.8),
            WhisperDecodedTokenPiece(text: "D", startTime: 0.6, endTime: 0.7, confidence: 0.8),
            WhisperDecodedTokenPiece(text: "ash", startTime: 0.7, endTime: 0.8, confidence: 0.8),
            WhisperDecodedTokenPiece(text: " V", startTime: 0.8, endTime: 0.9, confidence: 0.8),
            WhisperDecodedTokenPiece(text: "im", startTime: 0.9, endTime: 1.0, confidence: 0.8),
            WhisperDecodedTokenPiece(text: "?", startTime: 1.0, endTime: 1.1, confidence: 0.8)
        ])

        XCTAssertEqual(words.map(\.text), [
            "What",
            "if",
            "there's",
            "no",
            "DoorDash",
            "Vim?"
        ])
        XCTAssertEqual(words.first?.startTime, 0.0)
        XCTAssertEqual(words.last?.endTime, 1.1)
    }

    func testWhisperOuterVADSelectionUsesModelWhenAvailable() {
        XCTAssertEqual(
            WhisperOuterVADSelection.resolve(mode: .automatic, vadModelPath: "/tmp/ggml-silero.bin"),
            .whisper
        )
        XCTAssertEqual(
            WhisperOuterVADSelection.resolve(mode: .enabled, vadModelPath: "/tmp/ggml-silero.bin"),
            .whisper
        )
        XCTAssertEqual(
            WhisperOuterVADSelection.resolve(mode: .automatic, vadModelPath: nil),
            .energyFallback(reason: "missing-vad-model")
        )
        XCTAssertEqual(
            WhisperOuterVADSelection.resolve(mode: .disabled, vadModelPath: "/tmp/ggml-silero.bin"),
            .disabled
        )
    }

    func testWhisperInnerVADPolicyDisablesModelVADForStreaming() {
        XCTAssertFalse(WhisperInnerVADPolicy.shouldUseModelVAD(
            options: TranscriptionOptions(voiceActivityDetection: .enabled),
            isStreaming: true
        ))
        XCTAssertTrue(WhisperInnerVADPolicy.shouldUseModelVAD(
            options: TranscriptionOptions(voiceActivityDetection: .enabled),
            isStreaming: false
        ))
        XCTAssertFalse(WhisperInnerVADPolicy.shouldUseModelVAD(
            options: TranscriptionOptions(voiceActivityDetection: .automatic),
            isStreaming: false
        ))
        XCTAssertFalse(WhisperInnerVADPolicy.shouldUseModelVAD(
            options: TranscriptionOptions(voiceActivityDetection: .disabled),
            isStreaming: false
        ))
    }

    func testWhisperStreamingOptionsPreferContextualRollingForDefaultAutomaticStream() {
        let resolved = WhisperStreamingOptionsResolver.resolve(StreamingTranscriptionOptions(
            strategy: .balanced
        ))

        XCTAssertEqual(resolved.commitment, .localAgreement(iterations: 2))
        guard case .contextualRollingBuffer(let maxDuration, let updateInterval, let finalSilenceDelay) = resolved.emulation.window else {
            XCTFail("Expected Whisper default streaming to use contextual rolling windows.")
            return
        }
        XCTAssertEqual(maxDuration, 20.0)
        XCTAssertEqual(updateInterval, 2.0)
        XCTAssertEqual(finalSilenceDelay, 0.8)
    }

    func testWhisperStreamingOptionsUseContextualRollingWhenVADIsDisabled() {
        let resolved = WhisperStreamingOptionsResolver.resolve(StreamingTranscriptionOptions(
            transcription: TranscriptionOptions(voiceActivityDetection: .disabled),
            strategy: .balanced
        ))

        XCTAssertEqual(resolved.commitment, .localAgreement(iterations: 2))
        guard case .contextualRollingBuffer(let maxDuration, let updateInterval, let finalSilenceDelay) = resolved.emulation.window else {
            XCTFail("Expected Whisper streaming with disabled VAD to use contextual rolling windows.")
            return
        }
        XCTAssertEqual(maxDuration, 20.0)
        XCTAssertEqual(updateInterval, 2.0)
        XCTAssertEqual(finalSilenceDelay, 0.8)
    }

    func testWhisperStreamingOptionsKeepExplicitRollingBufferWithLocalAgreement() {
        let options = StreamingTranscriptionOptions(
            strategy: .balanced,
            implementation: .emulated,
            commitment: .automatic,
            emulation: EmulatedStreamingOptions(
                window: .rollingBuffer(maxDuration: 8.0, updateInterval: 1.5, overlap: 1.0)
            )
        )

        let resolved = WhisperStreamingOptionsResolver.resolve(options)

        XCTAssertEqual(resolved.commitment, .localAgreement(iterations: 2))
        guard case .rollingBuffer(let maxDuration, let updateInterval, let overlap) = resolved.emulation.window else {
            XCTFail("Expected explicit rolling-buffer configuration to be preserved.")
            return
        }
        XCTAssertEqual(maxDuration, 8.0)
        XCTAssertEqual(updateInterval, 1.5)
        XCTAssertEqual(overlap, 1.0)
    }

    func testWhisperStreamingOptionsKeepExplicitContextualRollingBufferWithLocalAgreement() {
        let options = StreamingTranscriptionOptions(
            strategy: .balanced,
            implementation: .emulated,
            commitment: .automatic,
            emulation: EmulatedStreamingOptions(
                window: .contextualRollingBuffer(maxDuration: 12.0, updateInterval: 2.0, finalSilenceDelay: 0.8)
            )
        )

        let resolved = WhisperStreamingOptionsResolver.resolve(options)

        XCTAssertEqual(resolved.commitment, .localAgreement(iterations: 2))
        guard case .contextualRollingBuffer(let maxDuration, let updateInterval, let finalSilenceDelay) = resolved.emulation.window else {
            XCTFail("Expected explicit contextual rolling-buffer configuration to be preserved.")
            return
        }
        XCTAssertEqual(maxDuration, 12.0)
        XCTAssertEqual(updateInterval, 2.0)
        XCTAssertEqual(finalSilenceDelay, 0.8)
    }

    func testWhisperStreamingOptionsPreserveExplicitCommitmentPolicy() {
        let resolved = WhisperStreamingOptionsResolver.resolve(StreamingTranscriptionOptions(
            strategy: .balanced,
            implementation: .emulated,
            commitment: .providerFinals,
            emulation: EmulatedStreamingOptions(
                window: .vadUtterances(.balancedDictation)
            )
        ))

        XCTAssertEqual(resolved.commitment, .providerFinals)
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
