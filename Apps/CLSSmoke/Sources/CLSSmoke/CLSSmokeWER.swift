import Foundation

struct CLSSmokeWERReport: Hashable {
    var substitutions: Int
    var deletions: Int
    var insertions: Int
    var referenceWordCount: Int
    var hypothesisWordCount: Int
    var skippedReason: String? = nil

    var editCount: Int {
        guard skippedReason == nil else { return 0 }
        return substitutions + deletions + insertions
    }

    var wordErrorRate: Double? {
        guard skippedReason == nil else { return nil }
        guard referenceWordCount > 0 else { return nil }
        return Double(editCount) / Double(referenceWordCount)
    }

    var summaryText: String {
        if let skippedReason {
            return "WER skipped: \(skippedReason)"
        }
        let rate = wordErrorRate.map { String(format: "%.1f%%", $0 * 100) } ?? "n/a"
        return "S \(substitutions) D \(deletions) I \(insertions) WER \(rate)"
    }
}

enum CLSSmokeWERApproach: String, CaseIterable, Hashable, Identifiable {
    case liveVADEnabled
    case liveVADDisabled
    case liveVADAutomatic
    case fileTranscription

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .liveVADEnabled:
            return "Live VAD"
        case .liveVADDisabled:
            return "Live no VAD"
        case .liveVADAutomatic:
            return "Live auto VAD"
        case .fileTranscription:
            return "File"
        }
    }
}

enum CLSSmokeWERCalculator {
    static let maximumComparedWords = 4_000
    private static let maximumComparisonCells = 1_000_000

    static func referenceWordCount(in text: String) -> Int {
        normalizedWordCount(in: text, limit: maximumComparedWords + 1)
    }

    static func report(referenceText: String, hypothesisText: String) -> CLSSmokeWERReport? {
        let wordLimit = maximumComparedWords + 1
        let referenceWords = normalizedWords(in: referenceText, limit: wordLimit)
        let hypothesisWords = normalizedWords(in: hypothesisText, limit: wordLimit)
        guard !referenceWords.isEmpty, !hypothesisWords.isEmpty else { return nil }

        if referenceWords.count > maximumComparedWords || hypothesisWords.count > maximumComparedWords {
            return skippedReport(
                reason: "limited to \(maximumComparedWords) words per side",
                referenceWordCount: min(referenceWords.count, maximumComparedWords),
                hypothesisWordCount: min(hypothesisWords.count, maximumComparedWords)
            )
        }

        guard referenceWords.count <= maximumComparisonCells / max(hypothesisWords.count, 1) else {
            return skippedReport(
                reason: "comparison exceeds \(maximumComparisonCells.formatted()) edit cells",
                referenceWordCount: referenceWords.count,
                hypothesisWordCount: hypothesisWords.count
            )
        }

        let state = editState(reference: referenceWords, hypothesis: hypothesisWords)
        return CLSSmokeWERReport(
            substitutions: state.substitutions,
            deletions: state.deletions,
            insertions: state.insertions,
            referenceWordCount: referenceWords.count,
            hypothesisWordCount: hypothesisWords.count
        )
    }

    private static func normalizedWordCount(in text: String, limit: Int? = nil) -> Int {
        scanNormalizedWords(in: text, limit: limit) { _ in }
    }

    private static func normalizedWords(in text: String, limit: Int? = nil) -> [String] {
        var tokens: [String] = []
        if let limit {
            tokens.reserveCapacity(limit)
        }
        scanNormalizedWords(in: text, limit: limit) { token in
            tokens.append(token)
        }
        return tokens
    }

    @discardableResult
    private static func scanNormalizedWords(
        in text: String,
        limit: Int? = nil,
        consume: (String) -> Void
    ) -> Int {
        var current = ""
        var pendingUSpelling = false
        var emittedCount = 0

        func emit(_ token: String) -> Bool {
            guard limit.map({ emittedCount < $0 }) ?? true else { return false }
            consume(token)
            emittedCount += 1
            return limit.map { emittedCount < $0 } ?? true
        }

        func flushRawToken(_ rawToken: String) -> Bool {
            if pendingUSpelling {
                pendingUSpelling = false
                if rawToken == "s" {
                    return emit("us")
                }
                guard emit("u") else { return false }
            }

            if rawToken == "u" {
                pendingUSpelling = true
                return true
            }

            if rawToken == "anytime" {
                guard emit("any") else { return false }
                return emit("time")
            }

            return emit(rawToken)
        }

        func flushCurrentToken() -> Bool {
            guard !current.isEmpty else { return true }
            let shouldContinue = flushRawToken(current.lowercased())
            current.removeAll(keepingCapacity: true)
            return shouldContinue
        }

        for scalar in text.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !flushCurrentToken() {
                return emittedCount
            }
        }

        guard flushCurrentToken() else { return emittedCount }
        if pendingUSpelling {
            _ = emit("u")
        }

        return emittedCount
    }

    private static func skippedReport(
        reason: String,
        referenceWordCount: Int,
        hypothesisWordCount: Int
    ) -> CLSSmokeWERReport {
        CLSSmokeWERReport(
            substitutions: 0,
            deletions: 0,
            insertions: 0,
            referenceWordCount: referenceWordCount,
            hypothesisWordCount: hypothesisWordCount,
            skippedReason: reason
        )
    }

    private static func editState(reference: [String], hypothesis: [String]) -> EditState {
        var previous = Array(repeating: EditState(), count: hypothesis.count + 1)
        if !hypothesis.isEmpty {
            for column in 1...hypothesis.count {
                previous[column] = EditState(cost: column, insertions: column)
            }
        }

        if !reference.isEmpty && !hypothesis.isEmpty {
            for row in 1...reference.count {
                var current = Array(repeating: EditState(), count: hypothesis.count + 1)
                current[0] = EditState(cost: row, deletions: row)

                for column in 1...hypothesis.count {
                    let isMatch = reference[row - 1] == hypothesis[column - 1]
                    var best = previous[column - 1]
                    if !isMatch {
                        best.cost += 1
                        best.substitutions += 1
                    }

                    var deletion = previous[column]
                    deletion.cost += 1
                    deletion.deletions += 1
                    if deletion.cost < best.cost {
                        best = deletion
                    }

                    var insertion = current[column - 1]
                    insertion.cost += 1
                    insertion.insertions += 1
                    if insertion.cost < best.cost {
                        best = insertion
                    }

                    current[column] = best
                }

                previous = current
            }
        }

        return previous[hypothesis.count]
    }

    private struct EditState {
        var cost = 0
        var substitutions = 0
        var deletions = 0
        var insertions = 0
    }
}
