import XCTest
import AppKit
@testable import TypeWhisper

/// M11 — calendar selection + color coding. Exercises the fakeable `CalendarEventProviding` seam
/// (never a live `EKEventStore`): provider-level filtering by selected calendar IDs, default-select
/// semantics for new calendars, the `CalendarColor` value-type roundtrip, and the view-model-level
/// settings-list rendering logic.
@MainActor
final class CalendarSelectionTests: XCTestCase {
    // MARK: - Fakes

    private final class FakeCalendarProvider: CalendarEventProviding {
        var authorizationStatus: CalendarAuthorizationStatus
        var eventsToReturn: [CalendarEventDTO]
        var calendarsToReturn: [CalendarInfo]

        init(
            authorizationStatus: CalendarAuthorizationStatus = .authorized,
            events: [CalendarEventDTO] = [],
            calendars: [CalendarInfo] = []
        ) {
            self.authorizationStatus = authorizationStatus
            self.eventsToReturn = events
            self.calendarsToReturn = calendars
        }

        func requestAccess() async -> CalendarAuthorizationStatus { authorizationStatus }
        func events(from start: Date, to end: Date) -> [CalendarEventDTO] { eventsToReturn }
        func calendars() -> [CalendarInfo] { calendarsToReturn }
    }

    /// In-memory selection store so the filtering tests don't touch `UserDefaults`.
    private final class StubSelectionStore: CalendarSelectionStoring {
        var deselected: Set<String>
        init(deselected: Set<String> = []) { self.deselected = deselected }
        var deselectedCalendarIDs: Set<String> { deselected }
        func isSelected(_ calendarID: String) -> Bool { !deselected.contains(calendarID) }
        func setSelected(_ selected: Bool, for calendarID: String) {
            if selected { deselected.remove(calendarID) } else { deselected.insert(calendarID) }
        }
    }

    /// Pinned to noon of a local calendar day so `-5h` events still land on/after that day's
    /// start-of-day lookback boundary regardless of the CI machine's time zone.
    private let now: Date = {
        var comps = DateComponents()
        comps.year = 2024
        comps.month = 6
        comps.day = 15
        comps.hour = 12
        return Calendar.current.date(from: comps)!
    }()
    private let lookAhead: TimeInterval = 12 * 60 * 60

    private func event(
        _ id: String,
        startOffset: TimeInterval,
        endOffset: TimeInterval,
        calendarID: String?,
        calendarName: String? = nil,
        calendarColor: CalendarColor? = nil
    ) -> CalendarEventDTO {
        CalendarEventDTO(
            id: id,
            title: "Event \(id)",
            startDate: now.addingTimeInterval(startOffset),
            endDate: now.addingTimeInterval(endOffset),
            calendarName: calendarName,
            calendarID: calendarID,
            calendarColor: calendarColor
        )
    }

    // MARK: - Provider-level filtering by selected IDs

    func testDeselectedCalendarEventsAreFilteredFromUpcoming() {
        let work = event("w", startOffset: 30 * 60, endOffset: 90 * 60, calendarID: "cal-work")
        let personal = event("p", startOffset: 60 * 60, endOffset: 120 * 60, calendarID: "cal-personal")
        let provider = FakeCalendarProvider(events: [work, personal])
        let store = StubSelectionStore(deselected: ["cal-personal"])
        let service = CalendarService(provider: provider, selectionStore: store, lookAhead: lookAhead)

        service.refresh(now: now)

        XCTAssertEqual(service.upcomingEvents.map(\.id), ["w"])
    }

    func testDeselectedCalendarEventsAreFilteredFromEarlier() {
        // Ended > grace ago (started 5h ago, ended 4h ago) → Earlier section.
        let work = event("w", startOffset: -5 * 60 * 60, endOffset: -4 * 60 * 60, calendarID: "cal-work")
        let personal = event("p", startOffset: -5 * 60 * 60, endOffset: -4 * 60 * 60, calendarID: "cal-personal")
        let provider = FakeCalendarProvider(events: [work, personal])
        let store = StubSelectionStore(deselected: ["cal-personal"])
        let service = CalendarService(provider: provider, selectionStore: store, lookAhead: lookAhead)

        // Widen lookback so both fall in the Earlier window: query since start of `now`'s day.
        service.refresh(now: now)

        XCTAssertEqual(service.earlierEvents.map(\.id), ["w"])
    }

    func testEventsWithoutCalendarIDAreNeverDropped() {
        // A nil calendarID (unknown owner) must be treated as selected so nothing is silently lost.
        let unknown = event("u", startOffset: 30 * 60, endOffset: 90 * 60, calendarID: nil)
        let provider = FakeCalendarProvider(events: [unknown])
        // Even with an unrelated deselection present, the nil-owner event survives.
        let store = StubSelectionStore(deselected: ["cal-anything"])
        let service = CalendarService(provider: provider, selectionStore: store, lookAhead: lookAhead)

        service.refresh(now: now)

        XCTAssertEqual(service.upcomingEvents.map(\.id), ["u"])
    }

    func testTogglingCalendarSelectionRepublishesWithoutProviderRoundTrip() {
        let work = event("w", startOffset: 30 * 60, endOffset: 90 * 60, calendarID: "cal-work")
        let provider = FakeCalendarProvider(events: [work])
        let store = StubSelectionStore()
        let service = CalendarService(provider: provider, selectionStore: store, lookAhead: lookAhead)
        service.refresh(now: now)
        XCTAssertEqual(service.upcomingEvents.map(\.id), ["w"])

        // Deselect → the event drops out immediately (no new provider query needed).
        service.setCalendarSelected(false, for: "cal-work")
        XCTAssertTrue(service.upcomingEvents.isEmpty)

        // Reselect → it returns.
        service.setCalendarSelected(true, for: "cal-work")
        XCTAssertEqual(service.upcomingEvents.map(\.id), ["w"])
    }

    /// The auto-brief scheduler and start-notification service consume `CalendarService.upcomingEvents`
    /// exclusively; filtering there is the single seam that keeps deselected-calendar events out of
    /// briefs and notifications. This asserts that seam directly.
    func testSchedulerAndNotificationSeamNeverSeesDeselectedEvents() {
        let work = event("w", startOffset: 10 * 60, endOffset: 70 * 60, calendarID: "cal-work")
        let secret = event("s", startOffset: 10 * 60, endOffset: 70 * 60, calendarID: "cal-secret")
        let provider = FakeCalendarProvider(events: [work, secret])
        let store = StubSelectionStore(deselected: ["cal-secret"])
        let service = CalendarService(provider: provider, selectionStore: store, lookAhead: lookAhead)

        service.refresh(now: now)

        // The exact list handed to notifyStartingMeetings(_:) / briefScheduler.tick(events:).
        let seen = Set(service.upcomingEvents.map(\.id))
        XCTAssertFalse(seen.contains("s"))
        XCTAssertTrue(seen.contains("w"))
    }

    // MARK: - Default-selected behavior incl. newly appearing calendars

    func testSelectionStoreDefaultsAllSelected() {
        let defaults = makeDefaults()
        let store = CalendarSelectionStore(defaults: defaults, key: "test.key")
        XCTAssertTrue(store.isSelected("anything"))
        XCTAssertTrue(store.deselectedCalendarIDs.isEmpty)
    }

    func testNewlyAppearingCalendarDefaultsSelected() {
        let defaults = makeDefaults()
        let store = CalendarSelectionStore(defaults: defaults, key: "test.key")
        // User deselects one known calendar.
        store.setSelected(false, for: "cal-known")
        XCTAssertFalse(store.isSelected("cal-known"))
        // A calendar that shows up later (never toggled) is still selected by default.
        XCTAssertTrue(store.isSelected("cal-brand-new"))
    }

    func testSelectionPersistsAcrossInstances() {
        let defaults = makeDefaults()
        let store = CalendarSelectionStore(defaults: defaults, key: "test.key")
        store.setSelected(false, for: "cal-a")

        // A fresh instance on the same defaults reads the persisted deselection.
        let reloaded = CalendarSelectionStore(defaults: defaults, key: "test.key")
        XCTAssertFalse(reloaded.isSelected("cal-a"))
        XCTAssertTrue(reloaded.isSelected("cal-b"))
        XCTAssertEqual(reloaded.deselectedCalendarIDs, ["cal-a"])
    }

    func testReselectingRemovesFromDeselectedSet() {
        let defaults = makeDefaults()
        let store = CalendarSelectionStore(defaults: defaults, key: "test.key")
        store.setSelected(false, for: "cal-a")
        store.setSelected(true, for: "cal-a")
        XCTAssertTrue(store.isSelected("cal-a"))
        XCTAssertTrue(store.deselectedCalendarIDs.isEmpty)
    }

    // MARK: - Color mapping roundtrip

    func testCalendarColorCodableRoundtrip() throws {
        let color = CalendarColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.4)
        let data = try JSONEncoder().encode(color)
        let decoded = try JSONDecoder().decode(CalendarColor.self, from: data)
        XCTAssertEqual(decoded, color)
    }

    func testCalendarColorFromNSColorPreservesComponents() {
        let nsColor = NSColor(srgbRed: 0.25, green: 0.5, blue: 0.75, alpha: 0.9)
        let color = CalendarColor(nsColor: nsColor)
        XCTAssertEqual(color.red, 0.25, accuracy: 0.001)
        XCTAssertEqual(color.green, 0.5, accuracy: 0.001)
        XCTAssertEqual(color.blue, 0.75, accuracy: 0.001)
        XCTAssertEqual(color.alpha, 0.9, accuracy: 0.001)
    }

    func testCalendarColorSurvivesDeviceColorSpaceConversion() {
        // A device-RGB color (as calendars sometimes expose) must still yield sRGB components.
        let deviceColor = NSColor(deviceRed: 1.0, green: 0.0, blue: 0.0, alpha: 1.0)
        let color = CalendarColor(nsColor: deviceColor)
        XCTAssertEqual(color.alpha, 1.0, accuracy: 0.001)
        // Red channel should dominate after conversion.
        XCTAssertGreaterThan(color.red, color.green)
        XCTAssertGreaterThan(color.red, color.blue)
    }

    func testDTOCarriesCalendarColorAndTitleAlias() {
        let color = CalendarColor(red: 0.2, green: 0.4, blue: 0.6)
        let dto = event("e", startOffset: 0, endOffset: 60 * 60, calendarID: "cal-x", calendarName: "Work", calendarColor: color)
        XCTAssertEqual(dto.calendarColor, color)
        XCTAssertEqual(dto.calendarID, "cal-x")
        // `calendarTitle` aliases `calendarName` (M11 naming) without a second stored field.
        XCTAssertEqual(dto.calendarTitle, "Work")
        XCTAssertEqual(dto.calendarTitle, dto.calendarName)
    }

    // MARK: - Settings-list rendering logic (view-model level)

    func testMakeCalendarRowsReflectsSelectionAndSortsByAccountThenTitle() {
        let calendars = [
            CalendarInfo(id: "b", title: "Personal", sourceName: "iCloud", color: .fallback),
            CalendarInfo(id: "a", title: "Work", sourceName: "Google", color: .fallback),
            CalendarInfo(id: "c", title: "Shared", sourceName: "Google", color: .fallback)
        ]
        let deselected: Set<String> = ["a"]

        let rows = MeetingsViewModel.makeCalendarRows(calendars: calendars) { !deselected.contains($0) }

        // Sorted: Google/Shared, Google/Work, iCloud/Personal.
        XCTAssertEqual(rows.map(\.calendar.id), ["c", "a", "b"])
        XCTAssertEqual(rows.map(\.isSelected), [true, false, true])
    }

    func testMakeCalendarRowsEmptyWhenNoCalendars() {
        let rows = MeetingsViewModel.makeCalendarRows(calendars: []) { _ in true }
        XCTAssertTrue(rows.isEmpty)
    }

    func testCalendarServiceExposesAvailableCalendarsFromProvider() {
        let provider = FakeCalendarProvider(calendars: [
            CalendarInfo(id: "x", title: "Work", sourceName: "iCloud", color: .fallback)
        ])
        let service = CalendarService(provider: provider, selectionStore: StubSelectionStore(), lookAhead: lookAhead)
        XCTAssertEqual(service.availableCalendars().map(\.id), ["x"])
        XCTAssertTrue(service.isCalendarSelected("x"))
        service.setCalendarSelected(false, for: "x")
        XCTAssertFalse(service.isCalendarSelected("x"))
    }

    // MARK: - Localization coverage (EN + DE)

    func testCalendarSelectionStringsHaveEnglishAndGermanEntries() throws {
        let keys = [
            "meetings.calendar.calendarsSection",
            "meetings.calendar.calendarsExplanation",
            "meetings.calendar.calendarsNeedsAccess",
            "meetings.calendar.noCalendars"
        ]
        for key in keys {
            XCTAssertFalse(try TestSupport.localizedCatalogValue(for: key, language: "en").isEmpty, "EN missing for \(key)")
            XCTAssertFalse(try TestSupport.localizedCatalogValue(for: key, language: "de").isEmpty, "DE missing for \(key)")
        }
    }

    // MARK: - Helpers

    private func makeDefaults() -> UserDefaults {
        let suite = "CalendarSelectionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
}
