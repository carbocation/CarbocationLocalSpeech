import CarbocationWhisperBenchmarkSupport
import Darwin
import Foundation

@main
struct CLSSBenchmarkMain {
    static func main() async {
        do {
            var parser = ArgumentParser(arguments: Array(CommandLine.arguments.dropFirst()))
            if parser.consume("compare") {
                let baseline = try parser.requiredValue(for: "--baseline")
                let candidate = try parser.requiredValue(for: "--candidate")
                try parser.finish()
                let baselineReport = try readReport(at: baseline)
                let candidateReport = try readReport(at: candidate)
                print(WhisperBenchmarkReport.comparisonSummary(
                    baseline: baselineReport,
                    candidate: candidateReport
                ))
                return
            }

            if parser.consume("--help") || parser.consume("-h") {
                print(Self.usage)
                return
            }

            let explicitModelPath = parser.optionalValue(for: "--model")
            let libraryRootPath = parser.optionalValue(for: "--library-root")
            let variant = parser.optionalValue(for: "--variant") ?? "small.en"
            let iterations = try parser.optionalInt(for: "--iterations") ?? 5
            let warmups = try parser.optionalInt(for: "--warmups") ?? 1
            let threadCount = try parser.optionalInt(for: "--threads").map(Int32.init)
            let outputPath = parser.optionalValue(for: "--output")
            let printJSON = parser.consume("--json")
            let useMetal = !parser.consume("--no-metal")
            let useCoreML = parser.consume("--coreml")
            let suppressNativeLogs = !parser.consume("--native-logs")
            try parser.finish()

            let report = try await WhisperBenchmarkRunner.run(configuration: WhisperBenchmarkConfiguration(
                explicitModelPath: explicitModelPath,
                libraryRootPath: libraryRootPath,
                variant: variant,
                iterations: iterations,
                warmups: warmups,
                threadCount: threadCount ?? 4,
                useMetal: useMetal,
                useCoreML: useCoreML,
                suppressNativeLogs: suppressNativeLogs
            ))

            if let outputPath {
                try write(report: report, to: outputPath)
            }

            if printJSON {
                let data = try WhisperBenchmarkJSON.encoder().encode(report)
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            } else {
                print(report.humanSummary())
                if let outputPath {
                    print("JSON: \(expandedPath(outputPath))")
                }
            }
        } catch {
            fputs("clss-benchmark: \(error.localizedDescription)\n\n\(Self.usage)\n", stderr)
            exit(1)
        }
    }

    private static let usage = """
    Usage:
      clss-benchmark --library-root <SpeechModels> [--variant small.en] [--iterations 5] [--warmups 1] [--output report.json]
      clss-benchmark --model <path/to/ggml-model.bin> [--iterations 5] [--warmups 1] [--output report.json]
      clss-benchmark compare --baseline baseline.json --candidate coreml.json

    Options:
      --threads <n>       Thread count for whisper.cpp decoding. Defaults to 4.
      --no-metal          Disable Metal/GPU backend.
      --coreml            Mark the report as an explicitly requested CoreML run.
      --native-logs       Let whisper.cpp native logs print during the run.
      --json              Print the JSON report to stdout.
    """

    private static func write(report: WhisperBenchmarkReport, to path: String) throws {
        let url = URL(fileURLWithPath: expandedPath(path))
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try WhisperBenchmarkJSON.encoder().encode(report)
        try data.write(to: url, options: .atomic)
    }

    private static func readReport(at path: String) throws -> WhisperBenchmarkReport {
        let url = URL(fileURLWithPath: expandedPath(path))
        let data = try Data(contentsOf: url)
        return try WhisperBenchmarkJSON.decoder().decode(WhisperBenchmarkReport.self, from: data)
    }

    private static func expandedPath(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}

private struct ArgumentParser {
    private var arguments: [String]

    init(arguments: [String]) {
        self.arguments = arguments
    }

    mutating func consume(_ token: String) -> Bool {
        guard let index = arguments.firstIndex(of: token) else { return false }
        arguments.remove(at: index)
        return true
    }

    mutating func optionalValue(for flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1)
        else {
            return nil
        }
        let value = arguments.remove(at: index + 1)
        arguments.remove(at: index)
        return value
    }

    mutating func requiredValue(for flag: String) throws -> String {
        guard let value = optionalValue(for: flag), !value.isEmpty else {
            throw BenchmarkCLIError.missingValue(flag)
        }
        return value
    }

    mutating func optionalInt(for flag: String) throws -> Int? {
        guard let value = optionalValue(for: flag) else { return nil }
        guard let integer = Int(value), integer >= 0 else {
            throw BenchmarkCLIError.invalidInteger(flag, value)
        }
        return integer
    }

    func finish() throws {
        if let unknown = arguments.first {
            throw BenchmarkCLIError.unknownArgument(unknown)
        }
    }
}

private enum BenchmarkCLIError: LocalizedError {
    case missingValue(String)
    case invalidInteger(String, String)
    case unknownArgument(String)

    var errorDescription: String? {
        switch self {
        case .missingValue(let flag):
            return "Missing value for \(flag)."
        case .invalidInteger(let flag, let value):
            return "\(flag) expects a non-negative integer, got '\(value)'."
        case .unknownArgument(let argument):
            return "Unknown argument '\(argument)'."
        }
    }
}
