import XCTest
@testable import TypeWhisper

/// M10 "past / overrunning meeting visibility": the grace window that keeps a running-long or
/// just-ended meeting in the primary Upcoming section, and the lookback "Earlier" section for
/// already-ended events. All assertions drive the pure windowing functions (and the service's
/// `refresh`) through the explicit `now:` seam, so they are fully time-deterministic.
@MainActor
final class CalendarVisibilityTests: XCTestCase {
    private final class FakeCalendarProvider: CalendarEventProviding {
        var authorizationStatus: CalendarAuthorizationStatus
        var eventsToReturn: [CalendarEventDTO]

        init(authorizationStatus: CalendarAuthorizationStatus = .authorized, events: [CalendarEventDTO] = []) {
            self.authorizationStatus = authorizationStatus
            self.eventsToReturn = events
        }

        func requestAccess() async -> CalendarAuthorizationStatus { authorizationStatus }
        func events(from start: Date, to end: Date) -> [CalendarEventDTO] { eventsToReturn }
    }

    // Pinned to *noon of the local calendar day* (not the raw epoch instant): the refresh-driven
    // tests below exercise `CalendarService.refresh`, whose Earlier-section lookback boundary is
    // `Calendar.current.startOfDay(for: now)` in the *device* timezone. Anchoring `now` to local
    // midnight + 12h guarantees that boundary is always exactly 12h before `now` in every timezone,
    // so events up to 12h back stay on the same calendar day and land in the lookback window
    // deterministically. The pure windowing tests use only offsets relative to `now`, so the
    // absolute value is otherwise immaterial to them.
    private let now = Calendar.current
        .startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        .addingTimeInterval(12 * 60 * 60)
    private let lookAhead: TimeInterval = 12 * 60 * 60
    private let grace: TimeInterval = 2 * 60 * 60

    private func event(
        _ id: String,
        startOffset: TimeInterval,
        endOffset: TimeInterval,
        isAllDay: Bool = false
    ) -> CalendarEventDTO {
        CalendarEventDTO(
            id: id,
            title: id,
            startDate: now.addingTimeInterval(startOffset),
            endDate: now.addingTimeInterval(endOffset),
            isAllDay: isAllDay
        )
    }

    // MARK: - Grace window (primary section)

    /// A meeting that started and whose scheduled end has passed but is still within the grace
    /// window (the exact reported pain: a meeting running long) must stay in the primary list.
    func testOverrunningEventStaysInPrimaryWithinGrace() {
        let inProgress = event("inProgress", startOffset: -10 * 60, endOffset: 50 * 60)
        let upcoming = event("upcoming", startOffset: 2 * 60 * 60, endOffset: 3 * 60 * 60)
        let overrunning = event("overrunning", startOffset: -90 * 60, endOffset: -30 * 60) // ended 30m ago
        let endedLongAgo = event("endedLongAgo", startOffset: -5 * 60 * 60, endOffset: -4 * 60 * 60)

        let result = CalendarService.currentUpcomingAndOverrunning(
            from: [upcoming, inProgress, overrunning, endedLongAgo],
            now: now,
            lookAhead: lookAhead,
            grace: grace,
            excludingEventIDs: []
        )

        // Overrunning stays; sorted by start ascending; the >2h-ago event drops out.
        XCTAssertEqual(result.map(\.id), ["overrunning", "inProgress", "upcoming"])
    }

    /// Determinism via the `now:` seam: an event exactly at the grace boundary is still shown; a
    /// small forward step of `now` past the boundary drops it from the primary list.
    func testGraceBoundaryIsDeterministicViaNowSeam() {
        // Ended just inside the grace window at `now` (1s short of the full grace).
        let ended = event("ended", startOffset: -3 * 60 * 60, endOffset: -(grace - 1))

        let withinGrace = CalendarService.currentUpcomingAndOverrunning(
            from: [ended], now: now, lookAhead: lookAhead, grace: grace, excludingEventIDs: []
        )
        XCTAssertEqual(withinGrace.map(\.id), ["ended"], "still shown while within grace")

        // Step `now` forward past the grace boundary via the seam: the same event now drops out.
        let pastGrace = CalendarService.currentUpcomingAndOverrunning(
            from: [ended], now: now.addingTimeInterval(2), lookAhead: lookAhead, grace: grace, excludingEventIDs: []
        )
        XCTAssertTrue(pastGrace.isEmpty, "past the grace boundary it drops out of the primary list")
    }

    func testAllDayEventsExcludedFromBothSections() {
        let allDay = event("allDay", startOffset: -3 * 60 * 60, endOffset: 20 * 60 * 60, isAllDay: true)
        let primary = CalendarService.currentUpcomingAndOverrunning(
            from: [allDay], now: now, lookAhead: lookAhead, grace: grace, excludingEventIDs: []
        )
        let earlier = CalendarService.earlierEvents(
            from: [allDay], now: now, since: now.addingTimeInterval(-24 * 60 * 60), grace: grace
        )
        XCTAssertTrue(primary.isEmpty)
        XCTAssertTrue(earlier.isEmpty)
    }

    // MARK: - Earlier / lookback section

    func testEarlierListsEndedEventsWithinLookbackOnly() {
        let since = now.addingTimeInterval(-6 * 60 * 60)
        let inProgress = event("inProgress", startOffset: -10 * 60, endOffset: 50 * 60)
        let overrunning = event("overrunning", startOffset: -90 * 60, endOffset: -30 * 60) // within grace, NOT earlier
        let endedYesterday = event("endedYesterday", startOffset: -5 * 60 * 60, endOffset: -4 * 60 * 60) // ended, in lookback
        let beforeLookback = event("beforeLookback", startOffset: -8 * 60 * 60, endOffset: -7 * 60 * 60) // before `since`

        let result = CalendarService.earlierEvents(
            from: [inProgress, overrunning, endedYesterday, beforeLookback],
            now: now,
            since: since,
            grace: grace
        )

        // Only the ended-beyond-grace event that started on/after the lookback boundary.
        XCTAssertEqual(result.map(\.id), ["endedYesterday"])
    }

    /// The Earlier section must NOT hide an event just because a backing meeting already exists —
    /// its row navigates to that meeting. The primary section still excludes such events.
    func testEarlierIgnoresExistingMeetingExclusionWhilePrimaryHonoursIt() {
        let overrunning = event("overrunning", startOffset: -90 * 60, endOffset: -30 * 60)
        // Ended 4h ago, started 5h ago. `now` is noon-local (see the property comment), so the
        // start-of-day lookback boundary is 12h back — this event's start is well within the same
        // calendar day in every timezone — and it is beyond the 2h grace, so it is "earlier".
        let endedLongAgo = event("endedLongAgo", startOffset: -5 * 60 * 60, endOffset: -4 * 60 * 60)
        let provider = FakeCalendarProvider(events: [overrunning, endedLongAgo])
        let service = CalendarService(provider: provider, lookAhead: lookAhead, grace: grace)

        // Both events already back a meeting.
        service.refresh(now: now, existingCalendarEventIDs: ["overrunning", "endedLongAgo"])

        // Primary honours the exclusion (overrunning has a meeting → hidden).
        XCTAssertFalse(service.upcomingEvents.contains { $0.id == "overrunning" })
        // Earlier ignores it so the past event can be opened.
        XCTAssertEqual(service.earlierEvents.map(\.id), ["endedLongAgo"])
    }

    func testDismissRemovesOverrunningFromPrimary() {
        let overrunning = event("overrunning", startOffset: -90 * 60, endOffset: -30 * 60)
        let upcoming = event("upcoming", startOffset: 60 * 60, endOffset: 2 * 60 * 60)
        let provider = FakeCalendarProvider(events: [overrunning, upcoming])
        let service = CalendarService(provider: provider, lookAhead: lookAhead, grace: grace)

        service.refresh(now: now, existingCalendarEventIDs: [])
        XCTAssertEqual(service.upcomingEvents.map(\.id), ["overrunning", "upcoming"])

        service.dismiss(eventID: "overrunning")
        XCTAssertEqual(service.upcomingEvents.map(\.id), ["upcoming"], "dismissed event leaves the primary list")
    }

    // MARK: - Sectioning (in-progress / upcoming / earlier)

    func testTimeStatusClassifiesEachSection() {
        let upcoming = event("upcoming", startOffset: 60 * 60, endOffset: 2 * 60 * 60)
        let inProgress = event("inProgress", startOffset: -10 * 60, endOffset: 50 * 60)
        let endedRecently = event("endedRecently", startOffset: -90 * 60, endOffset: -30 * 60)
        let ended = event("ended", startOffset: -5 * 60 * 60, endOffset: -4 * 60 * 60)

        XCTAssertEqual(CalendarService.timeStatus(for: upcoming, now: now, grace: grace), .upcoming)
        XCTAssertEqual(CalendarService.timeStatus(for: inProgress, now: now, grace: grace), .inProgress)
        XCTAssertEqual(CalendarService.timeStatus(for: endedRecently, now: now, grace: grace), .endedRecently)
        XCTAssertEqual(CalendarService.timeStatus(for: ended, now: now, grace: grace), .ended)
    }

    /// The view model mirrors the service's two sections exactly, so `refresh` producing the right
    /// split is the sectioning the UI renders.
    func testRefreshSplitsUpcomingAndEarlierSections() {
        let inProgress = event("inProgress", startOffset: -10 * 60, endOffset: 50 * 60)
        let overrunning = event("overrunning", startOffset: -90 * 60, endOffset: -30 * 60)
        let earlier = event("earlier", startOffset: -5 * 60 * 60, endOffset: -4 * 60 * 60)
        let provider = FakeCalendarProvider(events: [inProgress, overrunning, earlier])
        let service = CalendarService(provider: provider, lookAhead: lookAhead, grace: grace)

        service.refresh(now: now, existingCalendarEventIDs: [])

        XCTAssertEqual(service.upcomingEvents.map(\.id), ["overrunning", "inProgress"])
        XCTAssertEqual(service.earlierEvents.map(\.id), ["earlier"])
    }

    // MARK: - Localization (EN + DE)

    func testM10StringsHaveEnglishAndGermanEntries() throws {
        let keys = [
            "meetings.calendar.ended",
            "meetings.calendar.earlierSection",
            "meetings.calendar.openMeeting",
            "meetings.calendar.dismiss",
            "meetings.newMeeting.startRecording",
            "meetings.newMeeting.createEmpty",
            "meetings.menu.startRecording",
            "meetings.recording.alreadyActive"
        ]
        for key in keys {
            XCTAssertFalse(try TestSupport.localizedCatalogValue(for: key, language: "en").isEmpty, "EN missing for \(key)")
            XCTAssertFalse(try TestSupport.localizedCatalogValue(for: key, language: "de").isEmpty, "DE missing for \(key)")
        }
    }
}
