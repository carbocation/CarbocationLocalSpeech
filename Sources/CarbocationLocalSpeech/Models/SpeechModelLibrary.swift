import Foundation

public enum SpeechModelLibraryError: Error, LocalizedError, Sendable {
    case sourceFileMissing(URL)
    case sourceDirectoryMissing(URL)
    case destinationExists(URL)
    case metadataWriteFailed(String)
    case notAWhisperModel(String)
    case missingPrimaryWeights

    public var errorDescription: String? {
        switch self {
        case .sourceFileMissing(let url):
            return "Source file not found: \(url.lastPathComponent)"
        case .sourceDirectoryMissing(let url):
            return "Source directory not found: \(url.lastPathComponent)"
        case .destinationExists(let url):
            return "A speech model already exists at \(url.path)"
        case .metadataWriteFailed(let detail):
            return "Failed to save speech model metadata: \(detail)"
        case .notAWhisperModel(let filename):
            return "\(filename) is not a whisper.cpp .bin model."
        case .missingPrimaryWeights:
            return "Speech model metadata does not include primary weights."
        }
    }
}

@MainActor
public final class SpeechModelLibrary {
    public private(set) var models: [InstalledSpeechModel] = []
    public private(set) var partials: [PartialSpeechModelDownload] = []

    public let root: URL
    private let fileManager: FileManager

    public init(root: URL, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        refresh()
    }

    public func refresh() {
        var found: [InstalledSpeechModel] = []
        let decoder = LocalSpeechJSON.makeDecoder()

        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            models = []
            partials = []
            return
        }

        for entry in entries {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else { continue }

            let metadataURL = entry.appendingPathComponent("metadata.json")
            if let data = try? Data(contentsOf: metadataURL),
               let metadata = try? decoder.decode(InstalledSpeechModel.self, from: data) {
                found.append(metadata)
            } else if let synthesized = synthesizeMetadata(for: entry) {
                found.append(synthesized)
            }
        }

        models = found.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        partials = SpeechModelDownloader.listPartials(in: root, fileManager: fileManager)
    }

    public func model(id: UUID) -> InstalledSpeechModel? {
        models.first { $0.id == id }
    }

    public func model(id: String) -> InstalledSpeechModel? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return model(id: uuid)
    }

    public func importFile(at sourceURL: URL, displayName: String? = nil) throws -> InstalledSpeechModel {
        let filename = sourceURL.lastPathComponent
        guard filename.lowercased().hasSuffix(".bin") else {
            throw SpeechModelLibraryError.notAWhisperModel(filename)
        }
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw SpeechModelLibraryError.sourceFileMissing(sourceURL)
        }

        let id = UUID()
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(filename)
        do {
            try fileManager.copyItem(at: sourceURL, to: destination)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }

        let size = Self.sizeOfItem(at: destination, fileManager: fileManager)
        let asset = SpeechModelAsset(role: .primaryWeights, relativePath: filename, sizeBytes: size)
        let metadata = InstalledSpeechModel(
            id: id,
            displayName: displayName?.nilIfBlank ?? sourceURL.deletingPathExtension().lastPathComponent,
            providerKind: .whisperCpp,
            family: "whisper.cpp",
            variant: InstalledSpeechModel.inferVariant(from: filename),
            languageScope: InstalledSpeechModel.inferLanguageScope(from: filename),
            assets: [asset],
            source: .imported
        )

        do {
            try writeMetadata(metadata)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw SpeechModelLibraryError.metadataWriteFailed(error.localizedDescription)
        }

        refresh()
        return metadata
    }

    public func add(
        primaryAssetAt temporaryURL: URL,
        displayName: String,
        source: SpeechModelSource,
        sourceURL: URL? = nil,
        hfRepo: String? = nil,
        hfFilename: String? = nil,
        sha256: String? = nil,
        capabilities: SpeechModelCapabilities = .whisperCppDefault
    ) throws -> InstalledSpeechModel {
        let filename = temporaryURL.lastPathComponent
        guard filename.lowercased().hasSuffix(".bin") else {
            throw SpeechModelLibraryError.notAWhisperModel(filename)
        }
        guard fileManager.fileExists(atPath: temporaryURL.path) else {
            throw SpeechModelLibraryError.sourceFileMissing(temporaryURL)
        }

        let id = UUID()
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(filename)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw SpeechModelLibraryError.destinationExists(destination)
        }
        try fileManager.moveItem(at: temporaryURL, to: destination)

        let asset = SpeechModelAsset(
            role: .primaryWeights,
            relativePath: filename,
            sizeBytes: Self.sizeOfItem(at: destination, fileManager: fileManager),
            sha256: sha256
        )
        let metadata = InstalledSpeechModel(
            id: id,
            displayName: displayName,
            providerKind: .whisperCpp,
            family: "whisper.cpp",
            variant: InstalledSpeechModel.inferVariant(from: filename),
            languageScope: InstalledSpeechModel.inferLanguageScope(from: filename),
            assets: [asset],
            source: source,
            sourceURL: sourceURL,
            hfRepo: hfRepo,
            hfFilename: hfFilename,
            sha256: sha256,
            capabilities: capabilities
        )

        do {
            try writeMetadata(metadata)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw SpeechModelLibraryError.metadataWriteFailed(error.localizedDescription)
        }

        refresh()
        return metadata
    }

    public func add(assetBundleAt temporaryDirectory: URL, metadata: InstalledSpeechModel) throws -> InstalledSpeechModel {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: temporaryDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw SpeechModelLibraryError.sourceDirectoryMissing(temporaryDirectory)
        }
        guard metadata.primaryWeightsAsset != nil else {
            throw SpeechModelLibraryError.missingPrimaryWeights
        }

        let destination = root.appendingPathComponent(metadata.id.uuidString, isDirectory: true)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw SpeechModelLibraryError.destinationExists(destination)
        }

        try fileManager.moveItem(at: temporaryDirectory, to: destination)
        do {
            try writeMetadata(metadata)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw SpeechModelLibraryError.metadataWriteFailed(error.localizedDescription)
        }

        refresh()
        return metadata
    }

    public func delete(id: UUID) throws {
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        refresh()
    }

    public func deletePartial(_ partial: PartialSpeechModelDownload) {
        SpeechModelDownloader.deletePartial(partial, fileManager: fileManager)
        refresh()
    }

    public func totalDiskUsageBytes() -> Int64 {
        models.reduce(Int64(0)) { $0 + $1.totalSizeBytes }
            + partials.reduce(Int64(0)) { $0 + $1.bytesOnDisk }
    }

    public func writeMetadata(_ model: InstalledSpeechModel) throws {
        let encoder = LocalSpeechJSON.makePrettyEncoder()
        let data = try encoder.encode(model)
        let url = model.metadataURL(in: root)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private func synthesizeMetadata(for directory: URL) -> InstalledSpeechModel? {
        guard let uuid = UUID(uuidString: directory.lastPathComponent),
              let files = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
              ),
              let primary = files.first(where: { $0.pathExtension.lowercased() == "bin" })
        else { return nil }

        var assets: [SpeechModelAsset] = [
            SpeechModelAsset(
                role: .primaryWeights,
                relativePath: primary.lastPathComponent,
                sizeBytes: Self.sizeOfItem(at: primary, fileManager: fileManager)
            )
        ]
        for file in files where file.pathExtension.lowercased() == "mlmodelc" {
            assets.append(SpeechModelAsset(
                role: .coreMLEncoder,
                relativePath: file.lastPathComponent,
                sizeBytes: Self.sizeOfItem(at: file, fileManager: fileManager)
            ))
        }

        return InstalledSpeechModel(
            id: uuid,
            displayName: primary.deletingPathExtension().lastPathComponent,
            providerKind: .whisperCpp,
            family: "whisper.cpp",
            variant: InstalledSpeechModel.inferVariant(from: primary.lastPathComponent),
            languageScope: InstalledSpeechModel.inferLanguageScope(from: primary.lastPathComponent),
            assets: assets,
            source: .imported
        )
    }

    static func sizeOfItem(at url: URL, fileManager: FileManager) -> Int64 {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue {
            let attributes = (try? fileManager.attributesOfItem(atPath: url.path)) ?? [:]
            return (attributes[.size] as? NSNumber)?.int64Value ?? 0
        }
        guard let children = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        return children.reduce(Int64(0)) { partial, child in
            partial + sizeOfItem(at: child, fileManager: fileManager)
        }
    }
}
