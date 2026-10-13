import AppKit

/// What each status-item menu row does — the AppKit counterpart of `MenuBarView.menuItem(for:)`'s
/// button actions, kept behaviorally identical.
@MainActor
enum MenuBarMenuActions {
    static func perform(_ item: MenuBarMenuItem) {
        switch item {
        case .settings, .openMainWindow, .history, .errorLog:
            if let id = item.managedWindowTarget {
                ManagedAppWindowOpener.shared.open(id: id)
            }
        case .startMeetingRecording:
            // [M10] Create an ad-hoc meeting, start capture, and open the meetings-first `main`
            // window focused on it. The mutual-exclusion guard surfaces a busy message when a
            // capture is already active; the window still opens so the user sees state.
            Task {
                if let meeting = await MeetingsViewModel.shared.startMeetingRecordingFromMenu() {
                    MeetingsViewModel.shared.requestFocus(on: meeting)
                }
                ManagedAppWindowOpener.shared.open(id: AppWindowID.main)
            }
        case .toggleRecorder:
            AudioRecorderViewModel.shared.toggleRecording()
        case .toggleDictationHotkeysPause:
            ServiceContainer.shared.hotkeyService.dictationHotkeysPaused.toggle()
        case .transcribeFile:
            ManagedAppWindowOpener.shared.open(id: AppWindowID.settings)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                FileTranscriptionViewModel.shared.showFilePickerFromMenu = true
            }
        case .recoverLastRecording:
            DictationViewModel.shared.recoverLastRecording()
        case .recentTranscriptions:
            DictationViewModel.shared.triggerRecentTranscriptionsPalette()
        case .copyLastTranscription:
            DictationViewModel.shared.copyLastTranscriptionToClipboard()
        case .readBackLastTranscription:
            DictationViewModel.shared.readBackLastTranscription()
        case .checkForUpdates:
            UpdateChecker.shared?.checkForUpdates()
        }
    }
}

/// The tray menu's meeting entry, resolved when the menu is built (same precedence as the tray
/// title via `MeetingTrayIndicator.menuTarget`). Mirrors `MenuBarView.meetingIndicatorSection`.
@MainActor
enum MenuBarMeetingTarget {
    case recording(Meeting)
    case event(CalendarEventDTO, isOngoing: Bool)

    static func current(now: Date = Date()) -> MenuBarMeetingTarget? {
        let meetings = MeetingsViewModel.shared
        switch MeetingTrayIndicator.menuTarget(
            recordingTitle: meetings.isCapturing ? meetings.activeMeeting?.title : nil,
            events: meetings.upcomingEvents,
            now: now
        ) {
        case .recording:
            return meetings.activeMeeting.map(MenuBarMeetingTarget.recording)
        case let .event(event, isOngoing):
            return .event(event, isOngoing: isOngoing)
        case .none:
            return nil
        }
    }

    var menuInputs: MenuBarMenuInputs.Meeting {
        switch self {
        case .recording(let meeting):
            return MenuBarMenuInputs.Meeting(
                kind: .recording,
                title: meeting.title,
                hasConferenceLink: meeting.conferencingURL != nil,
                canOpenInChrome: launchableJoinURL != nil
            )
        case let .event(event, isOngoing):
            return MenuBarMenuInputs.Meeting(
                kind: isOngoing ? .ongoing : .upcoming,
                title: event.title,
                hasConferenceLink: event.conferencingURL != nil,
                canOpenInChrome: launchableJoinURL != nil
            )
        }
    }

    private var conferencingURL: String? {
        switch self {
        case .recording(let meeting): meeting.conferencingURL
        case .event(let event, _): event.conferencingURL
        }
    }

    private var calendarEventID: String? {
        switch self {
        case .recording(let meeting): meeting.calendarEventID
        case .event(let event, _): event.id
        }
    }

    private var accountSub: String? {
        calendarEventID.flatMap(GoogleCalendarID.accountSub(fromNamespacedID:))
    }

    private var launchableJoinURL: URL? {
        guard let conferencingURL, let url = URL(string: conferencingURL),
              MeetingJoinLauncher.isLaunchableJoinURL(url) else { return nil }
        return url
    }

    /// Open the meeting's document (creating it from the event if needed — `createMeeting(from:)`
    /// dedupes by `calendarEventID`) and join its call when it has a conference URL.
    func openAndJoin() {
        let meetings = MeetingsViewModel.shared
        let meeting: Meeting
        switch self {
        case .recording(let active): meeting = active
        case .event(let event, _): meeting = meetings.createMeeting(from: event)
        }
        meetings.requestFocus(on: meeting)
        ManagedAppWindowOpener.shared.open(id: AppWindowID.main)
        guard let conferencingURL, let url = URL(string: conferencingURL) else { return }
        MeetingJoinLauncher.open(url: url, accountSub: accountSub)
    }

    /// Join the call only — no document, no main window, no meeting row.
    func openInChrome() {
        guard let url = launchableJoinURL else { return }
        MeetingJoinLauncher.open(url: url, accountSub: accountSub)
    }
}
