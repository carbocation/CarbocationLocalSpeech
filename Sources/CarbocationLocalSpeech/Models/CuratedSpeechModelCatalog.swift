import Foundation

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
        capabilities: SpeechModelCapabilities = .whisperCppDefault
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
    }

    public var recommendedRAMBytes: UInt64 {
        UInt64(recommendedRAMGB) * 1_073_741_824
    }
}

public enum CuratedSpeechModelCatalog {
    public static let all: [CuratedSpeechModel] = [
        CuratedSpeechModel(
            id: "tiny.en",
            displayName: "Whisper tiny.en",
            subtitle: "Fastest English-only model for lightweight dictation checks.",
            variant: "tiny.en",
            languageScope: .englishOnly,
            approxSizeBytes: 75_000_000,
            recommendedRAMGB: 4
        ),
        CuratedSpeechModel(
            id: "base.en",
            displayName: "Whisper base.en",
            subtitle: "Small English-only default for low-latency local dictation.",
            variant: "base.en",
            languageScope: .englishOnly,
            approxSizeBytes: 145_000_000,
            recommendedRAMGB: 4
        ),
        CuratedSpeechModel(
            id: "small.en",
            displayName: "Whisper small.en",
            subtitle: "Better English accuracy while remaining practical on most Macs.",
            variant: "small.en",
            languageScope: .englishOnly,
            approxSizeBytes: 485_000_000,
            recommendedRAMGB: 8
        ),
        CuratedSpeechModel(
            id: "medium.en",
            displayName: "Whisper medium.en",
            subtitle: "Higher-quality English transcription for file and meeting audio.",
            variant: "medium.en",
            languageScope: .englishOnly,
            approxSizeBytes: 1_530_000_000,
            recommendedRAMGB: 16
        ),
        CuratedSpeechModel(
            id: "large-v3-turbo",
            displayName: "Whisper large-v3-turbo",
            subtitle: "Multilingual high-quality model for broad speech workflows.",
            variant: "large-v3-turbo",
            languageScope: .multilingual,
            approxSizeBytes: 1_620_000_000,
            recommendedRAMGB: 16
        )
    ]

    public static func entry(id: String, among models: [CuratedSpeechModel] = all) -> CuratedSpeechModel? {
        models.first { $0.id == id }
    }

    public static func recommendedModel(
        forPhysicalMemoryBytes physicalMemoryBytes: UInt64,
        among models: [CuratedSpeechModel] = all
    ) -> CuratedSpeechModel? {
        guard physicalMemoryBytes > 0 else { return nil }

        var bestFit: CuratedSpeechModel?
        for model in models where model.recommendedRAMBytes <= physicalMemoryBytes {
            if bestFit == nil || model.recommendedRAMBytes > bestFit!.recommendedRAMBytes {
                bestFit = model
            }
        }
        return bestFit
    }
}
