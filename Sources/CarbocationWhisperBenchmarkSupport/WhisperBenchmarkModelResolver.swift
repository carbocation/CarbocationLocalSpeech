import CarbocationLocalSpeech
import Foundation

public struct ResolvedWhisperBenchmarkModel: Hashable, Sendable {
    public var model: InstalledSpeechModel
    public var libraryRoot: URL
    public var modelURL: URL
    public var requestedVariant: String?

    public init(
        model: InstalledSpeechModel,
        libraryRoot: URL,
        modelURL: URL,
        requestedVariant: String?
    ) {
        self.model = model
        self.libraryRoot = libraryRoot
        self.modelURL = modelURL
        self.requestedVariant = requestedVariant
    }

    public var hasCoreMLEncoder: Bool {
        model.assets.contains { $0.role == .coreMLEncoder }
    }

    public var werThreshold: Double {
        let descriptor = [
            model.variant,
            model.primaryWeightsAsset?.relativePath,
            model.displayName
        ]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")

        if descriptor.contains("large") {
            return 0.25
        }
        if descriptor.contains("small.en") {
            return 0.35
        }
        if descriptor.contains("tiny.en") {
            return 0.60
        }
        return 0.60
    }
}

public enum WhisperBenchmarkModelResolutionError: LocalizedError {
    case explicitModelMissing(URL)
    case explicitModelIsDirectory(URL)
    case explicitModelIsNotWhisperWeights(URL)
    case libraryRootMissing(URL)
    case libraryRootIsNotDirectory(URL)
    case variantNotFound(String, [String])
    case missingPrimaryWeights(InstalledSpeechModel)
    case sidecarLinkFailed(URL, URL, String)

    public var errorDescription: String? {
        switch self {
        case .explicitModelMissing(let url):
            return "Explicit model path points to a missing file: \(url.path)"
        case .explicitModelIsDirectory(let url):
            return "Explicit model path must point at a .bin file, not a directory: \(url.path)"
        case .explicitModelIsNotWhisperWeights(let url):
            return "Explicit model path must point at a whisper.cpp primary .bin model, not \(url.lastPathComponent)."
        case .libraryRootMissing(let url):
            return "Library root points to a missing directory: \(url.path)"
        case .libraryRootIsNotDirectory(let url):
            return "Library root must point at a SpeechModels directory: \(url.path)"
        case .variantNotFound(let variant, let available):
            let list = available.isEmpty ? "none" : available.joined(separator: ", ")
            return "Could not find model variant '\(variant)' in library root. Available variants: \(list)."
        case .missingPrimaryWeights(let model):
            return "Resolved model '\(model.displayName)' does not include primary weights."
        case .sidecarLinkFailed(let source, let destination, let detail):
            return "Could not prepare explicit model sidecar \(source.lastPathComponent) at \(destination.path): \(detail)"
        }
    }
}

public enum WhisperBenchmarkModelResolver {
    public static let explicitModelEnv = "CARBOCATION_LOCAL_SPEECH_TEST_MODEL"
    public static let libraryRootEnv = "CARBOCATION_LOCAL_SPEECH_TEST_LIBRARY_ROOT"
    public static let modelVariantEnv = "CARBOCATION_LOCAL_SPEECH_TEST_MODEL_VARIANT"
    public static let defaultModelVariant = "tiny.en"

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) async throws -> ResolvedWhisperBenchmarkModel? {
        try await resolve(
            explicitModelPath: nonBlank(environment[explicitModelEnv]),
            libraryRootPath: nonBlank(environment[libraryRootEnv]),
            variant: nonBlank(environment[modelVariantEnv]),
            defaultVariant: defaultModelVariant,
            fileManager: fileManager
        )
    }

    public static func resolve(
        explicitModelPath: String?,
        libraryRootPath: String?,
        variant: String?,
        defaultVariant: String = defaultModelVariant,
        fileManager: FileManager = .default
    ) async throws -> ResolvedWhisperBenchmarkModel? {
        if let explicitModelPath = nonBlank(explicitModelPath) {
            return try await resolveExplicitModel(
                at: url(forPath: explicitModelPath),
                requestedVariant: nonBlank(variant),
                fileManager: fileManager
            )
        }

        guard let libraryRootPath = nonBlank(libraryRootPath) else {
            return nil
        }

        let resolvedVariant = nonBlank(variant) ?? defaultVariant
        return try await resolveLibraryModel(
            root: url(forPath: libraryRootPath),
            variant: resolvedVariant,
            fileManager: fileManager
        )
    }

    private static func resolveExplicitModel(
        at modelURL: URL,
        requestedVariant: String?,
        fileManager: FileManager
    ) async throws -> ResolvedWhisperBenchmarkModel {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: modelURL.path, isDirectory: &isDirectory) else {
            throw WhisperBenchmarkModelResolutionError.explicitModelMissing(modelURL)
        }
        guard !isDirectory.boolValue else {
            throw WhisperBenchmarkModelResolutionError.explicitModelIsDirectory(modelURL)
        }
        guard isLikelyPrimaryWeights(modelURL) else {
            throw WhisperBenchmarkModelResolutionError.explicitModelIsNotWhisperWeights(modelURL)
        }

        if let installed = try await resolveInstalledModel(at: modelURL, fileManager: fileManager) {
            return ResolvedWhisperBenchmarkModel(
                model: installed.model,
                libraryRoot: installed.libraryRoot,
                modelURL: modelURL,
                requestedVariant: requestedVariant
            )
        }

        return try prepareTemporaryInstalledModel(
            for: modelURL,
            requestedVariant: requestedVariant,
            fileManager: fileManager
        )
    }

    private static func resolveInstalledModel(
        at modelURL: URL,
        fileManager: FileManager
    ) async throws -> (model: InstalledSpeechModel, libraryRoot: URL)? {
        let modelDirectory = modelURL.deletingLastPathComponent()
        guard let modelID = UUID(uuidString: modelDirectory.lastPathComponent) else {
            return nil
        }

        let libraryRoot = modelDirectory.deletingLastPathComponent()
        let library = SpeechModelLibrary(root: libraryRoot, fileManager: fileManager)
        let snapshot = await library.refresh()
        guard let model = snapshot.model(id: modelID),
              let primaryURL = model.primaryWeightsURL(in: libraryRoot),
              primaryURL.standardizedFileURL.path == modelURL.standardizedFileURL.path
        else {
            return nil
        }

        return (model, libraryRoot)
    }

    private static func prepareTemporaryInstalledModel(
        for modelURL: URL,
        requestedVariant: String?,
        fileManager: FileManager
    ) throws -> ResolvedWhisperBenchmarkModel {
        let modelID = UUID()
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("CarbocationWhisperBenchmarkModels-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("SpeechModels", isDirectory: true)
        let modelDirectory = temporaryRoot.appendingPathComponent(modelID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: modelDirectory, withIntermediateDirectories: true)

        var assets: [SpeechModelAsset] = []
        try linkAsset(
            from: modelURL,
            to: modelDirectory.appendingPathComponent(modelURL.lastPathComponent),
            role: .primaryWeights,
            assets: &assets,
            fileManager: fileManager
        )

        for sidecar in adjacentSidecars(for: modelURL, fileManager: fileManager) {
            let role: SpeechModelAsset.Role = sidecar.pathExtension.lowercased() == "mlmodelc"
                ? .coreMLEncoder
                : .vadWeights
            try linkAsset(
                from: sidecar,
                to: modelDirectory.appendingPathComponent(sidecar.lastPathComponent),
                role: role,
                assets: &assets,
                fileManager: fileManager
            )
        }

        let model = InstalledSpeechModel(
            id: modelID,
            displayName: modelURL.deletingPathExtension().lastPathComponent,
            providerKind: .whisperCpp,
            family: "whisper.cpp",
            variant: InstalledSpeechModel.inferVariant(from: modelURL.lastPathComponent),
            languageScope: InstalledSpeechModel.inferLanguageScope(from: modelURL.lastPathComponent),
            assets: assets,
            source: .imported
        )

        return ResolvedWhisperBenchmarkModel(
            model: model,
            libraryRoot: temporaryRoot,
            modelURL: modelDirectory.appendingPathComponent(modelURL.lastPathComponent),
            requestedVariant: requestedVariant
        )
    }

    private static func linkAsset(
        from source: URL,
        to destination: URL,
        role: SpeechModelAsset.Role,
        assets: inout [SpeechModelAsset],
        fileManager: FileManager
    ) throws {
        do {
            try fileManager.createSymbolicLink(at: destination, withDestinationURL: source)
        } catch {
            throw WhisperBenchmarkModelResolutionError.sidecarLinkFailed(source, destination, error.localizedDescription)
        }

        assets.append(SpeechModelAsset(
            role: role,
            relativePath: destination.lastPathComponent,
            sizeBytes: sizeOfItem(at: source, fileManager: fileManager)
        ))
    }

    private static func resolveLibraryModel(
        root: URL,
        variant: String,
        fileManager: FileManager
    ) async throws -> ResolvedWhisperBenchmarkModel {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            throw WhisperBenchmarkModelResolutionError.libraryRootMissing(root)
        }
        guard isDirectory.boolValue else {
            throw WhisperBenchmarkModelResolutionError.libraryRootIsNotDirectory(root)
        }

        let library = SpeechModelLibrary(root: root, fileManager: fileManager)
        let snapshot = await library.refresh()
        guard let model = snapshot.models.first(where: { matches($0, variant: variant) }) else {
            throw WhisperBenchmarkModelResolutionError.variantNotFound(
                variant,
                snapshot.models.compactMap { model in
                    model.variant ?? model.primaryWeightsAsset?.relativePath ?? model.displayName
                }
            )
        }
        guard let modelURL = model.primaryWeightsURL(in: root) else {
            throw WhisperBenchmarkModelResolutionError.missingPrimaryWeights(model)
        }

        return ResolvedWhisperBenchmarkModel(
            model: model,
            libraryRoot: root,
            modelURL: modelURL,
            requestedVariant: variant
        )
    }

    public static func matches(_ model: InstalledSpeechModel, variant: String) -> Bool {
        let expected = variant.lowercased()
        if model.variant?.lowercased() == expected {
            return true
        }

        let primaryStem = model.primaryWeightsAsset?.relativePath
            .split(separator: "/")
            .last
            .map(String.init)?
            .replacingOccurrences(of: ".bin", with: "")
            .lowercased()

        return primaryStem == "ggml-\(expected)"
            || primaryStem == expected
            || model.displayName.lowercased() == "ggml-\(expected)"
            || model.displayName.lowercased() == expected
    }

    private static func adjacentSidecars(for modelURL: URL, fileManager: FileManager) -> [URL] {
        let directory = modelURL.deletingLastPathComponent()
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return files.filter { file in
            file.path != modelURL.path
                && (isLikelyVADWeights(file) || file.pathExtension.lowercased() == "mlmodelc")
        }
    }

    private static func isLikelyPrimaryWeights(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "bin" && !isLikelyVADWeights(url)
    }

    private static func isLikelyVADWeights(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "bin" else { return false }
        let filename = url.lastPathComponent.lowercased()
        return filename.contains("vad") || filename.contains("silero")
    }

    private static func sizeOfItem(at url: URL, fileManager: FileManager) -> Int64 {
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
        ) else {
            return 0
        }
        return children.reduce(Int64(0)) { partial, child in
            partial + sizeOfItem(at: child, fileManager: fileManager)
        }
    }

    private static func url(forPath path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    private static func nonBlank(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

public typealias ResolvedWhisperTestModel = ResolvedWhisperBenchmarkModel
public typealias WhisperRealTestModelResolver = WhisperBenchmarkModelResolver
