import CryptoKit
import Foundation

public enum SpeechModelDownloaderError: Error, LocalizedError, Sendable {
    case badURL(String)
    case httpStatus(Int)
    case hashMismatch(expected: String, actual: String)
    case noContentLength
    case incompleteResponse
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .badURL(let value):
            return "Invalid speech model download URL: \(value)"
        case .httpStatus(let code):
            return "Speech model download failed with HTTP \(code)."
        case .hashMismatch(let expected, let actual):
            return "SHA256 mismatch; expected \(expected.prefix(12)), got \(actual.prefix(12))."
        case .noContentLength:
            return "Server did not report a content length."
        case .incompleteResponse:
            return "Server closed the connection before the speech model download completed."
        case .cancelled:
            return "Download cancelled."
        }
    }
}

public struct SpeechDownloadProgress: Sendable, Hashable {
    public let bytesReceived: Int64
    public let totalBytes: Int64
    public let bytesPerSecond: Double

    public init(bytesReceived: Int64, totalBytes: Int64, bytesPerSecond: Double) {
        self.bytesReceived = bytesReceived
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
    }

    public var fractionComplete: Double {
        totalBytes > 0 ? Double(bytesReceived) / Double(totalBytes) : 0
    }
}

public struct PartialSpeechModelDownload: Identifiable, Hashable, Sendable {
    public var id: String
    public var partialURL: URL
    public var sidecarURL: URL
    public var sourceURL: URL
    public var displayName: String
    public var totalBytes: Int64
    public var bytesOnDisk: Int64

    public init(
        id: String,
        partialURL: URL,
        sidecarURL: URL,
        sourceURL: URL,
        displayName: String,
        totalBytes: Int64,
        bytesOnDisk: Int64
    ) {
        self.id = id
        self.partialURL = partialURL
        self.sidecarURL = sidecarURL
        self.sourceURL = sourceURL
        self.displayName = displayName
        self.totalBytes = totalBytes
        self.bytesOnDisk = bytesOnDisk
    }

    public var fractionComplete: Double {
        totalBytes > 0 ? Double(bytesOnDisk) / Double(totalBytes) : 0
    }
}

public struct SpeechModelDownloadResult: Sendable, Hashable {
    public let tempURL: URL
    public let sizeBytes: Int64
    public let sha256: String

    public init(tempURL: URL, sizeBytes: Int64, sha256: String) {
        self.tempURL = tempURL
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
    }
}

private struct PartialSpeechSidecar: Codable, Sendable {
    var url: String
    var totalBytes: Int64
    var displayName: String?
    var schemaVersion: Int?
    var chunkSize: Int64?
    var doneChunks: [Int]?
}

public enum SpeechModelDownloader {
    public static let partialPrefix = "cls-partial-"

    public static func partialsDirectory(
        in root: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let url = root.appendingPathComponent(".partials", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static func listPartials(
        in root: URL,
        fileManager: FileManager = .default
    ) -> [PartialSpeechModelDownload] {
        guard let partialsRoot = try? partialsDirectory(in: root, fileManager: fileManager),
              let entries = try? fileManager.contentsOfDirectory(
                at: partialsRoot,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
              )
        else { return [] }

        let decoder = JSONDecoder()
        return entries
            .filter { $0.pathExtension == "json" && $0.deletingPathExtension().lastPathComponent.hasPrefix(partialPrefix) }
            .compactMap { sidecarURL in
                guard let data = try? Data(contentsOf: sidecarURL),
                      let sidecar = try? decoder.decode(PartialSpeechSidecar.self, from: data),
                      let sourceURL = URL(string: sidecar.url)
                else { return nil }

                let stem = sidecarURL.deletingPathExtension().lastPathComponent
                let partialURL = matchingPartialFile(stem: stem, in: partialsRoot, fileManager: fileManager)
                    ?? partialsRoot.appendingPathComponent("\(stem).bin")
                let bytesOnDisk = bytesOnDisk(
                    partialURL: partialURL,
                    totalBytes: sidecar.totalBytes,
                    chunkSize: sidecar.chunkSize,
                    doneChunks: sidecar.doneChunks,
                    fileManager: fileManager
                )
                return PartialSpeechModelDownload(
                    id: stem,
                    partialURL: partialURL,
                    sidecarURL: sidecarURL,
                    sourceURL: sourceURL,
                    displayName: sidecar.displayName ?? sourceURL.deletingPathExtension().lastPathComponent,
                    totalBytes: sidecar.totalBytes,
                    bytesOnDisk: bytesOnDisk
                )
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    public static func deletePartial(
        _ partial: PartialSpeechModelDownload,
        fileManager: FileManager = .default
    ) {
        try? fileManager.removeItem(at: partial.partialURL)
        try? fileManager.removeItem(at: partial.sidecarURL)
    }

    public static func download(
        from sourceURL: URL,
        displayName: String? = nil,
        expectedSHA256: String? = nil,
        to root: URL,
        fileManager: FileManager = .default
    ) async throws -> SpeechModelDownloadResult {
        if Task.isCancelled {
            throw SpeechModelDownloaderError.cancelled
        }

        let (downloadURL, response) = try await URLSession.shared.download(from: sourceURL)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else {
            throw SpeechModelDownloaderError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        let data = try Data(contentsOf: downloadURL)
        let actualSHA = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let expectedSHA256, expectedSHA256.lowercased() != actualSHA.lowercased() {
            throw SpeechModelDownloaderError.hashMismatch(expected: expectedSHA256, actual: actualSHA)
        }

        let tempRoot = root.appendingPathComponent(".downloads", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let destination = tempRoot.appendingPathComponent("\(UUID().uuidString)-\(sourceURL.lastPathComponent)")
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: downloadURL, to: destination)
        _ = displayName
        return SpeechModelDownloadResult(tempURL: destination, sizeBytes: Int64(data.count), sha256: actualSHA)
    }

    private static func matchingPartialFile(
        stem: String,
        in partialsRoot: URL,
        fileManager: FileManager
    ) -> URL? {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: partialsRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return entries.first {
            $0.deletingPathExtension().lastPathComponent == stem && $0.pathExtension != "json"
        }
    }

    private static func bytesOnDisk(
        partialURL: URL,
        totalBytes: Int64,
        chunkSize: Int64?,
        doneChunks: [Int]?,
        fileManager: FileManager
    ) -> Int64 {
        if let chunkSize, let doneChunks, !doneChunks.isEmpty {
            return doneChunks.reduce(Int64(0)) { partial, index in
                let start = Int64(index) * chunkSize
                guard start < totalBytes else { return partial }
                let end = min(start + chunkSize, totalBytes)
                return partial + max(0, end - start)
            }
        }

        let attributes = (try? fileManager.attributesOfItem(atPath: partialURL.path)) ?? [:]
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }
}

public struct HuggingFaceSpeechModelURL: Hashable, Sendable {
    public var repo: String
    public var filename: String

    public init(repo: String, filename: String) {
        self.repo = repo
        self.filename = filename
    }

    public static func parse(_ rawValue: String) -> HuggingFaceSpeechModelURL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed),
           let host = url.host(),
           host == "huggingface.co" {
            let components = url.pathComponents.filter { $0 != "/" }
            guard components.count >= 5,
                  let markerIndex = components.firstIndex(where: { $0 == "resolve" || $0 == "blob" }),
                  markerIndex >= 2,
                  markerIndex + 2 < components.count
            else { return nil }
            let repo = components[0..<markerIndex].joined(separator: "/")
            let filename = components[(markerIndex + 2)...].joined(separator: "/")
            guard filename.lowercased().hasSuffix(".bin") else { return nil }
            return HuggingFaceSpeechModelURL(repo: repo, filename: filename)
        }

        let pieces = trimmed.split(separator: "/").map(String.init)
        guard pieces.count >= 3 else { return nil }
        let repo = pieces[0...1].joined(separator: "/")
        let filename = pieces[2...].joined(separator: "/")
        guard filename.lowercased().hasSuffix(".bin") else { return nil }
        return HuggingFaceSpeechModelURL(repo: repo, filename: filename)
    }
}
