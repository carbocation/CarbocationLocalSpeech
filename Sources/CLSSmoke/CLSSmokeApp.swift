import CarbocationLocalSpeech
import CarbocationLocalSpeechRuntime
import CarbocationLocalSpeechUI
import SwiftUI

@main
struct CLSSmokeApp: App {
    var body: some Scene {
        WindowGroup {
            CLSSmokeRootView()
        }
    }
}

@MainActor
private struct CLSSmokeRootView: View {
    @State private var selectionStorageValue = SpeechSystemModelID.appleSpeech.rawValue
    @State private var systemOptions: [SpeechSystemModelOption] = []
    @State private var events: [TranscriptEvent] = []

    private let library = SpeechModelLibrary(
        root: SpeechModelStorage.modelsDirectory(appSupportFolderName: "CLSSmoke")
    )

    var body: some View {
        NavigationSplitView {
            SpeechModelLibraryPickerView(
                library: library,
                selectionStorageValue: $selectionStorageValue,
                systemOptions: systemOptions,
                onSelectionConfirmed: { selection in
                    Task {
                        _ = try? await LocalSpeechEngine.shared.load(
                            selection: selection,
                            from: library,
                            options: SpeechLoadOptions(locale: .current)
                        )
                    }
                },
                onDeleteModel: { model in
                    try? library.delete(id: model.id)
                }
            )
            .navigationTitle("Speech Providers")
        } detail: {
            LiveTranscriptDebugView(events: events)
                .navigationTitle("Diagnostics")
        }
        .frame(minWidth: 860, minHeight: 560)
        .task {
            systemOptions = await LocalSpeechEngine.systemModelOptions(locale: .current)
        }
    }
}
