import Foundation

public enum SpeechModelSource: String, Codable, Hashable, Sendable {
    case curated
    case customURL
    case imported
    case bundled
}

public enum SpeechLanguageScope: String, Codable, Hashable, Sendable {
    case englishOnly
    case multilingual
    case languageSpecific
    case unknown
}

public struct SpeechLanguage: Codable, Hashable, Sendable {
    public var code: String
    public var displayName: String?
    public var probability: Double?

    public init(code: String, displayName: String? = nil, probability: Double? = nil) {
        self.code = code
        self.displayName = displayName
        self.probability = probability
    }
}

public struct SpeechModelAsset: Codable, Hashable, Sendable {
    public enum Role: String, Codable, Hashable, Sendable {
        case primaryWeights
        case coreMLEncoder
        case vocabulary
        case configuration
        case diarizationWeights
        case other
    }

    public var role: Role
    public var relativePath: String
    public var sizeBytes: Int64
    public var sha256: String?

    public init(
        role: Role,
        relativePath: String,
        sizeBytes: Int64,
        sha256: String? = nil
    ) {
        self.role = role
        self.relativePath = relativePath
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
    }
}

public struct InstalledSpeechModel: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var displayName: String
    public var providerKind: SpeechProviderKind
    public var family: String
    public var variant: String?
    public var languageScope: SpeechLanguageScope
    public var quantization: String?
    public var assets: [SpeechModelAsset]
    public var source: SpeechModelSource
    public var sourceURL: URL?
    public var hfRepo: String?
    public var hfFilename: String?
    public var sha256: String?
    public var capabilities: SpeechModelCapabilities
    public var installedAt: Date

    public init(
        id: UUID = UUID(),
        displayName: String,
        providerKind: SpeechProviderKind = .whisperCpp,
        family: String = "whisper.cpp",
        variant: String? = nil,
        languageScope: SpeechLanguageScope = .unknown,
        quantization: String? = nil,
        assets: [SpeechModelAsset],
        source: SpeechModelSource,
        sourceURL: URL? = nil,
        hfRepo: String? = nil,
        hfFilename: String? = nil,
        sha256: String? = nil,
        capabilities: SpeechModelCapabilities = .whisperCppDefault,
        installedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.providerKind = providerKind
        self.family = family
        self.variant = variant
        self.languageScope = languageScope
        self.quantization = quantization
        self.assets = assets
        self.source = source
        self.sourceURL = sourceURL
        self.hfRepo = hfRepo
        self.hfFilename = hfFilename
        self.sha256 = sha256
        self.capabilities = capabilities
        self.installedAt = installedAt
    }

    public var totalSizeBytes: Int64 {
        assets.reduce(0) { $0 + $1.sizeBytes }
    }

    public var primaryWeightsAsset: SpeechModelAsset? {
        assets.first { $0.role == .primaryWeights }
    }

    public func directory(in root: URL) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public func metadataURL(in root: URL) -> URL {
        directory(in: root).appendingPathComponent("metadata.json")
    }

    public func assetURL(_ asset: SpeechModelAsset, in root: URL) -> URL {
        directory(in: root).appendingPathComponent(asset.relativePath)
    }

    public func primaryWeightsURL(in root: URL) -> URL? {
        primaryWeightsAsset.map { assetURL($0, in: root) }
    }

    public static func inferLanguageScope(from filename: String) -> SpeechLanguageScope {
        let lowercased = filename.lowercased()
        if lowercased.contains(".en.") || lowercased.contains("-en.") || lowercased.contains("_en.") {
            return .englishOnly
        }
        if lowercased.contains("whisper") || lowercased.contains("large") || lowercased.contains("turbo") {
            return .multilingual
        }
        return .unknown
    }

    public static func inferVariant(from filename: String) -> String? {
        let stem = filename.replacingOccurrences(of: ".bin", with: "")
        guard let range = stem.range(of: "ggml-", options: .caseInsensitive) else {
            return stem.nilIfBlank
        }
        return String(stem[range.upperBound...]).nilIfBlank
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
