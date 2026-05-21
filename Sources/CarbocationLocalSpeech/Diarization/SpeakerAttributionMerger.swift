import Foundation

public struct SpeakerAttributionMergeResult: Sendable {
    public var transcript: Transcript
    public var diagnostics: [SpeechDiagnostic]

    public init(transcript: Transcript, diagnostics: [SpeechDiagnostic] = []) {
        self.transcript = transcript
        self.diagnostics = diagnostics
    }
}

public enum SpeakerAttributionMerger {
    public static func merge(
        transcript: Transcript,
        diarization: DiarizationResult,
        policy: SpeakerAttributionPolicy,
        minimumSegmentOverlap: TimeInterval = 0.05,
        minimumWordOverlap: TimeInterval = 0.0
    ) -> SpeakerAttributionMergeResult {
        var diagnostics: [SpeechDiagnostic] = []
        let selectedTurns: [SpeakerTurn]
        switch policy {
        case .preferExclusiveWordLevel:
            if diarization.exclusiveTurns.isEmpty {
                selectedTurns = diarization.turns
                diagnostics.append(SpeechDiagnostic(
                    source: "merger",
                    message: "Exclusive turns empty; falling back to standard turns (count: \(diarization.turns.count))"
                ))
            } else {
                selectedTurns = diarization.exclusiveTurns
                diagnostics.append(SpeechDiagnostic(
                    source: "merger",
                    message: "Using exclusive turns for attribution (count: \(diarization.exclusiveTurns.count))"
                ))
            }
        case .preferStandardWordLevel, .segmentLargestOverlap:
            selectedTurns = diarization.turns
            diagnostics.append(SpeechDiagnostic(
                source: "merger",
                message: "Using standard turns for attribution (count: \(diarization.turns.count))"
            ))
        }

        let minSegOverlap = max(0, minimumSegmentOverlap)
        let minWordOverlap = max(0, minimumWordOverlap)
        var newSegments: [TranscriptSegment] = []
        var reportedCollapsedOverlap = false

        for segment in transcript.segments {
            if !segment.words.isEmpty && policy != .segmentLargestOverlap {
                var attributedWords = segment.words
                for index in attributedWords.indices {
                    let word = attributedWords[index]
                    reportCollapsedOverlapIfNeeded(
                        start: word.startTime,
                        end: word.endTime,
                        turns: selectedTurns,
                        minimumOverlap: minWordOverlap,
                        diagnostics: &diagnostics,
                        reported: &reportedCollapsedOverlap
                    )
                    if let turn = bestSpeakerTurn(
                        start: word.startTime,
                        end: word.endTime,
                        turns: selectedTurns,
                        minimumOverlap: minWordOverlap
                    ) {
                        attributedWords[index].speaker = turn.speaker
                    }
                }

                let wordGroups = groupedBySpeaker(attributedWords)
                if wordGroups.count > 1 {
                    diagnostics.append(SpeechDiagnostic(
                        source: "merger",
                        message: "Split segment '\(segment.id)' into \(wordGroups.count) speaker-based segments",
                        time: segment.startTime
                    ))
                }

                for group in wordGroups {
                    guard let firstWord = group.first, let lastWord = group.last else { continue }
                    let confidences = group.compactMap(\.confidence)
                    let averageConfidence = confidences.isEmpty
                        ? segment.confidence
                        : confidences.reduce(0, +) / Double(confidences.count)

                    newSegments.append(TranscriptSegment(
                        id: UUID(),
                        text: group.map(\.text).joined(separator: " "),
                        startTime: firstWord.startTime,
                        endTime: lastWord.endTime,
                        words: group,
                        speaker: firstWord.speaker,
                        confidence: averageConfidence
                    ))
                }
            } else {
                var updatedSegment = segment
                reportCollapsedOverlapIfNeeded(
                    start: segment.startTime,
                    end: segment.endTime,
                    turns: selectedTurns,
                    minimumOverlap: minSegOverlap,
                    diagnostics: &diagnostics,
                    reported: &reportedCollapsedOverlap
                )
                if let turn = bestSpeakerTurn(
                    start: segment.startTime,
                    end: segment.endTime,
                    turns: selectedTurns,
                    minimumOverlap: minSegOverlap
                ) {
                    updatedSegment.speaker = turn.speaker
                }
                newSegments.append(updatedSegment)
            }
        }

        return SpeakerAttributionMergeResult(
            transcript: Transcript(
                segments: newSegments,
                language: transcript.language,
                duration: transcript.duration,
                backend: transcript.backend
            ),
            diagnostics: diagnostics
        )
    }

    public static func merge(
        transcript: Transcript,
        speakerTurns: [SpeakerTurn],
        minimumOverlap: TimeInterval = 0.05
    ) -> Transcript {
        let speakers = orderedSpeakerIDs(from: speakerTurns).map { Speaker(id: $0) }
        let result = DiarizationResult(
            turns: speakerTurns,
            speakers: speakers,
            duration: speakerTurns.map(\.endTime).max() ?? transcript.duration ?? 0
        )
        return merge(
            transcript: transcript,
            diarization: result,
            policy: .segmentLargestOverlap,
            minimumSegmentOverlap: minimumOverlap
        ).transcript
    }

    private static func bestSpeakerTurn(
        start: TimeInterval,
        end: TimeInterval,
        turns: [SpeakerTurn],
        minimumOverlap: TimeInterval
    ) -> SpeakerTurn? {
        turns
            .map { turn -> (SpeakerTurn, TimeInterval) in
                let overlap = max(0, min(end, turn.endTime) - max(start, turn.startTime))
                return (turn, overlap)
            }
            .filter { minimumOverlap <= 0 ? $0.1 > 0 : $0.1 >= minimumOverlap }
            .max { lhs, rhs in lhs.1 < rhs.1 }?
            .0
    }

    private static func reportCollapsedOverlapIfNeeded(
        start: TimeInterval,
        end: TimeInterval,
        turns: [SpeakerTurn],
        minimumOverlap: TimeInterval,
        diagnostics: inout [SpeechDiagnostic],
        reported: inout Bool
    ) {
        guard !reported else { return }
        let overlappingTurns = turns.filter { turn in
            let overlap = max(0, min(end, turn.endTime) - max(start, turn.startTime))
            return minimumOverlap <= 0 ? overlap > 0 : overlap >= minimumOverlap
        }
        let speakerIDs = Set(overlappingTurns.map(\.speaker))
        guard speakerIDs.count > 1,
              overlappingTurns.contains(where: \.isOverlap)
        else {
            return
        }

        reported = true
        diagnostics.append(SpeechDiagnostic(
            source: "merger",
            message: "Overlapping diarization turns mapped to a single transcript speaker label.",
            time: start,
            code: .overlappingSpeechCollapsed
        ))
    }

    private static func groupedBySpeaker(_ words: [TranscriptWord]) -> [[TranscriptWord]] {
        var groups: [[TranscriptWord]] = []
        var currentGroup: [TranscriptWord] = []

        for word in words {
            if let last = currentGroup.last, last.speaker != word.speaker {
                groups.append(currentGroup)
                currentGroup = [word]
            } else {
                currentGroup.append(word)
            }
        }

        if !currentGroup.isEmpty {
            groups.append(currentGroup)
        }
        return groups
    }

    private static func orderedSpeakerIDs(from turns: [SpeakerTurn]) -> [SpeakerID] {
        turns.reduce(into: [SpeakerID]()) { ids, turn in
            guard !ids.contains(turn.speaker) else { return }
            ids.append(turn.speaker)
        }
    }
}
