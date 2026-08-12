import XCTest
@testable import TypeWhisper

/// [Google Phase 1 · M4 / PR #7 review finding 4] Cross-provider CalDAV twin collapse for the
/// automatic consumers of the fanned-in event list: same real event from Google + EventKit ⇒ one
/// entry (the Google copy), everything else untouched.
final class CalendarEventTwinCollapserTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func googleEvent(
        raw: String = "evt-1",
        sub: String = "sub-1",
        title: String = "Acme Sync",
        seriesID: String? = nil,
        start: Date? = nil,
        minutes: Double = 30
    ) -> CalendarEventDTO {
        let begin = start ?? self.start
        return CalendarEventDTO(
            id: GoogleCalendarID.eventID(sub: sub, raw: raw),
            title: title,
            startDate: begin,
            endDate: begin.addingTimeInterval(minutes * 60),
            seriesID: seriesID,
            calendarID: GoogleCalendarID.calendarID(sub: sub, raw: "primary")
        )
    }

    private func eventKitEvent(
        id: String = "UUID-1",
        title: String = "Acme Sync",
        seriesID: String? = nil,
        start: Date? = nil,
        minutes: Double = 30
    ) -> CalendarEventDTO {
        let begin = start ?? self.start
        return CalendarEventDTO(
            id: "\(id)#\(begin.timeIntervalSince1970)",
            title: title,
            startDate: begin,
            endDate: begin.addingTimeInterval(minutes * 60),
            seriesID: seriesID,
            calendarID: "cal-uuid"
        )
    }

    // MARK: - Collapse

    func testRecurringTwinsCollapseOnSeriesIDAndStartPreferringGoogle() {
        let ical = "abc123@google.com"
        let events = [
            eventKitEvent(seriesID: ical),
            googleEvent(seriesID: ical),
        ]
        let collapsed = CalendarEventTwinCollapser.collapse(events)
        XCTAssertEqual(collapsed.map(\.id), ["google:sub-1:evt-1"], "the richer Google copy survives")
    }

    func testNonRecurringTwinsCollapseOnTitleAndExactTimes() {
        let collapsed = CalendarEventTwinCollapser.collapse([
            eventKitEvent(),
            googleEvent(),
        ])
        XCTAssertEqual(collapsed.map(\.id), ["google:sub-1:evt-1"])
    }

    func testTitleMatchIsCaseAndWhitespaceInsensitive() {
        let collapsed = CalendarEventTwinCollapser.collapse([
            eventKitEvent(title: "  acme sync "),
            googleEvent(title: "Acme Sync"),
        ])
        XCTAssertEqual(collapsed.count, 1)
    }

    // MARK: - Non-twins are never touched

    func testDifferentStartInstantsAreNotTwins() {
        let events = [
            eventKitEvent(start: start),
            googleEvent(start: start.addingTimeInterval(60)),
        ]
        XCTAssertEqual(CalendarEventTwinCollapser.collapse(events).count, 2, "an adjacent occurrence is a different event")
    }

    func testDifferentEndInstantsAreNotTwins() {
        let events = [
            eventKitEvent(minutes: 30),
            googleEvent(minutes: 60),
        ]
        XCTAssertEqual(CalendarEventTwinCollapser.collapse(events).count, 2)
    }

    func testSameSideDuplicatesAreNeverCollapsed() {
        // Two Google accounts invited to the same event (spec §8) and two EventKit calendars
        // carrying the same event both stay — collapse requires one copy from each side.
        let twoGoogle = [
            googleEvent(sub: "sub-1"),
            googleEvent(sub: "sub-2"),
        ]
        XCTAssertEqual(CalendarEventTwinCollapser.collapse(twoGoogle).count, 2)

        let twoEventKit = [
            eventKitEvent(id: "UUID-1"),
            eventKitEvent(id: "UUID-2"),
        ]
        XCTAssertEqual(CalendarEventTwinCollapser.collapse(twoEventKit).count, 2)
    }

    func testDifferentSeriesNeverCollapseEvenAtTheSameTime() {
        let events = [
            eventKitEvent(title: "Standup", seriesID: "series-a"),
            googleEvent(title: "Standup", seriesID: "series-b"),
        ]
        XCTAssertEqual(CalendarEventTwinCollapser.collapse(events).count, 2, "identity is the series id when present")
    }

    func testBlankTitledEventsWithoutSeriesAreNeverCollapsed() {
        let events = [
            eventKitEvent(title: "   "),
            googleEvent(title: ""),
        ]
        XCTAssertEqual(CalendarEventTwinCollapser.collapse(events).count, 2, "no identity ⇒ no collapse")
        XCTAssertNil(CalendarEventTwinCollapser.collapseKey(for: events[0]))
    }

    func testUnrelatedEventsPassThroughInOrder() {
        let events = [
            eventKitEvent(id: "UUID-1", title: "One"),
            googleEvent(raw: "evt-2", title: "Two"),
            eventKitEvent(id: "UUID-3", title: "Three"),
        ]
        XCTAssertEqual(CalendarEventTwinCollapser.collapse(events).map(\.title), ["One", "Two", "Three"])
    }

    func testMixedListCollapsesOnlyTheTwinPair() {
        let other = start.addingTimeInterval(3600)
        let events = [
            eventKitEvent(id: "UUID-1", title: "Acme Sync"),
            eventKitEvent(id: "UUID-2", title: "Solo", start: other),
            googleEvent(raw: "evt-1", title: "Acme Sync"),
        ]
        XCTAssertEqual(
            CalendarEventTwinCollapser.collapse(events).map(\.id),
            ["UUID-2#\(other.timeIntervalSince1970)", "google:sub-1:evt-1"]
        )
    }
}
