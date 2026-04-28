import AppKit
import CarbocationLocalSpeech
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
public struct SpeechModelLibraryPickerView: View {
    private let library: SpeechModelLibrary
    @Binding private var selectionStorageValue: String
    private let title: String
    private let confirmTitle: String
    private let confirmDisabled: Bool
    private let systemOptions: [SpeechSystemModelOption]
    private let curatedCatalog: [CuratedSpeechModel]
    private let labelPolicy: SpeechModelPickerLabelPolicy
    private let physicalMemoryBytes: UInt64
    private let onSelectionConfirmed: @MainActor (SpeechModelSelection) -> Void
    private let onDeleteModel: (@MainActor (InstalledSpeechModel) -> Void)?
    private let onDownloadCuratedModel: ((CuratedSpeechModel) -> Void)?
    private let onImportRequested: (() -> Void)?
    private let onCustomURLRequested: (() -> Void)?

    @State private var activeDownload: SpeechModelLibraryDownload?
    @State private var notice: PickerNotice?
    @State private var showCustomSheet = false
    @State private var showDeleteConfirm: InstalledSpeechModel?
    @State private var showDeletePartialConfirm: PartialSpeechModelDownload?
    @State private var refreshToken = UUID()

    public init(
        library: SpeechModelLibrary,
        selectionStorageValue: Binding<String>,
        title: String = "Choose a Speech Provider",
        confirmTitle: String = "Use Selected Provider",
        confirmDisabled: Bool = false,
        systemOptions: [SpeechSystemModelOption] = [],
        curatedCatalog: [CuratedSpeechModel] = CuratedSpeechModelCatalog.all,
        labelPolicy: SpeechModelPickerLabelPolicy = .default,
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
        onSelectionConfirmed: @escaping @MainActor (SpeechModelSelection) -> Void = { _ in },
        onDeleteModel: (@MainActor (InstalledSpeechModel) -> Void)? = nil,
        onDownloadCuratedModel: ((CuratedSpeechModel) -> Void)? = nil,
        onImportRequested: (() -> Void)? = nil,
        onCustomURLRequested: (() -> Void)? = nil
    ) {
        self.library = library
        self._selectionStorageValue = selectionStorageValue
        self.title = title
        self.confirmTitle = confirmTitle
        self.confirmDisabled = confirmDisabled
        self.systemOptions = systemOptions
        self.curatedCatalog = curatedCatalog
        self.labelPolicy = labelPolicy
        self.physicalMemoryBytes = physicalMemoryBytes
        self.onSelectionConfirmed = onSelectionConfirmed
        self.onDeleteModel = onDeleteModel
        self.onDownloadCuratedModel = onDownloadCuratedModel
        self.onImportRequested = onImportRequested
        self.onCustomURLRequested = onCustomURLRequested
    }

    private var selectedSystemOption: SpeechSystemModelOption? {
        systemOptions.first { $0.selection.storageValue == selectionStorageValue }
    }

    private var selectedInstalledModel: InstalledSpeechModel? {
        library.model(id: selectionStorageValue)
    }

    private var selectedSelection: SpeechModelSelection? {
        if let selectedSystemOption {
            return selectedSystemOption.selection
        }
        if let selectedInstalledModel {
            return .installed(selectedInstalledModel.id)
        }
        return nil
    }

    private var recommendedCuratedModels: [CuratedSpeechModel] {
        CuratedSpeechModelCatalog.recommendedModels(among: curatedCatalog)
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !systemOptions.isEmpty {
                        systemProviderSection
                        Divider()
                    }
                    installedSection
                    if !library.partials.isEmpty {
                        Divider()
                        interruptedSection
                    }
                    Divider()
                    downloadSection
                    if let notice {
                        Label(notice.message, systemImage: notice.systemImageName)
                            .font(.callout)
                            .foregroundStyle(color(for: notice.tone))
                    }
                }
                .padding(20)
                .id(refreshToken)
            }
            Divider()
            footer
        }
        .task {
            refresh()
        }
        .sheet(isPresented: $showCustomSheet) {
            CustomSpeechDownloadSheet { request in
                startDownload(
                    from: request.sourceURL,
                    displayName: request.displayName,
                    filename: request.filename,
                    source: request.source,
                    hfRepo: request.hfRepo,
                    hfFilename: request.hfFilename,
                    expectedSHA256: nil,
                    capabilities: .whisperCppDefault
                )
            }
        }
        .alert(
            "Delete \(showDeleteConfirm?.displayName ?? "model")?",
            isPresented: Binding(
                get: { showDeleteConfirm != nil },
                set: { if !$0 { showDeleteConfirm = nil } }
            ),
            presenting: showDeleteConfirm
        ) { model in
            Button("Delete", role: .destructive) { delete(model) }
            Button("Cancel", role: .cancel) {}
        } message: { model in
            Text("This will remove \(formatBytes(model.totalSizeBytes)) from disk.")
        }
        .alert(
            "Delete interrupted download?",
            isPresented: Binding(
                get: { showDeletePartialConfirm != nil },
                set: { if !$0 { showDeletePartialConfirm = nil } }
            ),
            presenting: showDeletePartialConfirm
        ) { partial in
            Button("Delete", role: .destructive) {
                library.deletePartial(partial)
                notice = PickerNotice(
                    message: "Deleted interrupted download for \(partial.displayName).",
                    tone: .positive
                )
                refresh()
            }
            Button("Cancel", role: .cancel) {}
        } message: { partial in
            Text("This will delete the partial download for \(partial.displayName) and reclaim \(formatBytes(partial.bytesOnDisk)).")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.bold())
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var headerSubtitle: String {
        if systemOptions.isEmpty {
            return "Installed Whisper models, curated downloads, Hugging Face URLs, HTTPS URLs, and local .bin imports."
        }
        return "System providers, installed Whisper models, curated downloads, Hugging Face URLs, HTTPS URLs, and local .bin imports."
    }

    @ViewBuilder
    private var systemProviderSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("System Providers")
                .font(.headline)

            ForEach(systemOptions) { option in
                systemProviderRow(option)
            }
        }
    }

    private func systemProviderRow(_ option: SpeechSystemModelOption) -> some View {
        let isSelected = option.selection.storageValue == selectionStorageValue
        let statusLabel = labelPolicy.systemProviderLabel(for: option)

        return Button {
            selectionStorageValue = option.selection.storageValue
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                Image(systemName: option.systemImageName)
                    .foregroundStyle(.tint)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(option.displayName)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if let statusLabel {
                            statusBadge(statusLabel)
                        }
                    }
                    Text(option.subtitle.isEmpty ? option.availability.displayMessage : option.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!option.availability.shouldOfferModelOption)
    }

    @ViewBuilder
    private var installedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Installed Models")
                    .font(.headline)
                Spacer()
                Text("Total: \(formatBytes(library.totalDiskUsageBytes()))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if library.models.isEmpty {
                Text("No Whisper models installed. Download one below, or import an existing whisper.cpp .bin file.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ForEach(library.models) { model in
                    installedModelRow(model)
                }
            }

            HStack {
                Button {
                    importLocalModel()
                } label: {
                    Label("Import .bin", systemImage: "square.and.arrow.down")
                }

                Button {
                    revealModelsFolder()
                } label: {
                    Label("Reveal Folder", systemImage: "folder")
                }

                Spacer()

                Button {
                    refresh()
                    notice = PickerNotice(message: "Model library refreshed.", tone: .secondary)
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    private func installedModelRow(_ model: InstalledSpeechModel) -> some View {
        let selection = SpeechModelSelection.installed(model.id)
        let isSelected = selection.storageValue == selectionStorageValue
        let statusLabel = labelPolicy.installedModelLabel(
            for: model,
            recommendedCuratedModels: recommendedCuratedModels
        )

        return Button {
            selectionStorageValue = selection.storageValue
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(model.displayName)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if let statusLabel {
                            statusBadge(statusLabel)
                        }
                    }
                    HStack(spacing: 6) {
                        if let variant = model.variant {
                            Text(variant)
                                .font(.caption.monospaced())
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: .rect(cornerRadius: 3))
                        }
                        Text(formatBytes(model.totalSizeBytes))
                        Text(languageScopeLabel(model.languageScope))
                        if let repo = model.hfRepo {
                            Text(repo)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }

                Spacer()

                Button {
                    showDeleteConfirm = model
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete this model")
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([model.directory(in: library.root)])
            } label: {
                Label("Reveal", systemImage: "folder")
            }
            Button(role: .destructive) {
                showDeleteConfirm = model
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var interruptedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Interrupted Downloads")
                .font(.headline)
            ForEach(library.partials) { partial in
                interruptedRow(partial)
            }
        }
    }

    private func interruptedRow(_ partial: PartialSpeechModelDownload) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(partial.displayName)
                    .font(.body)
                    .lineLimit(1)
                Text("\(formatBytes(partial.bytesOnDisk)) of \(formatBytes(partial.totalBytes)) - \(Int(partial.fractionComplete * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Resume") {
                resume(partial)
            }
            .disabled(activeDownload != nil)
            Button {
                showDeletePartialConfirm = partial
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete partial download")
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var downloadSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Download a Model")
                .font(.headline)
            Text(recommendationSummary())
                .font(.caption)
                .foregroundStyle(.secondary)

            if let activeDownload {
                activeDownloadRow(activeDownload)
            } else {
                ForEach(curatedCatalog) { model in
                    curatedModelRow(model)
                }
                Button {
                    requestCustomDownload()
                } label: {
                    Label("Paste a Hugging Face or HTTPS URL", systemImage: "link")
                }
                .padding(.top, 4)
            }
        }
    }

    private func curatedModelRow(_ model: CuratedSpeechModel) -> some View {
        let alreadyInstalled = library.models.contains {
            SpeechModelPickerLabelPolicy.installedModel($0, matches: model)
        }
        let statusLabel = labelPolicy.curatedModelLabel(for: model)

        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(model.displayName)
                        .font(.body)
                        .lineLimit(1)
                    if let statusLabel {
                        statusBadge(statusLabel)
                    }
                }
                Text(model.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text("\(formatBytes(model.approxSizeBytes)) - \(languageScopeLabel(model.languageScope)) - ~\(model.recommendedRAMGB) GB RAM")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if alreadyInstalled {
                Label("Installed", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                    .font(.caption)
                    .fixedSize(horizontal: true, vertical: false)
            } else {
                Button("Download") {
                    downloadCuratedModel(model)
                }
                .disabled(model.downloadURL == nil)
            }
        }
        .padding(.vertical, 4)
    }

    private func activeDownloadRow(_ download: SpeechModelLibraryDownload) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Downloading \(download.displayName)")
                .font(.body)
                .lineLimit(1)
            ProgressView(value: download.progress.fractionComplete)
            HStack {
                Text("\(formatBytes(download.progress.bytesReceived)) of \(formatBytes(download.progress.totalBytes))")
                if download.progress.bytesPerSecond > 0 {
                    Text("\(formatBytes(Int64(download.progress.bytesPerSecond)))/s")
                }
                Spacer()
                Button("Cancel", role: .destructive) {
                    download.cancel()
                    activeDownload = nil
                    refresh()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let errorMessage = download.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }

    private var footer: some View {
        HStack {
            if let selectedSystemOption {
                Label(selectedSystemOption.displayName, systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let selectedInstalledModel {
                Label(selectedInstalledModel.displayName, systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Label("Select a provider", systemImage: "circle")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(confirmTitle) {
                if let selectedSelection {
                    onSelectionConfirmed(selectedSelection)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedSelection == nil || confirmDisabled)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func statusBadge(_ label: SpeechModelPickerStatusLabel) -> some View {
        HStack(spacing: 3) {
            if let systemImageName = label.systemImageName {
                Image(systemName: systemImageName)
            }
            Text(label.title)
        }
        .font(.caption2)
        .fontWeight(.semibold)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(color(for: label.tone).opacity(0.15), in: Capsule())
        .foregroundStyle(color(for: label.tone))
    }

    private func color(for tone: SpeechModelPickerStatusLabel.Tone) -> Color {
        switch tone {
        case .accent:
            return .accentColor
        case .positive:
            return .green
        case .warning:
            return .orange
        case .secondary:
            return .secondary
        }
    }

    private func downloadCuratedModel(_ model: CuratedSpeechModel) {
        if let onDownloadCuratedModel {
            onDownloadCuratedModel(model)
            refresh()
            return
        }

        guard let sourceURL = model.downloadURL else {
            notice = PickerNotice(message: "No download URL is configured for \(model.displayName).", tone: .warning)
            return
        }

        startDownload(
            from: sourceURL,
            displayName: model.displayName,
            filename: model.hfFilename ?? sourceURL.lastPathComponent,
            source: .curated,
            hfRepo: model.hfRepo,
            hfFilename: model.hfFilename,
            expectedSHA256: model.sha256,
            capabilities: model.capabilities
        )
    }

    private func resume(_ partial: PartialSpeechModelDownload) {
        let curated = curatedCatalog.first {
            $0.hfRepo == partial.hfRepo && $0.hfFilename == partial.hfFilename
        }
        let sourceURL = curated?.downloadURL ?? partial.sourceURL
        startDownload(
            from: sourceURL,
            displayName: partial.displayName,
            filename: partial.hfFilename ?? sourceURL.lastPathComponent,
            source: curated == nil ? .customURL : .curated,
            hfRepo: partial.hfRepo,
            hfFilename: partial.hfFilename,
            expectedSHA256: curated?.sha256,
            capabilities: curated?.capabilities ?? .whisperCppDefault
        )
    }

    private func requestCustomDownload() {
        if let onCustomURLRequested {
            onCustomURLRequested()
            refresh()
            return
        }
        showCustomSheet = true
    }

    private func startDownload(
        from sourceURL: URL,
        displayName: String,
        filename: String,
        source: SpeechModelSource,
        hfRepo: String?,
        hfFilename: String?,
        expectedSHA256: String?,
        capabilities: SpeechModelCapabilities
    ) {
        guard activeDownload == nil else { return }
        notice = nil
        let download = SpeechModelLibraryDownload(
            sourceURL: sourceURL,
            displayName: displayName,
            filename: filename,
            source: source,
            hfRepo: hfRepo,
            hfFilename: hfFilename,
            expectedSHA256: expectedSHA256,
            capabilities: capabilities,
            vadModel: CuratedSpeechModelCatalog.recommendedVADModel
        )
        activeDownload = download
        download.start(into: library) { result in
            switch result {
            case .success(let model):
                if selectionStorageValue.isEmpty {
                    selectionStorageValue = SpeechModelSelection.installed(model.id).storageValue
                }
                notice = PickerNotice(message: "Installed \(model.displayName).", tone: .positive)
            case .failure(let error):
                notice = PickerNotice(
                    message: "Failed to download \(displayName): \(error.localizedDescription)",
                    tone: .warning
                )
            }
            activeDownload = nil
            refresh()
        }
    }

    private func importLocalModel() {
        if let onImportRequested {
            onImportRequested()
            refresh()
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Import Whisper Model"
        panel.message = "Choose a whisper.cpp .bin model file."
        panel.allowedContentTypes = [UTType(filenameExtension: "bin") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = library.root

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        do {
            let model = try library.importFile(at: url)
            if selectionStorageValue.isEmpty {
                selectionStorageValue = SpeechModelSelection.installed(model.id).storageValue
            }
            notice = PickerNotice(message: "Imported \(model.displayName).", tone: .positive)
            refresh()
        } catch {
            notice = PickerNotice(
                message: "Failed to import model: \(error.localizedDescription)",
                tone: .warning
            )
        }
    }

    private func delete(_ model: InstalledSpeechModel) {
        do {
            if let onDeleteModel {
                onDeleteModel(model)
                library.refresh()
            } else {
                try library.delete(id: model.id)
            }
            if selectionStorageValue == SpeechModelSelection.installed(model.id).storageValue {
                selectionStorageValue = systemOptions.first?.selection.storageValue
                    ?? library.models.first.map { SpeechModelSelection.installed($0.id).storageValue }
                    ?? ""
            }
            notice = PickerNotice(message: "Deleted \(model.displayName).", tone: .positive)
            refresh()
        } catch {
            notice = PickerNotice(
                message: "Failed to delete \(model.displayName): \(error.localizedDescription)",
                tone: .warning
            )
        }
    }

    private func revealModelsFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([library.root])
    }

    private func refresh() {
        library.refresh()
        normalizeSelection()
        refreshToken = UUID()
    }

    private func normalizeSelection() {
        if selectionStorageValue.isEmpty {
            selectionStorageValue = systemOptions.first?.selection.storageValue
                ?? library.models.first.map { SpeechModelSelection.installed($0.id).storageValue }
                ?? ""
        } else if selectedSystemOption == nil && selectedInstalledModel == nil {
            if case .system = SpeechModelSelection(storageValue: selectionStorageValue),
               systemOptions.isEmpty {
                return
            }
            selectionStorageValue = systemOptions.first?.selection.storageValue
                ?? library.models.first.map { SpeechModelSelection.installed($0.id).storageValue }
                ?? ""
        }
    }

    private func recommendationSummary() -> String {
        let liveEnglish = recommendedCuratedModels.first { $0.recommendation == .bestLiveEnglish }?.displayName
        let liveMultilingual = recommendedCuratedModels.first { $0.recommendation == .bestLiveMultilingual }?.displayName
        let file = recommendedCuratedModels.first { $0.recommendation == .bestFile }?.displayName

        if let liveEnglish, let liveMultilingual, let file {
            return "Live: \(liveEnglish) for English, \(liveMultilingual) for multilingual. Files: \(file)."
        }
        if let liveEnglish, let liveMultilingual {
            return "Live transcription: \(liveEnglish) for English, \(liveMultilingual) for multilingual."
        }
        if let file {
            return "File transcription: \(file)."
        }
        return "Curated downloads include approximate size and RAM guidance."
    }

    private func languageScopeLabel(_ scope: SpeechLanguageScope) -> String {
        switch scope {
        case .englishOnly:
            return "English"
        case .multilingual:
            return "Multilingual"
        case .languageSpecific:
            return "Language-specific"
        case .unknown:
            return "Unknown language"
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 B" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: bytes)
    }
}

@MainActor
@Observable
private final class SpeechModelLibraryDownload {
    var progress = SpeechDownloadProgress(bytesReceived: 0, totalBytes: 0, bytesPerSecond: 0)
    var isRunning = false
    var errorMessage: String?

    let sourceURL: URL
    let displayName: String
    let filename: String
    let source: SpeechModelSource
    let hfRepo: String?
    let hfFilename: String?
    let expectedSHA256: String?
    let capabilities: SpeechModelCapabilities
    let vadModel: CuratedSpeechVADModel?

    @ObservationIgnored
    private var task: Task<Void, Never>?

    init(
        sourceURL: URL,
        displayName: String,
        filename: String,
        source: SpeechModelSource,
        hfRepo: String?,
        hfFilename: String?,
        expectedSHA256: String?,
        capabilities: SpeechModelCapabilities,
        vadModel: CuratedSpeechVADModel? = nil
    ) {
        self.sourceURL = sourceURL
        self.displayName = displayName
        self.filename = filename
        self.source = source
        self.hfRepo = hfRepo
        self.hfFilename = hfFilename
        self.expectedSHA256 = expectedSHA256
        self.capabilities = capabilities
        self.vadModel = vadModel
    }

    func start(
        into library: SpeechModelLibrary,
        completion: @escaping @MainActor (Result<InstalledSpeechModel, Error>) -> Void
    ) {
        guard !isRunning else { return }
        isRunning = true
        errorMessage = nil

        task = Task { @MainActor [weak self] in
            guard let self else { return }
            var primaryTempURL: URL?
            var vadTempURL: URL?
            do {
                let result = try await SpeechModelDownloader.download(
                    from: sourceURL,
                    displayName: displayName,
                    expectedSHA256: expectedSHA256,
                    to: library.root,
                    onProgress: { [weak self] progress in
                        Task { @MainActor [weak self] in
                            self?.progress = progress
                        }
                    }
                )
                primaryTempURL = result.tempURL
                var vadResult: SpeechModelDownloadResult?
                if let vadModel {
                    do {
                        try Task.checkCancellation()
                        vadResult = try await SpeechModelDownloader.download(
                            hfRepo: vadModel.hfRepo,
                            hfFilename: vadModel.hfFilename,
                            modelsRoot: library.root,
                            displayName: vadModel.displayName,
                            expectedSHA256: vadModel.sha256,
                            onProgress: { [weak self] progress in
                                Task { @MainActor [weak self] in
                                    self?.progress = progress
                                }
                            }
                        )
                        vadTempURL = vadResult?.tempURL
                    } catch SpeechModelDownloaderError.cancelled {
                        throw SpeechModelDownloaderError.cancelled
                    } catch is CancellationError {
                        throw SpeechModelDownloaderError.cancelled
                    } catch {
                        errorMessage = "Downloaded \(displayName), but VAD download failed: \(error.localizedDescription)"
                    }
                }
                let model = try library.add(
                    primaryAssetAt: result.tempURL,
                    displayName: displayName,
                    filename: filename,
                    source: source,
                    sourceURL: sourceURL,
                    hfRepo: hfRepo,
                    hfFilename: hfFilename,
                    sha256: result.sha256,
                    capabilities: capabilities,
                    vadAssetAt: vadResult?.tempURL,
                    vadFilename: vadResult == nil ? nil : vadModel?.hfFilename,
                    vadSHA256: vadResult?.sha256
                )
                primaryTempURL = nil
                vadTempURL = nil
                isRunning = false
                completion(.success(model))
            } catch is CancellationError {
                if let primaryTempURL {
                    try? FileManager.default.removeItem(at: primaryTempURL)
                }
                if let vadTempURL {
                    try? FileManager.default.removeItem(at: vadTempURL)
                }
                isRunning = false
                errorMessage = SpeechModelDownloaderError.cancelled.localizedDescription
                completion(.failure(SpeechModelDownloaderError.cancelled))
            } catch {
                if let primaryTempURL {
                    try? FileManager.default.removeItem(at: primaryTempURL)
                }
                if let vadTempURL {
                    try? FileManager.default.removeItem(at: vadTempURL)
                }
                isRunning = false
                errorMessage = error.localizedDescription
                completion(.failure(error))
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
    }
}

private struct SpeechCustomDownloadRequest: Hashable {
    var sourceURL: URL
    var displayName: String
    var filename: String
    var source: SpeechModelSource
    var hfRepo: String?
    var hfFilename: String?
}

private struct CustomSpeechDownloadSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var displayName = ""
    @State private var parseError: String?

    let onSubmit: (SpeechCustomDownloadRequest) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Download Whisper Model")
                .font(.title3.bold())

            TextField(
                "https://huggingface.co/<repo>/resolve/main/<file>.bin",
                text: $input,
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .lineLimit(2...4)

            TextField("Display name", text: $displayName)
                .textFieldStyle(.roundedBorder)

            if let parseError {
                Label(parseError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Download") { submit() }
                    .buttonStyle(.borderedProminent)
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    private func submit() {
        let rawValue = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawValue.isEmpty else { return }

        if let hfModel = HuggingFaceSpeechModelURL.parse(rawValue),
           let sourceURL = CuratedSpeechModel.huggingFaceResolveURL(repo: hfModel.repo, filename: hfModel.filename) {
            let name = displayName.nilIfEmpty ?? hfModel.filename.replacingOccurrences(of: ".bin", with: "")
            onSubmit(SpeechCustomDownloadRequest(
                sourceURL: sourceURL,
                displayName: name,
                filename: hfModel.filename,
                source: .customURL,
                hfRepo: hfModel.repo,
                hfFilename: hfModel.filename
            ))
            dismiss()
            return
        }

        guard let sourceURL = URL(string: rawValue),
              sourceURL.scheme?.lowercased() == "https",
              sourceURL.pathExtension.lowercased() == "bin"
        else {
            parseError = "Expected a Hugging Face URL, repo/file.bin path, or direct HTTPS URL ending in .bin."
            return
        }

        let name = displayName.nilIfEmpty ?? sourceURL.deletingPathExtension().lastPathComponent
        onSubmit(SpeechCustomDownloadRequest(
            sourceURL: sourceURL,
            displayName: name,
            filename: sourceURL.lastPathComponent,
            source: .customURL,
            hfRepo: nil,
            hfFilename: nil
        ))
        dismiss()
    }
}

private struct PickerNotice: Equatable {
    var message: String
    var tone: SpeechModelPickerStatusLabel.Tone

    var systemImageName: String {
        switch tone {
        case .accent:
            return "arrow.down.circle"
        case .positive:
            return "checkmark.circle"
        case .warning:
            return "exclamationmark.triangle"
        case .secondary:
            return "info.circle"
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
