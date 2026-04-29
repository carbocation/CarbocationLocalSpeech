import CarbocationLocalSpeech
import CarbocationLocalSpeechRuntime
import CarbocationLocalSpeechUI
import CarbocationWhisperRuntime
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

private enum CLSSmokeConsoleDiagnostics {
    static func log(_ message: String) {
        NSLog("%@", "[CLSSmokeDiagnostics] \(message)")
    }
}

private final class CLSSmokeLiveDiagnosticsState {
    var eventDescriptions: [String] = []
    var eventCount = 0
    var lastEventDisplayUpdateDate = Date.distantPast
    var transcriptSnapshot = LiveTranscriptDebugSnapshot()
    var lastTranscriptDisplayUpdateDate = Date.distantPast
    var lastSummaryLogDate = Date.distantPast
    var lastSegmentCount = 0
    var hasLoggedEventCap = false

    func reset() {
        eventDescriptions.removeAll(keepingCapacity: true)
        eventCount = 0
        lastEventDisplayUpdateDate = Date.distantPast
        transcriptSnapshot = LiveTranscriptDebugSnapshot()
        lastTranscriptDisplayUpdateDate = Date.distantPast
        lastSummaryLogDate = Date.distantPast
        lastSegmentCount = 0
        hasLoggedEventCap = false
    }
}

#if os(macOS)
private final class CLSSmokeHangSampler {
    private let monitorQueue = DispatchQueue(label: "CLSSmoke.HangSampler", qos: .utility)
    private var heartbeatTimer: DispatchSourceTimer?
    private var monitorTimer: DispatchSourceTimer?
    private var lastMainHeartbeat = CFAbsoluteTimeGetCurrent()
    private var isSampling = false
    private var lastSampleDate = Date.distantPast

    private let stallThreshold: TimeInterval = 5
    private let sampleCooldown: TimeInterval = 20
    private let sampleDurationSeconds = 5
    private let sampleIntervalMilliseconds = 20

    func start() {
        CLSSmokeConsoleDiagnostics.log(
            "hangSampler started pid=\(ProcessInfo.processInfo.processIdentifier) stallThresholdSeconds=\(stallThreshold)"
        )

        let heartbeatTimer = DispatchSource.makeTimerSource(queue: .main)
        heartbeatTimer.schedule(deadline: .now(), repeating: .milliseconds(500))
        heartbeatTimer.setEventHandler { [weak self] in
            let now = CFAbsoluteTimeGetCurrent()
            self?.monitorQueue.async {
                self?.lastMainHeartbeat = now
            }
        }
        heartbeatTimer.resume()
        self.heartbeatTimer = heartbeatTimer

        let monitorTimer = DispatchSource.makeTimerSource(queue: monitorQueue)
        monitorTimer.schedule(deadline: .now() + 2, repeating: .seconds(2))
        monitorTimer.setEventHandler { [weak self] in
            self?.checkForStall()
        }
        monitorTimer.resume()
        self.monitorTimer = monitorTimer
    }

    func stop() {
        heartbeatTimer?.cancel()
        monitorTimer?.cancel()
        heartbeatTimer = nil
        monitorTimer = nil
    }

    private func checkForStall() {
        let staleSeconds = CFAbsoluteTimeGetCurrent() - lastMainHeartbeat
        guard staleSeconds >= stallThreshold else { return }
        guard !isSampling else { return }
        guard Date().timeIntervalSince(lastSampleDate) >= sampleCooldown else { return }

        isSampling = true
        lastSampleDate = Date()
        writeSample(staleSeconds: staleSeconds)
        isSampling = false
    }

    private func writeSample(staleSeconds: TimeInterval) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let fileURL = URL(fileURLWithPath: "/tmp/CLSSmoke-hang-\(pid)-\(Int(Date().timeIntervalSince1970)).sample.txt")
        CLSSmokeConsoleDiagnostics.log(
            "hangSampler detectedMainThreadStall staleSeconds=\(Self.format(staleSeconds)) sampleFile=\(fileURL.path)"
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = [
            "\(pid)",
            "\(sampleDurationSeconds)",
            "\(sampleIntervalMilliseconds)",
            "-mayDie",
            "-fullPaths",
            "-file",
            fileURL.path
        ]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
            process.waitUntilExit()
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            CLSSmokeConsoleDiagnostics.log(
                "hangSampler sampleFinished status=\(process.terminationStatus) sampleFile=\(fileURL.path) output=\(output)"
            )
        } catch {
            CLSSmokeConsoleDiagnostics.log(
                "hangSampler sampleFailed sampleFile=\(fileURL.path) error=\(error)"
            )
        }
    }

    private static func format(_ value: TimeInterval) -> String {
        String(format: "%.1f", value)
    }
}
#endif

#if os(macOS)
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
    private let hangSampler = CLSSmokeHangSampler()

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMainMenu()
        hangSampler.start()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "CLSSmoke"
        window.contentMinSize = NSSize(width: 1240, height: 680)
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

    func applicationWillTerminate(_ notification: Notification) {
        hangSampler.stop()
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
#else
@main
private struct CLSSmokeApp: App {
    var body: some Scene {
        WindowGroup {
            CLSSmokeRootView()
        }
    }
}
#endif

private enum CLSSmokePlatformColor {
    static var windowBackground: Color {
#if os(macOS)
        Color(nsColor: .windowBackgroundColor)
#elseif canImport(UIKit)
        Color(uiColor: .systemBackground)
#else
        Color.clear
#endif
    }

    static var controlBackground: Color {
#if os(macOS)
        Color(nsColor: .controlBackgroundColor)
#elseif canImport(UIKit)
        Color(uiColor: .secondarySystemBackground)
#else
        Color.clear
#endif
    }

    static var textBackground: Color {
#if os(macOS)
        Color(nsColor: .textBackgroundColor)
#elseif canImport(UIKit)
        Color(uiColor: .secondarySystemBackground)
#else
        Color.clear
#endif
    }
}

private struct CLSSmokePlatformCheckboxToggleStyle: ViewModifier {
    func body(content: Content) -> some View {
#if os(macOS)
        content.toggleStyle(.checkbox)
#else
        content
#endif
    }
}

@MainActor
private struct CLSSmokeRootView: View {
    @AppStorage("CLSSmoke.selectedSpeechModelSelection") private var selectionStorageValue = SpeechSystemModelID.appleSpeech.rawValue
    @AppStorage("CLSSmoke.vadMode") private var vadModeStorageValue = CLSSmokeVADMode.automatic.rawValue
    @AppStorage("CLSSmoke.vadSensitivity") private var vadSensitivityStorageValue = CLSSmokeVADSensitivity.medium.rawValue
    @AppStorage("CLSSmoke.liveInput") private var liveInputStorageValue = CLSSmokeLiveInput.microphone.rawValue
    @AppStorage("CLSSmoke.recordLiveAudio") private var recordLiveAudio = false
    @AppStorage("CLSSmoke.werReferenceText") private var werReferenceText = ""
    @State private var systemOptions: [SpeechSystemModelOption] = []
    @State private var visibleEventDescriptions: [String] = []
    @State private var visibleEventDescriptionTotalCount = 0
    @State private var visibleTranscriptSnapshot = LiveTranscriptDebugSnapshot()
    @State private var microphoneStatus = MicrophonePermissionHelper.authorizationStatus()
    @State private var loadedInfo: LocalSpeechLoadedModelInfo?
    @State private var statusMessage = "Select a provider, then start listening."
    @State private var statusTone = CLSSmokeStatusTone.secondary
    @State private var isStarting = false
    @State private var isListening = false
    @State private var captureSession: (any AudioCapturing)?
    @State private var transcriptionTask: Task<Void, Never>?
    @State private var activeSessionID: UUID?
    @State private var activeRecordingURL: URL?
    @State private var lastLoggedAudioLevelTime: TimeInterval?
    @State private var lastLoggedVoiceActivityTime: TimeInterval?
    @State private var lastLoggedVoiceActivityState: VoiceActivityState?
    @State private var lastLoggedProgressDuration: TimeInterval?
    @State private var lastTranscriptProgressDuration: TimeInterval?
    @State private var selectedFileURL: URL?
    @State private var scopedFileAccessURL: URL?
    @State private var fileTranscript: Transcript?
    @State private var fileProcessingDuration: TimeInterval?
    @State private var fileStatusMessage = "Pick or drop an audio or movie file."
    @State private var fileStatusTone = CLSSmokeStatusTone.secondary
    @State private var isFileDropTargeted = false
    @State private var showAudioFileImporter = false
    @State private var isFileTranscribing = false
    @State private var fileTranscriptionTask: Task<Void, Never>?
    @State private var activeFileTranscriptionID: UUID?
    @State private var werHypotheses: [CLSSmokeWERApproach: String] = [:]
    @State private var werReports: [CLSSmokeWERApproach: CLSSmokeWERReport] = [:]
    @State private var werReferenceWordCount = 0
    @State private var currentTranscriptWERReport: CLSSmokeWERReport?
    @State private var lastCurrentTranscriptWERUpdateDate = Date.distantPast
    @State private var liveDiagnostics = CLSSmokeLiveDiagnosticsState()

    private let maximumRetainedEvents = 1_000
    private let retainedEventTrimBatchSize = 100
    private let visibleEventLineLimit = 50
    private let eventDisplayUpdateInterval: TimeInterval = 0.25
    private let transcriptDisplayUpdateInterval: TimeInterval = 0.25
    private let currentTranscriptWERUpdateInterval: TimeInterval = 1.0
    private let diagnosticLogThrottleInterval: TimeInterval = 1.0
    private let transcriptMetricThrottleInterval: TimeInterval = 1.0
    private static let supportedAudioFileExtensions: Set<String> = [
        "aac", "aif", "aiff", "caf", "flac", "m4a", "m4b", "m4p",
        "m4v", "mov", "mp3", "mp4", "wav", "wave"
    ]
    private static let supportedAudioFileTypes: [UTType] = {
        let base: [UTType] = [.audio, .movie]
        let dynamic = supportedAudioFileExtensions.compactMap { UTType(filenameExtension: $0) }
        return base + dynamic
    }()

    private let library = SpeechModelLibrary(
        root: SpeechModelStorage.modelsDirectory(appSupportFolderName: "CLSSmoke")
    )

    var body: some View {
        rootContent
            .task {
                refreshWERState()
                systemOptions = await LocalSpeechEngine.systemModelOptions(locale: .current)
            }
            .onDisappear {
                cancelFileTranscription(updateStatus: false)
                stopListening()
                releaseSelectedFileSecurityScope()
            }
            .onChange(of: werReferenceText) {
                refreshWERState()
            }
            .fileImporter(
                isPresented: $showAudioFileImporter,
                allowedContentTypes: Self.supportedAudioFileTypes
            ) { result in
                handleFileImportResult(result)
            }
    }

    @ViewBuilder
    private var rootContent: some View {
#if os(macOS)
        HStack(spacing: 0) {
            speechProvidersColumn
                .frame(width: 430)

            Divider()

            diagnosticsColumn
        }
        .frame(minWidth: 1240, minHeight: 680)
#else
        TabView {
            speechProvidersColumn
                .tabItem {
                    Label("Models", systemImage: "shippingbox")
                }

            diagnosticsColumn
                .tabItem {
                    Label("Diagnostics", systemImage: "waveform.path.ecg")
                }
        }
#endif
    }

    private var speechProvidersColumn: some View {
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
                showsConfirmationFooter: false,
                systemOptions: systemOptions,
                onSelectionConfirmed: { selection in
                    startListening(with: selection)
                },
                onDeleteModel: { model in
                    try? library.delete(id: model.id)
                }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var diagnosticsColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Diagnostics")
                .font(.title2.weight(.semibold))
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            Divider()
            diagnosticsContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        isStarting || isFileTranscribing || isForcedVADUnavailable || isSelectedLiveInputUnavailable
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

    private var selectedLiveInput: CLSSmokeLiveInput {
        let input = CLSSmokeLiveInput(rawValue: liveInputStorageValue) ?? .microphone
#if os(macOS)
        return input
#else
        return input == .systemAudio ? .microphone : input
#endif
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

    private var liveInputBinding: Binding<CLSSmokeLiveInput> {
        Binding(
            get: { selectedLiveInput },
            set: { liveInputStorageValue = $0.rawValue }
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

    private var isSelectedLiveInputUnavailable: Bool {
        selectedLiveInput == .systemAudio && !systemAudioInputIsAvailable
    }

    private var systemAudioInputIsAvailable: Bool {
#if os(macOS)
        if #available(macOS 15.0, *) {
            return true
        }
#endif
        return false
    }

    private var werReferenceSummaryText: String {
        guard werReferenceWordCount > 0 else { return "Reference: none" }
        if werReferenceWordCount > CLSSmokeWERCalculator.maximumComparedWords {
            return "Reference: \(CLSSmokeWERCalculator.maximumComparedWords)+ words"
        }
        return "Reference: \(werReferenceWordCount) words"
    }

    @ViewBuilder
    private var diagnosticsContent: some View {
#if os(macOS)
        HStack(spacing: 0) {
            diagnosticsControlsColumn

            Divider()

            liveTranscriptDebugPane
                .frame(minWidth: 430, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
#else
        VStack(spacing: 0) {
            diagnosticsControlsColumn
            Divider()
            liveTranscriptDebugPane
                .frame(height: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
#endif
    }

    private var liveTranscriptDebugPane: some View {
        LiveTranscriptDebugView(
            eventDescriptions: visibleEventDescriptions,
            snapshot: visibleTranscriptSnapshot,
            totalEventDescriptionCount: visibleEventDescriptionTotalCount,
            copyAllEventDescriptions: {
                copyEventDescriptions(liveDiagnostics.eventDescriptions)
            },
            copyTranscript: {
                copyTranscript(liveDiagnostics.transcriptSnapshot)
            }
        )
    }

    private var diagnosticsControlsColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                sessionStatus
                Divider()
                fileTranscriptionPanel
                Divider()
                werPanel
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(CLSSmokePlatformColor.windowBackground)
#if os(macOS)
        .frame(minWidth: 360, idealWidth: 420, maxWidth: 500, maxHeight: .infinity)
#else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
#endif
    }

    private var sessionStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Label(statusMessage, systemImage: statusTone.systemImageName)
                    .foregroundStyle(statusTone.color)
                    .lineLimit(3)

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
            }

            HStack(spacing: 10) {
                Button {
                    if let selectedSelection {
                        startListening(with: selectedSelection)
                    }
                } label: {
                    Label(confirmTitle, systemImage: isListening ? "arrow.clockwise" : "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedSelection == nil || isConfirmDisabled)

                Button {
                    stopListening()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .disabled(!isStarting && !isListening)

                Spacer()
            }

            liveInputSettings

            liveRecordingStatus

            vadSettings

            if selectedLiveInput == .microphone {
                MicrophonePermissionStatusView(status: microphoneStatus)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var liveInputSettings: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("Input")
                    .font(.caption.weight(.semibold))
                    .frame(width: 80, alignment: .leading)

                Picker("Input", selection: liveInputBinding) {
                    ForEach(CLSSmokeLiveInput.allCases) { input in
                        Text(input.displayName)
                            .tag(input)
                            .disabled(input == .systemAudio && !systemAudioInputIsAvailable)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
                .disabled(isStarting || isListening || isFileTranscribing)
            }

            if isSelectedLiveInputUnavailable {
                Text("System audio input requires macOS 15 or newer.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }

            HStack(spacing: 10) {
                Text("Recording")
                    .font(.caption.weight(.semibold))
                    .frame(width: 80, alignment: .leading)

                Toggle("Record live audio", isOn: $recordLiveAudio)
                    .modifier(CLSSmokePlatformCheckboxToggleStyle())
                    .disabled(isStarting || isListening || isFileTranscribing)

                Spacer(minLength: 8)

                Button {
                    openLiveRecordingsFolder()
                } label: {
                    Label("Open Folder", systemImage: "folder")
                }
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var liveRecordingStatus: some View {
        if let activeRecordingURL {
            Label(activeRecordingURL.path, systemImage: "record.circle")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
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
                .disabled(isStarting || isListening || isFileTranscribing)
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
                .disabled(isStarting || isListening || isFileTranscribing || selectedVADMode == .disabled)
            }

            Text(selectedVADAvailability.message)
                .font(.caption)
                .foregroundStyle(isForcedVADUnavailable ? .orange : .secondary)
                .lineLimit(2)
        }
    }

    private var fileTranscriptionPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Label("File Transcription", systemImage: "doc.text.magnifyingglass")
                    .font(.headline)

                if isFileTranscribing {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()

                Button {
                    chooseAudioFile()
                } label: {
                    Label("Pick File", systemImage: "folder")
                }
                .disabled(isFileTranscribing || isStarting)

                if isFileTranscribing {
                    Button {
                        cancelFileTranscription()
                    } label: {
                        Label("Cancel", systemImage: "xmark.circle")
                    }
                } else {
                    Button {
                        startFileTranscription()
                    } label: {
                        Label("Transcribe", systemImage: "text.quote")
                    }
                    .disabled(selectedFileURL == nil || isStarting)
                }
            }

            fileDropTarget

            Label(fileStatusMessage, systemImage: fileStatusTone.systemImageName)
                .font(.callout)
                .foregroundStyle(fileStatusTone.color)
                .lineLimit(2)

            if let fileTranscript {
                fileTranscriptResult(fileTranscript)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(CLSSmokePlatformColor.windowBackground)
    }

    private var werPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("WER Reference", systemImage: "chart.bar.doc.horizontal")
                    .font(.headline)

                Spacer()

                if !werReports.isEmpty {
                    Button {
                        werHypotheses.removeAll(keepingCapacity: true)
                        werReports.removeAll(keepingCapacity: true)
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                    .controlSize(.small)
                }
            }

            TextEditor(text: $werReferenceText)
                .font(.system(.caption, design: .monospaced))
                .frame(height: 74)
                .scrollContentBackground(.hidden)
                .background(CLSSmokePlatformColor.textBackground)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            HStack(spacing: 12) {
                Text(werReferenceSummaryText)
                    .font(.caption.monospaced())
                    .foregroundStyle(werReferenceWordCount > 0 ? Color.secondary : Color.orange)

                if let currentTranscriptWERReport {
                    Text("Current \(currentTranscriptWERReport.summaryText)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if !werReports.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(CLSSmokeWERApproach.allCases) { approach in
                        if let report = werReports[approach] {
                            HStack {
                                Text(approach.displayName)
                                    .font(.caption.weight(.semibold))
                                    .frame(width: 92, alignment: .leading)
                                Text(report.summaryText)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                        }
                    }
                }
            } else if werReferenceWordCount > 0 && currentTranscriptWERReport == nil {
                Text("Waiting for visible or completed transcript text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if werReferenceWordCount == 0 {
                Text("Paste original text to compare the current transcript and completed runs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(CLSSmokePlatformColor.windowBackground)
    }

    private var fileDropTarget: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .font(.title3)
                    .foregroundStyle(isFileDropTargeted ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedFileURL?.lastPathComponent ?? "No file selected")
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text("MP3, WAV, M4A, MP4, MOV, CAF, AIFF, FLAC")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
        .background(isFileDropTargeted ? Color.accentColor.opacity(0.12) : CLSSmokePlatformColor.controlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    isFileDropTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: 1, dash: [6, 4])
                )
        }
        .contentShape(Rectangle())
        .onTapGesture {
            chooseAudioFile()
        }
        .onDrop(
            of: [UTType.fileURL.identifier],
            isTargeted: $isFileDropTargeted,
            perform: handleFileDrop
        )
    }

    private func fileTranscriptResult(_ transcript: Transcript) -> some View {
        let transcriptText = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                fileMetric("Segments", "\(transcript.segments.count)")
                if let duration = transcript.duration {
                    fileMetric("Audio", Self.formatDuration(duration))
                }
                if let processingDuration = fileProcessingDuration {
                    fileMetric("Elapsed", Self.formatDuration(processingDuration))
                    if let audioDuration = transcript.duration, audioDuration > 0 {
                        fileMetric("RTF", String(format: "%.2f", processingDuration / audioDuration))
                    }
                }
                Spacer()
            }

            ScrollView {
                Text(transcriptText.isEmpty ? "No transcript text returned." : transcript.text)
                    .font(.system(size: 15))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(transcriptText.isEmpty ? Color.secondary : Color.primary)
                    .padding(10)
            }
            .frame(minHeight: 72, maxHeight: 130)
            .background(CLSSmokePlatformColor.textBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func fileMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospaced())
                .lineLimit(1)
        }
    }

    private func startListening(with selection: SpeechModelSelection) {
        let vadMode = selectedVADMode
        let vadSensitivity = selectedVADSensitivity
        let vadAvailability = vadAvailability(for: selection)
        let liveInput = selectedLiveInput
        guard liveInput != .systemAudio || systemAudioInputIsAvailable else {
            statusTone = .error
            statusMessage = "System audio input requires macOS 15 or newer."
            return
        }
        guard whisperRuntimeIsAvailableIfNeeded(for: selection) else {
            statusTone = .error
            statusMessage = WhisperRuntimeSmoke.linkStatus().displayDescription
            return
        }
        guard vadMode != .enabled || vadAvailability.isAvailable else {
            statusTone = .error
            statusMessage = "Model VAD is not available for the selected provider."
            return
        }

        cancelFileTranscription(updateStatus: false)
        stopListening(updateStatus: false, unloadProvider: false)

        let sessionID = UUID()
        activeSessionID = sessionID
        activeRecordingURL = nil
        loadedInfo = nil
        resetTranscriptDiagnostics()
        isStarting = true
        isListening = false
        statusTone = .secondary
        statusMessage = "Preparing selected provider..."

        transcriptionTask = Task {
            await runLiveTranscriptionSession(
                id: sessionID,
                selection: selection,
                liveInput: liveInput,
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
        activeRecordingURL = nil

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
        liveInput: CLSSmokeLiveInput,
        vadMode: CLSSmokeVADMode,
        vadSensitivity: CLSSmokeVADSensitivity,
        vadAvailability: CLSSmokeVADAvailability
    ) async {
        var recordingContext: CLSSmokeLiveRecordingContext?
        do {
            if liveInput == .microphone {
                guard await ensureMicrophoneAccess() else {
                    finishSession(id: id, message: "Microphone access is required to listen.", tone: .error)
                    return
                }
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
            appendEvent(.diagnostic(TranscriptionDiagnostic(
                source: "smoke.input",
                message: "input=\(liveInput.diagnosticValue)"
            )))

            let capture = try makeCaptureSession(for: liveInput)
            captureSession = capture
            isStarting = false
            isListening = true
            statusTone = .listening
            statusMessage = "Listening to \(liveInput.statusDisplayName) with \(loaded.displayName)."

            let audio = capture.start(configuration: AudioCaptureConfiguration(
                preferredSampleRate: 16_000,
                preferredChannelCount: 1,
                frameDuration: 0.1
            ))
            if recordLiveAudio {
                let context = try makeLiveRecordingContext(for: liveInput)
                recordingContext = context
                activeRecordingURL = context.fileURL
                logLiveRecordingStarted(context)
            }
            let transcriptionAudio = recordingContext.map {
                AudioChunkStreams.recording(audio, recorder: $0.recorder)
            } ?? audio
            let stream = LocalSpeechEngine.shared.stream(
                audio: transcriptionAudio,
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
                if case .completed(let transcript) = event {
                    recordWER(
                        approach: liveWERApproach(for: vadMode),
                        hypothesisText: transcript.text
                    )
                }
            }

            await finishLiveRecording(recordingContext)
            guard activeSessionID == id else { return }
            await LocalSpeechEngine.shared.unload()
            finishSession(id: id, message: "Listening completed.", tone: .secondary)
        } catch is CancellationError {
            await finishLiveRecording(recordingContext)
            finishSession(id: id, message: "Stopped.", tone: .secondary)
        } catch {
            if let recordingContext {
                logLiveRecordingFailure(error, context: recordingContext)
            }
            await finishLiveRecording(recordingContext)
            guard activeSessionID == id else { return }
            await LocalSpeechEngine.shared.unload()
            finishSession(id: id, message: error.localizedDescription, tone: .error)
        }
    }

    private func makeCaptureSession(for input: CLSSmokeLiveInput) throws -> any AudioCapturing {
        switch input {
        case .microphone:
            return AVAudioEngineCaptureSession()
        case .systemAudio:
#if os(macOS)
            guard #available(macOS 15.0, *) else {
                throw CLSSmokeLiveInputError.systemAudioRequiresMacOS15
            }
            return SystemAudioCaptureSession(options: SystemAudioCaptureOptions(
                excludesCurrentProcessAudio: true
            ))
#else
            throw CLSSmokeLiveInputError.systemAudioRequiresMacOS15
#endif
        }
    }

    private func makeLiveRecordingContext(for input: CLSSmokeLiveInput) throws -> CLSSmokeLiveRecordingContext {
        let fileURL = Self.liveRecordingURL(for: input)
        return CLSSmokeLiveRecordingContext(
            fileURL: fileURL,
            recorder: AudioChunkFileRecorder(configuration: AudioRecordingConfiguration(
                fileURL: fileURL,
                format: .cafFloat32,
                overwriteExistingFile: false,
                createParentDirectories: true
            ))
        )
    }

    private func openLiveRecordingsFolder() {
        let directory = Self.liveRecordingsDirectory()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
#if os(macOS)
            guard NSWorkspace.shared.open(directory) else {
                statusMessage = "Could not open recordings folder."
                statusTone = .error
                return
            }
#else
            statusMessage = "Recordings are saved in the app container."
            statusTone = .secondary
#endif
        } catch {
            statusMessage = "Could not open recordings folder: \(error.localizedDescription)"
            statusTone = .error
        }
    }

    private func logLiveRecordingStarted(_ context: CLSSmokeLiveRecordingContext) {
        let message = "started file=\(context.fileURL.lastPathComponent) path=\(context.fileURL.path)"
        appendEvent(.diagnostic(TranscriptionDiagnostic(
            source: "smoke.recording",
            message: message
        )))
        CLSSmokeConsoleDiagnostics.log("recording \(message)")
    }

    private func logLiveRecordingFailure(_ error: Error, context: CLSSmokeLiveRecordingContext) {
        let message = "sessionError file=\(context.fileURL.lastPathComponent) error=\(error.localizedDescription)"
        appendEvent(.diagnostic(TranscriptionDiagnostic(
            source: "smoke.recording",
            message: message
        )))
        CLSSmokeConsoleDiagnostics.log("recording \(message) path=\(context.fileURL.path)")
    }

    private func finishLiveRecording(_ context: CLSSmokeLiveRecordingContext?) async {
        guard let context else { return }
        defer {
            if activeRecordingURL == context.fileURL {
                activeRecordingURL = nil
            }
        }

        do {
            if let summary = try await context.recorder.finish() {
                let message = "finished file=\(summary.fileURL.lastPathComponent) duration=\(Self.formatDuration(summary.duration)) frames=\(summary.frameCount) sampleRate=\(Int(summary.sampleRate)) channels=\(summary.channelCount)"
                appendEvent(.diagnostic(TranscriptionDiagnostic(
                    source: "smoke.recording",
                    message: message
                )))
                CLSSmokeConsoleDiagnostics.log("recording \(message) path=\(summary.fileURL.path)")
            } else {
                let message = "empty file=\(context.fileURL.lastPathComponent)"
                appendEvent(.diagnostic(TranscriptionDiagnostic(
                    source: "smoke.recording",
                    message: message
                )))
                CLSSmokeConsoleDiagnostics.log("recording \(message) path=\(context.fileURL.path)")
            }
        } catch {
            let message = "finishFailed file=\(context.fileURL.lastPathComponent) error=\(error.localizedDescription)"
            appendEvent(.diagnostic(TranscriptionDiagnostic(
                source: "smoke.recording",
                message: message
            )))
            CLSSmokeConsoleDiagnostics.log("recording \(message) path=\(context.fileURL.path)")
        }
    }

    private static func liveRecordingURL(for input: CLSSmokeLiveInput, date: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: date)
        let filename = "cls-live-\(timestamp)-\(input.recordingFilenameComponent).caf"
        return liveRecordingsDirectory().appendingPathComponent(filename)
    }

    private static func liveRecordingsDirectory() -> URL {
        return SpeechModelStorage.appSupportDirectory(appSupportFolderName: "CLSSmoke")
            .appendingPathComponent("Recordings", isDirectory: true)
    }

    private func chooseAudioFile() {
#if os(macOS)
        let panel = NSOpenPanel()
        panel.title = "Choose Audio or Movie File"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = Self.supportedAudioFileTypes

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        selectFile(url, startImmediately: true)
#else
        showAudioFileImporter = true
#endif
    }

    private func handleFileImportResult(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            retainSelectedFileSecurityScope(url)
            selectFile(url, startImmediately: true)
        case .failure(let error):
            fileStatusTone = .error
            fileStatusMessage = error.localizedDescription
        }
    }

    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }) else {
            return false
        }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
            let url = Self.fileURL(from: item)
            Task { @MainActor in
                if let error {
                    fileStatusTone = .error
                    fileStatusMessage = error.localizedDescription
                    return
                }
                guard let url else {
                    fileStatusTone = .error
                    fileStatusMessage = "Could not read the dropped file URL."
                    return
                }
                selectFile(url, startImmediately: true)
            }
        }
        return true
    }

    private func selectFile(_ url: URL, startImmediately: Bool) {
        guard Self.isSupportedAudioFile(url) else {
            selectedFileURL = url
            fileTranscript = nil
            fileProcessingDuration = nil
            fileStatusTone = .error
            fileStatusMessage = "Unsupported file extension: \(url.lastPathComponent)"
            return
        }

        selectedFileURL = url
        fileTranscript = nil
        fileProcessingDuration = nil
        fileStatusTone = .secondary
        fileStatusMessage = "Selected \(url.lastPathComponent)."

        if startImmediately {
            startFileTranscription()
        }
    }

    private func retainSelectedFileSecurityScope(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        releaseSelectedFileSecurityScope()
        scopedFileAccessURL = url
    }

    private func releaseSelectedFileSecurityScope() {
        scopedFileAccessURL?.stopAccessingSecurityScopedResource()
        scopedFileAccessURL = nil
    }

    private func startFileTranscription() {
        guard let selectedFileURL else {
            fileStatusTone = .error
            fileStatusMessage = "Choose an audio or movie file first."
            return
        }
        guard let selection = selectedSelection else {
            fileStatusTone = .error
            fileStatusMessage = "Choose a speech provider first."
            return
        }
        guard whisperRuntimeIsAvailableIfNeeded(for: selection) else {
            fileStatusTone = .error
            fileStatusMessage = WhisperRuntimeSmoke.linkStatus().displayDescription
            return
        }

        let vadMode = selectedVADMode
        let vadSensitivity = selectedVADSensitivity
        let vadAvailability = vadAvailability(for: selection)
        guard vadMode != .enabled || vadAvailability.isAvailable else {
            fileStatusTone = .error
            fileStatusMessage = "Model VAD is not available for the selected provider."
            return
        }

        cancelFileTranscription(updateStatus: false)
        stopListening(updateStatus: false, unloadProvider: false)
        statusTone = .secondary
        statusMessage = "Live listening stopped for file transcription."

        let sessionID = UUID()
        activeFileTranscriptionID = sessionID
        fileTranscript = nil
        fileProcessingDuration = nil
        resetTranscriptDiagnostics()
        isFileTranscribing = true
        fileStatusTone = .listening
        fileStatusMessage = "Preparing \(selectedFileURL.lastPathComponent)..."

        fileTranscriptionTask = Task {
            await runFileTranscriptionSession(
                id: sessionID,
                fileURL: selectedFileURL,
                selection: selection,
                vadMode: vadMode,
                vadSensitivity: vadSensitivity,
                vadAvailability: vadAvailability
            )
        }
    }

    private func whisperRuntimeIsAvailableIfNeeded(for selection: SpeechModelSelection) -> Bool {
        guard case .installed = selection else { return true }
        return WhisperRuntimeSmoke.linkStatus().isUsable
    }

    private func cancelFileTranscription(updateStatus: Bool = true) {
        activeFileTranscriptionID = nil
        fileTranscriptionTask?.cancel()
        fileTranscriptionTask = nil
        isFileTranscribing = false

        if updateStatus {
            fileStatusTone = .secondary
            fileStatusMessage = "File transcription cancelled."
        }
    }

    private func runFileTranscriptionSession(
        id: UUID,
        fileURL: URL,
        selection: SpeechModelSelection,
        vadMode: CLSSmokeVADMode,
        vadSensitivity: CLSSmokeVADSensitivity,
        vadAvailability: CLSSmokeVADAvailability
    ) async {
        do {
            guard activeFileTranscriptionID == id else { return }
            fileStatusMessage = "Loading selected provider..."

            let loaded = try await LocalSpeechEngine.shared.load(
                selection: selection,
                from: library,
                options: SpeechLoadOptions(
                    locale: .current,
                    installSystemAssetsIfNeeded: true
                )
            )

            guard activeFileTranscriptionID == id else { return }
            loadedInfo = loaded
            appendEvent(.started(loaded.backend))
            appendEvent(.diagnostic(TranscriptionDiagnostic(
                source: "smoke.file",
                message: "file=\(fileURL.lastPathComponent) provider=\(loaded.backend.displayName) vad=\(vadMode.diagnosticValue) sensitivity=\(vadSensitivity.diagnosticValue) availability=\(vadAvailability.diagnosticValue)"
            )))

            fileStatusMessage = "Transcribing \(fileURL.lastPathComponent) with \(loaded.displayName)..."
            let startedAt = Date()
            let transcript = try await LocalSpeechEngine.shared.transcribe(
                file: fileURL,
                options: TranscriptionOptions(
                    useCase: .general,
                    language: Locale.current.language.languageCode?.identifier,
                    voiceActivityDetection: VoiceActivityDetectionOptions(
                        mode: vadMode.runtimeMode,
                        sensitivity: vadSensitivity.runtimeSensitivity
                    )
                )
            )
            let processingDuration = Date().timeIntervalSince(startedAt)

            guard activeFileTranscriptionID == id else { return }
            fileTranscript = transcript
            fileProcessingDuration = processingDuration

            let audioDuration = transcript.duration ?? transcript.segments.last?.endTime ?? 0
            appendEvent(.progress(TranscriptionProgress(
                processedDuration: audioDuration,
                totalDuration: audioDuration > 0 ? audioDuration : nil,
                fractionComplete: 1
            )))
            appendEvent(.stats(TranscriptionStats(
                audioDuration: audioDuration,
                processingDuration: processingDuration,
                realTimeFactor: audioDuration > 0 ? processingDuration / audioDuration : nil,
                segmentCount: transcript.segments.count
            )))
            appendEvent(.completed(transcript))
            recordWER(approach: .fileTranscription, hypothesisText: transcript.text)

            finishFileTranscription(
                id: id,
                message: "Transcribed \(fileURL.lastPathComponent) with \(loaded.displayName).",
                tone: .secondary
            )
        } catch is CancellationError {
            finishFileTranscription(id: id, message: "File transcription cancelled.", tone: .secondary)
        } catch {
            guard activeFileTranscriptionID == id else { return }
            finishFileTranscription(id: id, message: error.localizedDescription, tone: .error)
        }
    }

    private func finishFileTranscription(id: UUID, message: String, tone: CLSSmokeStatusTone) {
        guard activeFileTranscriptionID == id else { return }

        fileTranscriptionTask = nil
        activeFileTranscriptionID = nil
        isFileTranscribing = false
        fileStatusMessage = message
        fileStatusTone = tone
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
        let didLogEvent = shouldLogEvent(event)
        let hadVisibleTranscriptText = visibleTranscriptSnapshot.hasTranscriptText
        var trimmedEventOverflow = 0
        if didLogEvent {
            liveDiagnostics.eventDescriptions.append(LiveTranscriptDebugView.describe(event))
            trimmedEventOverflow = trimEventDescriptions()
        }

        let didApplyToTranscriptPanel = shouldApplyToTranscriptPanel(event)
        if didApplyToTranscriptPanel {
            liveDiagnostics.transcriptSnapshot.apply(event)
        }

        logLiveDiagnosticsIfNeeded(
            event: event,
            didLogEvent: didLogEvent,
            didApplyToTranscriptPanel: didApplyToTranscriptPanel,
            trimmedEventOverflow: trimmedEventOverflow
        )

        if didLogEvent {
            refreshVisibleEventDescriptionsIfNeeded(force: visibleEventDescriptions.isEmpty)
        }
        if didApplyToTranscriptPanel {
            refreshVisibleTranscriptSnapshotIfNeeded(
                force: shouldForceTranscriptDisplayUpdate(
                    for: event,
                    hadVisibleTranscriptText: hadVisibleTranscriptText
                )
            )
        }
    }

    private func recordWER(approach: CLSSmokeWERApproach, hypothesisText: String) {
        werHypotheses[approach] = hypothesisText
        refreshWERReports()
    }

    private func liveWERApproach(for vadMode: CLSSmokeVADMode) -> CLSSmokeWERApproach {
        switch vadMode {
        case .enabled:
            return .liveVADEnabled
        case .disabled:
            return .liveVADDisabled
        case .automatic:
            return .liveVADAutomatic
        }
    }

    private func refreshWERReports() {
        guard werReferenceWordCount > 0 else {
            werReports.removeAll(keepingCapacity: true)
            return
        }

        var reports: [CLSSmokeWERApproach: CLSSmokeWERReport] = [:]
        for (approach, hypothesisText) in werHypotheses {
            if let report = CLSSmokeWERCalculator.report(
                referenceText: werReferenceText,
                hypothesisText: hypothesisText
            ) {
                reports[approach] = report
            }
        }
        werReports = reports
    }

    private func refreshWERState() {
        werReferenceWordCount = CLSSmokeWERCalculator.referenceWordCount(in: werReferenceText)
        refreshCurrentTranscriptWERReport(force: true)
        refreshWERReports()
    }

    private func refreshCurrentTranscriptWERReport(force: Bool = false) {
        guard werReferenceWordCount > 0 else {
            currentTranscriptWERReport = nil
            lastCurrentTranscriptWERUpdateDate = .distantPast
            return
        }

        let now = Date()
        guard force || now.timeIntervalSince(lastCurrentTranscriptWERUpdateDate) >= currentTranscriptWERUpdateInterval else {
            return
        }

        currentTranscriptWERReport = CLSSmokeWERCalculator.report(
            referenceText: werReferenceText,
            hypothesisText: visibleTranscriptSnapshot.transcriptText
        )
        lastCurrentTranscriptWERUpdateDate = now
    }

    @discardableResult
    private func trimEventDescriptions() -> Int {
        let overflow = liveDiagnostics.eventDescriptions.count - maximumRetainedEvents
        guard overflow > 0 else { return 0 }

        let removalCount = min(liveDiagnostics.eventDescriptions.count, overflow + retainedEventTrimBatchSize)
        liveDiagnostics.eventDescriptions.removeFirst(removalCount)
        return removalCount
    }

    private func refreshVisibleEventDescriptionsIfNeeded(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(liveDiagnostics.lastEventDisplayUpdateDate) >= eventDisplayUpdateInterval else {
            return
        }

        visibleEventDescriptions = Array(liveDiagnostics.eventDescriptions.suffix(visibleEventLineLimit))
        visibleEventDescriptionTotalCount = liveDiagnostics.eventDescriptions.count
        liveDiagnostics.lastEventDisplayUpdateDate = now
    }

    private func copyEventDescriptions(_ descriptions: [String]) {
        copyToPasteboard(descriptions.joined(separator: "\n"))
    }

    private func copyTranscript(_ snapshot: LiveTranscriptDebugSnapshot) {
        copyToPasteboard(snapshot.transcriptText)
    }

    private func copyToPasteboard(_ text: String) {
#if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
#elseif canImport(UIKit)
        UIPasteboard.general.string = text
#else
        _ = text
#endif
    }

    private func refreshVisibleTranscriptSnapshotIfNeeded(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(liveDiagnostics.lastTranscriptDisplayUpdateDate) >= transcriptDisplayUpdateInterval else {
            return
        }

        visibleTranscriptSnapshot = liveDiagnostics.transcriptSnapshot
        liveDiagnostics.lastTranscriptDisplayUpdateDate = now
        refreshCurrentTranscriptWERReport(force: force)
    }

    private func shouldForceTranscriptDisplayUpdate(
        for event: TranscriptEvent,
        hadVisibleTranscriptText: Bool
    ) -> Bool {
        if !hadVisibleTranscriptText, liveDiagnostics.transcriptSnapshot.hasTranscriptText {
            return true
        }

        switch event {
        case .completed, .stats:
            return true
        case .started, .audioLevel, .voiceActivity, .diagnostic, .snapshot, .progress:
            return false
        }
    }

    private func logLiveDiagnosticsIfNeeded(
        event: TranscriptEvent,
        didLogEvent: Bool,
        didApplyToTranscriptPanel: Bool,
        trimmedEventOverflow: Int
    ) {
        liveDiagnostics.eventCount += 1

        let now = Date()
        let segmentCountChanged = liveDiagnostics.transcriptSnapshot.segmentCount != liveDiagnostics.lastSegmentCount
        let reachedEventCap = liveDiagnostics.eventDescriptions.count >= maximumRetainedEvents
        let nearEventCap = liveDiagnostics.eventDescriptions.count >= maximumRetainedEvents - retainedEventTrimBatchSize
        let elapsed = now.timeIntervalSince(liveDiagnostics.lastSummaryLogDate)

        var reasons: [String] = []
        if liveDiagnostics.eventCount == 1 {
            reasons.append("first")
        }
        if segmentCountChanged {
            reasons.append("segment-change")
        }
        if reachedEventCap && !liveDiagnostics.hasLoggedEventCap {
            reasons.append("event-cap")
        }
        if nearEventCap && elapsed >= diagnosticLogThrottleInterval {
            reasons.append("near-cap")
        }

        guard !reasons.isEmpty else { return }

        let metrics = eventLogMetrics()
        CLSSmokeConsoleDiagnostics.log(
            "sourceEvent reason=\(reasons.joined(separator: ",")) " +
            "eventIndex=\(liveDiagnostics.eventCount) kind=\(Self.eventKind(event)) " +
            "logged=\(didLogEvent) applied=\(didApplyToTranscriptPanel) trimmed=\(trimmedEventOverflow) " +
            "eventLines=\(metrics.lineCount) eventTextUTF16=\(metrics.totalUTF16) " +
            "maxEventLineUTF16=\(metrics.maxLineUTF16) segments=\(liveDiagnostics.transcriptSnapshot.segmentCount) " +
            "stableUTF16=\(liveDiagnostics.transcriptSnapshot.stableText.utf16.count) " +
            "volatileUTF16=\(liveDiagnostics.transcriptSnapshot.volatileText.utf16.count)" +
            Self.eventMetricsSuffix(for: event)
        )

        liveDiagnostics.lastSummaryLogDate = now
        liveDiagnostics.lastSegmentCount = liveDiagnostics.transcriptSnapshot.segmentCount
        if reachedEventCap {
            liveDiagnostics.hasLoggedEventCap = true
        }
    }

    private func eventLogMetrics() -> (lineCount: Int, totalUTF16: Int, maxLineUTF16: Int) {
        var totalUTF16 = 0
        var maxLineUTF16 = 0

        for description in liveDiagnostics.eventDescriptions {
            let lineLength = description.utf16.count
            totalUTF16 += lineLength
            maxLineUTF16 = max(maxLineUTF16, lineLength)
        }

        if liveDiagnostics.eventDescriptions.count > 1 {
            totalUTF16 += liveDiagnostics.eventDescriptions.count - 1
        }

        return (liveDiagnostics.eventDescriptions.count, totalUTF16, maxLineUTF16)
    }

    private static func eventKind(_ event: TranscriptEvent) -> String {
        switch event {
        case .started:
            return "started"
        case .audioLevel:
            return "audioLevel"
        case .voiceActivity:
            return "voiceActivity"
        case .diagnostic:
            return "diagnostic"
        case .snapshot:
            return "snapshot"
        case .progress:
            return "progress"
        case .stats:
            return "stats"
        case .completed:
            return "completed"
        }
    }

    private static func eventMetricsSuffix(for event: TranscriptEvent) -> String {
        switch event {
        case .snapshot(let snapshot):
            return " sourceStableSegments=\(snapshot.stable.segments.count) sourceVolatileSegments=\(snapshot.volatile?.segments.count ?? 0) sourceVolatileUTF16=\(snapshot.volatile?.text.utf16.count ?? 0)"
        case .stats(let stats):
            return " statsSegments=\(stats.segmentCount) statsRTF=\(stats.realTimeFactor.map { String(format: "%.2f", $0) } ?? "n/a")"
        case .completed(let transcript):
            return " completedSegments=\(transcript.segments.count) completedTextUTF16=\(transcript.text.utf16.count)"
        case .diagnostic(let diagnostic):
            return " diagnosticSource=\(diagnostic.source) diagnosticMessageUTF16=\(diagnostic.message.utf16.count)"
        case .progress(let progress):
            return " processedDuration=\(formatDuration(progress.processedDuration))"
        case .audioLevel(let level):
            return " audioTime=\(formatDuration(level.time))"
        case .voiceActivity(let activity):
            return " vadState=\(activity.state.rawValue) vadEnd=\(formatDuration(activity.endTime))"
        case .started(let backend):
            return " backend=\(backend.displayName)"
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

    private func resetTranscriptDiagnostics() {
        visibleEventDescriptions.removeAll(keepingCapacity: true)
        visibleEventDescriptionTotalCount = 0
        visibleTranscriptSnapshot = LiveTranscriptDebugSnapshot()
        currentTranscriptWERReport = nil
        lastCurrentTranscriptWERUpdateDate = .distantPast
        liveDiagnostics.reset()
        resetDiagnosticThrottleState()
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

    private static func isSupportedAudioFile(_ url: URL) -> Bool {
        let pathExtension = url.pathExtension.lowercased()
        guard !pathExtension.isEmpty else {
            return false
        }
        return supportedAudioFileExtensions.contains(pathExtension)
    }

    nonisolated private static func fileURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL {
            return url
        }

        if let data = item as? Data,
           let string = String(data: data, encoding: .utf8) {
            return fileURL(fromString: string)
        }

        if let string = item as? String {
            return fileURL(fromString: string)
        }

        return nil
    }

    nonisolated private static func fileURL(fromString string: String) -> URL? {
        if let url = URL(string: string), url.isFileURL {
            return url
        }

        return URL(fileURLWithPath: string)
    }

    private static func formatDuration(_ duration: TimeInterval) -> String {
        guard duration.isFinite else {
            return "n/a"
        }

        if duration < 60 {
            return String(format: "%.2fs", duration)
        }

        let minutes = Int(duration / 60)
        let seconds = duration - Double(minutes * 60)
        return String(format: "%d:%04.1f", minutes, seconds)
    }
}

private struct CLSSmokeVADAvailability: Hashable {
    var isAvailable: Bool
    var message: String
    var diagnosticValue: String
}

private struct CLSSmokeLiveRecordingContext {
    var fileURL: URL
    var recorder: AudioChunkFileRecorder
}

private enum CLSSmokeLiveInput: String, CaseIterable, Identifiable {
    case microphone
    case systemAudio

    static var allCases: [CLSSmokeLiveInput] {
#if os(macOS)
        return [.microphone, .systemAudio]
#else
        return [.microphone]
#endif
    }

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .microphone:
            return "Microphone"
        case .systemAudio:
            return "System Audio"
        }
    }

    var statusDisplayName: String {
        switch self {
        case .microphone:
            return "the microphone"
        case .systemAudio:
            return "system audio"
        }
    }

    var diagnosticValue: String {
        rawValue
    }

    var recordingFilenameComponent: String {
        switch self {
        case .microphone:
            return "microphone"
        case .systemAudio:
            return "system-audio"
        }
    }
}

private enum CLSSmokeLiveInputError: Error, LocalizedError {
    case systemAudioRequiresMacOS15

    var errorDescription: String? {
        switch self {
        case .systemAudioRequiresMacOS15:
            return "System audio input requires macOS 15 or newer."
        }
    }
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
