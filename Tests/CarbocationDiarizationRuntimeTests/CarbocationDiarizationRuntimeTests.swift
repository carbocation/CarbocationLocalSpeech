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
}
