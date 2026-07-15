import XCTest
@testable import TypeWhisper

/// Unit tests for the pure menu-bar meeting indicator logic (owner requests 3 & 4): title truncation,
/// elapsed formatting (matching the in-app live band), the upcoming lead-window detection, and EN+DE
/// coverage of the new user-facing strings.
final class MeetingTrayIndicatorTests: XCTestCase {

    // MARK: - Title truncation

    func testShortTitlePassesThroughUntruncated() {
        XCTAssertEqual(MeetingTrayIndicator.truncatedTitle("Standup", maxLength: 22), "Standup")
    }

    func testLongTitleIsTruncatedWithEllipsis() {
        let title = "Quarterly Planning And Roadmap Review"
        let out = MeetingTrayIndicator.truncatedTitle(title, maxLength: 10)
        XCTAssertTrue(out.hasSuffix("\u{2026}"), "expected an ellipsis, got \(out)")
        XCTAssertEqual(out.count, 10, "truncated length includes the ellipsis")
    }

    func testTitleAtBoundaryIsNotTruncated() {
        let title = String(repeating: "a", count: 22)
        XCTAssertEqual(MeetingTrayIndicator.truncatedTitle(title, maxLength: 22), title)
    }

    // MARK: - Elapsed formatting (must match the in-app live band exactly)

    func testElapsedMatchesLiveBandFormatting() {
        for seconds: TimeInterval in [0, 5, 65, 599, 3600, 3661, 7325] {
            XCTAssertEqual(
                MeetingTrayIndicator.elapsed(seconds),
                LiveRecordingBand.elapsedString(seconds),
                "tray elapsed must match the in-app live band for \(seconds)s"
            )
        }
    }

    func testElapsedUnderAnHourIsMinutesSeconds() {
        XCTAssertEqual(MeetingTrayIndicator.elapsed(65), "1:05")
    }

    func testElapsedOverAnHourIsHoursMinutesSeconds() {
        XCTAssertEqual(MeetingTrayIndicator.elapsed(3661), "1:01:01")
    }

    // MARK: - Recording label composition

    func testRecordingLabelJoinsTitleAndElapsed() {
        let label = MeetingTrayIndicator.recordingLabel(title: "Standup", elapsedSeconds: 65)
        XCTAssertEqual(label, "Standup · 1:05")
    }

    func testRecordingLabelTruncatesTitle() {
        let label = MeetingTrayIndicator.recordingLabel(
            title: "Quarterly Planning And Roadmap Review",
            elapsedSeconds: 5,
            maxTitleLength: 10
        )
        XCTAssertTrue(label.contains("\u{2026}"))
        XCTAssertTrue(label.hasSuffix("0:05"))
    }

    // MARK: - Minutes-until (rounds up, clamps to 1)

    func testMinutesUntilRoundsUp() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(MeetingTrayIndicator.minutesUntil(now.addingTimeInterval(300), now: now), 5)
        XCTAssertEqual(MeetingTrayIndicator.minutesUntil(now.addingTimeInterval(301), now: now), 6)
        XCTAssertEqual(MeetingTrayIndicator.minutesUntil(now.addingTimeInterval(30), now: now), 1)
        // Never "0m": a start already reached still clamps to 1.
        XCTAssertEqual(MeetingTrayIndicator.minutesUntil(now, now: now), 1)
    }

    // MARK: - Upcoming detection (lead-window over the existing upcoming events)

    private func event(id: String, startsIn seconds: TimeInterval, allDay: Bool = false, now: Date) -> CalendarEventDTO {
        let start = now.addingTimeInterval(seconds)
        return CalendarEventDTO(
            id: id,
            title: id,
            startDate: start,
            endDate: start.addingTimeInterval(1800),
            isAllDay: allDay
        )
    }

    func testNextUpcomingPicksSoonestFutureWithinWindow() {
        let now = Date(timeIntervalSince1970: 10_000)
        let events = [
            event(id: "in8m", startsIn: 8 * 60, now: now),
            event(id: "in3m", startsIn: 3 * 60, now: now),
            event(id: "in30m", startsIn: 30 * 60, now: now)
        ]
        let next = MeetingTrayIndicator.nextUpcoming(events: events, now: now, leadWindow: 10 * 60)
        XCTAssertEqual(next?.id, "in3m")
    }

    func testNextUpcomingExcludesInProgressAndAllDayAndOutOfWindow() {
        let now = Date(timeIntervalSince1970: 10_000)
        let events = [
            event(id: "started", startsIn: -60, now: now),       // already in progress
            event(id: "allDay", startsIn: 2 * 60, allDay: true, now: now),
            event(id: "farOff", startsIn: 45 * 60, now: now)     // beyond the lead window
        ]
        XCTAssertNil(MeetingTrayIndicator.nextUpcoming(events: events, now: now, leadWindow: 10 * 60))
    }

    func testUpcomingHintIsNilForInProgressEvent() {
        let now = Date(timeIntervalSince1970: 10_000)
        let started = event(id: "started", startsIn: -30, now: now)
        XCTAssertNil(MeetingTrayIndicator.upcomingHint(for: started, now: now))
    }

    func testUpcomingHintContainsMinutes() {
        let now = Date(timeIntervalSince1970: 10_000)
        let soon = event(id: "soon", startsIn: 5 * 60, now: now)
        let hint = MeetingTrayIndicator.upcomingHint(for: soon, now: now)
        XCTAssertNotNil(hint)
        XCTAssertTrue(hint?.contains("5") == true, "hint should include the minute count, got \(hint ?? "nil")")
    }

    // MARK: - Localization coverage

    func testNewTrayAndMenuStringsHaveEnglishAndGerman() throws {
        for key in ["meetings.tray.upcoming.inMinutes", "meetings.menu.recording", "meetings.menu.upcoming"] {
            let en = try TestSupport.localizedCatalogValue(for: key, language: "en")
            let de = try TestSupport.localizedCatalogValue(for: key, language: "de")
            XCTAssertFalse(en.isEmpty, "missing EN for \(key)")
            XCTAssertFalse(de.isEmpty, "missing DE for \(key)")
        }
    }
}
