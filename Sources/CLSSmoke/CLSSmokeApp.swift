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
    @AppStorage("CLSSmoke.vadMode") private var vadModeStorageValue = CLSSmokeVADMode.disabled.rawValue
    @AppStorage("CLSSmoke.vadSensitivity") private var vadSensitivityStorageValue = CLSSmokeVADSensitivity.medium.rawValue
    @State private var systemOptions: [SpeechSystemModelOption] = []
    @State private var eventDescriptions: [String] = []
    @State private var transcriptSnapshot = LiveTranscriptDebugSnapshot()
    @State private var microphoneStatus = MicrophonePermissionHelper.authorizationStatus()
    @State private var loadedInfo: LocalSpeechLoadedModelInfo?
    @State private var statusMessage = "Select a provider, then start listening."
    @State private var statusTone = CLSSmokeStatusTone.secondary
    @State private var isStarting = false
    @State private var isListening = false
    @State private var captureSession: AVAudioEngineCaptureSession?
    @State private var transcriptionTask: Task<Void, Never>?
    @State private var activeSessionID: UUID?
    @State private var lastLoggedAudioLevelTime: TimeInterval?
    @State private var lastLoggedVoiceActivityTime: TimeInterval?
    @State private var lastLoggedVoiceActivityState: VoiceActivityState?
    @State private var lastLoggedProgressDuration: TimeInterval?
    @State private var lastTranscriptProgressDuration: TimeInterval?

    private let maximumDisplayedEvents = 500
    private let diagnosticLogThrottleInterval: TimeInterval = 1.0
    private let transcriptMetricThrottleInterval: TimeInterval = 1.0

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
                    confirmDisabled: isConfirmDisabled,
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
                LiveTranscriptDebugView(eventDescriptions: eventDescriptions, snapshot: transcriptSnapshot)
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

    private var isConfirmDisabled: Bool {
        isStarting || isForcedVADUnavailable
    }

    private var selectedSelection: SpeechModelSelection? {
        SpeechModelSelection(storageValue: selectionStorageValue)
    }

    private var selectedVADMode: CLSSmokeVADMode {
        CLSSmokeVADMode(rawValue: vadModeStorageValue) ?? .disabled
    }

    private var selectedVADSensitivity: CLSSmokeVADSensitivity {
        CLSSmokeVADSensitivity(rawValue: vadSensitivityStorageValue) ?? .medium
    }

    private var vadModeBinding: Binding<CLSSmokeVADMode> {
        Binding(
            get: { selectedVADMode },
            set: { vadModeStorageValue = $0.rawValue }
        )
    }

    private var vadSensitivityBinding: Binding<CLSSmokeVADSensitivity> {
        Binding(
            get: { selectedVADSensitivity },
            set: { vadSensitivityStorageValue = $0.rawValue }
        )
    }

    private var selectedVADAvailability: CLSSmokeVADAvailability {
        guard let selectedSelection else {
            return CLSSmokeVADAvailability(
                isAvailable: false,
                message: "Model VAD availability unavailable until a provider is selected.",
                diagnosticValue: "unavailable:no-selection"
            )
        }
        return vadAvailability(for: selectedSelection)
    }

    private var isForcedVADUnavailable: Bool {
        selectedVADMode == .enabled && !selectedVADAvailability.isAvailable
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

            vadSettings

            MicrophonePermissionStatusView(status: microphoneStatus)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var vadSettings: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("Model VAD")
                    .font(.caption.weight(.semibold))
                    .frame(width: 80, alignment: .leading)

                Picker("Model VAD", selection: vadModeBinding) {
                    ForEach(CLSSmokeVADMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)
                .disabled(isStarting || isListening)
            }

            HStack(spacing: 10) {
                Text("Sensitivity")
                    .font(.caption.weight(.semibold))
                    .frame(width: 80, alignment: .leading)

                Picker("Sensitivity", selection: vadSensitivityBinding) {
                    ForEach(CLSSmokeVADSensitivity.allCases) { sensitivity in
                        Text(sensitivity.displayName).tag(sensitivity)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 240)
                .disabled(isStarting || isListening || selectedVADMode == .disabled)
            }

            Text(selectedVADAvailability.message)
                .font(.caption)
                .foregroundStyle(isForcedVADUnavailable ? .orange : .secondary)
                .lineLimit(2)
        }
    }

    private func startListening(with selection: SpeechModelSelection) {
        let vadMode = selectedVADMode
        let vadSensitivity = selectedVADSensitivity
        let vadAvailability = vadAvailability(for: selection)
        guard vadMode != .enabled || vadAvailability.isAvailable else {
            statusTone = .error
            statusMessage = "Model VAD is not available for the selected provider."
            return
        }

        stopListening(updateStatus: false, unloadProvider: false)

        let sessionID = UUID()
        activeSessionID = sessionID
        loadedInfo = nil
        eventDescriptions.removeAll(keepingCapacity: true)
        transcriptSnapshot = LiveTranscriptDebugSnapshot()
        resetDiagnosticThrottleState()
        isStarting = true
        isListening = false
        statusTone = .secondary
        statusMessage = "Preparing selected provider..."

        transcriptionTask = Task {
            await runLiveTranscriptionSession(
                id: sessionID,
                selection: selection,
                vadMode: vadMode,
                vadSensitivity: vadSensitivity,
                vadAvailability: vadAvailability
            )
        }
    }

    private func stopListening(updateStatus: Bool = true, unloadProvider: Bool = true) {
        activeSessionID = nil
        let capture = captureSession
        captureSession = nil
        let task = transcriptionTask
        transcriptionTask = nil
        capture?.stop()
        task?.cancel()
        isStarting = false
        isListening = false

        if unloadProvider {
            loadedInfo = nil
            Task {
                await LocalSpeechEngine.shared.unload()
            }
        }

        if updateStatus {
            statusTone = .secondary
            statusMessage = "Stopped."
        }
    }

    private func runLiveTranscriptionSession(
        id: UUID,
        selection: SpeechModelSelection,
        vadMode: CLSSmokeVADMode,
        vadSensitivity: CLSSmokeVADSensitivity,
        vadAvailability: CLSSmokeVADAvailability
    ) async {
        do {
            guard await ensureMicrophoneAccess() else {
                finishSession(id: id, message: "Microphone access is required to listen.", tone: .error)
                return
            }

            guard activeSessionID == id else { return }
            switch selection {
            case .installed:
                statusMessage = "Loading Whisper model. First run can take a few seconds..."
            case .system:
                statusMessage = "Loading selected provider..."
            }

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
            appendEvent(.diagnostic(TranscriptionDiagnostic(
                source: "smoke.vad",
                message: "mode=\(vadMode.diagnosticValue) sensitivity=\(vadSensitivity.diagnosticValue) provider=\(loaded.backend.displayName) availability=\(vadAvailability.diagnosticValue)"
            )))

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
                        language: Locale.current.language.languageCode?.identifier,
                        voiceActivityDetection: VoiceActivityDetectionOptions(
                            mode: vadMode.runtimeMode,
                            sensitivity: vadSensitivity.runtimeSensitivity
                        )
                    ),
                    strategy: .balanced
                )
            )

            for try await event in stream {
                try Task.checkCancellation()
                guard activeSessionID == id else { return }
                appendEvent(event)
            }

            guard activeSessionID == id else { return }
            await LocalSpeechEngine.shared.unload()
            finishSession(id: id, message: "Listening completed.", tone: .secondary)
        } catch is CancellationError {
            finishSession(id: id, message: "Stopped.", tone: .secondary)
        } catch {
            guard activeSessionID == id else { return }
            await LocalSpeechEngine.shared.unload()
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

    private func vadAvailability(for selection: SpeechModelSelection) -> CLSSmokeVADAvailability {
        switch selection {
        case .installed(let id):
            guard let model = library.model(id: id) else {
                return CLSSmokeVADAvailability(
                    isAvailable: false,
                    message: "Whisper model VAD unavailable: selected model is not installed.",
                    diagnosticValue: "unavailable:missing-installed-model"
                )
            }
            guard let vadURL = model.vadWeightsURL(in: library.root) else {
                return CLSSmokeVADAvailability(
                    isAvailable: false,
                    message: "Whisper model VAD unavailable: selected model has no VAD asset.",
                    diagnosticValue: "unavailable:no-vad-asset"
                )
            }
            guard FileManager.default.fileExists(atPath: vadURL.path) else {
                return CLSSmokeVADAvailability(
                    isAvailable: false,
                    message: "Whisper model VAD unavailable: VAD asset file is missing.",
                    diagnosticValue: "unavailable:missing-vad-file"
                )
            }
            return CLSSmokeVADAvailability(
                isAvailable: true,
                message: "Whisper model VAD available.",
                diagnosticValue: "available:whisper-vad-asset"
            )
        case .system(.appleSpeech):
            guard let option = systemOptions.first(where: { $0.selection == .system(.appleSpeech) }) else {
                return CLSSmokeVADAvailability(
                    isAvailable: false,
                    message: "Apple Speech VAD availability is not available for the current locale.",
                    diagnosticValue: "unavailable:no-apple-option"
                )
            }
            guard option.availability.isAvailable else {
                return CLSSmokeVADAvailability(
                    isAvailable: false,
                    message: "Apple Speech VAD unavailable: \(option.availability.displayMessage)",
                    diagnosticValue: "unavailable:apple-\(option.availability.unavailableReason?.rawValue ?? "unknown")"
                )
            }
            return CLSSmokeVADAvailability(
                isAvailable: true,
                message: "Apple SpeechDetector available.",
                diagnosticValue: "available:apple-speechdetector"
            )
        }
    }

    private func appendEvent(_ event: TranscriptEvent) {
        if shouldLogEvent(event) {
            eventDescriptions.append(LiveTranscriptDebugView.describe(event))
            trimEventDescriptions()
        }

        if shouldApplyToTranscriptPanel(event) {
            transcriptSnapshot.apply(event)
        }
    }

    private func trimEventDescriptions() {
        let overflow = eventDescriptions.count - maximumDisplayedEvents
        if overflow > 0 {
            eventDescriptions.removeFirst(overflow)
        }
    }

    private func shouldLogEvent(_ event: TranscriptEvent) -> Bool {
        switch event {
        case .audioLevel(let level):
            return shouldLogAudioLevel(at: level.time)
        case .voiceActivity(let activity):
            return shouldLogVoiceActivity(activity)
        case .progress(let progress):
            return shouldLogProgress(processedDuration: progress.processedDuration)
        case .started, .diagnostic, .snapshot, .stats, .completed:
            return true
        }
    }

    private func shouldApplyToTranscriptPanel(_ event: TranscriptEvent) -> Bool {
        switch event {
        case .progress(let progress):
            return shouldUpdateTranscriptProgress(processedDuration: progress.processedDuration)
        case .snapshot, .stats, .completed:
            return true
        case .started, .audioLevel, .voiceActivity, .diagnostic:
            return false
        }
    }

    private func shouldLogAudioLevel(at time: TimeInterval) -> Bool {
        guard let lastTime = lastLoggedAudioLevelTime else {
            lastLoggedAudioLevelTime = time
            return true
        }

        guard time - lastTime >= diagnosticLogThrottleInterval else {
            return false
        }

        lastLoggedAudioLevelTime = time
        return true
    }

    private func shouldLogVoiceActivity(_ activity: VoiceActivityEvent) -> Bool {
        let stateChanged = lastLoggedVoiceActivityState != activity.state
        let elapsed = lastLoggedVoiceActivityTime.map { activity.endTime - $0 } ?? diagnosticLogThrottleInterval
        guard stateChanged || elapsed >= diagnosticLogThrottleInterval else {
            return false
        }

        lastLoggedVoiceActivityState = activity.state
        lastLoggedVoiceActivityTime = activity.endTime
        return true
    }

    private func shouldLogProgress(processedDuration: TimeInterval) -> Bool {
        guard let lastDuration = lastLoggedProgressDuration else {
            lastLoggedProgressDuration = processedDuration
            return true
        }

        guard processedDuration - lastDuration >= diagnosticLogThrottleInterval else {
            return false
        }

        lastLoggedProgressDuration = processedDuration
        return true
    }

    private func shouldUpdateTranscriptProgress(processedDuration: TimeInterval) -> Bool {
        guard let lastDuration = lastTranscriptProgressDuration else {
            lastTranscriptProgressDuration = processedDuration
            return true
        }

        guard processedDuration - lastDuration >= transcriptMetricThrottleInterval else {
            return false
        }

        lastTranscriptProgressDuration = processedDuration
        return true
    }

    private func resetDiagnosticThrottleState() {
        lastLoggedAudioLevelTime = nil
        lastLoggedVoiceActivityTime = nil
        lastLoggedVoiceActivityState = nil
        lastLoggedProgressDuration = nil
        lastTranscriptProgressDuration = nil
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

private struct CLSSmokeVADAvailability: Hashable {
    var isAvailable: Bool
    var message: String
    var diagnosticValue: String
}

private enum CLSSmokeVADMode: String, CaseIterable, Identifiable {
    case disabled
    case enabled
    case automatic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .disabled:
            return "Disabled"
        case .enabled:
            return "Enabled"
        case .automatic:
            return "Automatic"
        }
    }

    var runtimeMode: VoiceActivityDetectionMode {
        switch self {
        case .disabled:
            return .disabled
        case .enabled:
            return .enabled
        case .automatic:
            return .automatic
        }
    }

    var diagnosticValue: String {
        rawValue
    }
}

private enum CLSSmokeVADSensitivity: String, CaseIterable, Identifiable {
    case low
    case medium
    case high

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .low:
            return "Low"
        case .medium:
            return "Medium"
        case .high:
            return "High"
        }
    }

    var runtimeSensitivity: VoiceActivityDetectionSensitivity {
        switch self {
        case .low:
            return .low
        case .medium:
            return .medium
        case .high:
            return .high
        }
    }

    var diagnosticValue: String {
        rawValue
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
