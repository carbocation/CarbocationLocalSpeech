import Foundation

public struct KnownSpeechFixture: Codable, Hashable, Sendable {
    public var name: String
    public var audioURL: URL
    public var referenceText: String
    public var language: String

    public init(name: String, audioURL: URL, referenceText: String, language: String) {
        self.name = name
        self.audioURL = audioURL
        self.referenceText = referenceText
        self.language = language
    }

    public static func jfk() throws -> KnownSpeechFixture {
        let packageRoot = try PackagePath.packageRoot(startingAt: URL(fileURLWithPath: #filePath))
        let audioURL = packageRoot.appendingPathComponent("Vendor/whisper.cpp/samples/jfk.wav")
        let referenceURL = try resourceURL(for: "jfk", extension: "txt")
        let referenceText = try String(contentsOf: referenceURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return KnownSpeechFixture(
            name: "jfk",
            audioURL: audioURL,
            referenceText: referenceText,
            language: "en"
        )
    }

    private static func resourceURL(for name: String, extension pathExtension: String) throws -> URL {
        if let url = Bundle.module.url(forResource: name, withExtension: pathExtension) {
            return url
        }
        throw CocoaError(.fileNoSuchFile)
    }
}

enum PackagePath {
    enum Error: Swift.Error, LocalizedError {
        case notFound(URL)

        var errorDescription: String? {
            switch self {
            case .notFound(let start):
                return "Could not find Package.swift above \(start.path)."
            }
        }
    }

    static func packageRoot(startingAt startURL: URL, fileManager: FileManager = .default) throws -> URL {
        var directory = startURL.hasDirectoryPath ? startURL : startURL.deletingLastPathComponent()

        while true {
            if fileManager.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) {
                return directory
            }

            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path {
                throw Error.notFound(startURL)
            }
            directory = parent
        }
    }
}
