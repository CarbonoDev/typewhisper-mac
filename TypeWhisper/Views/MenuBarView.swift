import SwiftUI
import Combine

/// Lightweight state tracker for MenuBarView that only re-publishes
/// on menu-relevant changes, avoiding high-frequency audioLevel updates.
@MainActor
private final class MenuBarState: ObservableObject {
    @Published var statusText: String
    @Published var statusImage: String
    @Published var isModelReady: Bool
    @Published var hasRecentTranscriptions: Bool
    @Published var canCopyLastTranscription: Bool
    @Published var hasRecoverableRecording: Bool
    @Published var recorderState: AudioRecorderViewModel.RecorderState
    @Published var canToggleRecorder: Bool
    @Published var dictationHotkeysPaused: Bool
    @Published var recentTranscriptionsMenuShortcut: HotkeyService.MenuShortcutDescriptor?
    @Published var copyLastTranscriptionMenuShortcut: HotkeyService.MenuShortcutDescriptor?
    @Published var recorderToggleMenuShortcut: HotkeyService.MenuShortcutDescriptor?

    private var cancellables = Set<AnyCancellable>()

    init() {
        let dictation = DictationViewModel.shared
        let modelManager = ServiceContainer.shared.modelManagerService
        let audioRecordingService = ServiceContainer.shared.audioRecordingService
        let historyService = ServiceContainer.shared.historyService
        let recentTranscriptionStore = ServiceContainer.shared.recentTranscriptionStore
        let recorder = AudioRecorderViewModel.shared
        let hotkeyService = ServiceContainer.shared.hotkeyService

        // Set initial values immediately
        self.isModelReady = modelManager.isModelReady
        let hasRecentTranscriptions = recentTranscriptionStore.latestEntry(historyRecords: historyService.records) != nil
        self.hasRecentTranscriptions = hasRecentTranscriptions
        self.canCopyLastTranscription = hasRecentTranscriptions
        self.hasRecoverableRecording = audioRecordingService.latestRecoveryRecordingURL != nil
        self.recorderState = recorder.state
        self.canToggleRecorder = recorder.canToggleRecording
        self.dictationHotkeysPaused = hotkeyService.dictationHotkeysPaused
        self.recentTranscriptionsMenuShortcut = DictationSettingsHandler.loadMenuShortcutDescriptor(for: .recentTranscriptions)
        self.copyLastTranscriptionMenuShortcut = DictationSettingsHandler.loadMenuShortcutDescriptor(for: .copyLastTranscription)
        self.recorderToggleMenuShortcut = DictationSettingsHandler.loadMenuShortcutDescriptor(for: .recorderToggle)
        let modelStatus = Self.idleModelStatus(from: modelManager)
        self.statusText = modelStatus.text
        self.statusImage = modelStatus.image

        // React to dictation state changes (not audioLevel/duration/partialText)
        dictation.$state
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.update(state: state)
            }
            .store(in: &cancellables)

        // React to model changes via objectWillChange (covers model loading/selection)
        modelManager.objectWillChange
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let ready = modelManager.isModelReady
                self.isModelReady = ready
                // Only update text if not in recording/processing state
                if case .idle = dictation.state {
                    self.update(state: .idle)
                }
            }
            .store(in: &cancellables)

        recentTranscriptionStore.$sessionEntries
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshCopyAvailability()
            }
            .store(in: &cancellables)

        historyService.$records
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshCopyAvailability()
            }
            .store(in: &cancellables)

        audioRecordingService.$recoverableRecordingURL
            .receive(on: DispatchQueue.main)
            .sink { [weak self] url in
                self?.hasRecoverableRecording = url != nil
            }
            .store(in: &cancellables)

        Publishers.CombineLatest3(
            recorder.$state.removeDuplicates(),
            recorder.$micEnabled.removeDuplicates(),
            recorder.$systemAudioEnabled.removeDuplicates()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] state, micEnabled, systemAudioEnabled in
            self?.refreshRecorderToggle(
                state: state,
                micEnabled: micEnabled,
                systemAudioEnabled: systemAudioEnabled
            )
        }
        .store(in: &cancellables)

        dictation.$hotkeyLabelsVersion
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshMenuShortcuts()
            }
            .store(in: &cancellables)

        hotkeyService.$dictationHotkeysPaused
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] paused in
                self?.dictationHotkeysPaused = paused
                self?.update(state: dictation.state)
            }
            .store(in: &cancellables)
    }

    private func update(state: DictationViewModel.State) {
        let modelManager = ServiceContainer.shared.modelManagerService
        if dictationHotkeysPaused, state == .idle {
            statusText = String(localized: "Dictation hotkeys paused")
            statusImage = "pause.circle.fill"
            isModelReady = modelManager.isModelReady
            return
        }

        switch state {
        case .recording:
            statusText = String(localized: "Recording...")
            statusImage = "record.circle.fill"
        case .processing:
            statusText = String(localized: "Transcribing...")
            statusImage = "arrow.triangle.2.circlepath"
        default:
            let modelStatus = Self.idleModelStatus(from: modelManager)
            statusText = modelStatus.text
            statusImage = modelStatus.image
        }
        isModelReady = modelManager.isModelReady
    }

    private static func idleModelStatus(from modelManager: ModelManagerService) -> (text: String, image: String) {
        guard let name = modelManager.activeModelName else {
            return (String(localized: "No model loaded"), "exclamationmark.triangle.fill")
        }

        let label = activeModelLabel(engine: modelManager.activeEngineName, model: name)

        if modelManager.isModelReady {
            return (String(localized: "\(label) ready"), "checkmark.circle.fill")
        }

        return (String(localized: "\(label) selected"), "clock.fill")
    }

    /// Prefixes the model name with its provider/engine (e.g. "Groq • whisper-large-v3") so the
    /// menu bar shows which provider handles transcription. Skips the prefix when it would be
    /// redundant — e.g. local engines whose model name already contains the provider ("Parakeet").
    static func activeModelLabel(engine: String?, model: String) -> String {
        guard let engine, !engine.isEmpty, engine != model,
              !model.localizedCaseInsensitiveContains(engine) else {
            return model
        }
        return "\(engine) • \(model)"
    }

    private func refreshCopyAvailability() {
        let historyService = ServiceContainer.shared.historyService
        let recentTranscriptionStore = ServiceContainer.shared.recentTranscriptionStore
        let hasRecentTranscriptions = recentTranscriptionStore.latestEntry(historyRecords: historyService.records) != nil
        self.hasRecentTranscriptions = hasRecentTranscriptions
        canCopyLastTranscription = hasRecentTranscriptions
    }

    private func refreshRecorderToggle(
        state: AudioRecorderViewModel.RecorderState,
        micEnabled: Bool,
        systemAudioEnabled: Bool
    ) {
        recorderState = state
        canToggleRecorder = AudioRecorderViewModel.canToggleRecording(
            state: state,
            micEnabled: micEnabled,
            systemAudioEnabled: systemAudioEnabled
        )
    }

    private func refreshMenuShortcuts() {
        recentTranscriptionsMenuShortcut = DictationSettingsHandler.loadMenuShortcutDescriptor(for: .recentTranscriptions)
        copyLastTranscriptionMenuShortcut = DictationSettingsHandler.loadMenuShortcutDescriptor(for: .copyLastTranscription)
        recorderToggleMenuShortcut = DictationSettingsHandler.loadMenuShortcutDescriptor(for: .recorderToggle)
    }
}

enum MenuBarMenuItem: Hashable {
    case settings
    case openMainWindow
    case startMeetingRecording
    case history
    case errorLog
    case toggleRecorder
    case toggleDictationHotkeysPause
    case transcribeFile
    case recoverLastRecording
    case recentTranscriptions
    case copyLastTranscription
    case readBackLastTranscription
    case checkForUpdates

    /// The managed window this item opens, if any. Declared alongside the menu button arms so the
    /// window target is unit-testable (`MenuBarItemsTests`) and can never silently drift from the id
    /// constants in `AppWindowID`.
    var managedWindowTarget: String? {
        switch self {
        case .settings, .transcribeFile: return AppWindowID.settings
        case .openMainWindow: return AppWindowID.main
        case .history: return AppWindowID.history
        case .errorLog: return AppWindowID.errors
        default: return nil
        }
    }
}

/// The slim menu-bar item set (D8). The visible menu is exactly: status line · Start Meeting
/// Recording · Recorder toggle · Pause dictation · Recent transcriptions · Open TypeWhisper ·
/// Settings… · Quit (eight entries). History, Error Log, and Transcribe File are removed from the
/// menu and reachable only in Settings (Tools › History / File Transcription, Application › Advanced).
///
/// "Open TypeWhisper" always targets the meetings-first `AppWindowID.main` window; the legacy
/// `meetings` window scene was retired (D10), so there is no longer a rollout-flag alternative.
enum MenuBarLayout {
    /// Divider-separated groups of the slim menu, in display order.
    static func groups() -> [[MenuBarMenuItem]] {
        [
            [.startMeetingRecording],
            [.toggleRecorder, .toggleDictationHotkeysPause, .recentTranscriptions],
            [.openMainWindow, .settings]
        ]
    }

    /// Flat ordered item list (groups concatenated).
    static func items() -> [MenuBarMenuItem] {
        groups().flatMap { $0 }
    }
}

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @StateObject private var status = MenuBarState()
    // Owner requests 3 & 4: surface the recording / upcoming meeting as an actionable menu entry that
    // opens the main window focused on that meeting.
    @ObservedObject private var meetings = MeetingsViewModel.shared

    var body: some View {
        Group {
            let _ = { ManagedAppWindowOpener.shared.openWindow = openWindow }()

            Label(status.statusText, systemImage: status.statusImage)

            Divider()

            meetingIndicatorSection

            let groups = MenuBarLayout.groups()
            ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                if index > 0 {
                    Divider()
                }
                ForEach(group, id: \.self) { item in
                    menuItem(for: item)
                }
            }

            Divider()

            Button(String(localized: "Quit")) {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .onReceive(NotificationCenter.default.publisher(for: .openManagedAppWindow)) { notification in
            guard let id = notification.userInfo?["id"] as? String else { return }
            openWindow(id: id)
        }
    }

    private func openManagedWindow(_ id: String) {
        ManagedAppWindowOpener.shared.open(id: id)
    }

    /// Owner requests 3 & 4: a single entry above the main menu that reflects, in priority order, an
    /// in-progress meeting recording (opens + focuses that meeting) or the soonest upcoming calendar
    /// meeting within the lead window (opens the main window). Recording wins when both apply. Nothing
    /// is shown when neither applies, and the existing click-through-to-menu behavior is unchanged.
    @ViewBuilder
    private var meetingIndicatorSection: some View {
        if meetings.isCapturing, let active = meetings.activeMeeting {
            Button {
                meetings.requestFocus(on: active)
                openManagedWindow(AppWindowID.main)
            } label: {
                Label(
                    String(format: String(localized: "meetings.menu.recording"), active.title),
                    systemImage: "record.circle"
                )
            }
            Divider()
        } else if let event = MeetingTrayIndicator.nextUpcoming(events: meetings.upcomingEvents, now: Date()) {
            Button {
                openManagedWindow(AppWindowID.main)
            } label: {
                Label(
                    String(format: String(localized: "meetings.menu.upcoming"), event.title),
                    systemImage: "calendar"
                )
            }
            Divider()
        }
    }

    @ViewBuilder
    private func menuItem(for item: MenuBarMenuItem) -> some View {
        switch item {
        case .settings:
            Button {
                openManagedWindow(AppWindowID.settings)
            } label: {
                Label(String(localized: "Settings..."), systemImage: "gear")
            }
            .keyboardShortcut(",")

        case .startMeetingRecording:
            Button {
                // [M10] Create an ad-hoc meeting, start capture, and open the meetings-first `main`
                // window focused on it. The mutual-exclusion guard surfaces a busy message (never
                // crashes) when a capture is already active; the window still opens so the user sees
                // state.
                Task {
                    if let meeting = await MeetingsViewModel.shared.startMeetingRecordingFromMenu() {
                        MeetingsViewModel.shared.requestFocus(on: meeting)
                    }
                    openManagedWindow(AppWindowID.main)
                }
            } label: {
                Label(String(localized: "meetings.menu.startRecording"), systemImage: "record.circle")
            }

        case .openMainWindow:
            Button {
                openManagedWindow(AppWindowID.main)
            } label: {
                Label(String(localized: "menubar.openMainWindow"), systemImage: "macwindow")
            }

        case .history:
            Button {
                openManagedWindow(AppWindowID.history)
            } label: {
                Label(String(localized: "History"), systemImage: "clock.arrow.circlepath")
            }

        case .errorLog:
            Button {
                openManagedWindow(AppWindowID.errors)
            } label: {
                Label(String(localized: "Error Log"), systemImage: "exclamationmark.triangle")
            }

        case .toggleRecorder:
            Button {
                AudioRecorderViewModel.shared.toggleRecording()
            } label: {
                Label(recorderToggleTitle, systemImage: recorderToggleSystemImage)
            }
            .keyboardShortcut(keyboardShortcut(from: status.recorderToggleMenuShortcut))
            .disabled(!status.canToggleRecorder)

        case .toggleDictationHotkeysPause:
            Button {
                ServiceContainer.shared.hotkeyService.dictationHotkeysPaused.toggle()
            } label: {
                Label(dictationHotkeysPauseTitle, systemImage: dictationHotkeysPauseSystemImage)
            }

        case .transcribeFile:
            Button {
                openManagedWindow(AppWindowID.settings)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    FileTranscriptionViewModel.shared.showFilePickerFromMenu = true
                }
            } label: {
                Label(String(localized: "Transcribe File..."), systemImage: "doc.text")
            }
            .disabled(!status.isModelReady)

        case .recoverLastRecording:
            Button {
                DictationViewModel.shared.recoverLastRecording()
            } label: {
                Label(String(localized: "Recover Last Recording"), systemImage: "waveform")
            }

        case .recentTranscriptions:
            Button {
                DictationViewModel.shared.triggerRecentTranscriptionsPalette()
            } label: {
                Label(String(localized: "Recent Transcriptions"), systemImage: "clock.arrow.circlepath")
            }
            .keyboardShortcut(keyboardShortcut(from: status.recentTranscriptionsMenuShortcut))
            .disabled(!status.hasRecentTranscriptions)

        case .copyLastTranscription:
            Button {
                DictationViewModel.shared.copyLastTranscriptionToClipboard()
            } label: {
                Label(String(localized: "Copy Last Transcription"), systemImage: "doc.on.doc")
            }
            .keyboardShortcut(keyboardShortcut(from: status.copyLastTranscriptionMenuShortcut))
            .disabled(!status.canCopyLastTranscription)

        case .readBackLastTranscription:
            Button {
                DictationViewModel.shared.readBackLastTranscription()
            } label: {
                Label(String(localized: "Read Back Last Transcription"), systemImage: "speaker.wave.2")
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(DictationViewModel.shared.lastTranscribedText == nil)

        case .checkForUpdates:
            Button(String(localized: "Check for Updates...")) {
                UpdateChecker.shared?.checkForUpdates()
            }
            .disabled(UpdateChecker.shared?.canCheckForUpdates() != true)
        }
    }

    private var recorderToggleTitle: String {
        switch status.recorderState {
        case .idle:
            String(localized: "recorder.startRecording")
        case .recording:
            String(localized: "recorder.stopRecording")
        case .finalizing:
            String(localized: "recorder.transcribing")
        }
    }

    private var recorderToggleSystemImage: String {
        switch status.recorderState {
        case .idle:
            "record.circle"
        case .recording:
            "stop.fill"
        case .finalizing:
            "arrow.triangle.2.circlepath"
        }
    }

    private var dictationHotkeysPauseTitle: String {
        status.dictationHotkeysPaused
            ? String(localized: "Resume Dictation Hotkeys")
            : String(localized: "Pause Dictation Hotkeys")
    }

    private var dictationHotkeysPauseSystemImage: String {
        status.dictationHotkeysPaused ? "play.circle" : "pause.circle"
    }

    private func keyboardShortcut(
        from descriptor: HotkeyService.MenuShortcutDescriptor?
    ) -> KeyboardShortcut? {
        guard let descriptor else { return nil }
        return KeyboardShortcut(
            KeyEquivalent(descriptor.keyEquivalent),
            modifiers: eventModifiers(from: descriptor.modifiers)
        )
    }

    private func eventModifiers(from flags: NSEvent.ModifierFlags) -> EventModifiers {
        var modifiers: EventModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.function) { modifiers.insert(EventModifiers(rawValue: 1 << 23)) }
        return modifiers
    }
}
