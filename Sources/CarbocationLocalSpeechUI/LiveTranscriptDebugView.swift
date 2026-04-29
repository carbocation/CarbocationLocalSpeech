import CarbocationLocalSpeech
import SwiftUI

#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public struct LiveTranscriptDebugView: View {
    public var events: [TranscriptEvent]
    private var eventDescriptions: [String]?
    private var totalEventDescriptionCount: Int?
    private var copyAllEventDescriptions: (() -> Void)?
    private var copyTranscriptAction: (() -> Void)?
    private var transcriptEvents: [TranscriptEvent]
    private var snapshot: LiveTranscriptDebugSnapshot?
    private let liveEventLineLimit = 50
    private let transcriptPanelHeightRatio: CGFloat = 0.67

    public init(events: [TranscriptEvent], transcriptEvents: [TranscriptEvent]? = nil) {
        self.events = events
        self.eventDescriptions = nil
        self.totalEventDescriptionCount = nil
        self.copyAllEventDescriptions = nil
        self.copyTranscriptAction = nil
        self.transcriptEvents = transcriptEvents ?? events
        self.snapshot = nil
    }

    public init(
        eventDescriptions: [String],
        snapshot: LiveTranscriptDebugSnapshot,
        totalEventDescriptionCount: Int? = nil,
        copyAllEventDescriptions: (() -> Void)? = nil,
        copyTranscript: (() -> Void)? = nil
    ) {
        self.events = []
        self.eventDescriptions = eventDescriptions
        self.totalEventDescriptionCount = totalEventDescriptionCount
        self.copyAllEventDescriptions = copyAllEventDescriptions
        self.copyTranscriptAction = copyTranscript
        self.transcriptEvents = []
        self.snapshot = snapshot
    }

    public var body: some View {
        let snapshot = snapshot ?? LiveTranscriptDebugSnapshot(events: transcriptEvents)

        GeometryReader { geometry in
            let availableHeight = max(geometry.size.height - 1, 0)
            let transcriptHeight = availableHeight * transcriptPanelHeightRatio
            let eventStreamHeight = availableHeight - transcriptHeight

            VStack(spacing: 0) {
                transcriptPanel(snapshot)
                    .frame(height: transcriptHeight)
                    .frame(maxWidth: .infinity)
                Divider()
                eventStream
                    .frame(height: eventStreamHeight)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func transcriptPanel(_ snapshot: LiveTranscriptDebugSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Label("Transcript", systemImage: "text.quote")
                    .font(.headline)

                Spacer(minLength: 12)

                if snapshot.hasTranscriptText {
                    Button {
                        if let copyTranscriptAction {
                            copyTranscriptAction()
                        } else {
                            copyTranscript(snapshot)
                        }
                    } label: {
                        Label("Copy Transcript", systemImage: "doc.on.doc")
                    }
                    .controlSize(.small)
                }

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
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 8)
            }
            .frame(minHeight: 0, maxHeight: .infinity)

            if let latestText = snapshot.latestDisplayText {
                Divider()
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Label(snapshot.hasVolatileText ? "Live" : "Latest", systemImage: snapshot.hasVolatileText ? "waveform" : "checkmark.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(snapshot.hasVolatileText ? Color.accentColor : Color.secondary)
                        .labelStyle(.titleAndIcon)

                    Text(latestText)
                        .font(.callout)
                        .lineLimit(2)

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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(CLSPlatformColor.textBackground)
    }

    @ViewBuilder private func transcriptText(_ snapshot: LiveTranscriptDebugSnapshot) -> some View {
        let stableText = snapshot.stableDisplayText
        let volatileText = snapshot.volatileDisplayText

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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(CLSPlatformColor.windowBackground)
        } else {
            let liveLines = Array(lines.suffix(liveEventLineLimit))
            let totalLineCount = totalEventDescriptionCount ?? lines.count
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Label("Live Log", systemImage: "list.bullet.rectangle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("\(liveLines.count)/\(totalLineCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Button {
                        if let copyAllEventDescriptions {
                            copyAllEventDescriptions()
                        } else {
                            copyEventLogLines(lines)
                        }
                    } label: {
                        Label("Copy All", systemImage: "doc.on.doc")
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
                LiveEventLogTailView(lines: liveLines)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(CLSPlatformColor.windowBackground)
        }
    }

    private var eventLogLines: [String] {
        if let eventDescriptions {
            return eventDescriptions
        }
        return events.map(Self.describe)
    }

    private func copyEventLogLines(_ lines: [String]) {
        copyToPasteboard(lines.joined(separator: "\n"))
    }

    private func copyTranscript(_ snapshot: LiveTranscriptDebugSnapshot) {
        copyToPasteboard(snapshot.transcriptText)
    }

    private func copyToPasteboard(_ text: String) {
#if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
#elseif canImport(UIKit)
        UIPasteboard.general.string = text
#else
        _ = text
#endif
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

private enum CLSPlatformColor {
    static var textBackground: Color {
#if os(macOS)
        Color(nsColor: .textBackgroundColor)
#elseif canImport(UIKit)
        Color(uiColor: .systemBackground)
#else
        Color(.background)
#endif
    }

    static var windowBackground: Color {
#if os(macOS)
        Color(nsColor: .windowBackgroundColor)
#elseif canImport(UIKit)
        Color(uiColor: .secondarySystemBackground)
#else
        Color(.background)
#endif
    }
}

private struct LiveEventLogTailView: View {
    var lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(12)
            }
            .onAppear {
                scrollToBottom(proxy)
            }
            .onChange(of: lines) {
                scrollToBottom(proxy)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let lastIndex = lines.indices.last else { return }
        proxy.scrollTo(lastIndex, anchor: .bottom)
    }
}

public struct LiveTranscriptDebugSnapshot: Equatable {
    public private(set) var stableText = ""
    public private(set) var volatileText = ""
    public private(set) var stableDisplayText = ""
    public private(set) var volatileDisplayText = ""
    public private(set) var processedDuration: TimeInterval?
    public private(set) var realTimeFactor: Double?
    public private(set) var segmentCount = 0

    private var stableSnapshotSignature = StableSnapshotSignature()
    private var latestStableText: String?
    private var latestStableDisplayText: String?
    private var latestStableTimeRange: String?
    private var volatileTimeRange: String?

    private static let stableDisplayCharacterLimit = 1_500
    private static let volatileDisplayCharacterLimit = 700
    private static let latestDisplayCharacterLimit = 300

    private struct StableSnapshotSignature: Equatable {
        var segmentCount = 0
        var lastSegmentID: UUID?
        var lastSegmentText = ""
        var lastSegmentStartTime: TimeInterval = 0
        var lastSegmentEndTime: TimeInterval = 0
    }

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

    public var hasTranscriptText: Bool {
        !stableText.isEmpty || !volatileText.isEmpty
    }

    public var latestText: String? {
        if !volatileText.isEmpty {
            return volatileText
        }

        return latestStableText
    }

    public var latestDisplayText: String? {
        if !volatileDisplayText.isEmpty {
            return volatileDisplayText
        }

        return latestStableDisplayText
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
                applyStableSegments(snapshot.stable.segments, signature: signature)
            }
            applyVolatileTranscript(snapshot.volatile)
        case .progress(let progress):
            processedDuration = progress.processedDuration
        case .stats(let stats):
            realTimeFactor = stats.realTimeFactor
        case .completed(let transcript):
            let nonEmptySegments = transcript.segments.filter { !Self.trim($0.text).isEmpty }
            if !nonEmptySegments.isEmpty && nonEmptySegments.count != segmentCount {
                applyStableSegments(
                    transcript.segments,
                    signature: Self.stableSnapshotSignature(for: transcript.segments)
                )
            }
            applyVolatileTranscript(nil)
        case .started, .audioLevel, .voiceActivity, .diagnostic:
            break
        }
    }

    private mutating func applyStableSegments(_ segments: [TranscriptSegment], signature: StableSnapshotSignature) {
        guard !appendStableSegmentsIfPossible(segments, signature: signature) else { return }

        let nonEmptySegments = segments.compactMap { segment -> (segment: TranscriptSegment, text: String)? in
            let text = Self.trim(segment.text)
            guard !text.isEmpty else { return nil }
            return (segment, text)
        }

        stableText = nonEmptySegments.map(\.text).joined(separator: " ")
        stableDisplayText = Self.displayText(stableText, characterLimit: Self.stableDisplayCharacterLimit)
        segmentCount = nonEmptySegments.count
        stableSnapshotSignature = signature

        if let latest = nonEmptySegments.last {
            applyLatestStableSegment(latest.segment, text: latest.text)
        } else {
            latestStableText = nil
            latestStableDisplayText = nil
            latestStableTimeRange = nil
        }
    }

    private mutating func appendStableSegmentsIfPossible(
        _ segments: [TranscriptSegment],
        signature: StableSnapshotSignature
    ) -> Bool {
        let previousSourceSegmentCount = stableSnapshotSignature.segmentCount
        guard signature.segmentCount >= previousSourceSegmentCount else { return false }

        if previousSourceSegmentCount > 0 {
            let previousLastIndex = previousSourceSegmentCount - 1
            guard segments.indices.contains(previousLastIndex),
                  Self.segment(segments[previousLastIndex], matches: stableSnapshotSignature) else {
                return false
            }
        }

        var appendedNonEmptyCount = 0
        for segment in segments.dropFirst(previousSourceSegmentCount) {
            let text = Self.trim(segment.text)
            guard !text.isEmpty else { continue }

            appendStableText(text)
            appendedNonEmptyCount += 1
            applyLatestStableSegment(segment, text: text)
        }

        segmentCount += appendedNonEmptyCount
        stableSnapshotSignature = signature
        return true
    }

    private mutating func appendStableText(_ text: String) {
        if stableText.isEmpty {
            stableText = text
            stableDisplayText = Self.displayText(text, characterLimit: Self.stableDisplayCharacterLimit)
        } else {
            stableText += " " + text
            stableDisplayText = Self.displayText(
                stableDisplayText + " " + text,
                characterLimit: Self.stableDisplayCharacterLimit
            )
        }
    }

    private mutating func applyLatestStableSegment(_ segment: TranscriptSegment, text: String) {
        latestStableText = text
        latestStableDisplayText = Self.displayText(text, characterLimit: Self.latestDisplayCharacterLimit)
        latestStableTimeRange = Self.formatTimeRange(
            start: segment.startTime,
            end: segment.endTime
        )
    }

    private mutating func applyVolatileTranscript(_ transcript: Transcript?) {
        guard let transcript else {
            volatileText = ""
            volatileDisplayText = ""
            volatileTimeRange = nil
            return
        }

        let segments = transcript.segments.filter { !Self.trim($0.text).isEmpty }
        guard let first = segments.first,
              let last = segments.last else {
            volatileText = ""
            volatileDisplayText = ""
            volatileTimeRange = nil
            return
        }

        volatileText = segments.map { Self.trim($0.text) }.joined(separator: " ")
        volatileDisplayText = Self.displayText(volatileText, characterLimit: Self.volatileDisplayCharacterLimit)
        volatileTimeRange = Self.formatTimeRange(start: first.startTime, end: last.endTime)
    }

    private static func trim(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func displayText(_ text: String, characterLimit: Int) -> String {
        guard text.count > characterLimit else {
            return text
        }

        return "... " + text.suffix(characterLimit).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stableSnapshotSignature(for segments: [TranscriptSegment]) -> StableSnapshotSignature {
        guard let last = segments.last else {
            return StableSnapshotSignature()
        }

        return StableSnapshotSignature(
            segmentCount: segments.count,
            lastSegmentID: last.id,
            lastSegmentText: trim(last.text),
            lastSegmentStartTime: last.startTime,
            lastSegmentEndTime: last.endTime
        )
    }

    private static func segment(_ segment: TranscriptSegment, matches signature: StableSnapshotSignature) -> Bool {
        signature.lastSegmentID == segment.id &&
            signature.lastSegmentText == trim(segment.text) &&
            signature.lastSegmentStartTime == segment.startTime &&
            signature.lastSegmentEndTime == segment.endTime
    }

    private static func formatTimeRange(start: TimeInterval, end: TimeInterval) -> String {
        "\(format(start))-\(format(end))"
    }

    private static func format(_ value: TimeInterval) -> String {
        String(format: "%.2f", value)
    }
}
