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
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: audio.sampleRate,
            channels: 1,
            interleaved: false
        ),
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(audio.samples.count)
        ) else {
            throw AppleSpeechEngineError.audioEncodingFailed
        }

        buffer.frameLength = AVAudioFrameCount(audio.samples.count)
        guard let channel = buffer.floatChannelData?[0] else {
            throw AppleSpeechEngineError.audioEncodingFailed
        }
        audio.samples.withUnsafeBufferPointer { pointer in
            if let baseAddress = pointer.baseAddress {
                channel.update(from: baseAddress, count: pointer.count)
            }
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cls-apple-speech-\(UUID().uuidString).caf")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
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

        let transcriber = Speech.SpeechTranscriber(locale: supportedLocale, preset: .transcription)
        let status = await Speech.AssetInventory.status(forModules: [transcriber])
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
    private nonisolated static func installAssets(locale: Locale) async throws {
        guard let supportedLocale = await Speech.SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw AppleSpeechEngineError.unavailable(.unavailable(.localeUnsupported))
        }
        try await Speech.AssetInventory.reserve(locale: supportedLocale)
        let transcriber = Speech.SpeechTranscriber(locale: supportedLocale, preset: .transcription)
        if let request = try await Speech.AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
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
            ? .progressiveTranscription
            : .transcription
        let transcriber = Speech.SpeechTranscriber(locale: supportedLocale, preset: preset)
        let analyzer = Speech.SpeechAnalyzer(modules: [transcriber])
        let context = Speech.AnalysisContext()
        if !options.contextualStrings.isEmpty {
            context.contextualStrings[.general] = options.contextualStrings
            try await analyzer.setContext(context)
        }

        let audioFile = try AVAudioFile(forReading: url)
        let collector = Task<[TranscriptSegment], Error> {
            var segments: [TranscriptSegment] = []
            for try await result in transcriber.results {
                let segment = segment(from: result)
                if !segment.text.isEmpty {
                    segments.append(segment)
                }
            }
            return segments
        }

        try await analyzer.prepareToAnalyze(in: audioFile.processingFormat)
        _ = try await analyzer.analyzeSequence(from: audioFile)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
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
    private nonisolated static func segment(
        from result: Speech.SpeechTranscriber.Result
    ) -> TranscriptSegment {
        let start = result.range.start.seconds.finiteOrZero
        let duration = result.range.duration.seconds.finiteOrZero
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        return TranscriptSegment(
            text: text,
            startTime: start,
            endTime: start + max(0, duration),
            confidence: nil
        )
    }
}

private extension Double {
    var finiteOrZero: Double {
        isFinite ? self : 0
    }
}
#endif
