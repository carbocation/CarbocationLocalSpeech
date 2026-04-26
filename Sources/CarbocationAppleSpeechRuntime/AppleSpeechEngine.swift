import AVFoundation
@_spi(Internal) import CarbocationLocalSpeech
import CoreMedia
import Foundation

#if canImport(Speech)
import Speech
#endif

public enum SystemProviderUnavailableBehavior: String, Codable, Hashable, Sendable {
    case fail
}

public enum AppleSpeechUnsupportedFeature: String, Codable, Hashable, Sendable {
    case translation
    case wordTimestamps
    case diarization
}

public struct AppleSpeechEngineConfiguration: Hashable, Sendable {
    public var providerUnavailableBehavior: SystemProviderUnavailableBehavior

    public init(providerUnavailableBehavior: SystemProviderUnavailableBehavior = .fail) {
        self.providerUnavailableBehavior = providerUnavailableBehavior
    }
}

public enum AppleSpeechEngineError: Error, LocalizedError, Sendable {
    case unavailable(SpeechProviderAvailability)
    case unsupportedFeatures(Set<AppleSpeechUnsupportedFeature>)
    case notPrepared
    case audioEncodingFailed

    public var errorDescription: String? {
        switch self {
        case .unavailable(let availability):
            return availability.displayMessage
        case .unsupportedFeatures(let features):
            let labels = features.map(\.rawValue).sorted().joined(separator: ", ")
            return "Apple Speech does not support these transcription options: \(labels)."
        case .notPrepared:
            return "Apple Speech has not been prepared for a locale."
        case .audioEncodingFailed:
            return "Could not encode audio for Apple Speech."
        }
    }
}

struct AppleAnalyzerInputClock {
    private var nextStartTime: TimeInterval?

    mutating func claimStartTime(
        sourceStartTime: TimeInterval,
        frameCount: Int,
        sampleRate: Double
    ) -> TimeInterval {
        let startTime = max(sourceStartTime, nextStartTime ?? sourceStartTime)
        if sampleRate > 0 {
            nextStartTime = startTime + Double(frameCount) / sampleRate
        } else {
            nextStartTime = startTime
        }
        return startTime
    }
}

public actor AppleSpeechEngine: @preconcurrency CarbocationLocalSpeech.SpeechTranscriber {
    public static let shared = AppleSpeechEngine()
    public static let systemModelID = SpeechSystemModelID.appleSpeech
    public static let displayName = "Apple Speech"

    private let configuration: AppleSpeechEngineConfiguration
    private var preparedLocale: Locale?

    public init(configuration: AppleSpeechEngineConfiguration = AppleSpeechEngineConfiguration()) {
        self.configuration = configuration
    }

    public nonisolated static var isBuiltWithModernSpeechSDK: Bool {
        #if canImport(Speech)
        true
        #else
        false
        #endif
    }

    public nonisolated static func availability(locale: Locale) async -> SpeechProviderAvailability {
        #if canImport(Speech)
        guard #available(macOS 26.0, *) else {
            return .unavailable(.operatingSystemUnavailable)
        }
        return await modernAvailability(locale: locale)
        #else
        _ = locale
        return .unavailable(.sdkUnavailable)
        #endif
    }

    public nonisolated static func systemModelOption(locale: Locale) async -> SpeechSystemModelOption? {
        let availability = await availability(locale: locale)
        guard availability.shouldOfferModelOption else { return nil }
        let subtitle: String
        if availability.isAvailable {
            subtitle = "Built-in on-device speech recognition"
        } else {
            subtitle = availability.displayMessage
        }
        return SpeechSystemModelOption(
            selection: .system(systemModelID),
            displayName: displayName,
            subtitle: subtitle,
            systemImageName: "waveform.and.mic",
            capabilities: .appleSpeechDefault,
            availability: availability
        )
    }

    public func prepare(locale: Locale, installAssetsIfNeeded: Bool) async throws {
        #if canImport(Speech)
        if #available(macOS 26.0, *) {
            try await Self.requestSpeechRecognitionAuthorizationIfNeeded()
        }
        #endif

        let availability = await Self.availability(locale: locale)
        if availability.isAvailable {
            preparedLocale = locale
            return
        }

        if availability == .unavailable(.assetDownloadRequired), installAssetsIfNeeded {
            #if canImport(Speech)
            guard #available(macOS 26.0, *) else {
                throw AppleSpeechEngineError.unavailable(.unavailable(.operatingSystemUnavailable))
            }
            try await Self.installAssets(locale: locale)
            let postInstallAvailability = await Self.availability(locale: locale)
            guard postInstallAvailability.isAvailable else {
                throw AppleSpeechEngineError.unavailable(postInstallAvailability)
            }
            preparedLocale = locale
            return
            #else
            throw AppleSpeechEngineError.unavailable(.unavailable(.sdkUnavailable))
            #endif
        }

        throw AppleSpeechEngineError.unavailable(availability)
    }

    public func transcribe(file url: URL, options: TranscriptionOptions) async throws -> Transcript {
        let unsupported = Self.unsupportedFeatures(for: options)
        guard unsupported.isEmpty else {
            throw AppleSpeechEngineError.unsupportedFeatures(unsupported)
        }

        let locale = preparedLocale ?? Locale(identifier: options.language ?? Locale.current.identifier)
        if preparedLocale == nil {
            try await prepare(locale: locale, installAssetsIfNeeded: false)
        }

        #if canImport(Speech)
        guard #available(macOS 26.0, *) else {
            throw AppleSpeechEngineError.unavailable(.unavailable(.operatingSystemUnavailable))
        }
        return try await Self.transcribeWithModernSpeech(file: url, locale: locale, options: options)
        #else
        throw AppleSpeechEngineError.unavailable(.unavailable(.sdkUnavailable))
        #endif
    }

    public func transcribe(audio: PreparedAudio, options: TranscriptionOptions) async throws -> Transcript {
        let url = try Self.writeTemporaryAudioFile(audio)
        defer { try? FileManager.default.removeItem(at: url) }
        return try await transcribe(file: url, options: options)
    }

    public func stream(
        audio: AsyncThrowingStream<AudioChunk, Error>,
        options: StreamingTranscriptionOptions
    ) -> AsyncThrowingStream<TranscriptEvent, Error> {
        let backend = SpeechBackendDescriptor(
            kind: .appleSpeech,
            displayName: Self.displayName,
            selection: .system(Self.systemModelID)
        )

        if options.implementation != .emulated {
            let locale = preparedLocale ?? Locale(identifier: options.transcription.language ?? Locale.current.identifier)
            #if canImport(Speech)
            if #available(macOS 26.0, *) {
                return Self.streamWithModernSpeech(
                    audio: audio,
                    locale: locale,
                    backend: backend,
                    options: options
                )
            }
            #endif

            if options.implementation == .native {
                return AsyncThrowingStream { continuation in
                    continuation.finish(throwing: AppleSpeechEngineError.unavailable(.unavailable(.operatingSystemUnavailable)))
                }
            }
        }

        let engine = self
        return SpeechChunkStreamingPipeline.stream(
            audio: audio,
            backend: backend,
            options: options
        ) { audio, transcriptionOptions in
            try await engine.transcribe(audio: audio, options: transcriptionOptions)
        }
    }

    public nonisolated static func unsupportedFeatures(
        for options: TranscriptionOptions
    ) -> Set<AppleSpeechUnsupportedFeature> {
        var unsupported = Set<AppleSpeechUnsupportedFeature>()
        if options.task == .translate {
            unsupported.insert(.translation)
        }
        if options.timestampMode == .words {
            unsupported.insert(.wordTimestamps)
        }
        return unsupported
    }

    private nonisolated static func writeTemporaryAudioFile(_ audio: PreparedAudio) throws -> URL {
        let buffer = try pcm16MonoBuffer(samples: audio.samples, sampleRate: audio.sampleRate)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cls-apple-speech-\(UUID().uuidString).caf")
        let file = try AVAudioFile(forWriting: url, settings: buffer.format.settings)
        try file.write(from: buffer)
        return url
    }

    private nonisolated static func buffer(
        from chunk: AudioChunk,
        outputFormat: AVAudioFormat
    ) throws -> (buffer: AVAudioPCMBuffer, startTime: TimeInterval) {
        let prepared = try AudioResampler16kMono(targetSampleRate: outputFormat.sampleRate).prepareChunk(chunk)
        return try (pcm16MonoBuffer(samples: prepared.samples, format: outputFormat), prepared.startTime)
    }

    private nonisolated static func pcm16MonoBuffer(samples: [Float], sampleRate: Double) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AppleSpeechEngineError.audioEncodingFailed
        }
        return try pcm16MonoBuffer(samples: samples, format: format)
    }

    private nonisolated static func pcm16MonoBuffer(samples: [Float], format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard format.commonFormat == .pcmFormatInt16,
              format.channelCount == 1,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
              ) else {
            throw AppleSpeechEngineError.audioEncodingFailed
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let channel = buffer.int16ChannelData?[0] else {
            throw AppleSpeechEngineError.audioEncodingFailed
        }
        for (index, sample) in samples.enumerated() {
            channel[index] = pcm16Sample(from: sample)
        }

        return buffer
    }

    private nonisolated static func pcm16Sample(from sample: Float) -> Int16 {
        if sample >= 1 {
            return Int16.max
        }
        if sample <= -1 {
            return Int16.min
        }
        return Int16(sample * Float(Int16.max))
    }
}

#if canImport(Speech)
extension AppleSpeechEngine {
    @available(macOS 26.0, *)
    private nonisolated static func modernAvailability(locale: Locale) async -> SpeechProviderAvailability {
        guard Speech.SpeechTranscriber.isAvailable else {
            return .unavailable(.deviceNotEligible)
        }

        switch SFSpeechRecognizer.authorizationStatus() {
        case .denied, .restricted:
            return .unavailable(.speechRecognitionDenied)
        case .authorized, .notDetermined:
            break
        @unknown default:
            break
        }

        guard let supportedLocale = await Speech.SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            return .unavailable(.localeUnsupported)
        }

        return await availabilityForAssets(supporting: assetModules(for: supportedLocale))
    }

    @available(macOS 26.0, *)
    private nonisolated static func installAssets(locale: Locale) async throws {
        guard let supportedLocale = await Speech.SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw AppleSpeechEngineError.unavailable(.unavailable(.localeUnsupported))
        }
        try await Speech.AssetInventory.reserve(locale: supportedLocale)
        if let request = try await Speech.AssetInventory.assetInstallationRequest(supporting: assetModules(for: supportedLocale)) {
            try await request.downloadAndInstall()
        }
    }

    @available(macOS 26.0, *)
    private nonisolated static func requestSpeechRecognitionAuthorizationIfNeeded() async throws {
        let currentStatus = SFSpeechRecognizer.authorizationStatus()
        if currentStatus == .notDetermined {
            let requestedStatus = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
            try throwIfSpeechRecognitionUnauthorized(requestedStatus)
        } else {
            try throwIfSpeechRecognitionUnauthorized(currentStatus)
        }
    }

    @available(macOS 26.0, *)
    private nonisolated static func throwIfSpeechRecognitionUnauthorized(_ status: SFSpeechRecognizerAuthorizationStatus) throws {
        switch status {
        case .authorized, .notDetermined:
            return
        case .denied, .restricted:
            throw AppleSpeechEngineError.unavailable(.unavailable(.speechRecognitionDenied))
        @unknown default:
            throw AppleSpeechEngineError.unavailable(.unavailable(.unknown))
        }
    }

    @available(macOS 26.0, *)
    private nonisolated static func assetModules(for supportedLocale: Locale) -> [any Speech.SpeechModule] {
        [
            Speech.SpeechTranscriber(locale: supportedLocale, preset: .transcription),
            Speech.DictationTranscriber(locale: supportedLocale, preset: liveDictationPreset(strategy: .automatic))
        ]
    }

    @available(macOS 26.0, *)
    private nonisolated static func liveDictationPreset(
        strategy: StreamingTranscriptionStrategy
    ) -> Speech.DictationTranscriber.Preset {
        var preset: Speech.DictationTranscriber.Preset
        switch strategy {
        case .accurate, .fileQuality:
            preset = .progressiveLongDictation
        case .automatic, .lowestLatency, .balanced:
            preset = .progressiveShortDictation
        }
        preset.reportingOptions.insert(.volatileResults)
        preset.reportingOptions.insert(.frequentFinalization)
        preset.attributeOptions.insert(.audioTimeRange)
        return preset
    }

    private nonisolated static func liveDictationPresetName(
        strategy: StreamingTranscriptionStrategy
    ) -> String {
        switch strategy {
        case .accurate, .fileQuality:
            return "progressiveLongDictation"
        case .automatic, .lowestLatency, .balanced:
            return "progressiveShortDictation"
        }
    }

    @available(macOS 26.0, *)
    private nonisolated static func liveAnalyzerOptions() -> Speech.SpeechAnalyzer.Options {
        Speech.SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .whileInUse)
    }

    @available(macOS 26.0, *)
    private nonisolated static func speechDetectionOptions(for options: VoiceActivityDetectionOptions) -> Speech.SpeechDetector.DetectionOptions {
        let sensitivity: Speech.SpeechDetector.SensitivityLevel
        switch options.sensitivity {
        case .low:
            sensitivity = .low
        case .medium:
            sensitivity = .medium
        case .high:
            sensitivity = .high
        }
        return Speech.SpeechDetector.DetectionOptions(sensitivityLevel: sensitivity)
    }

    private nonisolated static func shouldUseModelVAD(options: TranscriptionOptions, isStreaming: Bool) -> Bool {
        switch options.voiceActivityDetection.mode {
        case .enabled:
            return true
        case .disabled:
            return false
        case .automatic:
            return isStreaming && options.useCase == .dictation
        }
    }

    @available(macOS 26.0, *)
    private nonisolated static func availabilityForAssets(supporting modules: [any Speech.SpeechModule]) async -> SpeechProviderAvailability {
        let status = await Speech.AssetInventory.status(forModules: modules)
        switch status {
        case .installed:
            return .available
        case .supported:
            return .unavailable(.assetDownloadRequired)
        case .downloading:
            return .unavailable(.assetNotReady)
        case .unsupported:
            return .unavailable(.localeUnsupported)
        @unknown default:
            return .unavailable(.unknown)
        }
    }

    @available(macOS 26.0, *)
    private nonisolated static func ensureAssetsInstalled(supporting modules: [any Speech.SpeechModule]) async throws {
        let availability = await availabilityForAssets(supporting: modules)
        guard availability.isAvailable else {
            throw AppleSpeechEngineError.unavailable(availability)
        }
    }

    @available(macOS 26.0, *)
    private nonisolated static func transcribeWithModernSpeech(
        file url: URL,
        locale: Locale,
        options: TranscriptionOptions
    ) async throws -> Transcript {
        guard let supportedLocale = await Speech.SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw AppleSpeechEngineError.unavailable(.unavailable(.localeUnsupported))
        }

        let preset: Speech.SpeechTranscriber.Preset = options.useCase == .dictation
            ? .timeIndexedProgressiveTranscription
            : .transcription
        let transcriber = Speech.SpeechTranscriber(locale: supportedLocale, preset: preset)
        var modules: [any Speech.SpeechModule] = [transcriber]
        if shouldUseModelVAD(options: options, isStreaming: false) {
            let speechDetector = Speech.SpeechDetector(
                detectionOptions: speechDetectionOptions(for: options.voiceActivityDetection),
                reportResults: false
            )
            modules = [speechDetector, transcriber]
        }
        try await ensureAssetsInstalled(supporting: modules)
        let analyzer = Speech.SpeechAnalyzer(modules: modules)
        let context = Speech.AnalysisContext()
        if !options.contextualStrings.isEmpty {
            context.contextualStrings[.general] = options.contextualStrings
            try await analyzer.setContext(context)
        }

        let prepared = try await AudioResampler16kMono().prepareFile(at: url)
        let analysisURL = try writeTemporaryAudioFile(prepared)
        defer { try? FileManager.default.removeItem(at: analysisURL) }

        let audioFile = try AVAudioFile(forReading: analysisURL)
        let collector = Task<[TranscriptSegment], Error> {
            var segments: [TranscriptSegment] = []
            for try await result in transcriber.results {
                guard result.isFinal else { continue }

                let segment = segment(from: result)
                if !segment.text.isEmpty {
                    segments.append(segment)
                }
            }
            return segments
        }

        try await analyzer.prepareToAnalyze(in: audioFile.processingFormat)
        if let lastSampleTime = try await analyzer.analyzeSequence(from: audioFile) {
            try await analyzer.finalizeAndFinish(through: lastSampleTime)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        let segments = try await collector.value
        let duration = audioFile.length > 0
            ? Double(audioFile.length) / audioFile.processingFormat.sampleRate
            : segments.last?.endTime
        return Transcript(
            segments: segments,
            language: SpeechLanguage(code: supportedLocale.identifier),
            duration: duration,
            backend: SpeechBackendDescriptor(
                kind: .appleSpeech,
                displayName: displayName,
                selection: .system(systemModelID)
            )
        )
    }

    @available(macOS 26.0, *)
    private nonisolated static func streamWithModernSpeech(
        audio: AsyncThrowingStream<AudioChunk, Error>,
        locale: Locale,
        backend: SpeechBackendDescriptor,
        options: StreamingTranscriptionOptions
    ) -> AsyncThrowingStream<TranscriptEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let unsupported = unsupportedFeatures(for: options.transcription)
                    guard unsupported.isEmpty else {
                        throw AppleSpeechEngineError.unsupportedFeatures(unsupported)
                    }
                    try await requestSpeechRecognitionAuthorizationIfNeeded()
                    guard let supportedLocale = await Speech.DictationTranscriber.supportedLocale(equivalentTo: locale) else {
                        throw AppleSpeechEngineError.unavailable(.unavailable(.localeUnsupported))
                    }

                    let transcriber = Speech.DictationTranscriber(locale: supportedLocale, preset: liveDictationPreset(strategy: options.strategy))
                    var speechDetector: Speech.SpeechDetector?
                    var reportedSpeechDetector: Speech.SpeechDetector?
                    var modules: [any Speech.SpeechModule] = [transcriber]
                    if shouldUseModelVAD(options: options.transcription, isStreaming: true) {
                        let reportDetectorResults = options.transcription.voiceActivityDetection.mode == .enabled
                        let candidate = Speech.SpeechDetector(
                            detectionOptions: speechDetectionOptions(for: options.transcription.voiceActivityDetection),
                            reportResults: reportDetectorResults
                        )
                        let candidateModules: [any Speech.SpeechModule] = [candidate, transcriber]
                        switch options.transcription.voiceActivityDetection.mode {
                        case .enabled:
                            try await ensureAssetsInstalled(supporting: candidateModules)
                            speechDetector = candidate
                            reportedSpeechDetector = candidate
                            modules = candidateModules
                        case .automatic:
                            let availability = await availabilityForAssets(supporting: candidateModules)
                            if availability.isAvailable {
                                speechDetector = candidate
                                if reportDetectorResults {
                                    reportedSpeechDetector = candidate
                                }
                                modules = candidateModules
                            } else {
                                continuation.yield(.diagnostic(TranscriptionDiagnostic(
                                    source: "apple.vad",
                                    message: "SpeechDetector unavailable; falling back to energy voice activity events"
                                )))
                            }
                        case .disabled:
                            break
                        }
                    }
                    try await ensureAssetsInstalled(supporting: modules)
                    guard let analysisFormat = await Speech.SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
                        throw AppleSpeechEngineError.audioEncodingFailed
                    }
                    let analyzer = Speech.SpeechAnalyzer(modules: modules, options: liveAnalyzerOptions())
                    let context = Speech.AnalysisContext()
                    if !options.transcription.contextualStrings.isEmpty {
                        context.contextualStrings[.general] = options.transcription.contextualStrings
                        try await analyzer.setContext(context)
                    }

                    guard analysisFormat.commonFormat == .pcmFormatInt16,
                          analysisFormat.channelCount == 1 else {
                        throw AppleSpeechEngineError.audioEncodingFailed
                    }

                    var inputContinuation: AsyncThrowingStream<Speech.AnalyzerInput, Error>.Continuation?
                    let inputStream = AsyncThrowingStream<Speech.AnalyzerInput, Error>(
                        bufferingPolicy: .bufferingNewest(50)
                    ) { continuation in
                        inputContinuation = continuation
                    }
                    let coordinator = AppleLiveResultCoordinator(
                        language: SpeechLanguage(code: supportedLocale.identifier),
                        backend: backend
                    )

                    continuation.yield(.started(backend))
                    continuation.yield(.diagnostic(TranscriptionDiagnostic(
                        source: "apple.analyzer",
                        message: "modules=\(speechDetector == nil ? "DictationTranscriber" : "SpeechDetector,DictationTranscriber") preset=\(liveDictationPresetName(strategy: options.strategy)) locale=\(supportedLocale.identifier) format=\(describe(format: analysisFormat)) timestamps=implicit"
                    )))
                    try await analyzer.prepareToAnalyze(in: analysisFormat)
                    continuation.yield(.diagnostic(TranscriptionDiagnostic(
                        source: "apple.analyzer",
                        message: "prepared"
                    )))

                    let collector = Task<[TranscriptSegment], Error> {
                        var resultCount = 0

                        for try await result in transcriber.results {
                            try Task.checkCancellation()
                            resultCount += 1
                            let segment = segment(from: result)
                            if shouldLogLiveResult(number: resultCount, isFinal: result.isFinal) {
                                continuation.yield(.diagnostic(TranscriptionDiagnostic(
                                    source: "apple.results",
                                    message: "result #\(resultCount) final=\(result.isFinal) range=\(describe(range: result.range)) textLength=\(segment.text.count) text=\(diagnosticPreview(segment.text))"
                                )))
                            }
                            guard !segment.text.isEmpty else { continue }

                            let update = await coordinator.recordResult(
                                segment,
                                isFinal: result.isFinal
                            )
                            for event in update.events {
                                continuation.yield(event)
                            }
                        }

                        return await coordinator.committedSegments()
                    }

                    let detectorCollector: Task<Void, Error>? = reportedSpeechDetector.map { detector in
                        Task {
                            for try await result in detector.results {
                                try Task.checkCancellation()
                                continuation.yield(.voiceActivity(VoiceActivityEvent(
                                    state: result.speechDetected ? .speech : .silence,
                                    startTime: result.range.start.seconds.finiteOrZero,
                                    endTime: result.range.end.seconds.finiteOrZero
                                )))
                            }
                        }
                    }

                    let analyzerTask = Task {
                        if let lastSampleTime = try await analyzer.analyzeSequence(inputStream) {
                            try await analyzer.finalizeAndFinish(through: lastSampleTime)
                        } else {
                            await analyzer.cancelAndFinishNow()
                        }
                    }
                    let analyzerMonitor = Task {
                        do {
                            try await analyzerTask.value
                            continuation.yield(.diagnostic(TranscriptionDiagnostic(
                                source: "apple.analyzer",
                                message: "analyzeSequence finished"
                            )))
                        } catch is CancellationError {
                            continuation.yield(.diagnostic(TranscriptionDiagnostic(
                                source: "apple.analyzer",
                                message: "analyzeSequence cancelled"
                            )))
                        } catch {
                            continuation.yield(.diagnostic(TranscriptionDiagnostic(
                                source: "apple.analyzer",
                                message: "analyzeSequence failed: \(error.localizedDescription)"
                            )))
                            continuation.finish(throwing: error)
                        }
                    }
                    let collectorMonitor = Task {
                        do {
                            let segments = try await collector.value
                            continuation.yield(.diagnostic(TranscriptionDiagnostic(
                                source: "apple.results",
                                message: "result stream finished segments=\(segments.count)"
                            )))
                        } catch is CancellationError {
                            continuation.yield(.diagnostic(TranscriptionDiagnostic(
                                source: "apple.results",
                                message: "result stream cancelled"
                            )))
                        } catch {
                            continuation.yield(.diagnostic(TranscriptionDiagnostic(
                                source: "apple.results",
                                message: "result stream failed: \(error.localizedDescription)"
                            )))
                            continuation.finish(throwing: error)
                        }
                    }
                    defer {
                        inputContinuation?.finish()
                        analyzerTask.cancel()
                        collector.cancel()
                        detectorCollector?.cancel()
                        analyzerMonitor.cancel()
                        collectorMonitor.cancel()
                    }

                    var processedDuration: TimeInterval = 0
                    var inputCount = 0
                    var inputClock = AppleAnalyzerInputClock()
                    let fallbackDetector = EnergyVoiceActivityDetector()
                    let shouldReportFallbackVAD = reportedSpeechDetector == nil
                        && options.transcription.voiceActivityDetection.mode != .disabled
                    for try await chunk in audio {
                        try Task.checkCancellation()

                        continuation.yield(.audioLevel(AudioLevelMeter.measure(samples: chunk.samples, time: chunk.startTime)))
                        if shouldReportFallbackVAD {
                            continuation.yield(.voiceActivity(try fallbackDetector.analyze(chunk)))
                        }
                        let converted = try buffer(from: chunk, outputFormat: analysisFormat)
                        let analyzerStartTime = inputClock.claimStartTime(
                            sourceStartTime: converted.startTime,
                            frameCount: Int(converted.buffer.frameLength),
                            sampleRate: converted.buffer.format.sampleRate
                        )
                        let analyzerEndTime = analyzerStartTime + Double(converted.buffer.frameLength) / converted.buffer.format.sampleRate
                        processedDuration = max(processedDuration, analyzerEndTime)
                        continuation.yield(.progress(TranscriptionProgress(processedDuration: processedDuration)))
                        inputCount += 1
                        if inputCount <= 5 || inputCount.isMultiple(of: 20) {
                            let adjusted = analyzerStartTime > converted.startTime + 0.000_001
                            continuation.yield(.diagnostic(TranscriptionDiagnostic(
                                source: "apple.input",
                                message: "chunk #\(inputCount) start=\(analyzerStartTime.formattedDebug)\(adjusted ? " sourceStart=\(converted.startTime.formattedDebug)" : "") frames=\(converted.buffer.frameLength) format=\(describe(format: converted.buffer.format))",
                                time: analyzerStartTime
                            )))
                        }
                        let input = Speech.AnalyzerInput(buffer: converted.buffer)
                        if let inputContinuation {
                            inputContinuation.yield(input)
                        } else {
                            continuation.yield(.diagnostic(TranscriptionDiagnostic(
                                source: "apple.input",
                                message: "input continuation missing",
                                time: analyzerStartTime
                            )))
                        }
                    }

                    inputContinuation?.finish()
                    try await analyzerTask.value
                    if let detectorCollector {
                        try await detectorCollector.value
                    }
                    _ = try await collector.value
                    let finalUpdate = await coordinator.finish()
                    for event in finalUpdate.events {
                        continuation.yield(event)
                    }
                    let committedSegments = await coordinator.committedSegments()
                    continuation.yield(.completed(Transcript(
                        segments: committedSegments,
                        language: SpeechLanguage(code: supportedLocale.identifier),
                        duration: processedDuration,
                        backend: backend
                    )))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    @available(macOS 26.0, *)
    private nonisolated static func segment(
        from result: Speech.SpeechTranscriber.Result
    ) -> TranscriptSegment {
        segment(text: result.text, range: result.range)
    }

    @available(macOS 26.0, *)
    private nonisolated static func segment(
        from result: Speech.DictationTranscriber.Result
    ) -> TranscriptSegment {
        segment(text: result.text, range: result.range)
    }

    @available(macOS 26.0, *)
    private nonisolated static func segment(
        text: AttributedString,
        range: CMTimeRange
    ) -> TranscriptSegment {
        let start = range.start.seconds.finiteOrZero
        let duration = range.duration.seconds.finiteOrZero
        let text = String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        return TranscriptSegment(
            text: text,
            startTime: start,
            endTime: start + max(0, duration),
            confidence: nil
        )
    }

    fileprivate nonisolated static func uncommittedSegment(
        from segment: TranscriptSegment,
        after committedSegments: [TranscriptSegment]
    ) -> TranscriptSegment? {
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let trimResult = trimPreviouslyCommittedText(
            in: text,
            after: committedSegments,
            segmentStartTime: segment.startTime
        )
        let finalText = (trimResult.removedTokenCount > 0 ? trimResult.text : text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finalText.isEmpty else { return nil }

        let startTime: TimeInterval
        if trimResult.removedTokenCount > 0 {
            startTime = max(segment.startTime, committedSegments.last?.endTime ?? segment.startTime)
        } else {
            startTime = segment.startTime
        }

        return TranscriptSegment(
            id: segment.id,
            text: finalText,
            startTime: startTime,
            endTime: max(startTime, segment.endTime),
            words: [],
            speaker: segment.speaker,
            confidence: segment.confidence
        )
    }

    private nonisolated static func trimPreviouslyCommittedText(
        in text: String,
        after committedSegments: [TranscriptSegment],
        segmentStartTime: TimeInterval
    ) -> (text: String, removedTokenCount: Int) {
        guard !committedSegments.isEmpty else {
            return (text, 0)
        }

        if let firstCommittedStart = committedSegments.first?.startTime,
           segmentStartTime <= firstCommittedStart + 0.25 {
            let committedText = committedSegments.map(\.text).joined(separator: " ")
            let trimResult = trimCommonPrefix(in: text, after: committedText)
            if trimResult.removedTokenCount > 0 {
                return trimResult
            }
        }

        let committedOverlap = committedOverlapText(from: committedSegments)
        return trimDuplicatePrefix(in: text, after: committedOverlap)
    }

    private nonisolated static func trimCommonPrefix(
        in text: String,
        after committedText: String
    ) -> (text: String, removedTokenCount: Int) {
        let committedTokens = tokens(in: committedText)
        let newTokens = tokens(in: text)
        guard !committedTokens.isEmpty, !newTokens.isEmpty else {
            return (text, 0)
        }

        let committedNormalized = committedTokens.map(\.normalized)
        let newNormalized = newTokens.map(\.normalized)
        var commonTokenCount = 0
        while commonTokenCount < committedNormalized.count,
              commonTokenCount < newNormalized.count,
              committedNormalized[commonTokenCount] == newNormalized[commonTokenCount] {
            commonTokenCount += 1
        }

        guard commonTokenCount > 0 else {
            return (text, 0)
        }

        let cutIndex = newTokens[commonTokenCount - 1].range.upperBound
        let trimmed = trimLeadingSeparators(String(text[cutIndex...]))
        return (trimmed, commonTokenCount)
    }

    private nonisolated static func committedOverlapText(from segments: [TranscriptSegment]) -> String {
        let maximumOverlapTokenCount = 12
        var collectedTexts: [String] = []
        var collectedTokenCount = 0

        for segment in segments.reversed() {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let textTokens = tokens(in: text)
            guard !textTokens.isEmpty else { continue }

            let neededTokenCount = maximumOverlapTokenCount - collectedTokenCount
            if textTokens.count > neededTokenCount {
                let suffixStart = textTokens[textTokens.count - neededTokenCount].range.lowerBound
                collectedTexts.append(String(text[suffixStart...]).trimmingCharacters(in: .whitespacesAndNewlines))
                break
            }

            collectedTexts.append(text)
            collectedTokenCount += textTokens.count
            if collectedTokenCount >= maximumOverlapTokenCount { break }
        }

        return collectedTexts.reversed().joined(separator: " ")
    }

    private nonisolated static func trimDuplicatePrefix(
        in text: String,
        after committedText: String
    ) -> (text: String, removedTokenCount: Int) {
        let committedTokens = tokens(in: committedText)
        let newTokens = tokens(in: text)
        guard !committedTokens.isEmpty, !newTokens.isEmpty else {
            return (text, 0)
        }

        let maximumOverlap = min(committedTokens.count, newTokens.count, 12)
        var duplicateTokenCount = 0
        for count in stride(from: maximumOverlap, through: 1, by: -1) {
            let committedSuffix = committedTokens.suffix(count).map(\.normalized)
            let newPrefix = newTokens.prefix(count).map(\.normalized)
            if Array(committedSuffix) == Array(newPrefix) {
                duplicateTokenCount = count
                break
            }
        }

        guard duplicateTokenCount > 0 else {
            return (text, 0)
        }

        let cutIndex = newTokens[duplicateTokenCount - 1].range.upperBound
        let trimmed = trimLeadingSeparators(String(text[cutIndex...]))
        return (trimmed, duplicateTokenCount)
    }

    private nonisolated static func trimLeadingSeparators(_ text: String) -> String {
        let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        var startIndex = text.startIndex

        while startIndex < text.endIndex,
              text[startIndex].unicodeScalars.allSatisfy({ separators.contains($0) }) {
            startIndex = text.index(after: startIndex)
        }

        return String(text[startIndex...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func tokens(in text: String) -> [TranscriptTextToken] {
        var tokens: [TranscriptTextToken] = []
        var tokenStart: String.Index?

        for index in text.indices {
            let character = text[index]
            if character.isLetter || character.isNumber || character == "'" {
                if tokenStart == nil {
                    tokenStart = index
                }
            } else if let start = tokenStart {
                appendToken(from: start, to: index, in: text, tokens: &tokens)
                tokenStart = nil
            }
        }

        if let start = tokenStart {
            appendToken(from: start, to: text.endIndex, in: text, tokens: &tokens)
        }

        return tokens
    }

    private nonisolated static func appendToken(
        from start: String.Index,
        to end: String.Index,
        in text: String,
        tokens: inout [TranscriptTextToken]
    ) {
        let value = String(text[start..<end])
        tokens.append(TranscriptTextToken(
            normalized: value.lowercased(),
            range: start..<end
        ))
    }

    private nonisolated static func shouldLogLiveResult(number: Int, isFinal: Bool) -> Bool {
        isFinal || number <= 5 || number.isMultiple(of: 20)
    }

    private nonisolated static func diagnosticPreview(_ text: String, limit: Int = 120) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return "\(trimmed.prefix(limit))..."
    }

    private nonisolated static func describe(format: AVAudioFormat) -> String {
        "\(describe(commonFormat: format.commonFormat)) \(format.sampleRate.formattedDebug)Hz channels=\(format.channelCount) interleaved=\(format.isInterleaved)"
    }

    private nonisolated static func describe(commonFormat: AVAudioCommonFormat) -> String {
        switch commonFormat {
        case .pcmFormatFloat32:
            return "float32"
        case .pcmFormatFloat64:
            return "float64"
        case .pcmFormatInt16:
            return "int16"
        case .pcmFormatInt32:
            return "int32"
        case .otherFormat:
            return "other"
        @unknown default:
            return "unknown"
        }
    }

    private nonisolated static func describe(range: CMTimeRange) -> String {
        "\(range.start.seconds.finiteOrZero.formattedDebug)-\(range.end.seconds.finiteOrZero.formattedDebug)"
    }

}

private struct AppleLiveResultUpdate: Sendable {
    var events: [TranscriptEvent] = []
}

@available(macOS 26.0, *)
private actor AppleLiveResultCoordinator {
    private let language: SpeechLanguage
    private let backend: SpeechBackendDescriptor
    private var committed: [TranscriptSegment] = []
    private var volatile: TranscriptSegment?
    private var lastVolatileEmission = Date.distantPast

    private let volatileEmissionInterval: TimeInterval = 0.25

    init(language: SpeechLanguage, backend: SpeechBackendDescriptor) {
        self.language = language
        self.backend = backend
    }

    func committedSegments() -> [TranscriptSegment] {
        committed
    }

    func recordResult(_ segment: TranscriptSegment, isFinal: Bool) -> AppleLiveResultUpdate {
        if isFinal {
            volatile = nil
            _ = appendCommitted(segment)
            return update(events: [.snapshot(snapshot(volatile: nil))])
        }

        volatile = AppleSpeechEngine.uncommittedSegment(from: segment, after: committed)
        return update(events: volatileStateEvents(force: false))
    }

    func finish() -> AppleLiveResultUpdate {
        if let volatile {
            _ = appendCommitted(volatile)
            self.volatile = nil
        }
        return update(events: [.snapshot(snapshot(volatile: nil))])
    }

    private func volatileStateEvents(force: Bool) -> [TranscriptEvent] {
        guard let volatile else {
            guard force else { return [] }
            return [.snapshot(snapshot(volatile: nil))]
        }

        let now = Date()
        let shouldEmit = force
            || now.timeIntervalSince(lastVolatileEmission) >= volatileEmissionInterval
        guard shouldEmit else { return [] }

        lastVolatileEmission = now
        let volatileTranscript = Transcript(
            segments: [volatile],
            language: language,
            backend: backend
        )
        return [.snapshot(snapshot(volatile: volatileTranscript))]
    }

    private func snapshot(volatile: Transcript?) -> StreamingTranscriptSnapshot {
        StreamingTranscriptSnapshot(
            stable: Transcript(
                segments: committed,
                language: language,
                backend: backend
            ),
            volatile: volatile,
            volatileRange: volatileRange(for: volatile)
        )
    }

    private func update(events: [TranscriptEvent]) -> AppleLiveResultUpdate {
        AppleLiveResultUpdate(events: events)
    }

    private func appendCommitted(_ segment: TranscriptSegment) -> Bool {
        guard let committedSegment = AppleSpeechEngine.uncommittedSegment(
            from: segment,
            after: committed
        ) else {
            return false
        }

        if committed.contains(where: { sameRange($0, committedSegment) && $0.text == committedSegment.text }) {
            return false
        }

        committed.append(committedSegment)
        return true
    }

    private func sameRange(_ lhs: TranscriptSegment, _ rhs: TranscriptSegment) -> Bool {
        abs(lhs.startTime - rhs.startTime) < 0.01
            && abs(lhs.endTime - rhs.endTime) < 0.01
    }

    private func volatileRange(for transcript: Transcript?) -> TranscriptTimeRange? {
        guard let first = transcript?.segments.first,
              let last = transcript?.segments.last else {
            return nil
        }
        return TranscriptTimeRange(
            startTime: first.startTime,
            endTime: max(first.startTime, last.endTime)
        )
    }
}

private extension Double {
    var finiteOrZero: Double {
        isFinite ? self : 0
    }

    var formattedDebug: String {
        String(format: "%.3f", self)
    }
}

private struct TranscriptTextToken {
    var normalized: String
    var range: Range<String.Index>
}
#endif
