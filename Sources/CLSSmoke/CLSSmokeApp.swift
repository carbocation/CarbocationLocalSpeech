import AppKit
import CarbocationLocalSpeech
import CarbocationLocalSpeechRuntime
import CarbocationLocalSpeechUI
import SwiftUI

@main
private enum CLSSmokeApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let appDelegate = CLSSmokeAppDelegate()
        app.delegate = appDelegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(appDelegate) {
            app.finishLaunching()
            app.run()
        }
    }
}

@MainActor
private final class CLSSmokeAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMainMenu()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "CLSSmoke"
        window.contentMinSize = NSSize(width: 980, height: 600)
        window.contentViewController = NSHostingController(rootView: CLSSmokeRootView())
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false
        self.window = window

        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Quit CLSSmoke",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        NSApplication.shared.mainMenu = mainMenu
    }
}

@MainActor
private struct CLSSmokeRootView: View {
    @AppStorage("CLSSmoke.selectedSpeechModelSelection") private var selectionStorageValue = SpeechSystemModelID.appleSpeech.rawValue
    @State private var systemOptions: [SpeechSystemModelOption] = []
    @State private var events: [TranscriptEvent] = []

    private let library = SpeechModelLibrary(
        root: SpeechModelStorage.modelsDirectory(appSupportFolderName: "CLSSmoke")
    )

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Speech Providers")
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                Divider()
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
            }
            .frame(width: 430)

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                Text("Diagnostics")
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                Divider()
                LiveTranscriptDebugView(events: events)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 980, minHeight: 600)
        .task {
            systemOptions = await LocalSpeechEngine.systemModelOptions(locale: .current)
        }
    }
}
