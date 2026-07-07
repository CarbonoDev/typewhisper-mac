import Foundation
import Combine

@MainActor
final class MeetingsViewModel: ObservableObject {
    nonisolated(unsafe) static var _shared: MeetingsViewModel?
    static var shared: MeetingsViewModel {
        guard let instance = _shared else {
            fatalError("MeetingsViewModel not initialized")
        }
        return instance
    }

    @Published private(set) var meetings: [Meeting] = []

    // Calendar (M2)
    @Published private(set) var calendarAuthorizationStatus: CalendarAuthorizationStatus = .notDetermined
    @Published private(set) var upcomingEvents: [CalendarEventDTO] = []
    @Published private(set) var calendarErrorMessage: String?

    // Capture (M3)
    @Published private(set) var activeMeeting: Meeting?
    @Published private(set) var isCapturing = false
    @Published private(set) var liveTranscript: String = ""
    @Published private(set) var captureElapsedSeconds: TimeInterval = 0
    @Published private(set) var isDegradedLiveMode = false
    @Published private(set) var captureErrorMessage: String?

    private let meetingService: MeetingService
    private let calendarService: CalendarService
    private let captureService: MeetingCaptureService
    private let startNotificationService: MeetingStartNotificationService
    private var cancellables = Set<AnyCancellable>()
    private var pollingCancellable: AnyCancellable?

    init(
        meetingService: MeetingService,
        calendarService: CalendarService,
        captureService: MeetingCaptureService,
        startNotificationService: MeetingStartNotificationService
    ) {
        self.meetingService = meetingService
        self.calendarService = calendarService
        self.captureService = captureService
        self.startNotificationService = startNotificationService
        self.meetings = meetingService.meetings
        self.calendarAuthorizationStatus = calendarService.authorizationStatus
        self.upcomingEvents = calendarService.upcomingEvents
        self.calendarErrorMessage = calendarService.errorMessage

        meetingService.$meetings
            .receive(on: DispatchQueue.main)
            .sink { [weak self] meetings in
                self?.meetings = meetings
            }
            .store(in: &cancellables)

        calendarService.$authorizationStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.calendarAuthorizationStatus = status
            }
            .store(in: &cancellables)
        calendarService.$upcomingEvents
            .receive(on: DispatchQueue.main)
            .sink { [weak self] events in
                guard let self else { return }
                self.upcomingEvents = events
                // Prompt (never silently record) when a scheduled meeting reaches its start (D10).
                self.startNotificationService.notifyStartingMeetings(events)
            }
            .store(in: &cancellables)
        calendarService.$errorMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                self?.calendarErrorMessage = message
            }
            .store(in: &cancellables)

        captureService.$activeMeeting
            .receive(on: DispatchQueue.main)
            .sink { [weak self] meeting in self?.activeMeeting = meeting }
            .store(in: &cancellables)
        captureService.$isCapturing
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.isCapturing = value }
            .store(in: &cancellables)
        captureService.$liveTranscript
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.liveTranscript = value }
            .store(in: &cancellables)
        captureService.$elapsedSeconds
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.captureElapsedSeconds = value }
            .store(in: &cancellables)
        captureService.$isDegradedLiveMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.isDegradedLiveMode = value }
            .store(in: &cancellables)
        captureService.$errorMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in self?.captureErrorMessage = value }
            .store(in: &cancellables)
    }

    var hasMeetings: Bool { !meetings.isEmpty }

    // MARK: - Calendar

    var isCalendarAuthorized: Bool { calendarAuthorizationStatus == .authorized }

    /// Prompt for calendar access; refreshes the upcoming list on success.
    func requestCalendarAccess() async {
        await calendarService.requestAccess()
        loadUpcoming()
    }

    /// Re-query upcoming/current events, excluding any that already back a stored meeting.
    func loadUpcoming(now: Date = Date()) {
        calendarService.refresh(
            now: now,
            existingCalendarEventIDs: existingCalendarEventIDs
        )
    }

    /// Whether an upcoming event is happening right now (for the "in progress" badge).
    func isCurrent(_ event: CalendarEventDTO, now: Date = Date()) -> Bool {
        CalendarService.isCurrent(event, now: now)
    }

    /// Create (or return the existing) `.scheduled` meeting for a calendar event, deduping by
    /// `calendarEventID`. Refreshes the upcoming list so the created event drops out of it.
    @discardableResult
    func createMeeting(from event: CalendarEventDTO) -> Meeting {
        // Read the authoritative synchronous source, not the Combine-mirrored `self.meetings`
        // (updated via `$meetings.receive(on: .main)`, an async hop even on main). Using the
        // stale copy would let a rapid double-click insert a duplicate and would leave the
        // just-created event in the upcoming list until the next poll.
        if let existing = meetingService.meetings.first(where: { $0.calendarEventID == event.id }) {
            return existing
        }
        let projection = CalendarService.meetingProjection(for: event)
        let meeting = meetingService.createMeeting(
            title: projection.title,
            source: .calendar,
            state: .scheduled,
            startDate: projection.startDate,
            endDate: projection.endDate,
            calendarEventID: projection.calendarEventID,
            seriesID: projection.seriesID,
            attendees: projection.attendees
        )
        loadUpcoming()
        return meeting
    }

    // MARK: - Capture (M3)

    var canStartCapture: Bool { !isCapturing }

    /// Create an ad-hoc meeting so capture never hard-depends on the calendar (plan §1).
    @discardableResult
    func createAdHocMeeting(title: String? = nil) -> Meeting {
        let resolved = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = (resolved?.isEmpty == false) ? resolved! : String(localized: "meetings.adHoc.defaultTitle")
        return meetingService.createMeeting(title: finalTitle, source: .adHoc, state: .scheduled, startDate: Date())
    }

    /// Start live capture for an existing meeting. Surfaces a localized error (e.g. the Recorder
    /// currently owns the capture stack) via `captureErrorMessage`.
    func startCapture(for meeting: Meeting) async {
        captureErrorMessage = nil
        do {
            try await captureService.start(meeting: meeting)
        } catch {
            captureErrorMessage = error.localizedDescription
        }
    }

    /// Create an ad-hoc meeting and immediately begin capturing it.
    func startAdHocCapture(title: String? = nil) async {
        let meeting = createAdHocMeeting(title: title)
        await startCapture(for: meeting)
    }

    /// Create (or reuse) the meeting backing a calendar event, then begin capture.
    func startCapture(from event: CalendarEventDTO) async {
        let meeting = createMeeting(from: event)
        await startCapture(for: meeting)
    }

    func stopCapture() async {
        await captureService.stop()
    }

    /// Add an in-meeting note to the active capture, timestamped with elapsed seconds.
    func addNote(_ text: String) {
        captureService.addNote(text)
    }

    /// Poll the calendar roughly once a minute while the meetings UI is visible (plan D10).
    func startCalendarPolling() {
        loadUpcoming()
        guard pollingCancellable == nil else { return }
        pollingCancellable = Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.loadUpcoming()
            }
    }

    func stopCalendarPolling() {
        pollingCancellable?.cancel()
        pollingCancellable = nil
    }

    /// Derived from the service's synchronously-updated `meetings` (not the Combine-mirrored
    /// `self.meetings`) so `loadUpcoming()` called right after `createMeeting` sees the newly
    /// created event and excludes it immediately.
    private var existingCalendarEventIDs: Set<String> {
        Set(meetingService.meetings.compactMap { $0.calendarEventID })
    }

    #if DEBUG
    func seedDemoMeeting() {
        meetingService.seedDemoMeeting()
    }
    #endif
}
