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

public struct SpeechModelLibrarySnapshot: Hashable, Sendable {
    public static let empty = SpeechModelLibrarySnapshot()

    public let models: [InstalledSpeechModel]
    public let partials: [PartialSpeechModelDownload]
    public let totalDiskUsageBytes: Int64

    public init(
        models: [InstalledSpeechModel] = [],
        partials: [PartialSpeechModelDownload] = [],
        totalDiskUsageBytes: Int64? = nil
    ) {
        self.models = models
        self.partials = partials
        self.totalDiskUsageBytes = totalDiskUsageBytes
            ?? models.reduce(Int64(0)) { $0 + $1.totalSizeBytes }
            + partials.reduce(Int64(0)) { $0 + $1.bytesOnDisk }
    }

    public func model(id: UUID) -> InstalledSpeechModel? {
        models.first { $0.id == id }
    }

    public func model(id: String) -> InstalledSpeechModel? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return model(id: uuid)
    }
}

public struct SpeechModelImportResult: Hashable, Sendable {
    public let model: InstalledSpeechModel
    public let snapshot: SpeechModelLibrarySnapshot

    public init(model: InstalledSpeechModel, snapshot: SpeechModelLibrarySnapshot) {
        self.model = model
        self.snapshot = snapshot
    }
}

public struct SpeechModelDeleteResult: Hashable, Sendable {
    public let snapshot: SpeechModelLibrarySnapshot

    public init(snapshot: SpeechModelLibrarySnapshot) {
        self.snapshot = snapshot
    }
}

public actor SpeechModelLibrary {
    public nonisolated let root: URL

    private let fileManager: FileManager
    private var cachedSnapshot = SpeechModelLibrarySnapshot.empty

    public init(root: URL, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public func snapshot() async -> SpeechModelLibrarySnapshot {
        cachedSnapshot
    }

    public func refresh() async -> SpeechModelLibrarySnapshot {
        let snapshot = loadSnapshot()
        cachedSnapshot = snapshot
        return snapshot
    }

    public func model(id: UUID) async -> InstalledSpeechModel? {
        cachedSnapshot.model(id: id)
    }

    public func model(id: String) async -> InstalledSpeechModel? {
        cachedSnapshot.model(id: id)
    }

    public func resolveInstalledModel(id: UUID, refreshing: Bool = true) async -> InstalledSpeechModel? {
        let snapshot = refreshing ? loadAndCacheSnapshot() : cachedSnapshot
        return snapshot.model(id: id)
    }

    public func importFile(at sourceURL: URL, displayName: String? = nil) async throws -> SpeechModelImportResult {
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
            try writeMetadataSync(metadata)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw SpeechModelLibraryError.metadataWriteFailed(error.localizedDescription)
        }

        let snapshot = loadAndCacheSnapshot()
        return SpeechModelImportResult(model: metadata, snapshot: snapshot)
    }

    public func add(
        primaryAssetAt temporaryURL: URL,
        displayName: String,
        filename requestedFilename: String? = nil,
        source: SpeechModelSource,
        sourceURL: URL? = nil,
        hfRepo: String? = nil,
        hfFilename: String? = nil,
        sha256: String? = nil,
        capabilities: SpeechModelCapabilities = .whisperCppDefault,
        vadAssetAt temporaryVADURL: URL? = nil,
        vadFilename requestedVADFilename: String? = nil,
        vadSHA256: String? = nil
    ) async throws -> SpeechModelImportResult {
        let filename = requestedFilename?.nilIfBlank ?? temporaryURL.lastPathComponent
        guard filename.lowercased().hasSuffix(".bin") else {
            throw SpeechModelLibraryError.notAWhisperModel(filename)
        }
        guard fileManager.fileExists(atPath: temporaryURL.path) else {
            throw SpeechModelLibraryError.sourceFileMissing(temporaryURL)
        }
        if let temporaryVADURL {
            let vadFilename = requestedVADFilename?.nilIfBlank ?? temporaryVADURL.lastPathComponent
            guard vadFilename.lowercased().hasSuffix(".bin") else {
                throw SpeechModelLibraryError.notAWhisperModel(vadFilename)
            }
            guard fileManager.fileExists(atPath: temporaryVADURL.path) else {
                throw SpeechModelLibraryError.sourceFileMissing(temporaryVADURL)
            }
        }

        let id = UUID()
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let metadata: InstalledSpeechModel
        do {
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
            var assets = [asset]
            if let temporaryVADURL {
                let vadFilename = requestedVADFilename?.nilIfBlank ?? temporaryVADURL.lastPathComponent
                let vadDestination = directory.appendingPathComponent(vadFilename)
                guard !fileManager.fileExists(atPath: vadDestination.path) else {
                    throw SpeechModelLibraryError.destinationExists(vadDestination)
                }
                try fileManager.moveItem(at: temporaryVADURL, to: vadDestination)
                assets.append(SpeechModelAsset(
                    role: .vadWeights,
                    relativePath: vadFilename,
                    sizeBytes: Self.sizeOfItem(at: vadDestination, fileManager: fileManager),
                    sha256: vadSHA256
                ))
            }
            metadata = InstalledSpeechModel(
                id: id,
                displayName: displayName,
                providerKind: .whisperCpp,
                family: "whisper.cpp",
                variant: InstalledSpeechModel.inferVariant(from: filename),
                languageScope: InstalledSpeechModel.inferLanguageScope(from: filename),
                assets: assets,
                source: source,
                sourceURL: sourceURL,
                hfRepo: hfRepo,
                hfFilename: hfFilename,
                sha256: sha256,
                capabilities: capabilities
            )
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }

        do {
            try writeMetadataSync(metadata)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw SpeechModelLibraryError.metadataWriteFailed(error.localizedDescription)
        }

        let snapshot = loadAndCacheSnapshot()
        return SpeechModelImportResult(model: metadata, snapshot: snapshot)
    }

    public func add(assetBundleAt temporaryDirectory: URL, metadata: InstalledSpeechModel) async throws -> SpeechModelImportResult {
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
        guard let installedMetadata = diskValidModel(metadata, in: destination) else {
            try? fileManager.removeItem(at: destination)
            throw SpeechModelLibraryError.missingPrimaryWeights
        }
        do {
            try writeMetadataSync(installedMetadata)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw SpeechModelLibraryError.metadataWriteFailed(error.localizedDescription)
        }

        let snapshot = loadAndCacheSnapshot()
        return SpeechModelImportResult(model: installedMetadata, snapshot: snapshot)
    }

    public func delete(id: UUID) async throws -> SpeechModelDeleteResult {
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        return SpeechModelDeleteResult(snapshot: loadAndCacheSnapshot())
    }

    public func deletePartial(_ partial: PartialSpeechModelDownload) async -> SpeechModelDeleteResult {
        SpeechModelDownloader.deletePartial(partial, fileManager: fileManager)
        return SpeechModelDeleteResult(snapshot: loadAndCacheSnapshot())
    }

    public func totalDiskUsageBytes() async -> Int64 {
        cachedSnapshot.totalDiskUsageBytes
    }

    public func writeMetadata(_ model: InstalledSpeechModel) async throws {
        try writeMetadataSync(model)
        _ = loadAndCacheSnapshot()
    }

    private func loadAndCacheSnapshot() -> SpeechModelLibrarySnapshot {
        let snapshot = loadSnapshot()
        cachedSnapshot = snapshot
        return snapshot
    }

    private func loadSnapshot() -> SpeechModelLibrarySnapshot {
        var found: [InstalledSpeechModel] = []
        let decoder = LocalSpeechJSON.makeDecoder()

        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return .empty
        }

        for entry in entries {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else { continue }

            let metadataURL = entry.appendingPathComponent("metadata.json")
            if let data = try? Data(contentsOf: metadataURL),
               let metadata = try? decoder.decode(InstalledSpeechModel.self, from: data),
               let normalized = diskValidModel(metadata, in: entry) {
                found.append(normalized)
            } else if let synthesized = synthesizeMetadata(for: entry) {
                found.append(synthesized)
            }
        }

        let models = found.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        let partials = SpeechModelDownloader.listPartials(in: root, fileManager: fileManager)
        return SpeechModelLibrarySnapshot(models: models, partials: partials)
    }

    private func diskValidModel(_ model: InstalledSpeechModel, in directory: URL) -> InstalledSpeechModel? {
        var assets: [SpeechModelAsset] = []
        var hasPrimaryWeights = false

        for asset in model.assets {
            let url = directory.appendingPathComponent(asset.relativePath)
            guard fileManager.fileExists(atPath: url.path) else {
                if asset.role == .primaryWeights {
                    return nil
                }
                continue
            }

            var updated = asset
            updated.sizeBytes = Self.sizeOfItem(at: url, fileManager: fileManager)
            assets.append(updated)
            if asset.role == .primaryWeights {
                hasPrimaryWeights = true
            }
        }

        guard hasPrimaryWeights else { return nil }

        return InstalledSpeechModel(
            id: model.id,
            displayName: model.displayName,
            providerKind: model.providerKind,
            family: model.family,
            variant: model.variant,
            languageScope: model.languageScope,
            quantization: model.quantization,
            assets: assets,
            source: model.source,
            sourceURL: model.sourceURL,
            hfRepo: model.hfRepo,
            hfFilename: model.hfFilename,
            sha256: model.sha256,
            capabilities: model.capabilities,
            installedAt: model.installedAt
        )
    }

    private func writeMetadataSync(_ model: InstalledSpeechModel) throws {
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
              let primary = files.first(where: { isLikelyPrimaryWeights($0) })
        else { return nil }

        var assets: [SpeechModelAsset] = [
            SpeechModelAsset(
                role: .primaryWeights,
                relativePath: primary.lastPathComponent,
                sizeBytes: Self.sizeOfItem(at: primary, fileManager: fileManager)
            )
        ]
        for file in files where isLikelyVADWeights(file) {
            assets.append(SpeechModelAsset(
                role: .vadWeights,
                relativePath: file.lastPathComponent,
                sizeBytes: Self.sizeOfItem(at: file, fileManager: fileManager)
            ))
        }
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

    private func isLikelyPrimaryWeights(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "bin" && !isLikelyVADWeights(url)
    }

    private func isLikelyVADWeights(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "bin" else { return false }
        let filename = url.lastPathComponent.lowercased()
        return filename.contains("vad") || filename.contains("silero")
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
