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
    @State private var transcriptEvents: [TranscriptEvent] = []
    @State private var microphoneStatus = MicrophonePermissionHelper.authorizationStatus()
    @State private var loadedInfo: LocalSpeechLoadedModelInfo?
    @State private var statusMessage = "Select a provider, then start listening."
    @State private var statusTone = CLSSmokeStatusTone.secondary
    @State private var isStarting = false
    @State private var isListening = false
    @State private var captureSession: AVAudioEngineCaptureSession?
    @State private var transcriptionTask: Task<Void, Never>?
    @State private var activeSessionID: UUID?

    private let maximumDisplayedEvents = 500

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
                    confirmTitle: confirmTitle,
                    confirmDisabled: isStarting,
                    systemOptions: systemOptions,
                    onSelectionConfirmed: { selection in
                        startListening(with: selection)
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
                sessionStatus
                Divider()
                LiveTranscriptDebugView(events: events, transcriptEvents: transcriptEvents)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 980, minHeight: 600)
        .task {
            systemOptions = await LocalSpeechEngine.systemModelOptions(locale: .current)
        }
        .onDisappear {
            stopListening()
        }
    }

    private var confirmTitle: String {
        if isStarting {
            return "Starting..."
        }
        if isListening {
            return "Restart Listening"
        }
        return "Start Listening"
    }

    private var sessionStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Label(statusMessage, systemImage: statusTone.systemImageName)
                    .foregroundStyle(statusTone.color)
                    .lineLimit(2)

                if isStarting {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()

                if let loadedInfo {
                    Text(loadedInfo.backend.displayName)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Button {
                    stopListening()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .disabled(!isStarting && !isListening)
            }

            MicrophonePermissionStatusView(status: microphoneStatus)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func startListening(with selection: SpeechModelSelection) {
        stopListening(updateStatus: false)

        let sessionID = UUID()
        activeSessionID = sessionID
        loadedInfo = nil
        events.removeAll(keepingCapacity: true)
        transcriptEvents.removeAll(keepingCapacity: true)
        isStarting = true
        isListening = false
        statusTone = .secondary
        statusMessage = "Preparing selected provider..."

        transcriptionTask = Task {
            await runLiveTranscriptionSession(id: sessionID, selection: selection)
        }
    }

    private func stopListening(updateStatus: Bool = true) {
        activeSessionID = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
        captureSession?.stop()
        captureSession = nil
        isStarting = false
        isListening = false

        if updateStatus {
            statusTone = .secondary
            statusMessage = "Stopped."
        }
    }

    private func runLiveTranscriptionSession(id: UUID, selection: SpeechModelSelection) async {
        do {
            guard await ensureMicrophoneAccess() else {
                finishSession(id: id, message: "Microphone access is required to listen.", tone: .error)
                return
            }

            guard activeSessionID == id else { return }
            statusMessage = "Loading selected provider..."

            let loaded = try await LocalSpeechEngine.shared.load(
                selection: selection,
                from: library,
                options: SpeechLoadOptions(
                    locale: .current,
                    installSystemAssetsIfNeeded: true
                )
            )

            guard activeSessionID == id else { return }
            loadedInfo = loaded

            let capture = AVAudioEngineCaptureSession()
            captureSession = capture
            isStarting = false
            isListening = true
            statusTone = .listening
            statusMessage = "Listening with \(loaded.displayName)."

            let audio = capture.start(configuration: AudioCaptureConfiguration(
                preferredSampleRate: 16_000,
                preferredChannelCount: 1,
                frameDuration: 0.1
            ))
            let stream = await LocalSpeechEngine.shared.stream(
                audio: audio,
                options: StreamingTranscriptionOptions(
                    transcription: TranscriptionOptions(
                        useCase: .dictation,
                        language: Locale.current.language.languageCode?.identifier
                    ),
                    implementation: .automatic,
                    commitment: .automatic,
                    latencyPreset: .balancedDictation
                )
            )

            for try await event in stream {
                try Task.checkCancellation()
                guard activeSessionID == id else { return }
                appendEvent(event)
            }

            finishSession(id: id, message: "Listening completed.", tone: .secondary)
        } catch is CancellationError {
            finishSession(id: id, message: "Stopped.", tone: .secondary)
        } catch {
            finishSession(id: id, message: error.localizedDescription, tone: .error)
        }
    }

    private func ensureMicrophoneAccess() async -> Bool {
        microphoneStatus = MicrophonePermissionHelper.authorizationStatus()

        switch microphoneStatus {
        case .authorized:
            return true
        case .notDetermined:
            _ = await MicrophonePermissionHelper.requestAccess()
            microphoneStatus = MicrophonePermissionHelper.authorizationStatus()
            return microphoneStatus == .authorized
        case .denied, .restricted, .unknown:
            return false
        }
    }

    private func appendEvent(_ event: TranscriptEvent) {
        events.append(event)
        if event.isTranscriptPanelEvent {
            transcriptEvents.append(event)
        }

        let overflow = events.count - maximumDisplayedEvents
        if overflow > 0 {
            events.removeFirst(overflow)
        }
    }

    private func finishSession(id: UUID, message: String, tone: CLSSmokeStatusTone) {
        guard activeSessionID == id else { return }

        captureSession?.stop()
        captureSession = nil
        transcriptionTask = nil
        activeSessionID = nil
        isStarting = false
        isListening = false
        statusMessage = message
        statusTone = tone
    }
}

private extension TranscriptEvent {
    var isTranscriptPanelEvent: Bool {
        switch self {
        case .snapshot, .partial, .revision, .committed, .progress, .stats, .completed:
            return true
        case .started, .audioLevel, .voiceActivity, .diagnostic:
            return false
        }
    }
}

private enum CLSSmokeStatusTone {
    case secondary
    case listening
    case error

    var systemImageName: String {
        switch self {
        case .secondary:
            return "info.circle"
        case .listening:
            return "waveform.and.mic"
        case .error:
            return "exclamationmark.triangle"
        }
    }

    var color: Color {
        switch self {
        case .secondary:
            return .secondary
        case .listening:
            return .green
        case .error:
            return .red
        }
    }
}
