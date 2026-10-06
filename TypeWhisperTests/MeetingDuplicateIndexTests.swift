import XCTest
@testable import TypeWhisper

/// [Perf 1C] `MeetingDuplicateIndex` memoizes the archive's duplicate flags; it must always agree
/// with the uncached `MeetingsListView.duplicateMeetingIDs` and recompute when any input changes.
@MainActor
final class MeetingDuplicateIndexTests: XCTestCase {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return cal
    }

    private func at(hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: 7, hour: hour))!
    }

    func testFlagsAllButTheNewestSameDayTwin() {
        let older = Meeting(title: "Standup", startDate: at(hour: 9))
        let newer = Meeting(title: "standup ", startDate: at(hour: 11))
        let other = Meeting(title: "Retro", startDate: at(hour: 10))
        let meetings = [older, newer, other]

        let ids = MeetingDuplicateIndex.duplicateIDs(in: meetings, calendar: calendar)
        XCTAssertEqual(ids, [older.id])
        XCTAssertEqual(ids, MeetingsListView.duplicateMeetingIDs(in: meetings, calendar: calendar))
        XCTAssertEqual(MeetingDuplicateIndex.duplicateIDs(in: meetings, calendar: calendar), ids)
    }

    func testRecomputesWhenAMeetingIsRewritten() {
        let first = Meeting(title: "Standup", startDate: at(hour: 9), updatedAt: at(hour: 9))
        let second = Meeting(title: "Planning", startDate: at(hour: 11), updatedAt: at(hour: 11))
        XCTAssertTrue(MeetingDuplicateIndex.duplicateIDs(in: [first, second], calendar: calendar).isEmpty)

        // What `MeetingService.renameMeeting` does: new title, bumped `updatedAt`.
        second.title = "Standup"
        second.updatedAt = at(hour: 12)
        XCTAssertEqual(MeetingDuplicateIndex.duplicateIDs(in: [first, second], calendar: calendar), [first.id])
    }

    func testRecomputesWhenTheDisplayedListChanges() {
        let a = Meeting(title: "Standup", startDate: at(hour: 9))
        let b = Meeting(title: "Standup", startDate: at(hour: 11))
        XCTAssertEqual(MeetingDuplicateIndex.duplicateIDs(in: [a, b], calendar: calendar), [a.id])
        XCTAssertTrue(MeetingDuplicateIndex.duplicateIDs(in: [a], calendar: calendar).isEmpty)
    }

    func testRecomputesWhenTheCalendarZoneChanges() {
        // 23:00 and 01:00 next day in New York share a day in a zone four hours east.
        let late = Meeting(title: "Sync", startDate: at(hour: 23))
        let early = Meeting(title: "Sync", startDate: at(hour: 25))
        XCTAssertTrue(MeetingDuplicateIndex.duplicateIDs(in: [late, early], calendar: calendar).isEmpty)

        var east = calendar
        east.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(MeetingDuplicateIndex.duplicateIDs(in: [late, early], calendar: east), [late.id])
    }
}
