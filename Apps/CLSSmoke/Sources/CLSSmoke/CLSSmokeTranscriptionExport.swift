import CarbocationLocalSpeech
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct CLSSmokeTranscriptionExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [contentType] }
    static var writableContentTypes: [UTType] { [contentType] }
    static let contentType = UTType(filenameExtension: "zip") ?? .data

    var archiveData: Data

    init(archiveData: Data) {
        self.archiveData = archiveData
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CLSSmokeTranscriptionExportError.missingArchiveData
        }
        archiveData = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: archiveData)
    }
}

enum CLSSmokeTranscriptionExportBuilder {
    static func defaultArchiveFileName(sourceFileName: String?) -> String {
        let baseName = sourceFileName
            .flatMap { name -> String? in
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return URL(fileURLWithPath: trimmed).deletingPathExtension().lastPathComponent
            } ?? "transcription"

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let sanitized = baseName.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? String(scalar) : "-"
        }
        .joined()
        .trimmingCharacters(in: CharacterSet(charactersIn: "-_."))

        return "\((sanitized.isEmpty ? "transcription" : sanitized))-transcription-export.zip"
    }

    static func makeDocument(
        sourceFileName: String?,
        transcript: Transcript,
        analysisResult: SpeechAnalysisResult,
        processingDuration: TimeInterval?,
        generatedAt: Date = Date()
    ) throws -> CLSSmokeTranscriptionExportDocument {
        let sourceFileName = normalizedSourceFileName(sourceFileName)
        let archiveData = try makeArchiveData(
            sourceFileName: sourceFileName,
            transcript: transcript,
            analysisResult: analysisResult,
            processingDuration: processingDuration,
            generatedAt: generatedAt
        )
        return CLSSmokeTranscriptionExportDocument(archiveData: archiveData)
    }

    private static func makeArchiveData(
        sourceFileName: String,
        transcript: Transcript,
        analysisResult: SpeechAnalysisResult,
        processingDuration: TimeInterval?,
        generatedAt: Date
    ) throws -> Data {
        let transcriptForPlainText = transcript
        let transcriptForTimedChunks = analysisResult.transcript ?? transcript
        let attributedTranscript = speakerAttributedTranscript(
            displayTranscript: transcript,
            analysisResult: analysisResult
        )
        let diarization = analysisResult.diarization
        let speakersByID = Dictionary(uniqueKeysWithValues: (diarization?.speakers ?? []).map { ($0.id, $0) })

        var artifacts: [CLSSmokeExportArtifact] = []
        var entries: [CLSSmokeZIPArchive.Entry] = []

        func appendFile(
            name: String,
            mediaType: String,
            role: String,
            description: String,
            data: Data
        ) {
            artifacts.append(CLSSmokeExportArtifact(
                fileName: name,
                mediaType: mediaType,
                role: role,
                description: description
            ))
            entries.append(CLSSmokeZIPArchive.Entry(name: name, data: data))
        }

        let transcriptText = transcriptForPlainText.text.trimmingCharacters(in: .whitespacesAndNewlines)
        appendFile(
            name: "transcript.txt",
            mediaType: "text/plain; charset=utf-8",
            role: "plainTextTranscript",
            description: "Plain transcript text without speaker labels.",
            data: utf8Data(transcriptText + "\n")
        )

        let timedChunks = CLSSmokeTimedTextChunksFile(
            sourceFileName: sourceFileName,
            generatedAt: generatedAt,
            diarized: false,
            languageCode: transcriptForTimedChunks.language?.code,
            backendDisplayName: transcriptForTimedChunks.backend?.displayName,
            duration: transcriptForTimedChunks.duration,
            chunks: chunks(
                from: transcriptForTimedChunks,
                speakersByID: speakersByID,
                includeSpeakerLabels: false
            )
        )
        appendFile(
            name: "timed-text-chunks.json",
            mediaType: "application/json",
            role: "timedTextChunks",
            description: "Segment-level timed text chunks from the transcription result.",
            data: try encodeJSON(timedChunks)
        )

        appendFile(
            name: "analysis-result.json",
            mediaType: "application/json",
            role: "analysisResult",
            description: "Raw SpeechAnalysisResult encoded from the local speech package.",
            data: try encodeJSON(analysisResult)
        )

        appendFile(
            name: "diagnostics.json",
            mediaType: "application/json",
            role: "diagnostics",
            description: "Analysis diagnostics emitted during transcription and diarization.",
            data: try encodeJSON(CLSSmokeDiagnosticsFile(
                sourceFileName: sourceFileName,
                generatedAt: generatedAt,
                diagnostics: analysisResult.diagnostics
            ))
        )

        if let diarization {
            appendFile(
                name: "speaker-turns.json",
                mediaType: "application/json",
                role: "speakerTurns",
                description: "Diarization speaker turns and speaker metadata.",
                data: try encodeJSON(CLSSmokeSpeakerTurnsFile(
                    sourceFileName: sourceFileName,
                    generatedAt: generatedAt,
                    diarization: diarization
                ))
            )
            appendFile(
                name: "diarization-result.json",
                mediaType: "application/json",
                role: "diarizationResult",
                description: "Raw DiarizationResult encoded from the local speech package.",
                data: try encodeJSON(diarization)
            )
        }

        if let attributedTranscript {
            appendFile(
                name: "transcript-diarized.txt",
                mediaType: "text/plain; charset=utf-8",
                role: "diarizedPlainTextTranscript",
                description: "Plain transcript text grouped by speaker labels.",
                data: utf8Data(diarizedText(
                    from: attributedTranscript,
                    speakersByID: speakersByID
                ) + "\n")
            )

            let diarizedChunks = CLSSmokeTimedTextChunksFile(
                sourceFileName: sourceFileName,
                generatedAt: generatedAt,
                diarized: true,
                languageCode: attributedTranscript.language?.code,
                backendDisplayName: attributedTranscript.backend?.displayName,
                duration: attributedTranscript.duration,
                chunks: chunks(
                    from: attributedTranscript,
                    speakersByID: speakersByID,
                    includeSpeakerLabels: true
                )
            )
            appendFile(
                name: "diarized-timed-text-chunks.json",
                mediaType: "application/json",
                role: "diarizedTimedTextChunks",
                description: "Segment-level timed text chunks with speaker attribution.",
                data: try encodeJSON(diarizedChunks)
            )
        }

        let manifestArtifact = CLSSmokeExportArtifact(
            fileName: "manifest.json",
            mediaType: "application/json",
            role: "manifest",
            description: "Export manifest and artifact inventory."
        )
        let manifest = CLSSmokeExportManifest(
            sourceFileName: sourceFileName,
            generatedAt: generatedAt,
            processingDuration: processingDuration,
            transcript: CLSSmokeTranscriptSummary(
                segmentCount: transcriptForTimedChunks.segments.count,
                wordCount: transcriptForTimedChunks.segments.flatMap(\.words).count,
                duration: transcriptForTimedChunks.duration ?? transcriptForTimedChunks.segments.last?.endTime,
                backendDisplayName: transcriptForTimedChunks.backend?.displayName,
                languageCode: transcriptForTimedChunks.language?.code
            ),
            diarization: diarization.map {
                CLSSmokeDiarizationSummary(
                    status: analysisResult.diarizationStatus.rawValue,
                    speakerCount: $0.speakers.count,
                    turnCount: $0.turns.count,
                    exclusiveTurnCount: $0.exclusiveTurns.count,
                    duration: $0.duration,
                    backendDisplayName: $0.backend?.displayName,
                    hasSpeakerAttributedTranscript: attributedTranscript != nil
                )
            } ?? CLSSmokeDiarizationSummary(
                status: analysisResult.diarizationStatus.rawValue,
                speakerCount: 0,
                turnCount: 0,
                exclusiveTurnCount: 0,
                duration: nil,
                backendDisplayName: nil,
                hasSpeakerAttributedTranscript: false
            ),
            artifacts: [manifestArtifact] + artifacts
        )

        let manifestEntry = CLSSmokeZIPArchive.Entry(
            name: "manifest.json",
            data: try encodeJSON(manifest)
        )
        return try CLSSmokeZIPArchive.data(entries: [manifestEntry] + entries)
    }

    private static func normalizedSourceFileName(_ sourceFileName: String?) -> String {
        let fallback = "transcription"
        guard let sourceFileName else { return fallback }
        let trimmed = sourceFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        return URL(fileURLWithPath: trimmed).lastPathComponent
    }

    private static func speakerAttributedTranscript(
        displayTranscript: Transcript,
        analysisResult: SpeechAnalysisResult
    ) -> Transcript? {
        if let attributed = analysisResult.speakerAttributedTranscript,
           hasSpeakerAttribution(attributed) {
            return attributed
        }

        if hasSpeakerAttribution(displayTranscript) {
            return displayTranscript
        }

        guard let diarization = analysisResult.diarization,
              !diarization.turns.isEmpty || !diarization.exclusiveTurns.isEmpty
        else {
            return nil
        }

        let baseTranscript = analysisResult.transcript ?? displayTranscript
        let merge = SpeakerAttributionMerger.merge(
            transcript: baseTranscript,
            diarization: diarization,
            policy: .preferExclusiveWordLevel
        )
        return hasSpeakerAttribution(merge.transcript) ? merge.transcript : nil
    }

    private static func hasSpeakerAttribution(_ transcript: Transcript) -> Bool {
        transcript.segments.contains { segment in
            segment.speaker != nil || segment.words.contains { $0.speaker != nil }
        }
    }

    private static func chunks(
        from transcript: Transcript,
        speakersByID: [SpeakerID: Speaker],
        includeSpeakerLabels: Bool
    ) -> [CLSSmokeTimedTextChunk] {
        transcript.segments.enumerated().map { index, segment in
            let speakerID = includeSpeakerLabels ? segment.speaker?.rawValue : nil
            return CLSSmokeTimedTextChunk(
                index: index,
                id: segment.id.uuidString,
                startTime: segment.startTime,
                endTime: segment.endTime,
                duration: max(0, segment.endTime - segment.startTime),
                text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines),
                speakerID: speakerID,
                speakerLabel: includeSpeakerLabels
                    ? speakerLabel(for: segment.speaker, speakersByID: speakersByID)
                    : nil,
                confidence: segment.confidence,
                words: segment.words.enumerated().map { wordIndex, word in
                    let wordSpeakerID = includeSpeakerLabels ? word.speaker?.rawValue : nil
                    return CLSSmokeTimedTextWord(
                        index: wordIndex,
                        id: word.id.uuidString,
                        startTime: word.startTime,
                        endTime: word.endTime,
                        duration: max(0, word.endTime - word.startTime),
                        text: word.text,
                        speakerID: wordSpeakerID,
                        speakerLabel: includeSpeakerLabels
                            ? speakerLabel(for: word.speaker, speakersByID: speakersByID)
                            : nil,
                        confidence: word.confidence
                    )
                }
            )
        }
    }

    private static func diarizedText(
        from transcript: Transcript,
        speakersByID: [SpeakerID: Speaker]
    ) -> String {
        var lines: [String] = []
        var currentSpeaker: SpeakerID?
        var currentText: [String] = []

        func flush() {
            let text = currentText.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            let label = speakerLabel(for: currentSpeaker, speakersByID: speakersByID) ?? "Unknown Speaker"
            lines.append("[\(label)] \(text)")
        }

        for segment in transcript.segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            if segment.speaker != currentSpeaker {
                flush()
                currentSpeaker = segment.speaker
                currentText.removeAll(keepingCapacity: true)
            }

            currentText.append(text)
        }

        flush()
        return lines.joined(separator: "\n")
    }

    fileprivate static func speakerLabel(
        for speakerID: SpeakerID?,
        speakersByID: [SpeakerID: Speaker]
    ) -> String? {
        guard let speakerID else { return nil }
        if let displayName = speakersByID[speakerID]?.displayName,
           !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return displayName
        }

        let raw = speakerID.rawValue
        if raw.hasPrefix("speaker_") {
            let suffix = raw.dropFirst("speaker_".count)
            return "Speaker \(suffix)"
        }
        return raw
    }

    private static func utf8Data(_ string: String) -> Data {
        Data(string.utf8)
    }

    private static func encodeJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }
}

private struct CLSSmokeExportManifest: Codable {
    var schema = "clssmoke.transcription-export.manifest"
    var version = 1
    var sourceFileName: String
    var generatedAt: Date
    var processingDuration: TimeInterval?
    var transcript: CLSSmokeTranscriptSummary
    var diarization: CLSSmokeDiarizationSummary
    var artifacts: [CLSSmokeExportArtifact]
    var schemaStability = "Smoke-app demonstration schema; not public package API."
}

private struct CLSSmokeTranscriptSummary: Codable {
    var segmentCount: Int
    var wordCount: Int
    var duration: TimeInterval?
    var backendDisplayName: String?
    var languageCode: String?
}

private struct CLSSmokeDiarizationSummary: Codable {
    var status: String
    var speakerCount: Int
    var turnCount: Int
    var exclusiveTurnCount: Int
    var duration: TimeInterval?
    var backendDisplayName: String?
    var hasSpeakerAttributedTranscript: Bool
}

private struct CLSSmokeExportArtifact: Codable {
    var fileName: String
    var mediaType: String
    var role: String
    var description: String
}

private struct CLSSmokeTimedTextChunksFile: Codable {
    var schema = "clssmoke.timed-text-chunks"
    var version = 1
    var sourceFileName: String
    var generatedAt: Date
    var diarized: Bool
    var languageCode: String?
    var backendDisplayName: String?
    var duration: TimeInterval?
    var chunks: [CLSSmokeTimedTextChunk]
}

private struct CLSSmokeTimedTextChunk: Codable {
    var index: Int
    var id: String
    var startTime: TimeInterval
    var endTime: TimeInterval
    var duration: TimeInterval
    var text: String
    var speakerID: String?
    var speakerLabel: String?
    var confidence: Double?
    var words: [CLSSmokeTimedTextWord]
}

private struct CLSSmokeTimedTextWord: Codable {
    var index: Int
    var id: String
    var startTime: TimeInterval
    var endTime: TimeInterval
    var duration: TimeInterval
    var text: String
    var speakerID: String?
    var speakerLabel: String?
    var confidence: Double?
}

private struct CLSSmokeDiagnosticsFile: Codable {
    var schema = "clssmoke.transcription-diagnostics"
    var version = 1
    var sourceFileName: String
    var generatedAt: Date
    var diagnostics: [SpeechDiagnostic]
}

private struct CLSSmokeSpeakerTurnsFile: Codable {
    var schema = "clssmoke.speaker-turns"
    var version = 1
    var sourceFileName: String
    var generatedAt: Date
    var duration: TimeInterval
    var backendDisplayName: String?
    var speakers: [CLSSmokeSpeakerSummary]
    var turns: [CLSSmokeSpeakerTurnExport]
    var exclusiveTurns: [CLSSmokeSpeakerTurnExport]

    init(sourceFileName: String, generatedAt: Date, diarization: DiarizationResult) {
        self.sourceFileName = sourceFileName
        self.generatedAt = generatedAt
        duration = diarization.duration
        backendDisplayName = diarization.backend?.displayName
        speakers = diarization.speakers.map(CLSSmokeSpeakerSummary.init)
        let speakersByID = Dictionary(uniqueKeysWithValues: diarization.speakers.map { ($0.id, $0) })
        turns = diarization.turns.enumerated().map {
            CLSSmokeSpeakerTurnExport(index: $0.offset, turn: $0.element, speakersByID: speakersByID)
        }
        exclusiveTurns = diarization.exclusiveTurns.enumerated().map {
            CLSSmokeSpeakerTurnExport(index: $0.offset, turn: $0.element, speakersByID: speakersByID)
        }
    }
}

private struct CLSSmokeSpeakerSummary: Codable {
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

private struct CLSSmokeSpeakerTurnExport: Codable {
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

    init(index: Int, turn: SpeakerTurn, speakersByID: [SpeakerID: Speaker]) {
        self.index = index
        id = turn.id.uuidString
        speakerID = turn.speaker.rawValue
        speakerLabel = CLSSmokeTranscriptionExportBuilder.speakerLabel(
            for: turn.speaker,
            speakersByID: speakersByID
        ) ?? turn.speaker.rawValue
        startTime = turn.startTime
        endTime = turn.endTime
        duration = max(0, turn.endTime - turn.startTime)
        confidence = turn.confidence
        isOverlap = turn.isOverlap
        isExclusive = turn.isExclusive
        source = turn.source
    }
}

private enum CLSSmokeTranscriptionExportError: Error, LocalizedError {
    case missingArchiveData
    case invalidFileName(String)
    case zipLimitExceeded(String)

    var errorDescription: String? {
        switch self {
        case .missingArchiveData:
            return "The exported archive did not contain readable data."
        case .invalidFileName(let name):
            return "Invalid ZIP entry filename: \(name)"
        case .zipLimitExceeded(let details):
            return "ZIP export is too large for the smoke app writer: \(details)"
        }
    }
}

private enum CLSSmokeZIPArchive {
    struct Entry {
        var name: String
        var data: Data
    }

    static func data(entries: [Entry]) throws -> Data {
        guard entries.count <= Int(UInt16.max) else {
            throw CLSSmokeTranscriptionExportError.zipLimitExceeded("too many files")
        }

        var archive = Data()
        var centralDirectory = Data()

        for entry in entries {
            guard let fileName = entry.name.data(using: .utf8), !fileName.isEmpty else {
                throw CLSSmokeTranscriptionExportError.invalidFileName(entry.name)
            }
            guard fileName.count <= Int(UInt16.max) else {
                throw CLSSmokeTranscriptionExportError.zipLimitExceeded("filename too long: \(entry.name)")
            }
            guard entry.data.count <= Int(UInt32.max) else {
                throw CLSSmokeTranscriptionExportError.zipLimitExceeded("file too large: \(entry.name)")
            }
            guard archive.count <= Int(UInt32.max) else {
                throw CLSSmokeTranscriptionExportError.zipLimitExceeded("archive offset exceeded UInt32")
            }

            let localHeaderOffset = UInt32(archive.count)
            let crc = CLSSmokeCRC32.checksum(entry.data)
            let size = UInt32(entry.data.count)
            let nameLength = UInt16(fileName.count)

            archive.appendLittleEndian(UInt32(0x0403_4B50))
            archive.appendLittleEndian(UInt16(20))
            archive.appendLittleEndian(UInt16(0x0800))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0x0021))
            archive.appendLittleEndian(crc)
            archive.appendLittleEndian(size)
            archive.appendLittleEndian(size)
            archive.appendLittleEndian(nameLength)
            archive.appendLittleEndian(UInt16(0))
            archive.append(fileName)
            archive.append(entry.data)

            centralDirectory.appendLittleEndian(UInt32(0x0201_4B50))
            centralDirectory.appendLittleEndian(UInt16(20))
            centralDirectory.appendLittleEndian(UInt16(20))
            centralDirectory.appendLittleEndian(UInt16(0x0800))
            centralDirectory.appendLittleEndian(UInt16(0))
            centralDirectory.appendLittleEndian(UInt16(0))
            centralDirectory.appendLittleEndian(UInt16(0x0021))
            centralDirectory.appendLittleEndian(crc)
            centralDirectory.appendLittleEndian(size)
            centralDirectory.appendLittleEndian(size)
            centralDirectory.appendLittleEndian(nameLength)
            centralDirectory.appendLittleEndian(UInt16(0))
            centralDirectory.appendLittleEndian(UInt16(0))
            centralDirectory.appendLittleEndian(UInt16(0))
            centralDirectory.appendLittleEndian(UInt16(0))
            centralDirectory.appendLittleEndian(UInt32(0))
            centralDirectory.appendLittleEndian(localHeaderOffset)
            centralDirectory.append(fileName)
        }

        guard archive.count <= Int(UInt32.max),
              centralDirectory.count <= Int(UInt32.max)
        else {
            throw CLSSmokeTranscriptionExportError.zipLimitExceeded("central directory exceeded UInt32")
        }

        let centralDirectoryOffset = UInt32(archive.count)
        let centralDirectorySize = UInt32(centralDirectory.count)
        archive.append(centralDirectory)
        archive.appendLittleEndian(UInt32(0x0605_4B50))
        archive.appendLittleEndian(UInt16(0))
        archive.appendLittleEndian(UInt16(0))
        archive.appendLittleEndian(UInt16(entries.count))
        archive.appendLittleEndian(UInt16(entries.count))
        archive.appendLittleEndian(centralDirectorySize)
        archive.appendLittleEndian(centralDirectoryOffset)
        archive.appendLittleEndian(UInt16(0))
        return archive
    }
}

private enum CLSSmokeCRC32 {
    private static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            if crc & 1 == 1 {
                crc = (crc >> 1) ^ 0xEDB8_8320
            } else {
                crc >>= 1
            }
        }
        return crc
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = (crc >> 8) ^ table[index]
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { buffer in
            append(contentsOf: buffer)
        }
    }
}
