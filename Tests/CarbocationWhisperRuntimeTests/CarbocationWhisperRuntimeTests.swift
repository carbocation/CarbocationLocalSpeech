@_spi(Internal) import CarbocationLocalSpeech
@testable import CarbocationWhisperBenchmarkSupport
@testable import CarbocationWhisperRuntime
import Foundation
import XCTest

final class CarbocationWhisperRuntimeTests: XCTestCase {
    func testBackendStatusIsCallableWithoutArtifact() {
        let status = WhisperRuntimeSmoke.linkStatus()
        XCTAssertFalse(status.displayDescription.isEmpty)
    }

    func testDefaultMetalPolicyDisablesIOSSimulatorMetal() {
#if os(iOS) && targetEnvironment(simulator)
        XCTAssertFalse(WhisperRuntimeDefaults.useMetal)
        XCTAssertFalse(WhisperEngineConfiguration().useMetal)
        XCTAssertFalse(WhisperLoadConfiguration().useMetal)
#else
        XCTAssertTrue(WhisperRuntimeDefaults.useMetal)
        XCTAssertTrue(WhisperEngineConfiguration().useMetal)
        XCTAssertTrue(WhisperLoadConfiguration().useMetal)
#endif
    }

    func testDefaultCoreMLPolicyMatchesLegacyConfiguration() {
        XCTAssertTrue(WhisperEngineConfiguration().useCoreML)
        XCTAssertTrue(WhisperLoadConfiguration().useCoreML)
    }

    func testEngineLoadsInstalledModelMetadataWithoutRunningInference() async throws {
        let root = try makeTemporaryDirectory()
        let source = root.appendingPathComponent("ggml-base.en.bin")
        try Data("fake".utf8).write(to: source)
        let vadSource = root.appendingPathComponent("ggml-silero-v6.2.0.bin")
        try Data("fake vad".utf8).write(to: vadSource)

        let library = SpeechModelLibrary(root: root.appendingPathComponent("SpeechModels", isDirectory: true))
        let result = try await library.add(
            primaryAssetAt: source,
            displayName: "Base",
            filename: "ggml-base.en.bin",
            source: .imported,
            vadAssetAt: vadSource,
            vadFilename: "ggml-silero-v6.2.0.bin"
        )
        let model = result.model
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

    func testRealWhisperModelResolverPreservesLibrarySidecars() async throws {
        let root = try makeTemporaryDirectory().appendingPathComponent("SpeechModels", isDirectory: true)
        let modelID = UUID()
        let modelDirectory = root.appendingPathComponent(modelID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        try Data("fake model".utf8).write(to: modelDirectory.appendingPathComponent("ggml-tiny.en.bin"))
        try Data("fake vad".utf8).write(to: modelDirectory.appendingPathComponent("ggml-silero-v6.2.0.bin"))
        let coreMLDirectory = modelDirectory.appendingPathComponent("ggml-tiny.en-encoder.mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(at: coreMLDirectory, withIntermediateDirectories: true)
        try Data("fake coreml".utf8).write(to: coreMLDirectory.appendingPathComponent("model"))

        let resolved = try await WhisperRealTestModelResolver.resolve(environment: [
            WhisperRealTestModelResolver.libraryRootEnv: root.path
        ])

        XCTAssertEqual(resolved?.model.id, modelID)
        XCTAssertEqual(resolved?.model.variant, "tiny.en")
        XCTAssertEqual(resolved?.model.assets.map(\.role).sorted(by: { $0.rawValue < $1.rawValue }), [
            .coreMLEncoder,
            .primaryWeights,
            .vadWeights
        ])
        XCTAssertEqual(resolved?.werThreshold, 0.60)
    }

    func testRealWhisperModelResolverUsesRequestedLibraryVariant() async throws {
        let root = try makeTemporaryDirectory().appendingPathComponent("SpeechModels", isDirectory: true)
        let tinyDirectory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let smallID = UUID()
        let smallDirectory = root.appendingPathComponent(smallID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tinyDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: smallDirectory, withIntermediateDirectories: true)
        try Data("fake tiny".utf8).write(to: tinyDirectory.appendingPathComponent("ggml-tiny.en.bin"))
        try Data("fake small".utf8).write(to: smallDirectory.appendingPathComponent("ggml-small.en.bin"))

        let resolved = try await WhisperRealTestModelResolver.resolve(environment: [
            WhisperRealTestModelResolver.libraryRootEnv: root.path,
            WhisperRealTestModelResolver.modelVariantEnv: "small.en"
        ])

        XCTAssertEqual(resolved?.model.id, smallID)
        XCTAssertEqual(resolved?.model.variant, "small.en")
        XCTAssertEqual(resolved?.werThreshold, 0.35)
    }

    func testBenchmarkTimingAggregation() {
        XCTAssertEqual(WhisperBenchmarkRunner.median([3, 1, 2]), 2)
        XCTAssertEqual(WhisperBenchmarkRunner.median([4, 1, 2, 3]), 2.5)
        XCTAssertEqual(WhisperBenchmarkRunner.best([4, 1, 2, 3]), 1)
    }

    func testBenchmarkReportJSONEncodingIncludesWERAndCoreMLExpectation() throws {
        let report = WhisperBenchmarkReport(
            configuration: WhisperBenchmarkConfigurationSummary(
                explicitModelPath: nil,
                libraryRootPath: "/tmp/SpeechModels",
                variant: "small.en",
                iterations: 2,
                warmups: 1,
                threadCount: 4,
                useMetal: true,
                useCoreML: true,
                suppressNativeLogs: true
            ),
            runtime: WhisperBenchmarkRuntimeSummary(
                backendStatus: "linked",
                backendStatusDescription: "whisper.cpp source artifact is present.",
                systemInfo: "WHISPER : COREML = 1 |",
                coreMLCompiledIn: true,
                coreMLRequested: true,
                modelDeclaresCoreMLEncoder: true,
                expectedCoreMLEncoderPath: "/tmp/SpeechModels/model/ggml-small.en-encoder.mlmodelc",
                expectedCoreMLEncoderExists: true,
                expectedCoreMLActive: true
            ),
            model: WhisperBenchmarkModelSummary(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                displayName: "Whisper small.en (English-only)",
                variant: "small.en",
                primaryWeightsPath: "/tmp/SpeechModels/model/ggml-small.en.bin",
                libraryRootPath: "/tmp/SpeechModels",
                assetRoles: ["coreMLEncoder", "primaryWeights", "vadWeights"]
            ),
            fixture: WhisperBenchmarkFixtureSummary(
                name: "jfk",
                audioPath: "/tmp/jfk.wav",
                language: "en",
                durationSeconds: 11,
                referenceWordCount: 19
            ),
            timings: WhisperBenchmarkTimingSummary(
                audioPreparationSeconds: 0.01,
                loadSeconds: 0.02,
                contextInitSeconds: 0.03,
                firstTranscriptionSeconds: 0.4,
                warmupTranscriptionSeconds: [0.3],
                warmTranscriptionSeconds: [0.2, 0.25],
                medianWarmTranscriptionSeconds: 0.225,
                bestWarmTranscriptionSeconds: 0.2,
                medianWarmRealTimeFactor: 48.8,
                bestWarmRealTimeFactor: 55
            ),
            wer: WhisperBenchmarkWERSummary(
                substitutions: 0,
                deletions: 0,
                insertions: 0,
                referenceWordCount: 19,
                hypothesisWordCount: 19,
                wordErrorRate: 0,
                summaryText: "S 0 D 0 I 0 WER 0.0%"
            ),
            transcriptExcerpt: "And so my fellow Americans..."
        )

        let data = try WhisperBenchmarkJSON.encoder().encode(report)
        let decoded = try WhisperBenchmarkJSON.decoder().decode(WhisperBenchmarkReport.self, from: data)

        XCTAssertEqual(decoded.schemaVersion, 2)
        XCTAssertEqual(decoded.wer?.wordErrorRate, 0)
        XCTAssertTrue(decoded.configuration.useCoreML)
        XCTAssertTrue(decoded.runtime.coreMLRequested)
        XCTAssertTrue(decoded.runtime.expectedCoreMLActive)
        XCTAssertTrue(String(data: data, encoding: .utf8)?.contains("\"wordErrorRate\"") ?? false)
    }

    func testCoreMLExpectedEncoderPathAndActiveCalculation() {
        let modelURL = URL(fileURLWithPath: "/tmp/ggml-small.en-q5_0.bin")
        XCTAssertEqual(
            WhisperRuntimeSmoke.expectedCoreMLEncoderURL(forModelAt: modelURL).path,
            "/tmp/ggml-small.en-encoder.mlmodelc"
        )

        let active = WhisperCoreMLExpectation(
            compiledIn: true,
            requested: true,
            modelDeclaresCoreMLEncoder: false,
            expectedEncoderPath: "/tmp/ggml-small.en-encoder.mlmodelc",
            expectedEncoderExists: true
        )
        XCTAssertTrue(active.expectedActive)

        let inactive = WhisperCoreMLExpectation(
            compiledIn: false,
            requested: true,
            modelDeclaresCoreMLEncoder: true,
            expectedEncoderPath: "/tmp/ggml-small.en-encoder.mlmodelc",
            expectedEncoderExists: true
        )
        XCTAssertFalse(inactive.expectedActive)

        let notRequested = WhisperCoreMLExpectation(
            compiledIn: true,
            requested: false,
            modelDeclaresCoreMLEncoder: true,
            expectedEncoderPath: "/tmp/ggml-small.en-encoder.mlmodelc",
            expectedEncoderExists: true
        )
        XCTAssertTrue(notRequested.expectedActive)
    }

    @MainActor
    func testLiveWhisperCppLoadsRealModelWhenProvided() async throws {
        guard let resolved = try await WhisperRealTestModelResolver.resolve() else {
            throw XCTSkip(Self.liveWhisperSkipReason)
        }

        let engine = WhisperEngine(configuration: Self.liveWhisperConfiguration(for: resolved))
        _ = try await engine.load(model: resolved.model, from: resolved.libraryRoot)

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

    @MainActor
    func testLiveWhisperCppTranscribesKnownAudioWithinWERBudget() async throws {
        guard let resolved = try await WhisperRealTestModelResolver.resolve() else {
            throw XCTSkip(Self.liveWhisperSkipReason)
        }

        let fixture = try KnownSpeechFixture.jfk()
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.audioURL.path),
            "Missing known speech fixture audio at \(fixture.audioURL.path)."
        )

        let engine = WhisperEngine(configuration: Self.liveWhisperConfiguration(for: resolved))
        _ = try await engine.load(model: resolved.model, from: resolved.libraryRoot)

        let transcript: Transcript
        do {
            transcript = try await engine.transcribe(
                file: fixture.audioURL,
                options: TranscriptionOptions(
                    language: fixture.language,
                    suppressBlankAudio: false,
                    temperature: 0
                )
            )
        } catch {
            await engine.unload()
            throw error
        }
        await engine.unload()

        let hypothesis = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(transcript.backend?.kind, .whisperCpp)
        XCTAssertFalse(hypothesis.isEmpty, "Whisper returned an empty transcript for \(fixture.name).")

        guard let report = WhisperWERCalculator.report(
            referenceText: fixture.referenceText,
            hypothesisText: hypothesis
        ) else {
            XCTFail("Could not compute WER for \(fixture.name). Hypothesis: \(Self.excerpt(hypothesis))")
            return
        }
        guard let wordErrorRate = report.wordErrorRate else {
            XCTFail("\(report.summaryText) for \(fixture.name). Hypothesis: \(Self.excerpt(hypothesis))")
            return
        }

        Self.emitRealWhisperWER(
            report,
            threshold: resolved.werThreshold,
            fixture: fixture,
            model: resolved,
            hypothesis: hypothesis
        )

        XCTAssertLessThanOrEqual(
            wordErrorRate,
            resolved.werThreshold,
            """
            Known-audio Whisper WER exceeded budget for \(resolved.model.displayName).
            Fixture: \(fixture.name)
            Model: \(resolved.modelURL.path)
            Threshold: \(String(format: "%.1f%%", resolved.werThreshold * 100))
            Actual: \(report.summaryText)
            Reference: \(fixture.referenceText)
            Hypothesis: \(Self.excerpt(hypothesis))
            """
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CarbocationWhisperRuntimeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static let liveWhisperSkipReason = """
    Set CARBOCATION_LOCAL_SPEECH_TEST_MODEL to an installed whisper.cpp .bin model, or set \
    CARBOCATION_LOCAL_SPEECH_TEST_LIBRARY_ROOT to a SpeechModels directory. \
    CARBOCATION_LOCAL_SPEECH_TEST_MODEL_VARIANT defaults to tiny.en when using a library root.
    """

    private static func liveWhisperConfiguration(for model: ResolvedWhisperTestModel) -> WhisperEngineConfiguration {
        WhisperEngineConfiguration(
            useCoreML: model.hasCoreMLEncoder,
            threadCount: 2
        )
    }

    private static func excerpt(_ text: String, limit: Int = 240) -> String {
        let singleLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard singleLine.count > limit else { return singleLine }
        return "\(singleLine.prefix(limit))..."
    }

    private static func emitRealWhisperWER(
        _ report: WhisperWERReport,
        threshold: Double,
        fixture: KnownSpeechFixture,
        model: ResolvedWhisperTestModel,
        hypothesis: String
    ) {
        let rate = report.wordErrorRate.map { String(format: "%.1f%%", $0 * 100) } ?? "n/a"
        let thresholdText = String(format: "%.1f%%", threshold * 100)
        let sidecarText = model.hasCoreMLEncoder ? "yes" : "no"
        let message = """
        [CarbocationLocalSpeech] \(fixture.name) WER \(rate) <= \(thresholdText); \(report.summaryText); model \(model.model.displayName); CoreML sidecar: \(sidecarText)
        [CarbocationLocalSpeech] hypothesis: \(excerpt(hypothesis))

        """
        FileHandle.standardError.write(Data(message.utf8))
    }
}
