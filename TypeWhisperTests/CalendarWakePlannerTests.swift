import XCTest
@testable import TypeWhisper

/// [Perf Phase 2] The pure wake planner that replaced the 60 s calendar poll.
@MainActor
final class CalendarWakePlannerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let lookAhead: TimeInterval = 12 * 3600
    private let grace: TimeInterval = 2 * 3600
    private let notification = CalendarWakePlanner.ConsumerWindow(lead: 60, trail: 120)
    private let brief = CalendarWakePlanner.ConsumerWindow(lead: 20 * 60, trail: 0)

    private func event(_ id: String, start: TimeInterval, end: TimeInterval, allDay: Bool = false) -> CalendarEventDTO {
        CalendarEventDTO(
            id: id, title: id,
            startDate: now.addingTimeInterval(start), endDate: now.addingTimeInterval(end),
            isAllDay: allDay, attendees: []
        )
    }

    private func wake(
        source: [CalendarEventDTO],
        consumers: [CalendarEventDTO]? = nil,
        windows: [CalendarWakePlanner.ConsumerWindow]? = nil,
        refetchAt: Date? = nil
    ) -> CalendarWakePlanner.Wake? {
        CalendarWakePlanner.nextWake(
            sourceEvents: source,
            consumerEvents: consumers ?? source,
            now: now,
            lookAhead: lookAhead,
            grace: grace,
            consumerWindows: windows ?? [notification, brief],
            refetchAt: refetchAt
        )
    }

    func testNothingScheduledWithNoEventsAndNoRefetch() {
        XCTAssertNil(wake(source: []))
    }

    func testWakesWhenTheBriefWindowOpens() {
        let evt = event("a", start: 3600, end: 7200)
        XCTAssertEqual(wake(source: [evt]), .init(date: now.addingTimeInterval(3600 - 20 * 60), isRefetch: false))
    }

    func testWakesWhenTheNotificationWindowOpensAfterTheBriefWindow() {
        // Already inside the brief window (10 min out): re-tick at the poll cadence…
        let evt = event("a", start: 10 * 60, end: 3600)
        XCTAssertEqual(wake(source: [evt])?.date, now.addingTimeInterval(CalendarWakePlanner.retickInterval))
        // …and with only the notification gate, its window opening is the next instant.
        XCTAssertEqual(wake(source: [evt], windows: [notification])?.date, now.addingTimeInterval(10 * 60 - 60))
    }

    func testRetickWhileInsideANotificationWindow() {
        let evt = event("a", start: -30, end: 3600)
        XCTAssertEqual(wake(source: [evt], windows: [notification])?.date, now.addingTimeInterval(60))
    }

    func testWindowingEdgesWithoutConsumers() {
        // In progress: the next edge is its end, then end + grace.
        let evt = event("a", start: -600, end: 1800)
        XCTAssertEqual(wake(source: [evt], consumers: [], windows: [])?.date, now.addingTimeInterval(1800))
        let ended = event("b", start: -3600, end: -600)
        XCTAssertEqual(wake(source: [ended], consumers: [], windows: [])?.date, now.addingTimeInterval(-600 + grace))
        // Beyond the look-ahead: wakes when it enters the window.
        let far = event("c", start: lookAhead + 900, end: lookAhead + 4500)
        XCTAssertEqual(wake(source: [far], consumers: [], windows: [])?.date, now.addingTimeInterval(900))
    }

    func testAllDayEventsNeverWake() {
        let evt = event("a", start: 600, end: 86400, allDay: true)
        XCTAssertNil(wake(source: [evt]))
    }

    func testRefetchWinsWhenItIsFirst() {
        let evt = event("a", start: 3 * 3600, end: 4 * 3600)
        let refetchAt = now.addingTimeInterval(3600)
        XCTAssertEqual(wake(source: [evt], refetchAt: refetchAt), .init(date: refetchAt, isRefetch: true))
        // A nearer edge wins over the refetch.
        let soon = event("b", start: 20 * 60 + 300, end: 3 * 3600)
        XCTAssertEqual(wake(source: [soon], refetchAt: refetchAt), .init(date: now.addingTimeInterval(300), isRefetch: false))
    }

    func testOverdueRefetchFiresNow() {
        XCTAssertEqual(wake(source: [], refetchAt: now.addingTimeInterval(-5)), .init(date: now, isRefetch: true))
    }
}
