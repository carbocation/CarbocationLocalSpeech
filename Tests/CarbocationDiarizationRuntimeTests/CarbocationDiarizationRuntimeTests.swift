import CarbocationDiarizationRuntime
import CarbocationLocalSpeech
import XCTest

@available(macOS 14.0, iOS 17.0, *)
final class CarbocationDiarizationRuntimeTests: XCTestCase {
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
}
