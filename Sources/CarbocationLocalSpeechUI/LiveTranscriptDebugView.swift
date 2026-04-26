import CarbocationLocalSpeech
import AppKit
import SwiftUI

public struct LiveTranscriptDebugView: View {
    public var events: [TranscriptEvent]
    private var eventDescriptions: [String]?
    private var transcriptEvents: [TranscriptEvent]
    private var snapshot: LiveTranscriptDebugSnapshot?

    public init(events: [TranscriptEvent], transcriptEvents: [TranscriptEvent]? = nil) {
        self.events = events
        self.eventDescriptions = nil
        self.transcriptEvents = transcriptEvents ?? events
        self.snapshot = nil
    }

    public init(eventDescriptions: [String], snapshot: LiveTranscriptDebugSnapshot) {
        self.events = []
        self.eventDescriptions = eventDescriptions
        self.transcriptEvents = []
        self.snapshot = snapshot
    }

    public var body: some View {
        let snapshot = snapshot ?? LiveTranscriptDebugSnapshot(events: transcriptEvents)

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
                transcriptText(snapshot)
                    .font(.system(size: 18, weight: .medium))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 8)
            }
            .frame(minHeight: 88, maxHeight: 150)

            if let latestText = snapshot.latestText {
                Divider()
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Label(snapshot.hasVolatileText ? "Live" : "Latest", systemImage: snapshot.hasVolatileText ? "waveform" : "checkmark.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(snapshot.hasVolatileText ? Color.accentColor : Color.secondary)
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

    @ViewBuilder private func transcriptText(_ snapshot: LiveTranscriptDebugSnapshot) -> some View {
        let stableText = snapshot.stableText
        let volatileText = snapshot.volatileText

        if stableText.isEmpty && volatileText.isEmpty {
            Text("Waiting for speech...")
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if !stableText.isEmpty {
                    transcriptRun(
                        stableText,
                        backgroundColor: Color.green.opacity(0.16)
                    )
                }

                if !volatileText.isEmpty {
                    transcriptRun(
                        volatileText,
                        backgroundColor: Color.accentColor.opacity(0.18)
                    )
                }
            }
        }
    }

    private func transcriptRun(_ text: String, backgroundColor: Color) -> some View {
        Text(text)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(backgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 4))
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
        let lines = eventLogLines
        if lines.isEmpty {
            ContentUnavailableView {
                Label("No Transcript Events", systemImage: "waveform.path.ecg")
            } description: {
                Text("Provider activity will appear here.")
            }
        } else {
            SelectableEventLogView(lines: lines)
        }
    }

    private var eventLogLines: [String] {
        if let eventDescriptions {
            return eventDescriptions
        }
        return events.map(Self.describe)
    }

    public static func describe(_ event: TranscriptEvent) -> String {
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
            let stableCount = snapshot.stable.segments.count
            if let volatileText = snapshot.volatile?.text, !volatileText.isEmpty {
                return "snapshot stable=\(stableCount) volatile \(volatileText)"
            }
            return "snapshot stable=\(stableCount)"
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

private struct SelectableEventLogView: NSViewRepresentable {
    var lines: [String]

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(lines, in: scrollView)
    }

    final class Coordinator {
        weak var textView: NSTextView?
        private var renderedLines: [String] = []

        func update(_ lines: [String], in scrollView: NSScrollView) {
            guard let textView else { return }

            if lines.isEmpty {
                guard !renderedLines.isEmpty else { return }
                textView.string = ""
                renderedLines.removeAll(keepingCapacity: true)
                return
            }

            if canAppend(lines) {
                append(Array(lines.dropFirst(renderedLines.count)), to: textView, in: scrollView)
            } else if let overlapCount = suffixPrefixOverlapCount(previous: renderedLines, current: lines),
                      overlapCount > 0 {
                removeRenderedPrefix(renderedLines.count - overlapCount, from: textView)
                append(Array(lines.dropFirst(overlapCount)), to: textView, in: scrollView)
            } else {
                textView.string = lines.joined(separator: "\n")
                renderedLines = lines
                scrollToBottom(scrollView)
            }
        }

        private func canAppend(_ lines: [String]) -> Bool {
            guard lines.count >= renderedLines.count else { return false }
            return zip(renderedLines, lines).allSatisfy(==)
        }

        private func suffixPrefixOverlapCount(previous: [String], current: [String]) -> Int? {
            let maximumOverlap = min(previous.count, current.count)
            guard maximumOverlap > 0 else { return nil }

            for count in stride(from: maximumOverlap, through: 1, by: -1) {
                if Array(previous.suffix(count)) == Array(current.prefix(count)) {
                    return count
                }
            }

            return nil
        }

        private func removeRenderedPrefix(_ count: Int, from textView: NSTextView) {
            guard count > 0, count <= renderedLines.count else { return }
            let removedTextLength = renderedLines.prefix(count).joined(separator: "\n").utf16.count
            let separatorLength = count < renderedLines.count ? 1 : 0
            textView.textStorage?.deleteCharacters(in: NSRange(
                location: 0,
                length: removedTextLength + separatorLength
            ))
            renderedLines.removeFirst(count)
        }

        private func append(_ newLines: [String], to textView: NSTextView, in scrollView: NSScrollView) {
            guard !newLines.isEmpty else { return }

            let prefix = renderedLines.isEmpty ? "" : "\n"
            let appendedText = prefix + newLines.joined(separator: "\n")
            textView.textStorage?.append(NSAttributedString(string: appendedText, attributes: attributes(for: textView)))
            renderedLines.append(contentsOf: newLines)
            scrollToBottom(scrollView)
        }

        private func attributes(for textView: NSTextView) -> [NSAttributedString.Key: Any] {
            var attributes: [NSAttributedString.Key: Any] = [:]
            if let font = textView.font {
                attributes[.font] = font
            }
            if let textColor = textView.textColor {
                attributes[.foregroundColor] = textColor
            }
            return attributes
        }

        private func scrollToBottom(_ scrollView: NSScrollView) {
            textView?.scrollRangeToVisible(NSRange(location: textView?.string.utf16.count ?? 0, length: 0))
        }
    }
}

public struct LiveTranscriptDebugSnapshot: Equatable {
    public private(set) var stableText = ""
    public private(set) var volatileText = ""
    public private(set) var processedDuration: TimeInterval?
    public private(set) var realTimeFactor: Double?
    public private(set) var segmentCount = 0

    private var stableSnapshotSignature = ""
    private var latestStableText: String?
    private var latestStableTimeRange: String?
    private var volatileTimeRange: String?

    public init(events: [TranscriptEvent] = []) {
        for event in events {
            apply(event)
        }
    }

    public var transcriptText: String {
        guard !volatileText.isEmpty else {
            return stableText
        }

        guard !stableText.isEmpty else {
            return volatileText
        }

        return "\(stableText) \(volatileText)"
    }

    public var latestText: String? {
        if !volatileText.isEmpty {
            return volatileText
        }

        return latestStableText
    }

    public var latestTimeRange: String? {
        if !volatileText.isEmpty {
            return volatileTimeRange
        }

        return latestStableTimeRange
    }

    public var hasVolatileText: Bool {
        !volatileText.isEmpty
    }

    public mutating func apply(_ event: TranscriptEvent) {
        switch event {
        case .snapshot(let snapshot):
            let signature = Self.stableSnapshotSignature(for: snapshot.stable.segments)
            if signature != stableSnapshotSignature {
                applyStableSegments(snapshot.stable.segments)
            }
            applyVolatileTranscript(snapshot.volatile)
        case .progress(let progress):
            processedDuration = progress.processedDuration
        case .stats(let stats):
            realTimeFactor = stats.realTimeFactor
        case .completed(let transcript):
            let nonEmptySegments = transcript.segments.filter { !Self.trim($0.text).isEmpty }
            if !nonEmptySegments.isEmpty && nonEmptySegments.count != segmentCount {
                applyStableSegments(nonEmptySegments)
            }
            applyVolatileTranscript(nil)
        case .started, .audioLevel, .voiceActivity, .diagnostic:
            break
        }
    }

    private mutating func applyStableSegments(_ segments: [TranscriptSegment]) {
        let nonEmptySegments = segments.compactMap { segment -> (segment: TranscriptSegment, text: String)? in
            let text = Self.trim(segment.text)
            guard !text.isEmpty else { return nil }
            return (segment, text)
        }

        stableText = nonEmptySegments.map(\.text).joined(separator: " ")
        segmentCount = nonEmptySegments.count
        stableSnapshotSignature = Self.stableSnapshotSignature(for: nonEmptySegments.map(\.segment))

        if let latest = nonEmptySegments.last {
            latestStableText = latest.text
            latestStableTimeRange = Self.formatTimeRange(
                start: latest.segment.startTime,
                end: latest.segment.endTime
            )
        } else {
            latestStableText = nil
            latestStableTimeRange = nil
        }
    }

    private mutating func applyVolatileTranscript(_ transcript: Transcript?) {
        guard let transcript else {
            volatileText = ""
            volatileTimeRange = nil
            return
        }

        let segments = transcript.segments.filter { !Self.trim($0.text).isEmpty }
        guard let first = segments.first,
              let last = segments.last else {
            volatileText = ""
            volatileTimeRange = nil
            return
        }

        volatileText = segments.map { Self.trim($0.text) }.joined(separator: " ")
        volatileTimeRange = Self.formatTimeRange(start: first.startTime, end: last.endTime)
    }

    private static func trim(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stableSnapshotSignature(for segments: [TranscriptSegment]) -> String {
        segments
            .map { segment in
                "\(segment.id.uuidString)|\(trim(segment.text))|\(format(segment.startTime))|\(format(segment.endTime))"
            }
            .joined(separator: "\n")
    }

    private static func formatTimeRange(start: TimeInterval, end: TimeInterval) -> String {
        "\(format(start))-\(format(end))"
    }

    private static func format(_ value: TimeInterval) -> String {
        String(format: "%.2f", value)
    }
}
