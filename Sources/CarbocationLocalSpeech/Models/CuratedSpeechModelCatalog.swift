import Foundation

public enum CuratedSpeechModelRecommendation: Hashable, Sendable {
    case bestLiveEnglish
    case bestLiveMultilingual
    case bestFile
}

public struct CuratedSpeechModel: Identifiable, Hashable, Sendable {
    public var id: String
    public var displayName: String
    public var subtitle: String
    public var family: String
    public var variant: String
    public var languageScope: SpeechLanguageScope
    public var approxSizeBytes: Int64
    public var recommendedRAMGB: Int
    public var sourceURL: URL?
    public var hfRepo: String?
    public var hfFilename: String?
    public var sha256: String?
    public var capabilities: SpeechModelCapabilities
    public var recommendation: CuratedSpeechModelRecommendation?

    public init(
        id: String,
        displayName: String,
        subtitle: String,
        family: String = "whisper.cpp",
        variant: String,
        languageScope: SpeechLanguageScope,
        approxSizeBytes: Int64,
        recommendedRAMGB: Int,
        sourceURL: URL? = nil,
        hfRepo: String? = nil,
        hfFilename: String? = nil,
        sha256: String? = nil,
        capabilities: SpeechModelCapabilities = .whisperCppDefault,
        recommendation: CuratedSpeechModelRecommendation? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.subtitle = subtitle
        self.family = family
        self.variant = variant
        self.languageScope = languageScope
        self.approxSizeBytes = approxSizeBytes
        self.recommendedRAMGB = recommendedRAMGB
        self.sourceURL = sourceURL
        self.hfRepo = hfRepo
        self.hfFilename = hfFilename
        self.sha256 = sha256
        self.capabilities = capabilities
        self.recommendation = recommendation
    }

    public var recommendedRAMBytes: UInt64 {
        UInt64(recommendedRAMGB) * 1_073_741_824
    }

    public var downloadURL: URL? {
        if let sourceURL {
            return sourceURL
        }
        guard let hfRepo, let hfFilename else { return nil }
        return Self.huggingFaceResolveURL(repo: hfRepo, filename: hfFilename)
    }

    public static func huggingFaceResolveURL(repo: String, filename: String) -> URL? {
        URL(string: "https://huggingface.co/\(repo)/resolve/main/\(filename)")
    }
}

public struct CuratedSpeechVADModel: Identifiable, Hashable, Sendable {
    public var id: String
    public var displayName: String
    public var hfRepo: String
    public var hfFilename: String
    public var approxSizeBytes: Int64
    public var sha256: String?

    public init(
        id: String,
        displayName: String,
        hfRepo: String,
        hfFilename: String,
        approxSizeBytes: Int64,
        sha256: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.hfRepo = hfRepo
        self.hfFilename = hfFilename
        self.approxSizeBytes = approxSizeBytes
        self.sha256 = sha256
    }

    public var downloadURL: URL? {
        CuratedSpeechModel.huggingFaceResolveURL(repo: hfRepo, filename: hfFilename)
    }
}

public enum CuratedSpeechModelCatalog {
    private static let whisperCppRepo = "ggerganov/whisper.cpp"
    private static let whisperVADRepo = "ggml-org/whisper-vad"

    public static let recommendedVADModel = CuratedSpeechVADModel(
        id: "silero-v6.2.0",
        displayName: "Silero VAD v6.2.0",
        hfRepo: whisperVADRepo,
        hfFilename: "ggml-silero-v6.2.0.bin",
        approxSizeBytes: 885_000
    )

    public static let all: [CuratedSpeechModel] = [
        CuratedSpeechModel(
            id: "tiny.en",
            displayName: "Whisper tiny.en (English-only)",
            subtitle: "Fastest stock English-only model for lightweight dictation checks.",
            variant: "tiny.en",
            languageScope: .englishOnly,
            approxSizeBytes: 75_000_000,
            recommendedRAMGB: 4,
            hfRepo: whisperCppRepo,
            hfFilename: "ggml-tiny.en.bin"
        ),
        CuratedSpeechModel(
            id: "small.en",
            displayName: "Whisper small.en (English-only)",
            subtitle: "Recommended English-only model for live streaming transcription.",
            variant: "small.en",
            languageScope: .englishOnly,
            approxSizeBytes: 485_000_000,
            recommendedRAMGB: 8,
            hfRepo: whisperCppRepo,
            hfFilename: "ggml-small.en.bin",
            recommendation: .bestLiveEnglish
        ),
        CuratedSpeechModel(
            id: "large-v2",
            displayName: "Whisper large-v2 (multilingual)",
            subtitle: "Recommended model for offline file and translation workflows.",
            variant: "large-v2",
            languageScope: .multilingual,
            approxSizeBytes: 3_090_000_000,
            recommendedRAMGB: 16,
            hfRepo: whisperCppRepo,
            hfFilename: "ggml-large-v2.bin",
            recommendation: .bestFile
        ),
        CuratedSpeechModel(
            id: "large-v3-turbo",
            displayName: "Whisper large-v3 turbo (multilingual)",
            subtitle: "Recommended multilingual model for live streaming transcription.",
            variant: "large-v3-turbo",
            languageScope: .multilingual,
            approxSizeBytes: 1_620_000_000,
            recommendedRAMGB: 16,
            hfRepo: whisperCppRepo,
            hfFilename: "ggml-large-v3-turbo.bin",
            recommendation: .bestLiveMultilingual
        )
    ]

    public static func entry(id: String, among models: [CuratedSpeechModel] = all) -> CuratedSpeechModel? {
        models.first { $0.id == id }
    }

    public static func recommendedModels(
        among models: [CuratedSpeechModel] = all
    ) -> [CuratedSpeechModel] {
        [
            bestLiveEnglishModel(among: models),
            bestLiveMultilingualModel(among: models),
            bestFileModel(among: models)
        ].compactMap { $0 }
    }

    public static func bestLiveEnglishModel(
        among models: [CuratedSpeechModel] = all
    ) -> CuratedSpeechModel? {
        models.first { $0.recommendation == .bestLiveEnglish }
    }

    public static func bestLiveMultilingualModel(
        among models: [CuratedSpeechModel] = all
    ) -> CuratedSpeechModel? {
        models.first { $0.recommendation == .bestLiveMultilingual }
    }

    public static func bestFileModel(
        among models: [CuratedSpeechModel] = all
    ) -> CuratedSpeechModel? {
        models.first { $0.recommendation == .bestFile }
    }

    public static func bestEnglishModel(
        among models: [CuratedSpeechModel] = all
    ) -> CuratedSpeechModel? {
        bestLiveEnglishModel(among: models)
    }

    public static func bestMultilingualModel(
        among models: [CuratedSpeechModel] = all
    ) -> CuratedSpeechModel? {
        bestLiveMultilingualModel(among: models)
    }

    public static func recommendedModel(
        forPhysicalMemoryBytes _: UInt64,
        among models: [CuratedSpeechModel] = all
    ) -> CuratedSpeechModel? {
        recommendedModels(among: models).first
    }
}
