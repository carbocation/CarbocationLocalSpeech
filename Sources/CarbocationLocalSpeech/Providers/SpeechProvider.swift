import Foundation

public enum SpeechSystemModelID: String, Codable, Hashable, Sendable {
    case appleSpeech = "system.apple-speech"
}

public enum SpeechModelSelection: Codable, Hashable, Sendable {
    case installed(UUID)
    case system(SpeechSystemModelID)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let selection = SpeechModelSelection(storageValue: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid speech model selection: \(value)"
            )
        }
        self = selection
    }

    public init?(storageValue: String) {
        if let systemModel = SpeechSystemModelID(rawValue: storageValue) {
            self = .system(systemModel)
            return
        }
        guard let uuid = UUID(uuidString: storageValue) else {
            return nil
        }
        self = .installed(uuid)
    }

    public var storageValue: String {
        switch self {
        case .installed(let id):
            return id.uuidString
        case .system(let id):
            return id.rawValue
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storageValue)
    }
}

public enum SpeechProviderKind: String, Codable, Hashable, Sendable {
    case whisperCpp
    case appleSpeech
    case whisperKit
    case mock
}

public enum SpeechProviderUnavailableReason: String, Codable, Hashable, Sendable {
    case sdkUnavailable
    case operatingSystemUnavailable
    case speechRecognitionDenied
    case localeUnsupported
    case assetDownloadRequired
    case assetNotReady
    case deviceNotEligible
    case unknown

    public var displayMessage: String {
        switch self {
        case .sdkUnavailable:
            return "This app was built without the required Speech SDK."
        case .operatingSystemUnavailable:
            return "Apple Speech requires macOS 26 or newer."
        case .speechRecognitionDenied:
            return "Speech recognition permission is denied."
        case .localeUnsupported:
            return "Speech recognition is not available for this locale."
        case .assetDownloadRequired:
            return "Speech recognition assets need to be installed."
        case .assetNotReady:
            return "Speech recognition assets are not ready yet."
        case .deviceNotEligible:
            return "This device does not support the requested speech provider."
        case .unknown:
            return "The speech provider is not available."
        }
    }
}

public enum SpeechProviderAvailability: Hashable, Sendable {
    case available
    case unavailable(SpeechProviderUnavailableReason)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    public var unavailableReason: SpeechProviderUnavailableReason? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }

    public var shouldOfferModelOption: Bool {
        switch self {
        case .available:
            return true
        case .unavailable(.assetDownloadRequired), .unavailable(.assetNotReady):
            return true
        case .unavailable:
            return false
        }
    }

    public var displayMessage: String {
        switch self {
        case .available:
            return "Available"
        case .unavailable(let reason):
            return reason.displayMessage
        }
    }
}

public struct SpeechModelCapabilities: Codable, Hashable, Sendable {
    public var supportsFileTranscription: Bool
    public var supportsLiveTranscription: Bool
    public var supportsDictationPreset: Bool
    public var supportsTranslation: Bool
    public var supportsWordTimestamps: Bool
    public var supportsLanguageDetection: Bool
    public var supportsDiarization: Bool
    public var supportsCoreMLAcceleration: Bool
    public var supportedLanguages: [String]

    public init(
        supportsFileTranscription: Bool = false,
        supportsLiveTranscription: Bool = false,
        supportsDictationPreset: Bool = false,
        supportsTranslation: Bool = false,
        supportsWordTimestamps: Bool = false,
        supportsLanguageDetection: Bool = false,
        supportsDiarization: Bool = false,
        supportsCoreMLAcceleration: Bool = false,
        supportedLanguages: [String] = []
    ) {
        self.supportsFileTranscription = supportsFileTranscription
        self.supportsLiveTranscription = supportsLiveTranscription
        self.supportsDictationPreset = supportsDictationPreset
        self.supportsTranslation = supportsTranslation
        self.supportsWordTimestamps = supportsWordTimestamps
        self.supportsLanguageDetection = supportsLanguageDetection
        self.supportsDiarization = supportsDiarization
        self.supportsCoreMLAcceleration = supportsCoreMLAcceleration
        self.supportedLanguages = supportedLanguages
    }

    public static let whisperCppDefault = SpeechModelCapabilities(
        supportsFileTranscription: true,
        supportsLiveTranscription: true,
        supportsDictationPreset: true,
        supportsTranslation: true,
        supportsWordTimestamps: true,
        supportsLanguageDetection: true,
        supportsDiarization: false,
        supportsCoreMLAcceleration: true,
        supportedLanguages: []
    )

    public static let appleSpeechDefault = SpeechModelCapabilities(
        supportsFileTranscription: true,
        supportsLiveTranscription: true,
        supportsDictationPreset: true,
        supportsTranslation: false,
        supportsWordTimestamps: false,
        supportsLanguageDetection: false,
        supportsDiarization: false,
        supportsCoreMLAcceleration: false,
        supportedLanguages: []
    )
}

public struct SpeechSystemModelOption: Identifiable, Hashable, Sendable {
    public var selection: SpeechModelSelection
    public var displayName: String
    public var subtitle: String
    public var systemImageName: String
    public var capabilities: SpeechModelCapabilities
    public var availability: SpeechProviderAvailability

    public var id: String {
        selection.storageValue
    }

    public init(
        selection: SpeechModelSelection,
        displayName: String,
        subtitle: String,
        systemImageName: String,
        capabilities: SpeechModelCapabilities,
        availability: SpeechProviderAvailability
    ) {
        self.selection = selection
        self.displayName = displayName
        self.subtitle = subtitle
        self.systemImageName = systemImageName
        self.capabilities = capabilities
        self.availability = availability
    }
}

public struct SpeechBackendDescriptor: Codable, Hashable, Sendable {
    public var kind: SpeechProviderKind
    public var displayName: String
    public var version: String?
    public var selection: SpeechModelSelection?

    public init(
        kind: SpeechProviderKind,
        displayName: String,
        version: String? = nil,
        selection: SpeechModelSelection? = nil
    ) {
        self.kind = kind
        self.displayName = displayName
        self.version = version
        self.selection = selection
    }
}
