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

    private let meetingService: MeetingService
    private let calendarService: CalendarService
    private var cancellables = Set<AnyCancellable>()
    private var pollingCancellable: AnyCancellable?

    init(meetingService: MeetingService, calendarService: CalendarService) {
        self.meetingService = meetingService
        self.calendarService = calendarService
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
                self?.upcomingEvents = events
            }
            .store(in: &cancellables)
        calendarService.$errorMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                self?.calendarErrorMessage = message
            }
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
