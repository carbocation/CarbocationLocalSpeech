import AppKit
import CarbocationLocalSpeech
import SwiftUI

@MainActor
public struct SpeechModelLibraryPickerView: View {
    private let library: SpeechModelLibrary
    @Binding private var selectionStorageValue: String
    private let systemOptions: [SpeechSystemModelOption]
    private let curatedCatalog: [CuratedSpeechModel]
    private let labelPolicy: SpeechModelPickerLabelPolicy
    private let physicalMemoryBytes: UInt64
    private let onSelectionConfirmed: (SpeechModelSelection) -> Void
    private let onDeleteModel: (InstalledSpeechModel) -> Void
    private let onDownloadCuratedModel: (CuratedSpeechModel) -> Void
    private let onImportRequested: () -> Void
    private let onCustomURLRequested: () -> Void

    public init(
        library: SpeechModelLibrary,
        selectionStorageValue: Binding<String>,
        systemOptions: [SpeechSystemModelOption] = [],
        curatedCatalog: [CuratedSpeechModel] = CuratedSpeechModelCatalog.all,
        labelPolicy: SpeechModelPickerLabelPolicy = .default,
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
        onSelectionConfirmed: @escaping (SpeechModelSelection) -> Void = { _ in },
        onDeleteModel: @escaping (InstalledSpeechModel) -> Void = { _ in },
        onDownloadCuratedModel: @escaping (CuratedSpeechModel) -> Void = { _ in },
        onImportRequested: @escaping () -> Void = {},
        onCustomURLRequested: @escaping () -> Void = {}
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
                Button(action: onImportRequested) {
                    Label("Import Local Model", systemImage: "square.and.arrow.down")
                }
                Button(action: onCustomURLRequested) {
                    Label("Download From URL", systemImage: "link.badge.plus")
                }
                Button {
                    library.refresh()
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
        let recommended = CuratedSpeechModelCatalog.recommendedModel(
            forPhysicalMemoryBytes: physicalMemoryBytes,
            among: curatedCatalog
        )
        let bestInstalled = SpeechModelPickerLabelPolicy.bestInstalledCuratedModel(
            forPhysicalMemoryBytes: physicalMemoryBytes,
            installedModels: library.models,
            curatedModels: curatedCatalog
        )
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
                    recommendedCuratedModel: recommended,
                    bestInstalledCuratedModel: bestInstalled
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
                onDeleteModel(model)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func curatedRow(_ model: CuratedSpeechModel) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)
                    .lineLimit(1)
                    .truncationMode(.tail)
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
                Button {
                    onDownloadCuratedModel(model)
                } label: {
                    Image(systemName: "arrow.down")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .disabled(model.sourceURL == nil && model.hfRepo == nil)
            }
        }
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
