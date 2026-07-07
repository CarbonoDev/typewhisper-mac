import XCTest
@testable import TypeWhisper

/// Track C — Home feed unit tests: day-bucketing/grouping, meeting → badge mapping, and the
/// calendar-color seam. All pure and container-free (meetings are built as detached `@Model`
/// objects; badge logic runs over value-type facts) so CI never touches a live store or calendar.

// MARK: - Day grouping / bucketing

@MainActor
final class HomeFeedGroupingTests: XCTestCase {
    /// Fixed gregorian calendar in a stable time zone so day math is deterministic.
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return cal
    }

    /// 2026-07-07 14:00 local.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: 7, hour: 14))!
    }

    private func date(daysBefore days: Int, hour: Int) -> Date {
        let day = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now))!
        return calendar.date(byAdding: .hour, value: hour, to: day)!
    }

    private func meeting(title: String, at date: Date) -> Meeting {
        Meeting(title: title, startDate: date)
    }

    func testBucketClassification() {
        XCTAssertEqual(MeetingsViewModel.homeDayBucket(for: date(daysBefore: 0, hour: 9), now: now, calendar: calendar), .today)
        XCTAssertEqual(MeetingsViewModel.homeDayBucket(for: date(daysBefore: 1, hour: 9), now: now, calendar: calendar), .yesterday)

        let threeDays = calendar.startOfDay(for: date(daysBefore: 3, hour: 9))
        XCTAssertEqual(MeetingsViewModel.homeDayBucket(for: date(daysBefore: 3, hour: 9), now: now, calendar: calendar), .earlierThisWeek(threeDays))

        let thirtyDays = calendar.startOfDay(for: date(daysBefore: 30, hour: 9))
        XCTAssertEqual(MeetingsViewModel.homeDayBucket(for: date(daysBefore: 30, hour: 9), now: now, calendar: calendar), .older(thirtyDays))
    }

    /// A future-dated day is clamped to `.today` (never crashes / produces a negative bucket).
    func testFutureDayClampsToToday() {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
        XCTAssertEqual(MeetingsViewModel.homeDayBucket(for: tomorrow, now: now, calendar: calendar), .today)
    }

    func testGroupingBucketsAndOrders() {
        let a = meeting(title: "A", at: date(daysBefore: 0, hour: 10))
        let b = meeting(title: "B", at: date(daysBefore: 0, hour: 9))
        let c = meeting(title: "C", at: date(daysBefore: 1, hour: 11))
        let d = meeting(title: "D", at: date(daysBefore: 3, hour: 8))
        let e = meeting(title: "E", at: date(daysBefore: 30, hour: 8))

        let groups = MeetingsViewModel.homeDayGroups(from: [d, b, e, a, c], calendar: calendar)

        // Four distinct days, newest first.
        XCTAssertEqual(groups.count, 4)
        XCTAssertEqual(groups.map { $0.meetings.map(\.title) }, [["A", "B"], ["C"], ["D"], ["E"]])

        // Bucket titles resolve as expected for the first three groups.
        let hfvm = HomeFeedViewModel(calendar: calendar)
        XCTAssertEqual(hfvm.groupTitle(for: groups[0], now: now), String(localized: "home.timeline.today"))
        XCTAssertEqual(hfvm.groupTitle(for: groups[1], now: now), String(localized: "home.timeline.yesterday"))
    }

    /// A meeting without a `startDate` falls back to `createdAt` for its day.
    func testMeetingWithoutStartUsesCreatedAt() {
        let created = date(daysBefore: 2, hour: 12)
        let m = Meeting(title: "NoStart", startDate: nil, createdAt: created)
        let groups = MeetingsViewModel.homeDayGroups(from: [m], calendar: calendar)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(calendar.startOfDay(for: created), groups[0].date)
    }
}

// MARK: - State badges

@MainActor
final class MeetingStateBadgeTests: XCTestCase {
    func testBadgeOrderWithEverythingOn() {
        let facts = MeetingBadgeFacts(
            hasSummary: true,
            hasExtended: true,
            hasBrief: true,
            isInVault: true,
            isRunningLong: true
        )
        XCTAssertEqual(
            MeetingsViewModel.homeBadges(for: facts),
            [.runningLong, .briefReady, .summary, .extended, .inVault]
        )
    }

    func testNoFactsProduceNoBadges() {
        let facts = MeetingBadgeFacts(
            hasSummary: false, hasExtended: false, hasBrief: false, isInVault: false, isRunningLong: false
        )
        XCTAssertTrue(MeetingsViewModel.homeBadges(for: facts).isEmpty)
    }

    func testBriefAndInVaultSubset() {
        let facts = MeetingBadgeFacts(
            hasSummary: false, hasExtended: false, hasBrief: true, isInVault: true, isRunningLong: false
        )
        XCTAssertEqual(MeetingsViewModel.homeBadges(for: facts), [.briefReady, .inVault])
    }

    /// Fact extraction from a live meeting: no outputs → no output badges; a set obsidian folder →
    /// in-vault; running-long is passed through from the seam.
    func testFactExtractionFromMeeting() {
        let meeting = Meeting(title: "M", obsidianFolder: "Meetings/2026")
        let facts = MeetingsViewModel.homeBadgeFacts(for: meeting, isRunningLong: true)
        XCTAssertFalse(facts.hasSummary)
        XCTAssertFalse(facts.hasExtended)
        XCTAssertFalse(facts.hasBrief)
        XCTAssertTrue(facts.isInVault)
        XCTAssertTrue(facts.isRunningLong)
    }

    func testFactExtractionEmptyFolderIsNotInVault() {
        let meeting = Meeting(title: "M", obsidianFolder: "   ")
        let facts = MeetingsViewModel.homeBadgeFacts(for: meeting, isRunningLong: false)
        XCTAssertFalse(facts.isInVault)
    }

    // Running-long seam.

    func testRunningLongMeetingLiveAndOverran() {
        let hfvm = HomeFeedViewModel()
        let now = Date()
        let live = Meeting(title: "Live", state: .live, endDate: now.addingTimeInterval(-60))
        XCTAssertTrue(hfvm.isRunningLong(meeting: live, now: now))

        let notOverran = Meeting(title: "Live2", state: .live, endDate: now.addingTimeInterval(600))
        XCTAssertFalse(hfvm.isRunningLong(meeting: notOverran, now: now))

        let completed = Meeting(title: "Done", state: .completed, endDate: now.addingTimeInterval(-60))
        XCTAssertFalse(hfvm.isRunningLong(meeting: completed, now: now))
    }

    func testRunningLongEventDefaultSeam() {
        let hfvm = HomeFeedViewModel()
        let now = Date()
        let ended = CalendarEventDTO(
            id: "e1", title: "Ended",
            startDate: now.addingTimeInterval(-3600), endDate: now.addingTimeInterval(-60)
        )
        // Ended, no linked meeting → running long.
        XCTAssertTrue(hfvm.isRunningLong(event: ended, existingMeeting: nil, now: now))
        // Ended, but a completed meeting is linked → not running long.
        let done = Meeting(title: "Done", state: .completed)
        XCTAssertFalse(hfvm.isRunningLong(event: ended, existingMeeting: done, now: now))
        // Still upcoming → not running long.
        let upcoming = CalendarEventDTO(
            id: "e2", title: "Up",
            startDate: now.addingTimeInterval(600), endDate: now.addingTimeInterval(1200)
        )
        XCTAssertFalse(hfvm.isRunningLong(event: upcoming, existingMeeting: nil, now: now))
    }
}

// MARK: - Calendar color seam

@MainActor
final class CalendarColorSeamTests: XCTestCase {
    private func event(id: String, calendarName: String?, color: CalendarColor?) -> CalendarEventDTO {
        CalendarEventDTO(
            id: id, title: "T",
            startDate: Date(), endDate: Date().addingTimeInterval(3600),
            calendarName: calendarName, calendarColor: color
        )
    }

    func testRealColorTakesPrecedence() {
        let provider = DefaultCalendarColorProvider()
        let color = CalendarColor(red: 0.1, green: 0.2, blue: 0.3)
        let e = event(id: "a", calendarName: "Work", color: color)
        XCTAssertEqual(provider.color(for: e), color)
    }

    func testFallbackPaletteIsStablePerCalendarName() {
        let provider = DefaultCalendarColorProvider()
        let e1 = event(id: "a", calendarName: "Work", color: nil)
        let e2 = event(id: "b", calendarName: "Work", color: nil)
        XCTAssertEqual(provider.color(for: e1), provider.color(for: e2))

        // And stable across repeated resolution.
        XCTAssertEqual(
            DefaultCalendarColorProvider.paletteColor(forName: "Personal"),
            DefaultCalendarColorProvider.paletteColor(forName: "Personal")
        )
    }

    func testFallbackColorIsWithinPalette() {
        let e = event(id: "a", calendarName: "Anything", color: nil)
        let color = DefaultCalendarColorProvider().color(for: e)
        XCTAssertTrue(DefaultCalendarColorProvider.palette.contains(color))
    }

    /// Swapping in a different provider changes the resolved color with no structural change to the
    /// call site — the point of the seam.
    func testProviderSwapChangesColor() {
        struct FixedProvider: CalendarColorProviding {
            let fixed = CalendarColor(red: 0.9, green: 0.9, blue: 0.9)
            func color(for event: CalendarEventDTO) -> CalendarColor { fixed }
        }
        let e = event(id: "a", calendarName: "Work", color: nil)
        let defaultColor = DefaultCalendarColorProvider().color(for: e)
        let swapped = FixedProvider().color(for: e)
        XCTAssertNotEqual(defaultColor, swapped)
        XCTAssertEqual(swapped, CalendarColor(red: 0.9, green: 0.9, blue: 0.9))
    }
}
