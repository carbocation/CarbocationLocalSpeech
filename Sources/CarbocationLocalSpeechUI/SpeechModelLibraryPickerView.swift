import AppKit
import CarbocationLocalSpeech
import SwiftUI
import UniformTypeIdentifiers

@MainActor
public struct SpeechModelLibraryPickerView: View {
    private let library: SpeechModelLibrary
    @Binding private var selectionStorageValue: String
    private let systemOptions: [SpeechSystemModelOption]
    private let curatedCatalog: [CuratedSpeechModel]
    private let labelPolicy: SpeechModelPickerLabelPolicy
    private let physicalMemoryBytes: UInt64
    private let onSelectionConfirmed: (SpeechModelSelection) -> Void
    private let onDeleteModel: ((InstalledSpeechModel) -> Void)?
    private let onDownloadCuratedModel: ((CuratedSpeechModel) -> Void)?
    private let onImportRequested: (() -> Void)?
    private let onCustomURLRequested: (() -> Void)?

    @State private var activeDownloadIDs: Set<String> = []
    @State private var notice: PickerNotice?

    public init(
        library: SpeechModelLibrary,
        selectionStorageValue: Binding<String>,
        systemOptions: [SpeechSystemModelOption] = [],
        curatedCatalog: [CuratedSpeechModel] = CuratedSpeechModelCatalog.all,
        labelPolicy: SpeechModelPickerLabelPolicy = .default,
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
        onSelectionConfirmed: @escaping (SpeechModelSelection) -> Void = { _ in },
        onDeleteModel: ((InstalledSpeechModel) -> Void)? = nil,
        onDownloadCuratedModel: ((CuratedSpeechModel) -> Void)? = nil,
        onImportRequested: (() -> Void)? = nil,
        onCustomURLRequested: (() -> Void)? = nil
    ) {
        self.library = library
        self._selectionStorageValue = selectionStorageValue
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

    public var body: some View {
        List {
            if let notice {
                Section {
                    Label(notice.message, systemImage: notice.systemImageName)
                        .font(.caption)
                        .foregroundStyle(color(for: notice.tone))
                }
            }

            if !systemOptions.isEmpty {
                Section("System Providers") {
                    ForEach(systemOptions) { option in
                        providerButton(option)
                    }
                }
            }

            Section("Installed Models") {
                if library.models.isEmpty {
                    Text("No installed speech models")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(library.models) { model in
                        installedModelButton(model)
                    }
                }
            }

            if !library.partials.isEmpty {
                Section("Interrupted Downloads") {
                    ForEach(library.partials) { partial in
                        HStack {
                            Label(partial.displayName, systemImage: "arrow.down.circle")
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .layoutPriority(1)
                            Spacer()
                            Text(partial.fractionComplete, format: .percent.precision(.fractionLength(0)))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: true, vertical: false)
                            Button(role: .destructive) {
                                library.deletePartial(partial)
                                notice = PickerNotice(
                                    message: "Deleted interrupted download for \(partial.displayName).",
                                    tone: .positive
                                )
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }

            Section("Curated Whisper Models") {
                ForEach(curatedCatalog) { model in
                    curatedRow(model)
                }
            }

            Section {
                Button(action: importModel) {
                    Label("Import Local Model", systemImage: "square.and.arrow.down")
                }
                Button(action: requestCustomURLDownload) {
                    Label("Download From URL", systemImage: "link.badge.plus")
                }
                Button {
                    library.refresh()
                    notice = PickerNotice(message: "Model library refreshed.", tone: .secondary)
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([library.root])
                } label: {
                    Label("Reveal Folder", systemImage: "folder")
                }
            }

            Section("Storage") {
                LabeledContent("Installed Usage") {
                    Text(ByteCountFormatter.string(fromByteCount: library.totalDiskUsageBytes(), countStyle: .file))
                }
            }
        }
        .listStyle(.inset)
    }

    private var recommendedCuratedModel: CuratedSpeechModel? {
        CuratedSpeechModelCatalog.recommendedModel(
            forPhysicalMemoryBytes: physicalMemoryBytes,
            among: curatedCatalog
        )
    }

    private var bestInstalledCuratedModel: CuratedSpeechModel? {
        SpeechModelPickerLabelPolicy.bestInstalledCuratedModel(
            forPhysicalMemoryBytes: physicalMemoryBytes,
            installedModels: library.models,
            curatedModels: curatedCatalog
        )
    }

    private func providerButton(_ option: SpeechSystemModelOption) -> some View {
        Button {
            selectionStorageValue = option.selection.storageValue
            onSelectionConfirmed(option.selection)
        } label: {
            rowContent(
                title: option.displayName,
                subtitle: option.subtitle,
                systemImageName: option.systemImageName,
                isSelected: selectionStorageValue == option.selection.storageValue,
                statusLabel: labelPolicy.systemProviderLabel(for: option)
            )
        }
        .disabled(!option.availability.shouldOfferModelOption)
    }

    private func installedModelButton(_ model: InstalledSpeechModel) -> some View {
        let selection = SpeechModelSelection.installed(model.id)

        return Button {
            selectionStorageValue = selection.storageValue
            onSelectionConfirmed(selection)
        } label: {
            rowContent(
                title: model.displayName,
                subtitle: installedSubtitle(model),
                systemImageName: "waveform",
                isSelected: selectionStorageValue == selection.storageValue,
                statusLabel: labelPolicy.installedModelLabel(
                    for: model,
                    recommendedCuratedModel: recommendedCuratedModel,
                    bestInstalledCuratedModel: bestInstalledCuratedModel
                )
            )
        }
        .contextMenu {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([model.directory(in: library.root)])
            } label: {
                Label("Reveal", systemImage: "folder")
            }
            Button(role: .destructive) {
                deleteModel(model)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func curatedRow(_ model: CuratedSpeechModel) -> some View {
        let downloadID = curatedDownloadID(for: model)
        let isDownloading = activeDownloadIDs.contains(downloadID)
        let isInstalled = library.models.contains {
            SpeechModelPickerLabelPolicy.installedModel($0, matches: model)
        }
        let statusLabel = labelPolicy.curatedModelLabel(
            for: model,
            recommendedCuratedModel: recommendedCuratedModel
        )

        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(model.displayName)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let statusLabel {
                        status(statusLabel)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                Text(model.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(ByteCountFormatter.string(fromByteCount: model.approxSizeBytes, countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
                if isInstalled {
                    status(SpeechModelPickerStatusLabel("Installed", systemImageName: "checkmark.circle", tone: .positive))
                        .fixedSize(horizontal: true, vertical: false)
                } else if isDownloading {
                    ProgressView()
                        .controlSize(.small)
                        .help("Downloading \(model.displayName)")
                } else {
                    Button {
                        downloadCuratedModel(model)
                    } label: {
                        Label("Download", systemImage: "arrow.down")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .fixedSize(horizontal: true, vertical: false)
                    .help(model.downloadURL == nil ? "No download URL is configured." : "Download \(model.displayName)")
                    .disabled(model.downloadURL == nil)
                }
            }
        }
    }

    private func deleteModel(_ model: InstalledSpeechModel) {
        if let onDeleteModel {
            onDeleteModel(model)
            return
        }

        do {
            try library.delete(id: model.id)
            notice = PickerNotice(message: "Deleted \(model.displayName).", tone: .positive)
        } catch {
            notice = PickerNotice(
                message: "Failed to delete \(model.displayName): \(error.localizedDescription)",
                tone: .warning
            )
        }
    }

    private func importModel() {
        if let onImportRequested {
            onImportRequested()
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Import Whisper Model"
        panel.message = "Choose a whisper.cpp .bin model file."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let binType = UTType(filenameExtension: "bin") {
            panel.allowedContentTypes = [binType]
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let model = try library.importFile(at: url)
            notice = PickerNotice(message: "Imported \(model.displayName).", tone: .positive)
        } catch {
            notice = PickerNotice(
                message: "Failed to import model: \(error.localizedDescription)",
                tone: .warning
            )
        }
    }

    private func requestCustomURLDownload() {
        if let onCustomURLRequested {
            onCustomURLRequested()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Download Whisper Model"
        alert.informativeText = "Enter a Hugging Face model path or a direct HTTPS URL to a whisper.cpp .bin file."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        input.placeholderString = "ggerganov/whisper.cpp/ggml-base.en.bin"
        alert.accessoryView = input

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let rawValue = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawValue.isEmpty else { return }

        if let hfModel = HuggingFaceSpeechModelURL.parse(rawValue),
           let sourceURL = CuratedSpeechModel.huggingFaceResolveURL(repo: hfModel.repo, filename: hfModel.filename) {
            startDownload(
                from: sourceURL,
                displayName: displayName(for: sourceURL),
                source: .customURL,
                downloadID: "url:\(sourceURL.absoluteString)",
                hfRepo: hfModel.repo,
                hfFilename: hfModel.filename,
                expectedSHA256: nil,
                capabilities: .whisperCppDefault
            )
            return
        }

        guard let sourceURL = URL(string: rawValue),
              sourceURL.scheme?.lowercased() == "https",
              sourceURL.pathExtension.lowercased() == "bin"
        else {
            notice = PickerNotice(message: "Enter an HTTPS URL ending in .bin.", tone: .warning)
            return
        }

        startDownload(
            from: sourceURL,
            displayName: displayName(for: sourceURL),
            source: .customURL,
            downloadID: "url:\(sourceURL.absoluteString)",
            hfRepo: nil,
            hfFilename: nil,
            expectedSHA256: nil,
            capabilities: .whisperCppDefault
        )
    }

    private func downloadCuratedModel(_ model: CuratedSpeechModel) {
        if let onDownloadCuratedModel {
            onDownloadCuratedModel(model)
            return
        }

        guard let sourceURL = model.downloadURL else {
            notice = PickerNotice(message: "No download URL is configured for \(model.displayName).", tone: .warning)
            return
        }

        startDownload(
            from: sourceURL,
            displayName: model.displayName,
            source: .curated,
            downloadID: curatedDownloadID(for: model),
            hfRepo: model.hfRepo,
            hfFilename: model.hfFilename,
            expectedSHA256: model.sha256,
            capabilities: model.capabilities
        )
    }

    private func startDownload(
        from sourceURL: URL,
        displayName: String,
        source: SpeechModelSource,
        downloadID: String,
        hfRepo: String?,
        hfFilename: String?,
        expectedSHA256: String?,
        capabilities: SpeechModelCapabilities
    ) {
        guard activeDownloadIDs.insert(downloadID).inserted else { return }
        notice = PickerNotice(message: "Downloading \(displayName)...", tone: .secondary)

        Task { @MainActor in
            do {
                let result = try await SpeechModelDownloader.download(
                    from: sourceURL,
                    displayName: displayName,
                    expectedSHA256: expectedSHA256,
                    to: library.root
                )
                _ = try library.add(
                    primaryAssetAt: result.tempURL,
                    displayName: displayName,
                    source: source,
                    sourceURL: sourceURL,
                    hfRepo: hfRepo,
                    hfFilename: hfFilename,
                    sha256: result.sha256,
                    capabilities: capabilities
                )
                notice = PickerNotice(message: "Installed \(displayName).", tone: .positive)
            } catch {
                notice = PickerNotice(
                    message: "Failed to download \(displayName): \(error.localizedDescription)",
                    tone: .warning
                )
            }
            activeDownloadIDs.remove(downloadID)
        }
    }

    private func curatedDownloadID(for model: CuratedSpeechModel) -> String {
        "curated:\(model.id)"
    }

    private func displayName(for sourceURL: URL) -> String {
        let displayName = sourceURL.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return displayName.isEmpty ? "Whisper Model" : displayName
    }

    private func rowContent(
        title: String,
        subtitle: String,
        systemImageName: String,
        isSelected: Bool,
        statusLabel: SpeechModelPickerStatusLabel?
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImageName)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            Spacer(minLength: 8)
            if let statusLabel {
                status(statusLabel)
                    .fixedSize(horizontal: true, vertical: false)
            }
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .contentShape(Rectangle())
    }

    private func status(_ label: SpeechModelPickerStatusLabel) -> some View {
        Label {
            Text(label.title)
        } icon: {
            if let image = label.systemImageName {
                Image(systemName: image)
            }
        }
        .font(.caption)
        .foregroundStyle(color(for: label.tone))
        .labelStyle(.titleAndIcon)
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

    private func installedSubtitle(_ model: InstalledSpeechModel) -> String {
        let size = ByteCountFormatter.string(fromByteCount: model.totalSizeBytes, countStyle: .file)
        let variant = model.variant.map { " \($0)" } ?? ""
        return "\(model.providerKind.rawValue)\(variant) - \(size)"
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
