import XCTest
@testable import TypeWhisper

@MainActor
final class CalendarServiceTests: XCTestCase {
    // MARK: - Fake provider (no live EKEventStore in CI)

    private final class FakeCalendarProvider: CalendarEventProviding {
        var authorizationStatus: CalendarAuthorizationStatus
        var requestResult: CalendarAuthorizationStatus
        var eventsToReturn: [CalendarEventDTO]
        private(set) var requestCount = 0
        private(set) var lastQueryWindow: (start: Date, end: Date)?

        init(
            authorizationStatus: CalendarAuthorizationStatus = .notDetermined,
            requestResult: CalendarAuthorizationStatus = .authorized,
            events: [CalendarEventDTO] = []
        ) {
            self.authorizationStatus = authorizationStatus
            self.requestResult = requestResult
            self.eventsToReturn = events
        }

        func requestAccess() async -> CalendarAuthorizationStatus {
            requestCount += 1
            authorizationStatus = requestResult
            return requestResult
        }

        func events(from start: Date, to end: Date) -> [CalendarEventDTO] {
            lastQueryWindow = (start, end)
            return eventsToReturn
        }

        var calendarsToReturn: [CalendarInfo] = []
        func calendars() -> [CalendarInfo] { calendarsToReturn }
    }

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let lookAhead: TimeInterval = 12 * 60 * 60

    private func event(
        _ id: String,
        title: String = "Event",
        startOffset: TimeInterval,
        endOffset: TimeInterval,
        isAllDay: Bool = false,
        seriesID: String? = nil,
        attendees: [Attendee] = []
    ) -> CalendarEventDTO {
        CalendarEventDTO(
            id: id,
            title: title,
            startDate: now.addingTimeInterval(startOffset),
            endDate: now.addingTimeInterval(endOffset),
            isAllDay: isAllDay,
            seriesID: seriesID,
            attendees: attendees
        )
    }

    // MARK: - Windowing (upcoming vs current)

    func testWindowingIncludesCurrentAndUpcomingSortedByStart() {
        let current = event("current", startOffset: -10 * 60, endOffset: 50 * 60)
        let upcoming = event("upcoming", startOffset: 2 * 60 * 60, endOffset: 3 * 60 * 60)
        let past = event("past", startOffset: -2 * 60 * 60, endOffset: -60 * 60)
        let tooFar = event("tooFar", startOffset: 13 * 60 * 60, endOffset: 14 * 60 * 60)

        let result = CalendarService.upcomingAndCurrent(
            from: [upcoming, past, current, tooFar],
            now: now,
            lookAhead: lookAhead,
            excludingEventIDs: []
        )

        XCTAssertEqual(result.map(\.id), ["current", "upcoming"])
    }

    func testWindowingExcludesAllDayEvents() {
        let allDay = event("allday", startOffset: 0, endOffset: 24 * 60 * 60, isAllDay: true)
        let normal = event("normal", startOffset: 60 * 60, endOffset: 2 * 60 * 60)

        let result = CalendarService.upcomingAndCurrent(
            from: [allDay, normal],
            now: now,
            lookAhead: lookAhead,
            excludingEventIDs: []
        )

        XCTAssertEqual(result.map(\.id), ["normal"])
    }

    func testWindowingDedupesByExcludedEventID() {
        let a = event("a", startOffset: 60 * 60, endOffset: 2 * 60 * 60)
        let b = event("b", startOffset: 90 * 60, endOffset: 3 * 60 * 60)

        let result = CalendarService.upcomingAndCurrent(
            from: [a, b],
            now: now,
            lookAhead: lookAhead,
            excludingEventIDs: ["a"]
        )

        XCTAssertEqual(result.map(\.id), ["b"])
    }

    func testIsCurrentDetectsInProgressEvents() {
        let running = event("r", startOffset: -5 * 60, endOffset: 25 * 60)
        let future = event("f", startOffset: 60 * 60, endOffset: 2 * 60 * 60)
        let ended = event("e", startOffset: -2 * 60 * 60, endOffset: -60 * 60)

        XCTAssertTrue(CalendarService.isCurrent(running, now: now))
        XCTAssertFalse(CalendarService.isCurrent(future, now: now))
        XCTAssertFalse(CalendarService.isCurrent(ended, now: now))
    }

    // MARK: - Projection (attendees, recurrence, title fallback)

    func testMeetingProjectionCarriesAttendeesSeriesAndDates() {
        let attendees = [
            Attendee(name: "Marco", email: "marco@example.com"),
            Attendee(name: "Alex", email: "alex@example.com")
        ]
        let dto = event(
            "evt-1",
            title: "Weekly Sync",
            startOffset: 60 * 60,
            endOffset: 2 * 60 * 60,
            seriesID: "series-A",
            attendees: attendees
        )

        let projection = CalendarService.meetingProjection(for: dto)

        XCTAssertEqual(projection.title, "Weekly Sync")
        XCTAssertEqual(projection.calendarEventID, "evt-1")
        XCTAssertEqual(projection.seriesID, "series-A")
        XCTAssertEqual(projection.attendees, attendees)
        XCTAssertEqual(projection.startDate, dto.startDate)
        XCTAssertEqual(projection.endDate, dto.endDate)
    }

    func testMeetingProjectionUsesLocalizedFallbackForEmptyTitle() {
        let dto = event("evt-blank", title: "   ", startOffset: 0, endOffset: 60 * 60)
        let projection = CalendarService.meetingProjection(for: dto)
        XCTAssertEqual(projection.title, String(localized: "meetings.calendar.untitledEvent"))
    }

    // MARK: - Recurring occurrences (occurrence-scoped ids)

    /// All occurrences of a recurring series share one `EKEvent.eventIdentifier`, so the provider
    /// composes an occurrence-scoped id (`"<eventIdentifier>#<startEpoch>"`). Two occurrences on
    /// different days must therefore carry distinct ids while sharing the series id — otherwise
    /// deduping one occurrence would remove the whole series from the upcoming list, and only one
    /// `Meeting` could ever exist per series.
    func testRecurringOccurrencesAreDistinctForDedupeWhileSharingSeries() {
        // Two occurrences of the same weekly series: identical eventIdentifier + series id,
        // different occurrence start dates → different composite ids.
        let base = "recurring-event-id"
        let series = "series-weekly"
        let thisWeekStart = now.addingTimeInterval(60 * 60)
        let nextWeekStart = now.addingTimeInterval(7 * 24 * 60 * 60 + 60 * 60)
        let thisWeek = CalendarEventDTO(
            id: "\(base)#\(thisWeekStart.timeIntervalSince1970)",
            title: "Weekly Sync",
            startDate: thisWeekStart,
            endDate: thisWeekStart.addingTimeInterval(60 * 60),
            seriesID: series
        )
        let nextWeek = CalendarEventDTO(
            id: "\(base)#\(nextWeekStart.timeIntervalSince1970)",
            title: "Weekly Sync",
            startDate: nextWeekStart,
            endDate: nextWeekStart.addingTimeInterval(60 * 60),
            seriesID: series
        )

        // Distinct ids, shared series id.
        XCTAssertNotEqual(thisWeek.id, nextWeek.id)
        XCTAssertEqual(thisWeek.seriesID, nextWeek.seriesID)

        // Both project to distinct calendar event ids (independent dedupe keys) with the same series.
        let p1 = CalendarService.meetingProjection(for: thisWeek)
        let p2 = CalendarService.meetingProjection(for: nextWeek)
        XCTAssertNotEqual(p1.calendarEventID, p2.calendarEventID)
        XCTAssertEqual(p1.seriesID, p2.seriesID)

        // Deduping this week's occurrence (already captured) must not exclude next week's.
        let result = CalendarService.upcomingAndCurrent(
            from: [thisWeek, nextWeek],
            now: now,
            lookAhead: 8 * 24 * 60 * 60,
            excludingEventIDs: [thisWeek.id]
        )
        XCTAssertEqual(result.map(\.id), [nextWeek.id])
    }

    // MARK: - Permission flow

    func testRequestAccessGrantedRefreshesAndClearsError() async {
        let upcoming = event("evt", startOffset: 60 * 60, endOffset: 2 * 60 * 60)
        let provider = FakeCalendarProvider(
            authorizationStatus: .notDetermined,
            requestResult: .authorized,
            events: [upcoming]
        )
        let service = CalendarService(provider: provider, lookAhead: lookAhead)

        XCTAssertNil(service.errorMessage)
        await service.requestAccess(now: now)

        XCTAssertEqual(service.authorizationStatus, .authorized)
        XCTAssertNil(service.errorMessage)
        XCTAssertEqual(provider.requestCount, 1)
        XCTAssertEqual(service.upcomingEvents.map(\.id), ["evt"])
    }

    func testRequestAccessDeniedSurfacesLocalizedMessage() async {
        let provider = FakeCalendarProvider(
            authorizationStatus: .notDetermined,
            requestResult: .denied
        )
        let service = CalendarService(provider: provider, lookAhead: lookAhead)

        await service.requestAccess()

        XCTAssertEqual(service.authorizationStatus, .denied)
        XCTAssertEqual(service.errorMessage, String(localized: "meetings.calendar.accessDenied"))
        XCTAssertTrue(service.upcomingEvents.isEmpty)
    }

    func testInitWithDeniedStatusSetsErrorMessage() {
        let provider = FakeCalendarProvider(authorizationStatus: .denied)
        let service = CalendarService(provider: provider, lookAhead: lookAhead)
        XCTAssertEqual(service.errorMessage, String(localized: "meetings.calendar.accessDenied"))
    }

    // MARK: - Refresh gating

    func testRefreshWhenAuthorizedPublishesFilteredEvents() {
        let current = event("current", startOffset: -10 * 60, endOffset: 50 * 60)
        // Ended 1h ago (started 2h ago) — within the 2h overrunning grace, so it now REMAINS in the
        // primary Upcoming section badged "ended" (M10) rather than vanishing at its scheduled end.
        let past = event("past", startOffset: -2 * 60 * 60, endOffset: -60 * 60)
        let provider = FakeCalendarProvider(authorizationStatus: .authorized, events: [current, past])
        let service = CalendarService(provider: provider, lookAhead: lookAhead)

        service.refresh(now: now, existingCalendarEventIDs: [])

        // Sorted by start ascending: the overrunning event (started -2h) then the current one (-10m).
        XCTAssertEqual(service.upcomingEvents.map(\.id), ["past", "current"])
        // Neither belongs in Earlier (one in progress, one still within grace).
        XCTAssertTrue(service.earlierEvents.isEmpty)
        XCTAssertNotNil(provider.lastQueryWindow)
    }

    func testRefreshWhenNotAuthorizedPublishesEmpty() {
        let current = event("current", startOffset: -10 * 60, endOffset: 50 * 60)
        let provider = FakeCalendarProvider(authorizationStatus: .notDetermined, events: [current])
        let service = CalendarService(provider: provider, lookAhead: lookAhead)

        service.refresh(now: now, existingCalendarEventIDs: [])

        XCTAssertTrue(service.upcomingEvents.isEmpty)
    }

    func testRefreshExcludesAlreadyCapturedEvents() {
        let a = event("a", startOffset: 30 * 60, endOffset: 90 * 60)
        let b = event("b", startOffset: 60 * 60, endOffset: 2 * 60 * 60)
        let provider = FakeCalendarProvider(authorizationStatus: .authorized, events: [a, b])
        let service = CalendarService(provider: provider, lookAhead: lookAhead)

        service.refresh(now: now, existingCalendarEventIDs: ["a"])

        XCTAssertEqual(service.upcomingEvents.map(\.id), ["b"])
    }

    // MARK: - Localization coverage (EN + DE)

    func testCalendarStringsHaveEnglishAndGermanEntries() throws {
        let keys = [
            "meetings.calendar.sectionTitle",
            "meetings.calendar.grantAccess",
            "meetings.calendar.accessExplanation",
            "meetings.calendar.accessDenied",
            "meetings.calendar.noUpcoming",
            "meetings.calendar.createMeeting",
            "meetings.calendar.inProgress",
            "meetings.calendar.untitledEvent"
        ]
        for key in keys {
            XCTAssertFalse(try TestSupport.localizedCatalogValue(for: key, language: "en").isEmpty, "EN missing for \(key)")
            XCTAssertFalse(try TestSupport.localizedCatalogValue(for: key, language: "de").isEmpty, "DE missing for \(key)")
        }
    }

    func testMeetingStateDisplayNamesHaveEnglishAndGermanEntries() throws {
        for state in MeetingState.allCases {
            let key = "meetings.state.\(state.rawValue)"
            XCTAssertFalse(try TestSupport.localizedCatalogValue(for: key, language: "en").isEmpty, "EN missing for \(key)")
            XCTAssertFalse(try TestSupport.localizedCatalogValue(for: key, language: "de").isEmpty, "DE missing for \(key)")
        }
    }
}
