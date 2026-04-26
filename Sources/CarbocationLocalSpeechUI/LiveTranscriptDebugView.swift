import CarbocationLocalSpeech
import SwiftUI

public struct LiveTranscriptDebugView: View {
    public var events: [TranscriptEvent]
    private var transcriptEvents: [TranscriptEvent]

    public init(events: [TranscriptEvent], transcriptEvents: [TranscriptEvent]? = nil) {
        self.events = events
        self.transcriptEvents = transcriptEvents ?? events
    }

    public var body: some View {
        let snapshot = LiveTranscriptDebugSnapshot(events: transcriptEvents)

        VStack(spacing: 0) {
            transcriptPanel(snapshot)
            Divider()
            eventStream
        }
    }

    private func transcriptPanel(_ snapshot: LiveTranscriptDebugSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Label("Transcript", systemImage: "text.quote")
                    .font(.headline)

                Spacer(minLength: 12)

                HStack(spacing: 14) {
                    metric("Segments", "\(snapshot.segmentCount)")
                    if let processedDuration = snapshot.processedDuration {
                        metric("Audio", Self.format(processedDuration))
                    }
                    if let realTimeFactor = snapshot.realTimeFactor {
                        metric("RTF", Self.format(realTimeFactor))
                    }
                }
            }

            ScrollView {
                Text(snapshot.transcriptText.isEmpty ? "Waiting for speech..." : snapshot.transcriptText)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(snapshot.transcriptText.isEmpty ? .secondary : .primary)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 8)
            }
            .frame(minHeight: 88, maxHeight: 150)

            if let latestText = snapshot.latestText {
                Divider()
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Label(snapshot.hasPendingPartial ? "Live" : "Latest", systemImage: snapshot.hasPendingPartial ? "waveform" : "checkmark.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(snapshot.hasPendingPartial ? Color.accentColor : Color.secondary)
                        .labelStyle(.titleAndIcon)

                    Text(latestText)
                        .font(.callout)
                        .lineLimit(2)
                        .textSelection(.enabled)

                    Spacer(minLength: 8)

                    if let latestTimeRange = snapshot.latestTimeRange {
                        Text(latestTimeRange)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospaced())
                .lineLimit(1)
        }
    }

    @ViewBuilder private var eventStream: some View {
        if events.isEmpty {
            ContentUnavailableView {
                Label("No Transcript Events", systemImage: "waveform.path.ecg")
            } description: {
                Text("Provider activity will appear here.")
            }
        } else {
            ScrollView {
                Text(events.map(Self.describe).joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
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
        case .diagnostic(let diagnostic):
            let time = diagnostic.time.map { " \(format($0))" } ?? ""
            return "debug \(diagnostic.source)\(time) \(diagnostic.message)"
        case .snapshot(let snapshot):
            let committedCount = snapshot.committed.segments.count
            if let unconfirmed = snapshot.unconfirmed, !unconfirmed.text.isEmpty {
                return "snapshot committed=\(committedCount) live \(unconfirmed.text)"
            }
            return "snapshot committed=\(committedCount)"
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

struct LiveTranscriptDebugSnapshot: Equatable {
    var committedSegments: [TranscriptSegment] = []
    var pendingPartial: TranscriptPartial?
    var processedDuration: TimeInterval?
    var realTimeFactor: Double?

    init(events: [TranscriptEvent]) {
        for event in events {
            apply(event)
        }
    }

    var transcriptText: String {
        let committedText = committedSegments
            .map(\.text)
            .map(Self.trim)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard let partialText = pendingPartial.map({ Self.trim($0.text) }), !partialText.isEmpty else {
            return committedText
        }

        guard !committedText.isEmpty else {
            return partialText
        }

        return "\(committedText) \(partialText)"
    }

    var latestText: String? {
        if let partialText = pendingPartial.map({ Self.trim($0.text) }), !partialText.isEmpty {
            return partialText
        }

        if let segmentText = committedSegments.last.map({ Self.trim($0.text) }), !segmentText.isEmpty {
            return segmentText
        }

        return nil
    }

    var latestTimeRange: String? {
        if let pendingPartial {
            return Self.formatTimeRange(start: pendingPartial.startTime, end: pendingPartial.endTime)
        }

        if let lastSegment = committedSegments.last {
            return Self.formatTimeRange(start: lastSegment.startTime, end: lastSegment.endTime)
        }

        return nil
    }

    var hasPendingPartial: Bool {
        guard let pendingPartial else { return false }
        return !Self.trim(pendingPartial.text).isEmpty
    }

    var segmentCount: Int {
        committedSegments.count
    }

    private mutating func apply(_ event: TranscriptEvent) {
        switch event {
        case .snapshot(let snapshot):
            committedSegments = snapshot.committed.segments.filter { !Self.trim($0.text).isEmpty }
            pendingPartial = snapshot.unconfirmed
        case .partial(let partial):
            pendingPartial = partial
        case .revision(let revision):
            pendingPartial = revision.replacement
        case .committed(let segment):
            if !Self.trim(segment.text).isEmpty {
                committedSegments.append(segment)
            }
            pendingPartial = nil
        case .progress(let progress):
            processedDuration = progress.processedDuration
        case .stats(let stats):
            realTimeFactor = stats.realTimeFactor
        case .completed(let transcript):
            let nonEmptySegments = transcript.segments.filter { !Self.trim($0.text).isEmpty }
            if !nonEmptySegments.isEmpty {
                committedSegments = nonEmptySegments
            }
            pendingPartial = nil
        case .started, .audioLevel, .voiceActivity, .diagnostic:
            break
        }
    }

    private static func trim(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func formatTimeRange(start: TimeInterval, end: TimeInterval) -> String {
        "\(format(start))-\(format(end))"
    }

    private static func format(_ value: TimeInterval) -> String {
        String(format: "%.2f", value)
    }
}
