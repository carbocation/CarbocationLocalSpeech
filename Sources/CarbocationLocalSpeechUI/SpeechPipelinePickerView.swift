import CarbocationLocalSpeech
import SwiftUI

@MainActor
public struct SpeechPipelinePickerView: View {
    private let library: SpeechModelLibrary
    @Binding private var selectionStorageValue: String
    private let title: String
    private let confirmTitle: String
    private let confirmDisabled: Bool
    private let showsConfirmationFooter: Bool
    private let systemOptions: [SpeechSystemModelOption]
    private let curatedCatalog: [CuratedSpeechModel]
    private let diarizationOptions: [DiarizationModelOption]
    private let labelPolicy: SpeechModelPickerLabelPolicy
    private let physicalMemoryBytes: UInt64
    private let onSelectionConfirmed: @MainActor (SpeechPipelineSelection) -> Void
    private let onDeleteModel: (@MainActor (InstalledSpeechModel) async throws -> SpeechModelDeleteResult)?
    private let onDownloadCuratedModel: ((CuratedSpeechModel) -> Void)?
    private let onImportRequested: (() -> Void)?
    private let onCustomURLRequested: (() -> Void)?
    private let onLibraryChanged: @MainActor (SpeechModelLibrarySnapshot) -> Void

    public init(
        library: SpeechModelLibrary,
        selectionStorageValue: Binding<String>,
        title: String = "Choose a Speech Pipeline",
        confirmTitle: String = "Use Selected Pipeline",
        confirmDisabled: Bool = false,
        showsConfirmationFooter: Bool = true,
        systemOptions: [SpeechSystemModelOption] = [],
        curatedCatalog: [CuratedSpeechModel] = CuratedSpeechModelCatalog.all,
        diarizationOptions: [DiarizationModelOption] = DiarizationModelCatalog.all,
        labelPolicy: SpeechModelPickerLabelPolicy = .default,
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
        onSelectionConfirmed: @escaping @MainActor (SpeechPipelineSelection) -> Void = { _ in },
        onDeleteModel: (@MainActor (InstalledSpeechModel) async throws -> SpeechModelDeleteResult)? = nil,
        onDownloadCuratedModel: ((CuratedSpeechModel) -> Void)? = nil,
        onImportRequested: (() -> Void)? = nil,
        onCustomURLRequested: (() -> Void)? = nil,
        onLibraryChanged: @escaping @MainActor (SpeechModelLibrarySnapshot) -> Void = { _ in }
    ) {
        self.library = library
        self._selectionStorageValue = selectionStorageValue
        self.title = title
        self.confirmTitle = confirmTitle
        self.confirmDisabled = confirmDisabled
        self.showsConfirmationFooter = showsConfirmationFooter
        self.systemOptions = systemOptions
        self.curatedCatalog = curatedCatalog
        self.diarizationOptions = diarizationOptions
        self.labelPolicy = labelPolicy
        self.physicalMemoryBytes = physicalMemoryBytes
        self.onSelectionConfirmed = onSelectionConfirmed
        self.onDeleteModel = onDeleteModel
        self.onDownloadCuratedModel = onDownloadCuratedModel
        self.onImportRequested = onImportRequested
        self.onCustomURLRequested = onCustomURLRequested
        self.onLibraryChanged = onLibraryChanged
    }

    private var pipelineSelection: SpeechPipelineSelection? {
        SpeechPipelineSelection(storageValue: selectionStorageValue)
    }

    private var diarizationMode: SpeechPipelineDiarizationPickerMode {
        guard let diarization = pipelineSelection?.diarization else {
            return .off
        }
        if diarization.streaming != nil {
            return .live
        }
        if diarization.file != nil {
            return .file
        }
        return .off
    }

    private var transcriptionBinding: Binding<String> {
        Binding {
            pipelineSelection?.transcription.storageValue
                ?? SpeechModelSelection(storageValue: selectionStorageValue)?.storageValue
                ?? ""
        } set: { newValue in
            guard let transcription = SpeechModelSelection(storageValue: newValue) else {
                selectionStorageValue = newValue
                return
            }
            updatePipeline(transcription: transcription)
        }
    }

    private var diarizationModeBinding: Binding<SpeechPipelineDiarizationPickerMode> {
        Binding {
            diarizationMode
        } set: { mode in
            updatePipeline(diarization: diarizationSelection(for: mode))
        }
    }

    private var fileDiarizationBinding: Binding<String> {
        Binding {
            pipelineSelection?.diarization.file?.storageValue
                ?? defaultFileSelection.storageValue
        } set: { newValue in
            guard let selection = DiarizationModelSelection(storageValue: newValue) else {
                return
            }
            updatePipeline(diarization: SpeechDiarizationSelection(file: selection))
        }
    }

    private var streamingDiarizationBinding: Binding<String> {
        Binding {
            pipelineSelection?.diarization.streaming?.storageValue
                ?? defaultStreamingSelection.storageValue
        } set: { newValue in
            guard let selection = DiarizationModelSelection(storageValue: newValue) else {
                return
            }
            updatePipeline(diarization: SpeechDiarizationSelection(streaming: selection))
        }
    }

    private var fileOptions: [DiarizationModelOption] {
        diarizationOptions.filter(\.capabilities.supportsFileDiarization)
    }

    private var streamingOptions: [DiarizationModelOption] {
        diarizationOptions.filter(\.capabilities.supportsStreamingDiarization)
    }

    private var defaultFileSelection: DiarizationModelSelection {
        fileOptions.first?.selection ?? DiarizationModelCatalog.defaultFile.selection
    }

    private var defaultStreamingSelection: DiarizationModelSelection {
        streamingOptions.first?.selection ?? DiarizationModelCatalog.defaultStreaming.selection
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            SpeechModelLibraryPickerView(
                library: library,
                selectionStorageValue: transcriptionBinding,
                title: "Transcription Provider",
                confirmDisabled: confirmDisabled,
                showsConfirmationFooter: false,
                systemOptions: systemOptions,
                curatedCatalog: curatedCatalog,
                labelPolicy: labelPolicy,
                physicalMemoryBytes: physicalMemoryBytes,
                onDeleteModel: onDeleteModel,
                onDownloadCuratedModel: onDownloadCuratedModel,
                onImportRequested: onImportRequested,
                onCustomURLRequested: onCustomURLRequested,
                onLibraryChanged: onLibraryChanged
            )
            Divider()
            diarizationSection
            if showsConfirmationFooter {
                Divider()
                footer
            }
        }
        .onAppear {
            normalizePipelineStorage()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.bold())
                Text("Choose a required transcription provider and optional speaker diarization model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var diarizationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Speaker Diarization")
                .font(.headline)

            Picker("Diarization", selection: diarizationModeBinding) {
                ForEach(SpeechPipelineDiarizationPickerMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            switch diarizationMode {
            case .off:
                Label("Speaker diarization is off.", systemImage: "person.2.slash")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .file:
                diarizationModelPicker(
                    title: "File diarization model",
                    selection: fileDiarizationBinding,
                    options: fileOptions
                )
            case .live:
                diarizationModelPicker(
                    title: "Live diarization model",
                    selection: streamingDiarizationBinding,
                    options: streamingOptions
                )
            }
        }
        .padding(20)
    }

    private func diarizationModelPicker(
        title: String,
        selection: Binding<String>,
        options: [DiarizationModelOption]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(title, selection: selection) {
                ForEach(options) { option in
                    Text(option.displayName).tag(option.selection.storageValue)
                }
            }
            .labelsHidden()

            if let option = options.first(where: { $0.selection.storageValue == selection.wrappedValue }) {
                Label(option.subtitle, systemImage: option.systemImageName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            if let pipelineSelection {
                Label(summary(for: pipelineSelection), systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Label("Select a transcription provider", systemImage: "circle")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(confirmTitle) {
                if let pipelineSelection {
                    onSelectionConfirmed(pipelineSelection)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(pipelineSelection == nil || confirmDisabled)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func updatePipeline(
        transcription: SpeechModelSelection? = nil,
        diarization: SpeechDiarizationSelection? = nil
    ) {
        guard let resolvedTranscription = transcription
            ?? pipelineSelection?.transcription
            ?? SpeechModelSelection(storageValue: selectionStorageValue)
        else {
            return
        }

        let resolvedDiarization = diarization ?? pipelineSelection?.diarization ?? .off
        selectionStorageValue = SpeechPipelineSelection(
            transcription: resolvedTranscription,
            diarization: resolvedDiarization
        ).storageValue
    }

    private func diarizationSelection(
        for mode: SpeechPipelineDiarizationPickerMode
    ) -> SpeechDiarizationSelection {
        switch mode {
        case .off:
            return .off
        case .file:
            return SpeechDiarizationSelection(
                file: pipelineSelection?.diarization.file ?? defaultFileSelection
            )
        case .live:
            return SpeechDiarizationSelection(
                streaming: pipelineSelection?.diarization.streaming ?? defaultStreamingSelection
            )
        }
    }

    private func normalizePipelineStorage() {
        guard let pipelineSelection else {
            return
        }
        selectionStorageValue = pipelineSelection.storageValue
    }

    private func summary(for pipelineSelection: SpeechPipelineSelection) -> String {
        switch pipelineSelection.diarization {
        case let diarization where diarization.streaming != nil:
            return "Transcription with live diarization"
        case let diarization where diarization.file != nil:
            return "Transcription with file diarization"
        default:
            return "Transcription only"
        }
    }
}

private enum SpeechPipelineDiarizationPickerMode: String, CaseIterable, Identifiable {
    case off
    case file
    case live

    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .off:
            return "Off"
        case .file:
            return "File Diarization"
        case .live:
            return "Live Diarization"
        }
    }
}
