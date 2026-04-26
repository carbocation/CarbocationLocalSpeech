import AVFoundation
import CarbocationLocalSpeech
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
            Speech.SpeechTranscriber(locale: supportedLocale, preset: .timeIndexedProgressiveTranscription),
            Speech.DictationTranscriber(locale: supportedLocale, preset: liveDictationPreset())
        ]
    }

    @available(macOS 26.0, *)
    private nonisolated static func liveDictationPreset() -> Speech.DictationTranscriber.Preset {
        var preset = Speech.DictationTranscriber.Preset.progressiveLongDictation
        preset.reportingOptions.insert(.frequentFinalization)
        preset.attributeOptions.insert(.audioTimeRange)
        return preset
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
        try await ensureAssetsInstalled(supporting: [transcriber])
        let analyzer = Speech.SpeechAnalyzer(modules: [transcriber])
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

                    let transcriber = Speech.DictationTranscriber(locale: supportedLocale, preset: liveDictationPreset())
                    let modules: [any Speech.SpeechModule] = [transcriber]
                    try await ensureAssetsInstalled(supporting: modules)
                    guard let analysisFormat = await Speech.SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
                        throw AppleSpeechEngineError.audioEncodingFailed
                    }
                    let analyzer = Speech.SpeechAnalyzer(modules: modules)
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
                    let inputStream = AsyncThrowingStream<Speech.AnalyzerInput, Error> { continuation in
                        inputContinuation = continuation
                    }

                    continuation.yield(.started(backend))
                    continuation.yield(.diagnostic(TranscriptionDiagnostic(
                        source: "apple.analyzer",
                        message: "module=DictationTranscriber locale=\(supportedLocale.identifier) format=\(describe(format: analysisFormat))"
                    )))
                    try await analyzer.prepareToAnalyze(in: analysisFormat)
                    continuation.yield(.diagnostic(TranscriptionDiagnostic(
                        source: "apple.analyzer",
                        message: "prepared"
                    )))

                    let collector = Task<[TranscriptSegment], Error> {
                        var committedSegments: [TranscriptSegment] = []
                        var pendingPartialID: UUID?
                        var resultCount = 0

                        for try await result in transcriber.results {
                            try Task.checkCancellation()
                            resultCount += 1
                            let segment = segment(from: result)
                            continuation.yield(.diagnostic(TranscriptionDiagnostic(
                                source: "apple.results",
                                message: "result #\(resultCount) final=\(result.isFinal) range=\(describe(range: result.range)) text=\(segment.text)"
                            )))
                            guard !segment.text.isEmpty else { continue }

                            if result.isFinal {
                                committedSegments.append(segment)
                                pendingPartialID = nil
                                continuation.yield(.committed(segment))
                                continuation.yield(.snapshot(StreamingTranscriptSnapshot(
                                    committed: Transcript(
                                        segments: committedSegments,
                                        language: SpeechLanguage(code: supportedLocale.identifier),
                                        backend: backend
                                    )
                                )))
                            } else {
                                let partial = TranscriptPartial(
                                    text: segment.text,
                                    startTime: segment.startTime,
                                    endTime: segment.endTime
                                )
                                if let previousID = pendingPartialID {
                                    continuation.yield(.revision(TranscriptRevision(
                                        replacesPartialID: previousID,
                                        replacement: partial
                                    )))
                                } else {
                                    continuation.yield(.partial(partial))
                                }
                                pendingPartialID = partial.id

                                continuation.yield(.snapshot(StreamingTranscriptSnapshot(
                                    committed: Transcript(
                                        segments: committedSegments,
                                        language: SpeechLanguage(code: supportedLocale.identifier),
                                        backend: backend
                                    ),
                                    unconfirmed: partial,
                                    volatileRange: TranscriptTimeRange(startTime: segment.startTime, endTime: segment.endTime)
                                )))
                            }
                        }

                        return committedSegments
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
                        } catch {
                            continuation.yield(.diagnostic(TranscriptionDiagnostic(
                                source: "apple.analyzer",
                                message: "analyzeSequence failed: \(error.localizedDescription)"
                            )))
                        }
                    }
                    let collectorMonitor = Task {
                        do {
                            let segments = try await collector.value
                            continuation.yield(.diagnostic(TranscriptionDiagnostic(
                                source: "apple.results",
                                message: "result stream finished segments=\(segments.count)"
                            )))
                        } catch {
                            continuation.yield(.diagnostic(TranscriptionDiagnostic(
                                source: "apple.results",
                                message: "result stream failed: \(error.localizedDescription)"
                            )))
                        }
                    }
                    defer {
                        inputContinuation?.finish()
                        analyzerTask.cancel()
                        collector.cancel()
                        analyzerMonitor.cancel()
                        collectorMonitor.cancel()
                    }

                    var processedDuration: TimeInterval = 0
                    var inputCount = 0
                    let detector = EnergyVoiceActivityDetector()
                    for try await chunk in audio {
                        try Task.checkCancellation()

                        continuation.yield(.audioLevel(AudioLevelMeter.measure(samples: chunk.samples, time: chunk.startTime)))
                        continuation.yield(.voiceActivity(try detector.analyze(chunk)))
                        let converted = try buffer(from: chunk, outputFormat: analysisFormat)
                        processedDuration = max(processedDuration, converted.startTime + Double(converted.buffer.frameLength) / converted.buffer.format.sampleRate)
                        continuation.yield(.progress(TranscriptionProgress(processedDuration: processedDuration)))
                        inputCount += 1
                        if inputCount <= 5 || inputCount.isMultiple(of: 20) {
                            continuation.yield(.diagnostic(TranscriptionDiagnostic(
                                source: "apple.input",
                                message: "chunk #\(inputCount) start=\(converted.startTime.formattedDebug) frames=\(converted.buffer.frameLength) format=\(describe(format: converted.buffer.format))",
                                time: converted.startTime
                            )))
                        }
                        let input = Speech.AnalyzerInput(buffer: converted.buffer)
                        if let inputContinuation {
                            inputContinuation.yield(input)
                        } else {
                            continuation.yield(.diagnostic(TranscriptionDiagnostic(
                                source: "apple.input",
                                message: "input continuation missing",
                                time: converted.startTime
                            )))
                        }
                    }

                    inputContinuation?.finish()
                    try await analyzerTask.value
                    let committedSegments = try await collector.value
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

private extension Double {
    var finiteOrZero: Double {
        isFinite ? self : 0
    }

    var formattedDebug: String {
        String(format: "%.3f", self)
    }
}
#endif
