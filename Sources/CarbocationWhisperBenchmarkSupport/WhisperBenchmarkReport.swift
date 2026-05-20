import Foundation

public struct WhisperBenchmarkReport: Codable, Hashable, Sendable {
    public var schemaVersion: Int
    public var generatedAt: Date
    public var configuration: WhisperBenchmarkConfigurationSummary
    public var runtime: WhisperBenchmarkRuntimeSummary
    public var model: WhisperBenchmarkModelSummary
    public var fixture: WhisperBenchmarkFixtureSummary
    public var timings: WhisperBenchmarkTimingSummary
    public var wer: WhisperBenchmarkWERSummary?
    public var transcriptExcerpt: String

    public init(
        schemaVersion: Int = 2,
        generatedAt: Date = Date(),
        configuration: WhisperBenchmarkConfigurationSummary,
        runtime: WhisperBenchmarkRuntimeSummary,
        model: WhisperBenchmarkModelSummary,
        fixture: WhisperBenchmarkFixtureSummary,
        timings: WhisperBenchmarkTimingSummary,
        wer: WhisperBenchmarkWERSummary?,
        transcriptExcerpt: String
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.configuration = configuration
        self.runtime = runtime
        self.model = model
        self.fixture = fixture
        self.timings = timings
        self.wer = wer
        self.transcriptExcerpt = transcriptExcerpt
    }
}

public struct WhisperBenchmarkConfigurationSummary: Codable, Hashable, Sendable {
    public var explicitModelPath: String?
    public var libraryRootPath: String?
    public var variant: String?
    public var iterations: Int
    public var warmups: Int
    public var threadCount: Int32?
    public var useMetal: Bool
    public var useCoreML: Bool
    public var suppressNativeLogs: Bool
}

public struct WhisperBenchmarkRuntimeSummary: Codable, Hashable, Sendable {
    public var backendStatus: String
    public var backendStatusDescription: String
    public var systemInfo: String
    public var coreMLCompiledIn: Bool
    public var coreMLRequested: Bool
    public var modelDeclaresCoreMLEncoder: Bool
    public var expectedCoreMLEncoderPath: String?
    public var expectedCoreMLEncoderExists: Bool
    public var expectedCoreMLActive: Bool
}

public struct WhisperBenchmarkModelSummary: Codable, Hashable, Sendable {
    public var id: UUID
    public var displayName: String
    public var variant: String?
    public var primaryWeightsPath: String
    public var libraryRootPath: String
    public var assetRoles: [String]
}

public struct WhisperBenchmarkFixtureSummary: Codable, Hashable, Sendable {
    public var name: String
    public var audioPath: String
    public var language: String
    public var durationSeconds: Double
    public var referenceWordCount: Int
}

public struct WhisperBenchmarkTimingSummary: Codable, Hashable, Sendable {
    public var audioPreparationSeconds: Double
    public var loadSeconds: Double
    public var contextInitSeconds: Double
    public var firstTranscriptionSeconds: Double
    public var warmupTranscriptionSeconds: [Double]
    public var warmTranscriptionSeconds: [Double]
    public var medianWarmTranscriptionSeconds: Double
    public var bestWarmTranscriptionSeconds: Double
    public var medianWarmRealTimeFactor: Double
    public var bestWarmRealTimeFactor: Double
}

public struct WhisperBenchmarkWERSummary: Codable, Hashable, Sendable {
    public var substitutions: Int
    public var deletions: Int
    public var insertions: Int
    public var referenceWordCount: Int
    public var hypothesisWordCount: Int
    public var wordErrorRate: Double?
    public var summaryText: String
}

public enum WhisperBenchmarkJSON {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public extension WhisperBenchmarkReport {
    func humanSummary() -> String {
        let werText = wer?.summaryText ?? "WER n/a"
        let medianText = Self.formatSeconds(timings.medianWarmTranscriptionSeconds)
        let bestText = Self.formatSeconds(timings.bestWarmTranscriptionSeconds)
        let firstText = Self.formatSeconds(timings.firstTranscriptionSeconds)
        let contextText = Self.formatSeconds(timings.contextInitSeconds)
        let rtfText = String(format: "%.3fx", timings.medianWarmRealTimeFactor)
        let coreMLText = runtime.expectedCoreMLActive ? "expected active" : "not active"

        return """
        \(fixture.name) / \(model.displayName)
        CoreML: compiled=\(runtime.coreMLCompiledIn) requested=\(runtime.coreMLRequested) sidecar=\(runtime.expectedCoreMLEncoderExists) \(coreMLText)
        Context init: \(contextText)  First: \(firstText)  Warm median: \(medianText)  Warm best: \(bestText)  RTF median: \(rtfText)
        \(werText)
        Hypothesis: \(transcriptExcerpt)
        """
    }

    static func comparisonSummary(baseline: WhisperBenchmarkReport, candidate: WhisperBenchmarkReport) -> String {
        func ratio(_ lhs: Double, _ rhs: Double) -> String {
            guard lhs > 0, rhs > 0 else { return "n/a" }
            return String(format: "%.2fx", lhs / rhs)
        }

        return """
        Baseline: \(baseline.model.displayName) CoreML active=\(baseline.runtime.expectedCoreMLActive)
        Candidate: \(candidate.model.displayName) CoreML active=\(candidate.runtime.expectedCoreMLActive)
        Context init: \(formatSeconds(baseline.timings.contextInitSeconds)) -> \(formatSeconds(candidate.timings.contextInitSeconds)) (\(ratio(baseline.timings.contextInitSeconds, candidate.timings.contextInitSeconds)))
        First transcription: \(formatSeconds(baseline.timings.firstTranscriptionSeconds)) -> \(formatSeconds(candidate.timings.firstTranscriptionSeconds)) (\(ratio(baseline.timings.firstTranscriptionSeconds, candidate.timings.firstTranscriptionSeconds)))
        Warm median: \(formatSeconds(baseline.timings.medianWarmTranscriptionSeconds)) -> \(formatSeconds(candidate.timings.medianWarmTranscriptionSeconds)) (\(ratio(baseline.timings.medianWarmTranscriptionSeconds, candidate.timings.medianWarmTranscriptionSeconds)))
        Warm best: \(formatSeconds(baseline.timings.bestWarmTranscriptionSeconds)) -> \(formatSeconds(candidate.timings.bestWarmTranscriptionSeconds)) (\(ratio(baseline.timings.bestWarmTranscriptionSeconds, candidate.timings.bestWarmTranscriptionSeconds)))
        Baseline WER: \(baseline.wer?.summaryText ?? "n/a")
        Candidate WER: \(candidate.wer?.summaryText ?? "n/a")
        """
    }

    private static func formatSeconds(_ seconds: Double) -> String {
        String(format: "%.3fs", seconds)
    }
}
