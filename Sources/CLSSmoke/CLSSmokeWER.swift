import Foundation

struct CLSSmokeWERReport: Hashable {
    var substitutions: Int
    var deletions: Int
    var insertions: Int
    var referenceWordCount: Int
    var hypothesisWordCount: Int

    var editCount: Int {
        substitutions + deletions + insertions
    }

    var wordErrorRate: Double? {
        guard referenceWordCount > 0 else { return nil }
        return Double(editCount) / Double(referenceWordCount)
    }

    var summaryText: String {
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
    static func referenceWordCount(in text: String) -> Int {
        normalizedWords(in: text).count
    }

    static func report(referenceText: String, hypothesisText: String) -> CLSSmokeWERReport? {
        let referenceWords = normalizedWords(in: referenceText)
        let hypothesisWords = normalizedWords(in: hypothesisText)
        guard !referenceWords.isEmpty, !hypothesisWords.isEmpty else { return nil }

        let table = editTable(reference: referenceWords, hypothesis: hypothesisWords)
        var row = referenceWords.count
        var column = hypothesisWords.count
        var substitutions = 0
        var deletions = 0
        var insertions = 0

        while row > 0 || column > 0 {
            switch table[row][column].operation {
            case .match:
                row -= 1
                column -= 1
            case .substitution:
                substitutions += 1
                row -= 1
                column -= 1
            case .deletion:
                deletions += 1
                row -= 1
            case .insertion:
                insertions += 1
                column -= 1
            case .none:
                return nil
            }
        }

        return CLSSmokeWERReport(
            substitutions: substitutions,
            deletions: deletions,
            insertions: insertions,
            referenceWordCount: referenceWords.count,
            hypothesisWordCount: hypothesisWords.count
        )
    }

    private static func normalizedWords(in text: String) -> [String] {
        var rawTokens: [String] = []
        var current = ""

        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                rawTokens.append(current)
                current.removeAll(keepingCapacity: true)
            }
        }
        if !current.isEmpty {
            rawTokens.append(current)
        }

        var tokens: [String] = []
        var index = 0
        while index < rawTokens.count {
            if index + 1 < rawTokens.count,
               rawTokens[index] == "u",
               rawTokens[index + 1] == "s" {
                tokens.append("us")
                index += 2
                continue
            }

            if rawTokens[index] == "anytime" {
                tokens.append("any")
                tokens.append("time")
            } else {
                tokens.append(rawTokens[index])
            }
            index += 1
        }

        return tokens
    }

    private static func editTable(reference: [String], hypothesis: [String]) -> [[EditCell]] {
        var table = Array(
            repeating: Array(repeating: EditCell(cost: 0, operation: .none), count: hypothesis.count + 1),
            count: reference.count + 1
        )

        if !reference.isEmpty {
            for row in 1...reference.count {
                table[row][0] = EditCell(cost: row, operation: .deletion)
            }
        }
        if !hypothesis.isEmpty {
            for column in 1...hypothesis.count {
                table[0][column] = EditCell(cost: column, operation: .insertion)
            }
        }

        if !reference.isEmpty && !hypothesis.isEmpty {
            for row in 1...reference.count {
                for column in 1...hypothesis.count {
                    let isMatch = reference[row - 1] == hypothesis[column - 1]
                    var best = EditCell(
                        cost: table[row - 1][column - 1].cost + (isMatch ? 0 : 1),
                        operation: isMatch ? .match : .substitution
                    )
                    let deletion = EditCell(cost: table[row - 1][column].cost + 1, operation: .deletion)
                    if deletion.cost < best.cost {
                        best = deletion
                    }
                    let insertion = EditCell(cost: table[row][column - 1].cost + 1, operation: .insertion)
                    if insertion.cost < best.cost {
                        best = insertion
                    }
                    table[row][column] = best
                }
            }
        }

        return table
    }

    private struct EditCell {
        var cost: Int
        var operation: EditOperation
    }

    private enum EditOperation {
        case none
        case match
        case substitution
        case deletion
        case insertion
    }
}
