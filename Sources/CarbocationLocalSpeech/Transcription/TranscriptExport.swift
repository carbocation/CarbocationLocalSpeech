import Foundation

public enum TranscriptExportFormat: String, Codable, CaseIterable, Sendable {
    case srt
    case webVTT
    case markdownMinutes
    case json

    public var fileExtension: String {
        switch self {
        case .srt:
            return "srt"
        case .webVTT:
            return "vtt"
        case .markdownMinutes:
            return "md"
        case .json:
            return "json"
        }
    }

    public var mediaType: String {
        switch self {
        case .srt:
            return "application/x-subrip; charset=utf-8"
        case .webVTT:
            return "text/vtt; charset=utf-8"
        case .markdownMinutes:
            return "text/markdown; charset=utf-8"
        case .json:
            return "application/json; charset=utf-8"
        }
    }

    public var role: String {
        switch self {
        case .srt:
            return "subRipSubtitles"
        case .webVTT:
            return "webVTTSubtitles"
        case .markdownMinutes:
            return "meetingMinutes"
        case .json:
            return "portableTranscriptJSON"
        }
    }

    fileprivate var defaultBaseFileName: String {
        switch self {
        case .markdownMinutes:
            return "meeting-minutes"
        case .srt, .webVTT, .json:
            return "transcript"
        }
    }
}

public struct TranscriptSpeakerStyle: Codable, Equatable, Sendable {
    public var color: String?
    public var avatar: String?

    public init(
        color: String? = nil,
        avatar: String? = nil
    ) {
        self.color = color
        self.avatar = avatar
    }
}

public struct TranscriptExportOptions: Sendable {
    public var fileBaseName: String?
    public var speakerStyles: [SpeakerID: TranscriptSpeakerStyle]
    public var includeSpeakerLabels: Bool

    public init(
        fileBaseName: String? = nil,
        speakerStyles: [SpeakerID: TranscriptSpeakerStyle] = [:],
        includeSpeakerLabels: Bool = true
    ) {
        self.fileBaseName = fileBaseName
        self.speakerStyles = speakerStyles
        self.includeSpeakerLabels = includeSpeakerLabels
    }

    public static let standard = TranscriptExportOptions()
}

public struct TranscriptExportSource: Sendable {
    public var transcript: Transcript
    public var diarization: DiarizationResult?
    public var speakers: [Speaker]
    public var title: String?
    public var sourceFileName: String?
    public var generatedAt: Date

    public init(
        transcript: Transcript,
        diarization: DiarizationResult? = nil,
        speakers: [Speaker] = [],
        title: String? = nil,
        sourceFileName: String? = nil,
        generatedAt: Date = Date()
    ) {
        self.transcript = transcript
        self.diarization = diarization
        self.speakers = speakers
        self.title = title
        self.sourceFileName = sourceFileName
        self.generatedAt = generatedAt
    }

    public init(
        transcript: Transcript,
        analysisResult: SpeechAnalysisResult,
        title: String? = nil,
        sourceFileName: String? = nil,
        generatedAt: Date = Date()
    ) {
        self.init(
            transcript: analysisResult.speakerAttributedTranscript ?? transcript,
            diarization: analysisResult.diarization,
            speakers: analysisResult.diarization?.speakers ?? [],
            title: title,
            sourceFileName: sourceFileName,
            generatedAt: generatedAt
        )
    }

    public init(
        analysisResult: SpeechAnalysisResult,
        title: String? = nil,
        sourceFileName: String? = nil,
        generatedAt: Date = Date()
    ) throws {
        guard let transcript = analysisResult.speakerAttributedTranscript ?? analysisResult.transcript else {
            throw TranscriptExportError.missingTranscript
        }
        self.init(
            transcript: transcript,
            diarization: analysisResult.diarization,
            speakers: analysisResult.diarization?.speakers ?? [],
            title: title,
            sourceFileName: sourceFileName,
            generatedAt: generatedAt
        )
    }
}

public struct TranscriptExportArtifact: Sendable {
    public var format: TranscriptExportFormat
    public var fileName: String
    public var fileExtension: String
    public var mediaType: String
    public var role: String
    public var data: Data

    public init(
        format: TranscriptExportFormat,
        fileName: String,
        fileExtension: String,
        mediaType: String,
        role: String,
        data: Data
    ) {
        self.format = format
        self.fileName = fileName
        self.fileExtension = fileExtension
        self.mediaType = mediaType
        self.role = role
        self.data = data
    }
}

public enum TranscriptExportError: Error, Equatable, LocalizedError, Sendable {
    case missingTranscript

    public var errorDescription: String? {
        switch self {
        case .missingTranscript:
            return "No transcript is available to export."
        }
    }
}

public enum TranscriptExporter {
    public static func export(
        format: TranscriptExportFormat,
        source: TranscriptExportSource,
        options: TranscriptExportOptions = .standard
    ) throws -> TranscriptExportArtifact {
        let preparedSource = PreparedTranscriptExportSource(source: source)
        let data: Data
        switch format {
        case .srt:
            data = Data(TranscriptSRTFormatter.string(from: preparedSource, options: options).utf8)
        case .webVTT:
            data = Data(TranscriptWebVTTFormatter.string(from: preparedSource, options: options).utf8)
        case .markdownMinutes:
            data = Data(TranscriptMarkdownMinutesFormatter.string(from: preparedSource, options: options).utf8)
        case .json:
            data = try TranscriptPortableJSONFormatter.data(from: preparedSource)
        }

        return TranscriptExportArtifact(
            format: format,
            fileName: makeFileName(format: format, source: source, options: options),
            fileExtension: format.fileExtension,
            mediaType: format.mediaType,
            role: format.role,
            data: data
        )
    }

    private static func makeFileName(
        format: TranscriptExportFormat,
        source: TranscriptExportSource,
        options: TranscriptExportOptions
    ) -> String {
        let candidate = [
            options.fileBaseName,
            source.sourceFileName.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent },
            source.title,
            format.defaultBaseFileName
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? format.defaultBaseFileName

        return "\(sanitizeFileBaseName(candidate)).\(format.fileExtension)"
    }

    private static func sanitizeFileBaseName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let sanitized = value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? String(scalar) : "-"
        }
        .joined()
        .trimmingCharacters(in: CharacterSet(charactersIn: "-_."))

        return sanitized.isEmpty ? "transcript" : sanitized
    }
}

private struct PreparedTranscriptExportSource {
    var original: TranscriptExportSource
    var transcript: Transcript
    var speakers: [Speaker]
    var speakersByID: [SpeakerID: Speaker]
    var diarization: DiarizationResult?

    init(source: TranscriptExportSource) {
        let speakers = Self.mergeSpeakers(
            primary: source.speakers,
            secondary: source.diarization?.speakers ?? []
        )
        let speakersByID = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0) })

        self.original = source
        self.diarization = source.diarization
        self.speakers = speakers
        self.speakersByID = speakersByID

        if !Self.hasSpeakerAttribution(source.transcript),
           let diarization = source.diarization,
           !diarization.turns.isEmpty || !diarization.exclusiveTurns.isEmpty {
            let merge = SpeakerAttributionMerger.merge(
                transcript: source.transcript,
                diarization: diarization,
                policy: .preferExclusiveWordLevel
            )
            self.transcript = Self.hasSpeakerAttribution(merge.transcript)
                ? merge.transcript
                : source.transcript
        } else {
            self.transcript = source.transcript
        }
    }

    func speakerID(for segment: TranscriptSegment) -> SpeakerID? {
        if let speaker = segment.speaker {
            return speaker
        }

        var durationsBySpeaker: [SpeakerID: TimeInterval] = [:]
        for word in segment.words {
            guard let speaker = word.speaker else { continue }
            durationsBySpeaker[speaker, default: 0] += max(0, word.endTime - word.startTime)
        }

        return durationsBySpeaker.max { lhs, rhs in
            if abs(lhs.value - rhs.value) > 0.000_001 {
                return lhs.value < rhs.value
            }
            return lhs.key.rawValue > rhs.key.rawValue
        }?.key
    }

    func speakerLabel(for speakerID: SpeakerID?) -> String {
        SpeakerLabelFormatter.label(for: speakerID, speakersByID: speakersByID)
    }

    private static func hasSpeakerAttribution(_ transcript: Transcript) -> Bool {
        transcript.segments.contains { segment in
            segment.speaker != nil || segment.words.contains { $0.speaker != nil }
        }
    }

    private static func mergeSpeakers(primary: [Speaker], secondary: [Speaker]) -> [Speaker] {
        var speakers: [Speaker] = []
        var seen = Set<SpeakerID>()
        for speaker in primary + secondary {
            guard !seen.contains(speaker.id) else { continue }
            seen.insert(speaker.id)
            speakers.append(speaker)
        }
        return speakers
    }
}

private enum SpeakerLabelFormatter {
    static func label(for speakerID: SpeakerID?, speakersByID: [SpeakerID: Speaker]) -> String {
        guard let speakerID else {
            return "Unknown Speaker"
        }

        if let displayName = speakersByID[speakerID]?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !displayName.isEmpty {
            return displayName
        }

        let rawValue = speakerID.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawValue.isEmpty else {
            return "Unknown Speaker"
        }

        if rawValue.hasPrefix("speaker_") {
            let suffix = rawValue.dropFirst("speaker_".count)
            if !suffix.isEmpty {
                return "Speaker \(suffix)"
            }
        }

        return rawValue
    }
}

private enum TranscriptSRTFormatter {
    static func string(
        from source: PreparedTranscriptExportSource,
        options: TranscriptExportOptions
    ) -> String {
        let cueBodies = source.transcript.segments
            .compactMap { segment -> (TranscriptSegment, String)? in
                let text = TranscriptTextFormatter.normalizedInlineText(segment.text)
                guard !text.isEmpty else { return nil }
                return (segment, text)
            }
        let cues = cueBodies.enumerated().map { index, body in
            let segment = body.0
            let speakerID = source.speakerID(for: segment)
            let labeledText = options.includeSpeakerLabels
                ? "[\(source.speakerLabel(for: speakerID))] \(body.1)"
                : body.1
            return [
                "\(index + 1)",
                "\(TranscriptTimeFormatter.srt(segment.startTime)) --> \(TranscriptTimeFormatter.srt(segment.endTime))",
                labeledText
            ].joined(separator: "\n")
        }

        return TranscriptTextFormatter.joinBlocks(cues)
    }
}

private enum TranscriptWebVTTFormatter {
    static func string(
        from source: PreparedTranscriptExportSource,
        options: TranscriptExportOptions
    ) -> String {
        var blocks = ["WEBVTT"]
        let styleBlock = makeStyleBlock(from: source, options: options)
        if !styleBlock.isEmpty {
            blocks.append(styleBlock)
        }

        let cues = source.transcript.segments.compactMap { segment -> String? in
            let text = TranscriptTextFormatter.normalizedInlineText(segment.text)
            guard !text.isEmpty else { return nil }
            let speakerID = source.speakerID(for: segment)
            let escapedText = TranscriptTextFormatter.escapeWebVTTText(text)
            let cueText: String
            if options.includeSpeakerLabels {
                let label = source.speakerLabel(for: speakerID)
                cueText = "<v \(TranscriptTextFormatter.escapeWebVTTCueVoice(label))>\(escapedText)"
            } else {
                cueText = escapedText
            }

            return [
                "\(TranscriptTimeFormatter.webVTT(segment.startTime)) --> \(TranscriptTimeFormatter.webVTT(segment.endTime))",
                cueText
            ].joined(separator: "\n")
        }

        blocks.append(contentsOf: cues)
        return TranscriptTextFormatter.joinBlocks(blocks)
    }

    private static func makeStyleBlock(
        from source: PreparedTranscriptExportSource,
        options: TranscriptExportOptions
    ) -> String {
        let lines = source.speakers.compactMap { speaker -> String? in
            guard let style = options.speakerStyles[speaker.id],
                  let color = style.color?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !color.isEmpty
            else {
                return nil
            }

            let label = source.speakerLabel(for: speaker.id)
            return "::cue(v[voice=\"\(TranscriptTextFormatter.escapeCSSString(label))\"]) { color: \(color); }"
        }

        guard !lines.isEmpty else {
            return ""
        }
        return (["STYLE"] + lines).joined(separator: "\n")
    }
}

private enum TranscriptMarkdownMinutesFormatter {
    static func string(
        from source: PreparedTranscriptExportSource,
        options: TranscriptExportOptions
    ) -> String {
        var lines: [String] = []
        let title = source.original.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let heading = title.map { $0.isEmpty ? "Meeting Minutes" : $0 } ?? "Meeting Minutes"
        lines.append("# \(TranscriptTextFormatter.escapeMarkdown(heading))")
        lines.append("")

        var metadata: [String] = []
        if let sourceFileName = source.original.sourceFileName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !sourceFileName.isEmpty {
            metadata.append("Source: \(TranscriptTextFormatter.escapeMarkdown(sourceFileName))")
        }
        metadata.append("Generated: \(TranscriptTimeFormatter.iso8601(source.original.generatedAt))")
        if let languageCode = source.transcript.language?.code {
            metadata.append("Language: \(TranscriptTextFormatter.escapeMarkdown(languageCode))")
        }
        if let duration = source.transcript.duration ?? source.transcript.segments.map(\.endTime).max() {
            metadata.append("Duration: \(TranscriptTimeFormatter.markdownDuration(duration))")
        }

        for item in metadata {
            lines.append("- \(item)")
        }
        lines.append("")
        lines.append("## Transcript")
        lines.append("")

        let groups = groupedSpeakerTurns(from: source)
        if groups.isEmpty {
            lines.append("_No transcript text available._")
            lines.append("")
            return lines.joined(separator: "\n")
        }

        for group in groups {
            let label = source.speakerLabel(for: group.speakerID)
            let avatar = group.speakerID.flatMap { options.speakerStyles[$0]?.avatar } ?? initials(for: label)
            lines.append("### \(TranscriptTextFormatter.escapeMarkdown(avatar)) \(TranscriptTextFormatter.escapeMarkdown(label)) - \(TranscriptTimeFormatter.markdown(group.startTime))-\(TranscriptTimeFormatter.markdown(group.endTime))")
            lines.append("")
            lines.append(group.paragraphs.map(TranscriptTextFormatter.escapeMarkdown).joined(separator: " "))
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private struct SpeakerTurnGroup {
        var speakerID: SpeakerID?
        var startTime: TimeInterval
        var endTime: TimeInterval
        var paragraphs: [String]
    }

    private static func groupedSpeakerTurns(from source: PreparedTranscriptExportSource) -> [SpeakerTurnGroup] {
        var groups: [SpeakerTurnGroup] = []
        for segment in source.transcript.segments {
            let text = TranscriptTextFormatter.normalizedInlineText(segment.text)
            guard !text.isEmpty else { continue }
            let speakerID = source.speakerID(for: segment)

            if let lastIndex = groups.indices.last,
               groups[lastIndex].speakerID == speakerID {
                groups[lastIndex].endTime = max(groups[lastIndex].endTime, segment.endTime)
                groups[lastIndex].paragraphs.append(text)
            } else {
                groups.append(SpeakerTurnGroup(
                    speakerID: speakerID,
                    startTime: segment.startTime,
                    endTime: segment.endTime,
                    paragraphs: [text]
                ))
            }
        }
        return groups
    }

    private static func initials(for label: String) -> String {
        let components = label
            .split { !$0.isLetter && !$0.isNumber }
            .prefix(2)
            .compactMap(\.first)
            .map { String($0).uppercased() }
        let initials = components.joined()
        return initials.isEmpty ? "?" : initials
    }
}

private enum TranscriptPortableJSONFormatter {
    static func data(from source: PreparedTranscriptExportSource) throws -> Data {
        let document = PortableTranscriptDocument(source: source)
        return try LocalSpeechJSON.makePrettyEncoder().encode(document)
    }

    private struct PortableTranscriptDocument: Codable {
        var schema = "com.carbocation.localspeech.transcript"
        var version = 1
        var metadata: PortableTranscriptMetadata
        var speakers: [PortableTranscriptSpeaker]
        var speakerTurns: [PortableTranscriptSpeakerTurn]
        var exclusiveSpeakerTurns: [PortableTranscriptSpeakerTurn]
        var segments: [PortableTranscriptSegment]

        init(source: PreparedTranscriptExportSource) {
            metadata = PortableTranscriptMetadata(source: source)
            speakers = source.speakers.map(PortableTranscriptSpeaker.init)
            speakerTurns = (source.diarization?.turns ?? []).enumerated().map {
                PortableTranscriptSpeakerTurn(index: $0.offset, turn: $0.element, source: source)
            }
            exclusiveSpeakerTurns = (source.diarization?.exclusiveTurns ?? []).enumerated().map {
                PortableTranscriptSpeakerTurn(index: $0.offset, turn: $0.element, source: source)
            }
            segments = source.transcript.segments.enumerated().map {
                PortableTranscriptSegment(index: $0.offset, segment: $0.element, source: source)
            }
        }
    }

    private struct PortableTranscriptMetadata: Codable {
        var title: String?
        var sourceFileName: String?
        var generatedAt: Date
        var languageCode: String?
        var duration: TimeInterval?
        var backend: PortableTranscriptBackend?

        init(source: PreparedTranscriptExportSource) {
            title = source.original.title
            sourceFileName = source.original.sourceFileName
            generatedAt = source.original.generatedAt
            languageCode = source.transcript.language?.code
            duration = source.transcript.duration ?? source.transcript.segments.map(\.endTime).max()
            backend = source.transcript.backend.map(PortableTranscriptBackend.init)
        }
    }

    private struct PortableTranscriptBackend: Codable {
        var kind: String
        var displayName: String
        var version: String?
        var selection: String?

        init(_ backend: SpeechBackendDescriptor) {
            kind = backend.kind.rawValue
            displayName = backend.displayName
            version = backend.version
            selection = backend.selection?.storageValue
        }
    }

    private struct PortableTranscriptSpeaker: Codable {
        var id: String
        var displayName: String?
        var confidence: Double?
        var metadata: [String: String]

        init(_ speaker: Speaker) {
            id = speaker.id.rawValue
            displayName = speaker.displayName
            confidence = speaker.confidence
            metadata = speaker.metadata
        }
    }

    private struct PortableTranscriptSpeakerTurn: Codable {
        var index: Int
        var id: String
        var speakerID: String
        var speakerLabel: String
        var startTime: TimeInterval
        var endTime: TimeInterval
        var duration: TimeInterval
        var confidence: Double?
        var isOverlap: Bool
        var isExclusive: Bool
        var source: String?

        init(index: Int, turn: SpeakerTurn, source: PreparedTranscriptExportSource) {
            self.index = index
            id = turn.id.uuidString
            speakerID = turn.speaker.rawValue
            speakerLabel = source.speakerLabel(for: turn.speaker)
            startTime = turn.startTime
            endTime = turn.endTime
            duration = max(0, turn.endTime - turn.startTime)
            confidence = turn.confidence
            isOverlap = turn.isOverlap
            isExclusive = turn.isExclusive
            self.source = turn.source
        }
    }

    private struct PortableTranscriptSegment: Codable {
        var index: Int
        var id: String
        var startTime: TimeInterval
        var endTime: TimeInterval
        var duration: TimeInterval
        var text: String
        var speakerID: String?
        var speakerLabel: String?
        var confidence: Double?
        var words: [PortableTranscriptWord]

        init(index: Int, segment: TranscriptSegment, source: PreparedTranscriptExportSource) {
            let speakerID = source.speakerID(for: segment)
            self.index = index
            id = segment.id.uuidString
            startTime = segment.startTime
            endTime = segment.endTime
            duration = max(0, segment.endTime - segment.startTime)
            text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            self.speakerID = speakerID?.rawValue
            speakerLabel = speakerID.map { source.speakerLabel(for: $0) }
            confidence = segment.confidence
            words = segment.words.enumerated().map {
                PortableTranscriptWord(index: $0.offset, word: $0.element, source: source)
            }
        }
    }

    private struct PortableTranscriptWord: Codable {
        var index: Int
        var id: String
        var startTime: TimeInterval
        var endTime: TimeInterval
        var duration: TimeInterval
        var text: String
        var speakerID: String?
        var speakerLabel: String?
        var confidence: Double?

        init(index: Int, word: TranscriptWord, source: PreparedTranscriptExportSource) {
            self.index = index
            id = word.id.uuidString
            startTime = word.startTime
            endTime = word.endTime
            duration = max(0, word.endTime - word.startTime)
            text = word.text
            speakerID = word.speaker?.rawValue
            speakerLabel = word.speaker.map { source.speakerLabel(for: $0) }
            confidence = word.confidence
        }
    }
}

private enum TranscriptTextFormatter {
    static func normalizedInlineText(_ text: String) -> String {
        text.split { $0.isWhitespace }.joined(separator: " ")
    }

    static func joinBlocks(_ blocks: [String]) -> String {
        guard !blocks.isEmpty else {
            return ""
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    static func escapeWebVTTText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func escapeWebVTTCueVoice(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: ">", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func escapeCSSString(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func escapeMarkdown(_ text: String) -> String {
        var escaped = ""
        let escapable = Set("\\`*_{}[]()#+!|<>")
        for character in text {
            if escapable.contains(character) {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return escaped
    }
}

private enum TranscriptTimeFormatter {
    static func srt(_ time: TimeInterval) -> String {
        timestamp(time, decimalSeparator: ",")
    }

    static func webVTT(_ time: TimeInterval) -> String {
        timestamp(time, decimalSeparator: ".")
    }

    static func markdown(_ time: TimeInterval) -> String {
        timestamp(time, decimalSeparator: ".")
    }

    static func markdownDuration(_ time: TimeInterval) -> String {
        timestamp(time, decimalSeparator: ".")
    }

    static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func timestamp(_ time: TimeInterval, decimalSeparator: String) -> String {
        let totalMilliseconds = max(0, Int((time * 1000).rounded()))
        let milliseconds = totalMilliseconds % 1000
        let totalSeconds = totalMilliseconds / 1000
        let seconds = totalSeconds % 60
        let totalMinutes = totalSeconds / 60
        let minutes = totalMinutes % 60
        let hours = totalMinutes / 60
        return String(
            format: "%02d:%02d:%02d%@%03d",
            hours,
            minutes,
            seconds,
            decimalSeparator,
            milliseconds
        )
    }
}
