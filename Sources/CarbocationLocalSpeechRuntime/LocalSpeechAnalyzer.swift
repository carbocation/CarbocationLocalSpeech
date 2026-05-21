import CarbocationLocalSpeech
import Foundation

public actor LocalSpeechAnalyzer: Sendable {
    private let transcriber: any SpeechTranscriber
    private let diarizer: (any SpeakerDiarizer)?

    public init(
        transcriber: any SpeechTranscriber,
        diarizer: (any SpeakerDiarizer)? = nil
    ) {
        self.transcriber = transcriber
        self.diarizer = diarizer
    }

    public func analyze(file url: URL, options: SpeechAnalysisOptions) async throws -> SpeechAnalysisResult {
        try options.diarization?.options.validate()
        guard options.diarization == nil || diarizer != nil else {
            throw SpeechAnalysisError.unsupportedFeature(
                "Diarization was requested, but no speaker diarizer is registered."
            )
        }

        let audio = try await AudioResampler16kMono().prepareFile(at: url)
        return try await analyze(audio: audio, options: options)
    }

    public func analyze(audio: PreparedAudio, options: SpeechAnalysisOptions) async throws -> SpeechAnalysisResult {
        try options.diarization?.options.validate()
        guard options.diarization == nil || diarizer != nil else {
            throw SpeechAnalysisError.unsupportedFeature(
                "Diarization was requested, but no speaker diarizer is registered."
            )
        }

        let activeTranscriber = transcriber
        let activeDiarizer = diarizer

        return try await withThrowingTaskGroup(of: SpeechAnalysisSubResult.self) { group in
            group.addTask {
                let transcript = try await activeTranscriber.transcribe(
                    audio: audio,
                    options: options.transcription
                )
                return .transcript(transcript)
            }

            if let diarizationRequest = options.diarization,
               let registeredDiarizer = activeDiarizer {
                group.addTask {
                    let diarization = try await registeredDiarizer.diarize(
                        audio: audio,
                        options: diarizationRequest.options
                    )
                    return .diarization(diarization)
                }
            }

            var transcript: Transcript?
            var diarization: DiarizationResult?

            while let subResult = try await group.next() {
                switch subResult {
                case .transcript(let value):
                    transcript = value
                case .diarization(let value):
                    diarization = value
                }
            }

            var attributedResult: SpeakerAttributionMergeResult?
            if let transcript,
               let diarization,
               let diarizationRequest = options.diarization {
                attributedResult = SpeakerAttributionMerger.merge(
                    transcript: transcript,
                    diarization: diarization,
                    policy: diarizationRequest.policy
                )
            }

            let diagnostics = (transcript?.backend != nil
                ? [SpeechDiagnostic(source: "analyzer", message: "Cooperative ASR finished")]
                : []
            ) + (diarization?.diagnostics ?? []) + (attributedResult?.diagnostics ?? [])
            return SpeechAnalysisResult(
                transcript: transcript,
                diarization: diarization,
                speakerAttributedTranscript: attributedResult?.transcript,
                diagnostics: diagnostics
            )
        }
    }
}

private enum SpeechAnalysisSubResult: Sendable {
    case transcript(Transcript)
    case diarization(DiarizationResult)
}
