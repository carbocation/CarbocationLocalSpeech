import CarbocationLocalSpeech
import CarbocationWhisperRuntime
import Foundation

public struct WhisperBenchmarkConfiguration: Hashable, Sendable {
    public var explicitModelPath: String?
    public var libraryRootPath: String?
    public var variant: String?
    public var iterations: Int
    public var warmups: Int
    public var threadCount: Int32?
    public var useMetal: Bool
    public var useCoreML: Bool
    public var suppressNativeLogs: Bool

    public init(
        explicitModelPath: String? = nil,
        libraryRootPath: String? = nil,
        variant: String? = "small.en",
        iterations: Int = 5,
        warmups: Int = 1,
        threadCount: Int32? = 4,
        useMetal: Bool = WhisperRuntimeDefaults.useMetal,
        useCoreML: Bool = false,
        suppressNativeLogs: Bool = true
    ) {
        self.explicitModelPath = explicitModelPath
        self.libraryRootPath = libraryRootPath
        self.variant = variant
        self.iterations = max(1, iterations)
        self.warmups = max(0, warmups)
        self.threadCount = threadCount.map { max(1, $0) }
        self.useMetal = useMetal
        self.useCoreML = useCoreML
        self.suppressNativeLogs = suppressNativeLogs
    }
}

public enum WhisperBenchmarkRunner {
    public static func run(configuration: WhisperBenchmarkConfiguration) async throws -> WhisperBenchmarkReport {
        guard let resolved = try await WhisperBenchmarkModelResolver.resolve(
            explicitModelPath: configuration.explicitModelPath,
            libraryRootPath: configuration.libraryRootPath,
            variant: configuration.variant,
            defaultVariant: "small.en"
        ) else {
            throw WhisperBenchmarkError.missingModelSelection
        }

        let fixture = try KnownSpeechFixture.jfk()
        let (preparedAudio, audioPreparationSeconds) = try await measure {
            try await AudioResampler16kMono().prepareFile(at: fixture.audioURL)
        }

        let runtimeDiagnostics = WhisperRuntimeSmoke.diagnostics(
            model: resolved.model,
            root: resolved.libraryRoot,
            coreMLRequested: configuration.useCoreML
        )
        let engine = WhisperEngine(configuration: WhisperEngineConfiguration(
            useMetal: configuration.useMetal,
            useCoreML: configuration.useCoreML,
            threadCount: configuration.threadCount,
            suppressNativeLogs: configuration.suppressNativeLogs
        ))
        let loadConfiguration = WhisperLoadConfiguration(
            language: fixture.language,
            useMetal: configuration.useMetal,
            useCoreML: configuration.useCoreML
        )

        let (_, loadSeconds) = try await measure {
            try await engine.load(model: resolved.model, from: resolved.libraryRoot, configuration: loadConfiguration)
        }
        let (_, contextInitSeconds) = try await measure {
            try await engine.preload()
        }

        let options = TranscriptionOptions(
            language: fixture.language,
            suppressBlankAudio: false,
            temperature: 0
        )
        let (firstTranscript, firstTranscriptionSeconds) = try await measure {
            try await engine.transcribe(audio: preparedAudio, options: options)
        }

        var warmupTimes: [Double] = []
        for _ in 0..<configuration.warmups {
            let (_, seconds) = try await measure {
                try await engine.transcribe(audio: preparedAudio, options: options)
            }
            warmupTimes.append(seconds)
        }

        var warmTimes: [Double] = []
        for _ in 0..<configuration.iterations {
            let (_, seconds) = try await measure {
                try await engine.transcribe(audio: preparedAudio, options: options)
            }
            warmTimes.append(seconds)
        }
        await engine.unload()

        let hypothesis = firstTranscript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let werReport = WhisperWERCalculator.report(
            referenceText: fixture.referenceText,
            hypothesisText: hypothesis
        )
        let medianWarm = median(warmTimes)
        let bestWarm = best(warmTimes)
        let duration = preparedAudio.duration

        return WhisperBenchmarkReport(
            configuration: WhisperBenchmarkConfigurationSummary(
                explicitModelPath: configuration.explicitModelPath,
                libraryRootPath: configuration.libraryRootPath,
                variant: configuration.variant,
                iterations: configuration.iterations,
                warmups: configuration.warmups,
                threadCount: configuration.threadCount,
                useMetal: configuration.useMetal,
                useCoreML: configuration.useCoreML,
                suppressNativeLogs: configuration.suppressNativeLogs
            ),
            runtime: WhisperBenchmarkRuntimeSummary(
                backendStatus: "\(runtimeDiagnostics.backendStatus)",
                backendStatusDescription: runtimeDiagnostics.backendStatusDescription,
                systemInfo: runtimeDiagnostics.systemInfo,
                coreMLCompiledIn: runtimeDiagnostics.coreML.compiledIn,
                coreMLRequested: runtimeDiagnostics.coreML.requested,
                modelDeclaresCoreMLEncoder: runtimeDiagnostics.coreML.modelDeclaresCoreMLEncoder,
                expectedCoreMLEncoderPath: runtimeDiagnostics.coreML.expectedEncoderPath,
                expectedCoreMLEncoderExists: runtimeDiagnostics.coreML.expectedEncoderExists,
                expectedCoreMLActive: runtimeDiagnostics.coreML.expectedActive
            ),
            model: WhisperBenchmarkModelSummary(
                id: resolved.model.id,
                displayName: resolved.model.displayName,
                variant: resolved.model.variant,
                primaryWeightsPath: resolved.modelURL.path,
                libraryRootPath: resolved.libraryRoot.path,
                assetRoles: resolved.model.assets.map { $0.role.rawValue }.sorted()
            ),
            fixture: WhisperBenchmarkFixtureSummary(
                name: fixture.name,
                audioPath: fixture.audioURL.path,
                language: fixture.language,
                durationSeconds: duration,
                referenceWordCount: werReport?.referenceWordCount ?? 0
            ),
            timings: WhisperBenchmarkTimingSummary(
                audioPreparationSeconds: audioPreparationSeconds,
                loadSeconds: loadSeconds,
                contextInitSeconds: contextInitSeconds,
                firstTranscriptionSeconds: firstTranscriptionSeconds,
                warmupTranscriptionSeconds: warmupTimes,
                warmTranscriptionSeconds: warmTimes,
                medianWarmTranscriptionSeconds: medianWarm,
                bestWarmTranscriptionSeconds: bestWarm,
                medianWarmRealTimeFactor: duration / medianWarm,
                bestWarmRealTimeFactor: duration / bestWarm
            ),
            wer: werReport.map {
                WhisperBenchmarkWERSummary(
                    substitutions: $0.substitutions,
                    deletions: $0.deletions,
                    insertions: $0.insertions,
                    referenceWordCount: $0.referenceWordCount,
                    hypothesisWordCount: $0.hypothesisWordCount,
                    wordErrorRate: $0.wordErrorRate,
                    summaryText: $0.summaryText
                )
            },
            transcriptExcerpt: excerpt(hypothesis)
        )
    }

    public static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let midpoint = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[midpoint - 1] + sorted[midpoint]) / 2
        }
        return sorted[midpoint]
    }

    public static func best(_ values: [Double]) -> Double {
        values.min() ?? 0
    }

    private static func measure<T>(_ operation: () async throws -> T) async throws -> (T, Double) {
        let start = DispatchTime.now().uptimeNanoseconds
        let value = try await operation()
        let end = DispatchTime.now().uptimeNanoseconds
        return (value, Double(end - start) / 1_000_000_000)
    }

    private static func excerpt(_ text: String, limit: Int = 240) -> String {
        let singleLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard singleLine.count > limit else { return singleLine }
        return "\(singleLine.prefix(limit))..."
    }
}

public enum WhisperBenchmarkError: LocalizedError {
    case missingModelSelection

    public var errorDescription: String? {
        switch self {
        case .missingModelSelection:
            return "Provide either --model or --library-root for clss-benchmark."
        }
    }
}
