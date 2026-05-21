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
        minimumWordOverlap: TimeInterval = 0.0,
        timingOptions: SpeakerAttributionTimingOptions = .disabled
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
                var preferredSpeaker = segment.speaker
                let timingOffset = bestLocalTimingOffset(
                    for: attributedWords,
                    turns: selectedTurns,
                    timingOptions: timingOptions
                )
                for index in attributedWords.indices {
                    let word = attributedWords[index]
                    let adjustedStart = word.startTime + timingOffset
                    let adjustedEnd = word.endTime + timingOffset
                    reportCollapsedOverlapIfNeeded(
                        start: adjustedStart,
                        end: adjustedEnd,
                        turns: selectedTurns,
                        minimumOverlap: minWordOverlap,
                        diagnostics: &diagnostics,
                        reported: &reportedCollapsedOverlap
                    )
                    if let turn = bestSpeakerTurn(
                        start: adjustedStart,
                        end: adjustedEnd,
                        turns: selectedTurns,
                        minimumOverlap: minWordOverlap,
                        preferredSpeaker: preferredSpeaker,
                        timingOptions: timingOptions
                    ) {
                        attributedWords[index].speaker = turn.speaker
                        preferredSpeaker = turn.speaker
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
                    minimumOverlap: minSegOverlap,
                    preferredSpeaker: nil,
                    timingOptions: timingOptions
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

    private struct SpeakerTurnMatch {
        var turn: SpeakerTurn
        var actualOverlap: TimeInterval
        var tolerantOverlap: TimeInterval
        var score: TimeInterval
    }

    private struct TimingOffsetScore {
        var offset: TimeInterval
        var totalOverlap: TimeInterval
        var attributedWordCount: Int
        var speakerSwitchCount: Int
    }

    private static func bestLocalTimingOffset(
        for words: [TranscriptWord],
        turns: [SpeakerTurn],
        timingOptions: SpeakerAttributionTimingOptions
    ) -> TimeInterval {
        let radius = max(0, timingOptions.timingTolerance)
        guard radius > 0,
              !words.isEmpty,
              !turns.isEmpty
        else {
            return 0
        }

        return timingOffsetCandidates(radius: radius)
            .map { offset in
                timingOffsetScore(offset: offset, words: words, turns: turns)
            }
            .max(by: timingOffsetScoreSort)?
            .offset ?? 0
    }

    private static func timingOffsetCandidates(radius: TimeInterval) -> [TimeInterval] {
        let step = max(0.025, min(0.05, radius / 2))
        var candidates: [TimeInterval] = [0]
        var offset = step
        while offset < radius {
            candidates.append(-offset)
            candidates.append(offset)
            offset += step
        }
        candidates.append(-radius)
        candidates.append(radius)
        return candidates
    }

    private static func timingOffsetScore(
        offset: TimeInterval,
        words: [TranscriptWord],
        turns: [SpeakerTurn]
    ) -> TimingOffsetScore {
        var totalOverlap: TimeInterval = 0
        var attributedWordCount = 0
        var speakerSwitchCount = 0
        var previousSpeaker: SpeakerID?

        for word in words {
            let start = word.startTime + offset
            let end = word.endTime + offset
            guard let match = speakerTurnMatches(
                start: start,
                end: end,
                turns: turns,
                minimumOverlap: 0,
                timingOptions: .disabled
            ).max(by: speakerTurnMatchSort) else {
                continue
            }

            totalOverlap += match.actualOverlap
            attributedWordCount += 1
            if let previousSpeaker, previousSpeaker != match.turn.speaker {
                speakerSwitchCount += 1
            }
            previousSpeaker = match.turn.speaker
        }

        return TimingOffsetScore(
            offset: offset,
            totalOverlap: totalOverlap,
            attributedWordCount: attributedWordCount,
            speakerSwitchCount: speakerSwitchCount
        )
    }

    private static func timingOffsetScoreSort(lhs: TimingOffsetScore, rhs: TimingOffsetScore) -> Bool {
        let epsilon = 0.000_001
        if abs(lhs.totalOverlap - rhs.totalOverlap) > epsilon {
            return lhs.totalOverlap < rhs.totalOverlap
        }
        if lhs.attributedWordCount != rhs.attributedWordCount {
            return lhs.attributedWordCount < rhs.attributedWordCount
        }
        if lhs.speakerSwitchCount != rhs.speakerSwitchCount {
            return lhs.speakerSwitchCount > rhs.speakerSwitchCount
        }
        return abs(lhs.offset) > abs(rhs.offset)
    }

    private static func bestSpeakerTurn(
        start: TimeInterval,
        end: TimeInterval,
        turns: [SpeakerTurn],
        minimumOverlap: TimeInterval,
        preferredSpeaker: SpeakerID?,
        timingOptions: SpeakerAttributionTimingOptions
    ) -> SpeakerTurn? {
        let matches = speakerTurnMatches(
            start: start,
            end: end,
            turns: turns,
            minimumOverlap: minimumOverlap,
            timingOptions: timingOptions
        )
        guard let best = matches.max(by: speakerTurnMatchSort) else {
            return nil
        }

        guard let preferredSpeaker,
              best.turn.speaker != preferredSpeaker,
              timingOptions.speakerSwitchScoreTolerance > 0,
              timingOptions.speakerSwitchGraceDuration > 0,
              isNearSpeakerSwitchBoundary(
                start: start,
                end: end,
                matches: matches,
                preferredSpeaker: preferredSpeaker,
                graceDuration: timingOptions.speakerSwitchGraceDuration
              ),
              let preferred = matches
                .filter({ $0.turn.speaker == preferredSpeaker })
                .max(by: speakerTurnMatchSort)
        else {
            return best.turn
        }

        let toleratedScore = best.score * (1 - timingOptions.speakerSwitchScoreTolerance)
        return preferred.score >= toleratedScore ? preferred.turn : best.turn
    }

    private static func speakerTurnMatches(
        start: TimeInterval,
        end: TimeInterval,
        turns: [SpeakerTurn],
        minimumOverlap: TimeInterval,
        timingOptions: SpeakerAttributionTimingOptions
    ) -> [SpeakerTurnMatch] {
        let tolerance = max(0, timingOptions.timingTolerance)
        let expandedStart = start - tolerance
        let expandedEnd = end + tolerance

        return turns.compactMap { turn -> SpeakerTurnMatch? in
            let actualOverlap = intervalOverlap(start: start, end: end, otherStart: turn.startTime, otherEnd: turn.endTime)
            let tolerantOverlap = tolerance > 0
                ? intervalOverlap(start: expandedStart, end: expandedEnd, otherStart: turn.startTime, otherEnd: turn.endTime)
                : actualOverlap
            let effectiveOverlap = actualOverlap > 0 ? actualOverlap : tolerantOverlap
            let meetsThreshold = minimumOverlap <= 0 ? effectiveOverlap > 0 : effectiveOverlap >= minimumOverlap
            guard meetsThreshold else { return nil }

            return SpeakerTurnMatch(
                turn: turn,
                actualOverlap: actualOverlap,
                tolerantOverlap: tolerantOverlap,
                score: actualOverlap > 0 ? actualOverlap : tolerantOverlap * 0.75
            )
        }
    }

    private static func speakerTurnMatchSort(lhs: SpeakerTurnMatch, rhs: SpeakerTurnMatch) -> Bool {
        let epsilon = 0.000_001
        if abs(lhs.score - rhs.score) > epsilon {
            return lhs.score < rhs.score
        }
        if abs(lhs.actualOverlap - rhs.actualOverlap) > epsilon {
            return lhs.actualOverlap < rhs.actualOverlap
        }
        return lhs.turn.startTime > rhs.turn.startTime
    }

    private static func isNearSpeakerSwitchBoundary(
        start: TimeInterval,
        end: TimeInterval,
        matches: [SpeakerTurnMatch],
        preferredSpeaker: SpeakerID,
        graceDuration: TimeInterval
    ) -> Bool {
        matches.contains { match in
            guard match.turn.speaker == preferredSpeaker else { return false }
            return intervalDistance(
                start: start,
                end: end,
                otherStart: match.turn.startTime,
                otherEnd: match.turn.endTime
            ) <= graceDuration
        }
    }

    private static func intervalOverlap(
        start: TimeInterval,
        end: TimeInterval,
        otherStart: TimeInterval,
        otherEnd: TimeInterval
    ) -> TimeInterval {
        max(0, min(end, otherEnd) - max(start, otherStart))
    }

    private static func intervalDistance(
        start: TimeInterval,
        end: TimeInterval,
        otherStart: TimeInterval,
        otherEnd: TimeInterval
    ) -> TimeInterval {
        if end < otherStart {
            return otherStart - end
        }
        if otherEnd < start {
            return start - otherEnd
        }
        return 0
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
