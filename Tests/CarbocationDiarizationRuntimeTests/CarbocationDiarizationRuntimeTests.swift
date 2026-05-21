import CarbocationLocalSpeech
@testable import CarbocationDiarizationRuntime
import Foundation
import FluidAudio
import XCTest

@available(macOS 14.0, iOS 17.0, *)
final class CarbocationDiarizationRuntimeTests: XCTestCase {
    private func packageRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fileManager = FileManager.default
        while true {
            if fileManager.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) {
                return directory
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path {
                struct NotFoundError: Error, LocalizedError {
                    var errorDescription: String? { "Could not find Package.swift starting from \(#filePath)" }
                }
                throw NotFoundError()
            }
            directory = parent
        }
    }

    func testFluidAudioDiarizerThrowsWhenModelsHaveNotBeenExplicitlyInstalled() async {
        let diarizer = FluidAudioSpeakerDiarizer()

        do {
            _ = try await diarizer.diarize(
                audio: PreparedAudio(samples: [], sampleRate: 16_000),
                options: DiarizationOptions()
            )
            XCTFail("Expected explicit model installation requirement.")
        } catch let error as FluidAudioSpeakerDiarizerError {
            guard case .modelAssetsMissing = error else {
                return XCTFail("Unexpected FluidAudio error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDiarizerValidatesOptionsBeforeCheckingModels() async {
        let diarizer = FluidAudioSpeakerDiarizer()

        do {
            _ = try await diarizer.diarize(
                audio: PreparedAudio(samples: [0], sampleRate: 16_000),
                options: DiarizationOptions(minimumTurnDuration: -1)
            )
            XCTFail("Expected option validation to run before model availability checks.")
        } catch let error as DiarizationValidationError {
            guard case .invalidValue(let details) = error else {
                return XCTFail("Unexpected validation error: \(error)")
            }
            XCTAssertTrue(details.contains("cannot be negative"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDiarizerPreservesBaseConfigSpeakerConstraints() async {
        var exactBase = OfflineDiarizerConfig.default
        exactBase.clustering.numSpeakers = 3
        exactBase.clustering.minSpeakers = nil
        exactBase.clustering.maxSpeakers = nil
        let exactDiarizer = FluidAudioSpeakerDiarizer(config: exactBase)

        let preservedExact = await exactDiarizer.buildConfig(for: DiarizationOptions())
        XCTAssertEqual(preservedExact.clustering.numSpeakers, 3)
        XCTAssertNil(preservedExact.clustering.minSpeakers)
        XCTAssertNil(preservedExact.clustering.maxSpeakers)

        var rangeBase = OfflineDiarizerConfig.default
        rangeBase.clustering.numSpeakers = nil
        rangeBase.clustering.minSpeakers = 2
        rangeBase.clustering.maxSpeakers = 5
        let rangeDiarizer = FluidAudioSpeakerDiarizer(config: rangeBase)

        let preservedRange = await rangeDiarizer.buildConfig(for: DiarizationOptions())
        XCTAssertNil(preservedRange.clustering.numSpeakers)
        XCTAssertEqual(preservedRange.clustering.minSpeakers, 2)
        XCTAssertEqual(preservedRange.clustering.maxSpeakers, 5)

        let exactOverride = await rangeDiarizer.buildConfig(for: DiarizationOptions(exactSpeakerCount: 4))
        XCTAssertEqual(exactOverride.clustering.numSpeakers, 4)
        XCTAssertNil(exactOverride.clustering.minSpeakers)
        XCTAssertNil(exactOverride.clustering.maxSpeakers)

        let rangeOverride = await exactDiarizer.buildConfig(
            for: DiarizationOptions(minimumSpeakerCount: 3, maximumSpeakerCount: 6)
        )
        XCTAssertNil(rangeOverride.clustering.numSpeakers)
        XCTAssertEqual(rangeOverride.clustering.minSpeakers, 3)
        XCTAssertEqual(rangeOverride.clustering.maxSpeakers, 6)
    }

    func testStreamingDiarizerMapsFinalizedAndTentativeSegments() throws {
        let snapshot = FluidAudioStreamingSpeakerDiarizer.mapSnapshot(
            finalizedSegments: [
                DiarizerSegment(
                    speakerIndex: 0,
                    startTime: 0.0,
                    endTime: 0.8,
                    frameDurationSeconds: 0.1,
                    activity: 0.8
                ),
                DiarizerSegment(
                    speakerIndex: 1,
                    startTime: 0.4,
                    endTime: 1.0,
                    frameDurationSeconds: 0.1,
                    activity: 0.6
                )
            ],
            tentativeSegments: [
                DiarizerSegment(
                    speakerIndex: 0,
                    startTime: 1.0,
                    endTime: 1.3,
                    finalized: false,
                    frameDurationSeconds: 0.1,
                    activity: 0.7
                )
            ],
            baseTime: 10.0,
            options: StreamingDiarizationOptions(
                options: DiarizationOptions(minimumTurnDuration: 0.1),
                backend: .sortformer,
                emitsTentativeTurns: true
            ),
            backend: .sortformer,
            displayName: "Test Sortformer"
        )

        XCTAssertEqual(snapshot.stable.turns.count, 2)
        XCTAssertEqual(snapshot.stable.turns[0].speaker, SpeakerID(rawValue: "speaker_0"))
        XCTAssertEqual(snapshot.stable.turns[0].startTime, 10.0, accuracy: 0.000_1)
        XCTAssertEqual(snapshot.stable.turns[0].endTime, 10.8, accuracy: 0.000_1)
        XCTAssertTrue(snapshot.stable.turns[0].isOverlap)
        XCTAssertEqual(snapshot.stable.speakers.map(\.displayName), ["Speaker 0", "Speaker 1"])
        XCTAssertEqual(snapshot.volatile?.turns.first?.speaker, SpeakerID(rawValue: "speaker_0"))
        let volatileRange = try XCTUnwrap(snapshot.volatileRange)
        XCTAssertEqual(volatileRange.startTime, 11.0, accuracy: 0.000_1)
        XCTAssertEqual(volatileRange.endTime, 11.3, accuracy: 0.000_1)
    }

    func testStreamingDiarizerNamespacesSpeakersAfterRecovery() {
        let snapshot = FluidAudioStreamingSpeakerDiarizer.mapSnapshot(
            finalizedSegments: [
                DiarizerSegment(
                    speakerIndex: 0,
                    startTime: 0,
                    endTime: 0.5,
                    frameDurationSeconds: 0.1,
                    activity: 0.9
                )
            ],
            tentativeSegments: [],
            baseTime: 5,
            options: StreamingDiarizationOptions(
                options: DiarizationOptions(minimumTurnDuration: 0),
                backend: .sortformer
            ),
            backend: .sortformer,
            displayName: "Test Sortformer",
            speakerNamespace: "recovery_1"
        )

        XCTAssertEqual(snapshot.stable.turns.first?.speaker, SpeakerID(rawValue: "recovery_1_speaker_0"))
        XCTAssertEqual(snapshot.stable.turns.first?.source, "FluidAudio.streaming.sortformer.recovery_1")
        XCTAssertEqual(snapshot.stable.speakers.first?.displayName, "Speaker 0 (recovery 1)")
    }

    func testStreamingDiarizerAllowsConcurrentStreamsAndRejectsInstallWhileStreaming() async throws {
        let firstChunkProcessed = expectation(description: "First streaming chunk was processed")
        let secondChunkProcessed = expectation(description: "Second streaming chunk was processed")
        let factory = TestFluidStreamingDiarizerFactory(diarizers: [
            TestFluidStreamingDiarizer(processedExpectation: firstChunkProcessed),
            TestFluidStreamingDiarizer(processedExpectation: secondChunkProcessed)
        ])
        let diarizer = FluidAudioStreamingSpeakerDiarizer(sortformerSessionFactory: {
            try factory.makeDiarizer()
        })
        var firstContinuation: AsyncThrowingStream<AudioChunk, Error>.Continuation!
        let firstAudio = AsyncThrowingStream<AudioChunk, Error> { continuation in
            firstContinuation = continuation
            continuation.yield(AudioChunk(
                samples: Array(repeating: 0.05, count: 1_600),
                sampleRate: 16_000,
                channelCount: 1,
                startTime: 0,
                duration: 0.1
            ))
        }
        let firstStream = diarizer.stream(
            audio: firstAudio,
            options: StreamingDiarizationOptions(
                options: DiarizationOptions(minimumTurnDuration: 0),
                backend: .sortformer
            )
        )
        let firstTask = Task {
            for try await _ in firstStream {}
        }
        await fulfillment(of: [firstChunkProcessed], timeout: 1.0)

        var secondContinuation: AsyncThrowingStream<AudioChunk, Error>.Continuation!
        let secondStream = diarizer.stream(
            audio: AsyncThrowingStream<AudioChunk, Error> { continuation in
                secondContinuation = continuation
                continuation.yield(AudioChunk(
                    samples: Array(repeating: 0.05, count: 1_600),
                    sampleRate: 16_000,
                    channelCount: 1,
                    startTime: 0.1,
                    duration: 0.1
                ))
                continuation.finish()
            },
            options: StreamingDiarizationOptions(
                options: DiarizationOptions(minimumTurnDuration: 0),
                backend: .sortformer
            )
        )
        let secondTask = Task {
            for try await _ in secondStream {}
        }
        await fulfillment(of: [secondChunkProcessed], timeout: 1.0)
        secondContinuation.finish()
        try await secondTask.value

        do {
            try await diarizer.installModels(backend: .sortformer)
            XCTFail("Expected model installation during streaming to be rejected.")
        } catch let error as FluidAudioStreamingSpeakerDiarizerError {
            guard case .operationInProgress = error else {
                return XCTFail("Unexpected FluidAudio streaming error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        firstContinuation.finish()
        try await firstTask.value
        XCTAssertEqual(factory.makeCount, 2)
    }

    func testStreamingDiarizerUnloadModelsCleansUpAndReleasesDiarizers() async throws {
        let testDiarizer = TestFluidStreamingDiarizer()
        let diarizer = FluidAudioStreamingSpeakerDiarizer(sortformerDiarizer: testDiarizer)

        try await diarizer.unloadModels()

        XCTAssertEqual(testDiarizer.cleanupCount, 1)
        let stream = diarizer.stream(
            audio: AsyncThrowingStream<AudioChunk, Error> { continuation in
                continuation.finish()
            },
            options: StreamingDiarizationOptions(backend: .sortformer)
        )

        do {
            for try await _ in stream {}
            XCTFail("Expected streaming to require models after unload.")
        } catch let error as FluidAudioStreamingSpeakerDiarizerError {
            guard case .modelAssetsMissing = error else {
                return XCTFail("Unexpected FluidAudio streaming error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testStreamingDiarizerEvictsIdleModelsOnMemoryPressure() async throws {
        let testDiarizer = TestFluidStreamingDiarizer()
        let diarizer = FluidAudioStreamingSpeakerDiarizer(
            sortformerDiarizer: testDiarizer,
            memoryPressurePolicy: .evictWhenIdle
        )

        await diarizer.simulateMemoryPressureForTesting()

        XCTAssertEqual(testDiarizer.cleanupCount, 1)
        let stream = diarizer.stream(
            audio: AsyncThrowingStream<AudioChunk, Error> { continuation in
                continuation.finish()
            },
            options: StreamingDiarizationOptions(backend: .sortformer)
        )

        do {
            for try await _ in stream {}
            XCTFail("Expected streaming to require models after memory-pressure eviction.")
        } catch let error as FluidAudioStreamingSpeakerDiarizerError {
            guard case .modelAssetsMissing = error else {
                return XCTFail("Unexpected FluidAudio streaming error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testStreamingDiarizerDefersMemoryPressureEvictionUntilActiveStreamEnds() async throws {
        let chunkProcessed = expectation(description: "Streaming chunk was processed")
        let testDiarizer = TestFluidStreamingDiarizer(processedExpectation: chunkProcessed)
        let diarizer = FluidAudioStreamingSpeakerDiarizer(
            sortformerDiarizer: testDiarizer,
            memoryPressurePolicy: .evictWhenIdle
        )
        var continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation!
        let stream = diarizer.stream(
            audio: AsyncThrowingStream<AudioChunk, Error> { audioContinuation in
                continuation = audioContinuation
                audioContinuation.yield(AudioChunk(
                    samples: Array(repeating: 0.05, count: 1_600),
                    sampleRate: 16_000,
                    channelCount: 1,
                    startTime: 0,
                    duration: 0.1
                ))
            },
            options: StreamingDiarizationOptions(
                options: DiarizationOptions(minimumTurnDuration: 0),
                backend: .sortformer
            )
        )
        let task = Task {
            for try await _ in stream {}
        }

        await fulfillment(of: [chunkProcessed], timeout: 1.0)
        await diarizer.simulateMemoryPressureForTesting()
        XCTAssertEqual(testDiarizer.cleanupCount, 0)

        continuation.finish()
        try await task.value
        XCTAssertEqual(testDiarizer.cleanupCount, 2)

        let nextStream = diarizer.stream(
            audio: AsyncThrowingStream<AudioChunk, Error> { continuation in
                continuation.finish()
            },
            options: StreamingDiarizationOptions(backend: .sortformer)
        )
        do {
            for try await _ in nextStream {}
            XCTFail("Expected deferred memory-pressure eviction to release models after the active stream.")
        } catch let error as FluidAudioStreamingSpeakerDiarizerError {
            guard case .modelAssetsMissing = error else {
                return XCTFail("Unexpected FluidAudio streaming error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testStreamingDiarizerMapsModelInstallProgress() {
        let progress = FluidAudioModelInstallDiagnostics.mapProgress(DownloadUtils.DownloadProgress(
            fractionCompleted: 0.25,
            phase: .downloading(completedFiles: 1, totalFiles: 4)
        ))

        XCTAssertEqual(progress.fractionCompleted, 0.25)
        XCTAssertEqual(progress.phase, .downloading(completedFiles: 1, totalFiles: 4))
    }

    func testStreamingDiarizerAcceptsBackendSpecificComputeUnits() {
        let diarizer = FluidAudioStreamingSpeakerDiarizer(computeUnits: FluidAudioStreamingComputeUnits(
            sortformer: .cpuOnly,
            lsEEND: .cpuAndGPU
        ))

        XCTAssertNotNil(diarizer)
    }

    func testStreamingDiarizerClassifiesInstallFailures() {
        let download = FluidAudioStreamingSpeakerDiarizer.installError(
            from: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [
                NSLocalizedDescriptionKey: "The download timed out."
            ])
        )
        guard case .modelDownloadFailed = download else {
            return XCTFail("Expected download failure, got \(download)")
        }

        let lowDisk = FluidAudioStreamingSpeakerDiarizer.installError(
            from: NSError(domain: NSPOSIXErrorDomain, code: 28, userInfo: [
                NSLocalizedDescriptionKey: "No space left on device."
            ])
        )
        guard case .lowDiskSpace = lowDisk else {
            return XCTFail("Expected low disk failure, got \(lowDisk)")
        }

        let compileTimeout = FluidAudioStreamingSpeakerDiarizer.installError(
            from: NSError(domain: "CoreML", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "CoreML model compilation timed out."
            ])
        )
        guard case .modelCompilationTimeout = compileTimeout else {
            return XCTFail("Expected compilation timeout, got \(compileTimeout)")
        }
    }

    func testLiveFluidAudioDiarization() async throws {
        guard ProcessInfo.processInfo.environment["RUN_HEAVY_DIARIZATION_TESTS"] == "1" else {
            throw XCTSkip("Skipping heavy diarization tests. Set RUN_HEAVY_DIARIZATION_TESTS=1 to enable.")
        }

        let diarizer = FluidAudioSpeakerDiarizer()
        try await diarizer.installModels()

        let audioURL = try packageRoot().appendingPathComponent("Vendor/whisper.cpp/samples/jfk.wav")
        let audio = try await AudioResampler16kMono().prepareFile(at: audioURL)
        let result = try await diarizer.diarize(
            audio: audio,
            options: DiarizationOptions(minimumTurnDuration: 0.1)
        )

        XCTAssertEqual(result.backend?.kind, .fluidAudio)
        XCTAssertGreaterThan(result.duration, 0)
        XCTAssertGreaterThanOrEqual(result.turns.count, 1)
    }

    func testLiveFluidAudioStreamingSortformerDiarization() async throws {
        guard ProcessInfo.processInfo.environment["RUN_HEAVY_DIARIZATION_TESTS"] == "1" else {
            throw XCTSkip("Skipping heavy diarization tests. Set RUN_HEAVY_DIARIZATION_TESTS=1 to enable.")
        }

        let diarizer = FluidAudioStreamingSpeakerDiarizer()
        try await diarizer.installModels(backend: .sortformer)

        let audioURL = try packageRoot().appendingPathComponent("Vendor/whisper.cpp/samples/jfk.wav")
        let audio = try await AudioResampler16kMono().prepareFile(at: audioURL)
        let chunkSize = 8_000
        let started = Date()
        let stream = diarizer.stream(
            audio: AsyncThrowingStream<AudioChunk, Error> { continuation in
                var start = 0
                while start < audio.samples.count {
                    let end = min(start + chunkSize, audio.samples.count)
                    continuation.yield(AudioChunk(
                        samples: Array(audio.samples[start..<end]),
                        sampleRate: audio.sampleRate,
                        channelCount: 1,
                        startTime: Double(start) / audio.sampleRate
                    ))
                    start = end
                }
                continuation.finish()
            },
            options: StreamingDiarizationOptions(options: DiarizationOptions(minimumTurnDuration: 0.1))
        )

        var snapshots: [StreamingDiarizationSnapshot] = []
        for try await snapshot in stream {
            snapshots.append(snapshot)
        }

        let processingDuration = Date().timeIntervalSince(started)
        XCTAssertFalse(snapshots.isEmpty)
        XCTAssertTrue(snapshots.contains { !$0.diarization.turns.isEmpty })
        XCTAssertLessThan(processingDuration / max(audio.duration, 0.001), 1.0)
    }

    func testLiveFluidAudioStreamingLSEENDDiarization() async throws {
        guard ProcessInfo.processInfo.environment["RUN_HEAVY_DIARIZATION_TESTS"] == "1" else {
            throw XCTSkip("Skipping heavy diarization tests. Set RUN_HEAVY_DIARIZATION_TESTS=1 to enable.")
        }

        let diarizer = FluidAudioStreamingSpeakerDiarizer()
        try await diarizer.installModels(backend: .lsEEND)

        let audioURL = try packageRoot().appendingPathComponent("Vendor/whisper.cpp/samples/jfk.wav")
        let audio = try await AudioResampler16kMono().prepareFile(at: audioURL)
        let chunkSize = 8_000
        let stream = diarizer.stream(
            audio: AsyncThrowingStream<AudioChunk, Error> { continuation in
                var start = 0
                while start < audio.samples.count {
                    let end = min(start + chunkSize, audio.samples.count)
                    continuation.yield(AudioChunk(
                        samples: Array(audio.samples[start..<end]),
                        sampleRate: audio.sampleRate,
                        channelCount: 1,
                        startTime: Double(start) / audio.sampleRate
                    ))
                    start = end
                }
                continuation.finish()
            },
            options: StreamingDiarizationOptions(
                options: DiarizationOptions(minimumTurnDuration: 0.1),
                backend: .lsEEND
            )
        )

        var snapshots: [StreamingDiarizationSnapshot] = []
        for try await snapshot in stream {
            snapshots.append(snapshot)
        }

        XCTAssertFalse(snapshots.isEmpty)
        XCTAssertTrue(snapshots.contains { !$0.diarization.turns.isEmpty })
    }
}

private final class TestFluidStreamingDiarizerFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var diarizers: [TestFluidStreamingDiarizer]
    private(set) var makeCount = 0

    init(diarizers: [TestFluidStreamingDiarizer]) {
        self.diarizers = diarizers
    }

    func makeDiarizer() throws -> any Diarizer {
        lock.lock()
        defer { lock.unlock() }

        guard !diarizers.isEmpty else {
            throw NSError(domain: "TestFluidStreamingDiarizerFactory", code: 1)
        }
        makeCount += 1
        return diarizers.removeFirst()
    }
}

private final class TestFluidStreamingDiarizer: Diarizer {
    var isAvailable: Bool { true }
    var numFramesProcessed: Int { 0 }
    var targetSampleRate: Int? { 16_000 }
    var modelFrameHz: Double? { 10 }
    var numSpeakers: Int? { 4 }
    private(set) var cleanupCount = 0
    private(set) var timeline = DiarizerTimeline(config: .sortformerDefault)

    private let processedExpectation: XCTestExpectation?

    init(processedExpectation: XCTestExpectation? = nil) {
        self.processedExpectation = processedExpectation
    }

    func addAudio<C: Collection>(_ samples: C, sourceSampleRate: Double?) throws where C.Element == Float {
        _ = samples
        _ = sourceSampleRate
    }

    func process() throws -> DiarizerTimelineUpdate? {
        processedExpectation?.fulfill()
        return nil
    }

    func process<C: Collection>(
        samples: C,
        sourceSampleRate: Double?
    ) throws -> DiarizerTimelineUpdate? where C.Element == Float {
        try addAudio(samples, sourceSampleRate: sourceSampleRate)
        return try process()
    }

    func processComplete<C: Collection>(
        _ samples: C,
        sourceSampleRate: Double?,
        keepingEnrolledSpeakers keepSpeakers: Bool?,
        finalizeOnCompletion: Bool,
        progressCallback: ((Int, Int, Int) -> Void)?
    ) throws -> DiarizerTimeline where C.Element == Float {
        _ = samples
        _ = sourceSampleRate
        _ = keepSpeakers
        _ = finalizeOnCompletion
        progressCallback?(0, 0, 0)
        return timeline
    }

    func processComplete(
        audioFileURL: URL,
        keepingEnrolledSpeakers keepSpeakers: Bool?,
        finalizeOnCompletion: Bool,
        progressCallback: ((Int, Int, Int) -> Void)?
    ) throws -> DiarizerTimeline {
        _ = audioFileURL
        _ = keepSpeakers
        _ = finalizeOnCompletion
        progressCallback?(0, 0, 0)
        return timeline
    }

    func reset() {
        timeline = DiarizerTimeline(config: .sortformerDefault)
    }

    func cleanup() {
        cleanupCount += 1
    }

    func enrollSpeaker<C: Collection>(
        withAudio samples: C,
        sourceSampleRate: Double?,
        named name: String?,
        overwritingAssignedSpeakerName overwriteAssignedSpeakerName: Bool
    ) throws -> DiarizerSpeaker? where C.Element == Float {
        _ = samples
        _ = sourceSampleRate
        _ = name
        _ = overwriteAssignedSpeakerName
        return nil
    }

    func finalizeSession() throws -> DiarizerTimelineUpdate? {
        nil
    }
}
