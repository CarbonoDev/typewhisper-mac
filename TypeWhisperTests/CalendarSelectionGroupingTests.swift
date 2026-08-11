import XCTest
@testable import TypeWhisper

/// [Google Phase 1 · M4] Pure grouping of the flat calendar-selection rows by source for the
/// Calendars settings list: one group per macOS Calendar source plus one per Google account
/// (email header), macOS groups always listed first ("split by account", D-G4).
final class CalendarSelectionGroupingTests: XCTestCase {
    private func row(
        id: String,
        title: String,
        sourceName: String,
        isSelected: Bool = true
    ) -> CalendarSelectionRow {
        CalendarSelectionRow(
            calendar: CalendarInfo(id: id, title: title, sourceName: sourceName, color: .fallback),
            isSelected: isSelected
        )
    }

    func testGroupsBySourcePreservingRowOrder() {
        let rows = [
            row(id: "ek-1", title: "Personal", sourceName: "iCloud"),
            row(id: "ek-2", title: "Work", sourceName: "iCloud"),
            row(id: "ek-3", title: "Team", sourceName: "Exchange")
        ]

        let groups = CalendarSelectionGrouping.groups(from: rows)

        XCTAssertEqual(groups.map(\.sourceName), ["iCloud", "Exchange"])
        XCTAssertEqual(groups[0].rows.map(\.id), ["ek-1", "ek-2"])
        XCTAssertEqual(groups[1].rows.map(\.id), ["ek-3"])
        XCTAssertFalse(groups.contains(where: \.isGoogle))
    }

    func testGoogleAccountsGroupSeparatelyAndAfterMacSources() {
        let rows = [
            // Deliberately interleaved: rows arrive sorted by sourceName, which can put a Google
            // account email alphabetically before an EventKit source.
            row(
                id: GoogleCalendarID.calendarID(sub: "sub-1", raw: "primary"),
                title: "a@x.com",
                sourceName: "a@x.com"
            ),
            row(id: "ek-1", title: "Personal", sourceName: "iCloud"),
            row(
                id: GoogleCalendarID.calendarID(sub: "sub-2", raw: "primary"),
                title: "b@x.com",
                sourceName: "b@x.com"
            )
        ]

        let groups = CalendarSelectionGrouping.groups(from: rows)

        XCTAssertEqual(groups.map(\.sourceName), ["iCloud", "a@x.com", "b@x.com"])
        XCTAssertEqual(groups.map(\.isGoogle), [false, true, true])
    }

    func testEventKitSourceTitledLikeAccountEmailDoesNotMergeIntoGoogleGroup() {
        // A CalDAV-synced EventKit source is often titled with the same account email as the
        // connected Google account — the two must stay separate groups (bare vs namespaced IDs)
        // with distinct identities, or SwiftUI's ForEach would see duplicate IDs.
        let rows = [
            row(id: "ek-caldav", title: "m@x.com", sourceName: "m@x.com"),
            row(
                id: GoogleCalendarID.calendarID(sub: "sub-1", raw: "primary"),
                title: "m@x.com",
                sourceName: "m@x.com"
            )
        ]

        let groups = CalendarSelectionGrouping.groups(from: rows)

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.map(\.isGoogle), [false, true])
        XCTAssertEqual(Set(groups.map(\.id)).count, 2)
    }

    func testEmptyRowsYieldNoGroups() {
        XCTAssertTrue(CalendarSelectionGrouping.groups(from: []).isEmpty)
    }
}
