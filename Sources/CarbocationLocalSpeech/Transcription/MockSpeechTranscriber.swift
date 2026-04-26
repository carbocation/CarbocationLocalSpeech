import Foundation

public struct MockSpeechTranscriber: SpeechTranscriber {
    public var transcript: Transcript
    public var streamEvents: [TranscriptEvent]

    public init(
        transcript: Transcript = Transcript(),
        streamEvents: [TranscriptEvent] = []
    ) {
        self.transcript = transcript
        self.streamEvents = streamEvents
    }

    public func transcribe(file url: URL, options: TranscriptionOptions) async throws -> Transcript {
        if Task.isCancelled {
            throw CancellationError()
        }
        _ = url
        _ = options
        return transcript
    }

    public func transcribe(audio: PreparedAudio, options: TranscriptionOptions) async throws -> Transcript {
        if Task.isCancelled {
            throw CancellationError()
        }
        _ = audio
        _ = options
        return transcript
    }

    public func stream(
        audio: AsyncThrowingStream<AudioChunk, Error>,
        options: StreamingTranscriptionOptions
    ) -> AsyncThrowingStream<TranscriptEvent, Error> {
        let events = streamEvents
        let transcript = transcript
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await _ in audio {
                        if Task.isCancelled {
                            throw CancellationError()
                        }
                    }
                    for event in events {
                        continuation.yield(event)
                    }
                    if !events.contains(where: { if case .completed = $0 { true } else { false } }) {
                        continuation.yield(.completed(transcript))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            _ = options
        }
    }
}
