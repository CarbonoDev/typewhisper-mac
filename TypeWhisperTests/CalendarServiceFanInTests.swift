import XCTest
@testable import TypeWhisper

/// [Google Phase 1 · M4] `CalendarService` multi-provider fan-in (D-G4): primary (EventKit)
/// + secondary providers concatenate into the same republish/selection choke point; the refresh
/// and link-candidate guards become "any provider authorized"; and the denied/restricted error
/// message is suppressed while a secondary provider stands in for the denied primary.
@MainActor
final class CalendarServiceFanInTests: XCTestCase {
    /// Canned provider honoring the seam's contract that an unauthorized provider returns `[]`
    /// (the real EventKit and Google providers both self-gate on their status).
    private final class FakeProvider: CalendarEventProviding {
        var authorizationStatus: CalendarAuthorizationStatus
        var eventsToReturn: [CalendarEventDTO]
        var calendarsToReturn: [CalendarInfo]

        init(
            authorizationStatus: CalendarAuthorizationStatus,
            events: [CalendarEventDTO] = [],
            calendars: [CalendarInfo] = []
        ) {
            self.authorizationStatus = authorizationStatus
            self.eventsToReturn = events
            self.calendarsToReturn = calendars
        }

        func requestAccess() async -> CalendarAuthorizationStatus { authorizationStatus }

        func events(from start: Date, to end: Date) -> [CalendarEventDTO] {
            guard authorizationStatus == .authorized else { return [] }
            return eventsToReturn
        }

        func calendars() -> [CalendarInfo] {
            guard authorizationStatus == .authorized else { return [] }
            return calendarsToReturn
        }
    }

    private final class InMemorySelectionStore: CalendarSelectionStoring {
        private var deselected: Set<String>
        init(deselected: Set<String> = []) { self.deselected = deselected }
        func isSelected(_ calendarID: String) -> Bool { !deselected.contains(calendarID) }
        func setSelected(_ selected: Bool, for calendarID: String) {
            if selected { deselected.remove(calendarID) } else { deselected.insert(calendarID) }
        }
        var deselectedCalendarIDs: Set<String> { deselected }
    }

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let lookAhead: TimeInterval = 12 * 60 * 60

    private func event(
        _ id: String,
        startOffset: TimeInterval,
        endOffset: TimeInterval,
        calendarID: String? = nil
    ) -> CalendarEventDTO {
        CalendarEventDTO(
            id: id,
            title: "Event \(id)",
            startDate: now.addingTimeInterval(startOffset),
            endDate: now.addingTimeInterval(endOffset),
            calendarID: calendarID
        )
    }

    // MARK: - Fan-in concat + sort

    func testRefreshConcatenatesProvidersAndSortsByStart() {
        let primary = FakeProvider(
            authorizationStatus: .authorized,
            events: [event("ek-late", startOffset: 3 * 60 * 60, endOffset: 4 * 60 * 60)]
        )
        let secondary = FakeProvider(
            authorizationStatus: .authorized,
            events: [event("google:sub-1:early", startOffset: 60 * 60, endOffset: 2 * 60 * 60)]
        )
        let service = CalendarService(
            provider: primary,
            secondaryProviders: [secondary],
            selectionStore: InMemorySelectionStore(),
            lookAhead: lookAhead
        )

        service.refresh(now: now)

        XCTAssertEqual(service.upcomingEvents.map(\.id), ["google:sub-1:early", "ek-late"])
    }

    func testUnauthorizedSecondaryYieldsPrimaryOnly() {
        let primary = FakeProvider(
            authorizationStatus: .authorized,
            events: [event("ek", startOffset: 60 * 60, endOffset: 2 * 60 * 60)]
        )
        let secondary = FakeProvider(
            authorizationStatus: .notDetermined,
            events: [event("google:sub-1:hidden", startOffset: 30 * 60, endOffset: 90 * 60)]
        )
        let service = CalendarService(
            provider: primary,
            secondaryProviders: [secondary],
            selectionStore: InMemorySelectionStore(),
            lookAhead: lookAhead
        )

        service.refresh(now: now)

        XCTAssertEqual(service.upcomingEvents.map(\.id), ["ek"])
    }

    // MARK: - Google-only configuration (primary denied)

    func testPrimaryDeniedWithAuthorizedSecondaryStillRefreshesAndSuppressesDeniedMessage() {
        let primary = FakeProvider(authorizationStatus: .denied)
        let secondary = FakeProvider(
            authorizationStatus: .authorized,
            events: [event("google:sub-1:evt", startOffset: 60 * 60, endOffset: 2 * 60 * 60)]
        )
        let service = CalendarService(
            provider: primary,
            secondaryProviders: [secondary],
            selectionStore: InMemorySelectionStore(),
            lookAhead: lookAhead
        )

        // Denied + a working secondary is a working configuration, not an error (D-G4).
        XCTAssertNil(service.errorMessage)

        service.refresh(now: now)

        XCTAssertEqual(service.upcomingEvents.map(\.id), ["google:sub-1:evt"])
        XCTAssertNil(service.errorMessage)
        // The published primary status is untouched — permission prompts keep their meaning.
        XCTAssertEqual(service.authorizationStatus, .denied)
    }

    func testDeniedMessageReappearsOnRefreshOnceSecondaryDropsOut() {
        let primary = FakeProvider(authorizationStatus: .denied)
        let secondary = FakeProvider(
            authorizationStatus: .authorized,
            events: [event("google:sub-1:evt", startOffset: 60 * 60, endOffset: 2 * 60 * 60)]
        )
        let service = CalendarService(
            provider: primary,
            secondaryProviders: [secondary],
            selectionStore: InMemorySelectionStore(),
            lookAhead: lookAhead
        )
        XCTAssertNil(service.errorMessage)

        // Every account drops out of `.connected` (D-G7: the provider's status leaves
        // `.authorized`) — the next refresh must re-evaluate the message without a restart.
        secondary.authorizationStatus = .notDetermined
        service.refresh(now: now)

        XCTAssertTrue(service.upcomingEvents.isEmpty)
        XCTAssertEqual(service.errorMessage, String(localized: "meetings.calendar.accessDenied"))
    }

    func testAllProvidersUnauthorizedPublishesEmpty() {
        let primary = FakeProvider(authorizationStatus: .denied)
        let secondary = FakeProvider(authorizationStatus: .notDetermined)
        let service = CalendarService(
            provider: primary,
            secondaryProviders: [secondary],
            selectionStore: InMemorySelectionStore(),
            lookAhead: lookAhead
        )

        service.refresh(now: now)

        XCTAssertTrue(service.upcomingEvents.isEmpty)
        XCTAssertTrue(service.earlierEvents.isEmpty)
    }

    // MARK: - Selection choke point over namespaced IDs

    func testSelectionFilterDropsDeselectedNamespacedGoogleCalendar() {
        let keptID = GoogleCalendarID.calendarID(sub: "sub-1", raw: "kept")
        let hiddenID = GoogleCalendarID.calendarID(sub: "sub-1", raw: "hidden")
        let secondary = FakeProvider(
            authorizationStatus: .authorized,
            events: [
                event("google:sub-1:a", startOffset: 60 * 60, endOffset: 2 * 60 * 60, calendarID: keptID),
                event("google:sub-1:b", startOffset: 90 * 60, endOffset: 3 * 60 * 60, calendarID: hiddenID)
            ]
        )
        let service = CalendarService(
            provider: FakeProvider(authorizationStatus: .authorized),
            secondaryProviders: [secondary],
            selectionStore: InMemorySelectionStore(deselected: [hiddenID]),
            lookAhead: lookAhead
        )

        service.refresh(now: now)

        XCTAssertEqual(service.upcomingEvents.map(\.id), ["google:sub-1:a"])
    }

    // MARK: - Calendars list fan-in

    func testAvailableCalendarsConcatenatesAcrossProviders() {
        let macCalendar = CalendarInfo(id: "ek-cal", title: "Work", sourceName: "iCloud", color: .fallback)
        let googleCalendar = CalendarInfo(
            id: GoogleCalendarID.calendarID(sub: "sub-1", raw: "primary"),
            title: "marco@example.com",
            sourceName: "marco@example.com",
            color: .fallback
        )
        let service = CalendarService(
            provider: FakeProvider(authorizationStatus: .authorized, calendars: [macCalendar]),
            secondaryProviders: [FakeProvider(authorizationStatus: .authorized, calendars: [googleCalendar])],
            selectionStore: InMemorySelectionStore(),
            lookAhead: lookAhead
        )

        XCTAssertEqual(service.availableCalendars().map(\.id), [macCalendar.id, googleCalendar.id])
    }

    // MARK: - Link candidates fan-in

    func testLinkCandidatesFanInAcrossProvidersAndKeepSelectionFilter() {
        let hiddenID = GoogleCalendarID.calendarID(sub: "sub-1", raw: "hidden")
        let primary = FakeProvider(
            authorizationStatus: .authorized,
            events: [event("ek", startOffset: -60 * 60, endOffset: 60 * 60, calendarID: "ek-cal")]
        )
        let secondary = FakeProvider(
            authorizationStatus: .authorized,
            events: [
                event("google:sub-1:a", startOffset: 0, endOffset: 60 * 60),
                event("google:sub-1:b", startOffset: 0, endOffset: 60 * 60, calendarID: hiddenID)
            ]
        )
        let service = CalendarService(
            provider: primary,
            secondaryProviders: [secondary],
            selectionStore: InMemorySelectionStore(deselected: [hiddenID]),
            lookAhead: lookAhead
        )

        let candidates = service.linkCandidates(around: now, window: 24 * 60 * 60)

        XCTAssertEqual(candidates.map(\.id), ["ek", "google:sub-1:a"])
    }

    func testLinkCandidatesWorkWithOnlySecondaryAuthorized() {
        let secondary = FakeProvider(
            authorizationStatus: .authorized,
            events: [event("google:sub-1:a", startOffset: 0, endOffset: 60 * 60)]
        )
        let service = CalendarService(
            provider: FakeProvider(authorizationStatus: .denied),
            secondaryProviders: [secondary],
            selectionStore: InMemorySelectionStore(),
            lookAhead: lookAhead
        )

        XCTAssertEqual(service.linkCandidates(around: now, window: 24 * 60 * 60).map(\.id), ["google:sub-1:a"])
    }

    func testLinkCandidatesEmptyWhenNoProviderAuthorized() {
        let service = CalendarService(
            provider: FakeProvider(authorizationStatus: .denied),
            secondaryProviders: [FakeProvider(authorizationStatus: .notDetermined)],
            selectionStore: InMemorySelectionStore(),
            lookAhead: lookAhead
        )

        XCTAssertTrue(service.linkCandidates(around: now, window: 24 * 60 * 60).isEmpty)
    }
}
