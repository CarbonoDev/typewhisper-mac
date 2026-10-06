import XCTest
@testable import TypeWhisper

/// [Perf 1C] `HomeFeedViewModel.actionFacts` is memoized per `(meeting id, updatedAt)` and the day
/// headers reuse cached formatters. These pin that the memo invalidates on every output write and
/// that cached headers read exactly like freshly formatted ones.
@MainActor
final class HomeFeedActionFactsTests: XCTestCase {
    private let twoActions = """
    ## Action Items

    - [ ] Prepare the deck @Marco
    - Luisa: send the minutes
    """

    private let oneOtherAction = """
    ## Action Items

    - [ ] Book the room
    """

    func testActionFactsFollowOutputWritesThroughTheMemo() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(directory) }
        let service = MeetingService(appSupportDirectory: directory)
        let hfvm = HomeFeedViewModel()
        let meeting = service.createMeeting(title: "Facts", source: .adHoc)

        XCTAssertNil(hfvm.actionFacts(for: meeting))
        XCTAssertNil(hfvm.actionFacts(for: meeting), "the memoized 'no outputs' answer is stable")

        let summary = service.addOutput(to: meeting, kind: .summary, content: twoActions)
        XCTAssertEqual(hfvm.actionFacts(for: meeting)?.totalCount, 2)
        XCTAssertEqual(hfvm.actionFacts(for: meeting)?.totalCount, 2)

        service.addOutput(to: meeting, kind: .extended, content: oneOtherAction)
        XCTAssertEqual(hfvm.actionFacts(for: meeting)?.totalCount, 3, "summary ∪ extended")

        service.deleteOutput(summary)
        XCTAssertEqual(hfvm.actionFacts(for: meeting)?.totalCount, 1)
    }

    /// Meetings with neither a summary nor an extended output are answered from the denormalised
    /// output kinds, without walking `outputs`.
    func testActionFactsAskTheOutputKindsColumnFirst() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(directory) }
        let service = MeetingService(appSupportDirectory: directory)
        let hfvm = HomeFeedViewModel()
        let meeting = service.createMeeting(title: "Brief only", source: .adHoc)
        service.addOutput(to: meeting, kind: .summary, content: twoActions)

        // A column that claims only a brief is believed (it claims content), so the summary row
        // is never read — proof the column is consulted before the relationship.
        meeting.factOutputKindsRaw = "brief"
        XCTAssertNil(hfvm.actionFacts(for: meeting))

        // With the column back in step (and a fresh updatedAt), the summary is parsed as before.
        service.recomputeFacts(for: meeting)
        meeting.updatedAt = Date().addingTimeInterval(1)
        XCTAssertEqual(hfvm.actionFacts(for: meeting)?.totalCount, 2)
    }

    func testCachedHeaderMatchesAFreshFormatter() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let hfvm = HomeFeedViewModel(calendar: calendar)
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 7, hour: 14)))
        let old = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 2, hour: 9)))
        let group = try XCTUnwrap(
            hfvm.timelineGroups(from: [Meeting(title: "Old", startDate: old)]).first
        )

        let fresh = DateFormatter()
        fresh.calendar = calendar
        fresh.timeZone = calendar.timeZone
        fresh.setLocalizedDateFormatFromTemplate("yMMMd")

        XCTAssertEqual(hfvm.groupTitle(for: group, now: now), fresh.string(from: group.date))
        XCTAssertEqual(hfvm.groupTitle(for: group, now: now), fresh.string(from: group.date))
    }
}
