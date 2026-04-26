import CarbocationLocalSpeech
import SwiftUI

public struct LiveTranscriptDebugView: View {
    public var events: [TranscriptEvent]

    public init(events: [TranscriptEvent]) {
        self.events = events
    }

    public var body: some View {
        List(events.indices, id: \.self) { index in
            Text(Self.describe(events[index]))
                .font(.system(.caption, design: .monospaced))
        }
    }

    private static func describe(_ event: TranscriptEvent) -> String {
        switch event {
        case .started(let backend):
            return "started \(backend.displayName)"
        case .audioLevel(let level):
            return "level rms=\(format(level.rms)) peak=\(format(level.peak))"
        case .voiceActivity(let event):
            return "vad \(event.state.rawValue) \(format(event.startTime))-\(format(event.endTime))"
        case .partial(let partial):
            return "partial \(partial.text)"
        case .revision(let revision):
            return "revision \(revision.replacesPartialID.uuidString) -> \(revision.replacement.text)"
        case .committed(let segment):
            return "committed \(segment.text)"
        case .progress(let progress):
            return "progress \(format(progress.processedDuration))"
        case .stats(let stats):
            return "stats rtf=\(stats.realTimeFactor.map(format) ?? "n/a") segments=\(stats.segmentCount)"
        case .completed(let transcript):
            return "completed \(transcript.segments.count) segments"
        }
    }

    private static func format(_ value: Float) -> String {
        String(format: "%.3f", value)
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
