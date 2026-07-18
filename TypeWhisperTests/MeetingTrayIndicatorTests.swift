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

    // MARK: - Countdown formatting (minutes / hours+minutes / whole hours / past-start "now")

    private let epoch = Date(timeIntervalSince1970: 1_000_000)

    func testCountdownMinutesFormUnderAnHour() {
        // 39 min out -> "in 39m" (the owner's reference case).
        let start = epoch.addingTimeInterval(39 * 60)
        XCTAssertEqual(MeetingTrayIndicator.countdown(start: start, now: epoch), "in 39m")
    }

    func testCountdownRoundsMinutesUp() {
        // 5 min 1 s out rounds up to 6.
        let start = epoch.addingTimeInterval(5 * 60 + 1)
        XCTAssertEqual(MeetingTrayIndicator.countdown(start: start, now: epoch), "in 6m")
    }

    func testCountdownHoursAndMinutesFormAboveAnHour() {
        // 1 h 5 m out -> "in 1h 5m".
        let start = epoch.addingTimeInterval(65 * 60)
        XCTAssertEqual(MeetingTrayIndicator.countdown(start: start, now: epoch), "in 1h 5m")
    }

    func testCountdownWholeHoursCollapseMinutes() {
        // Exactly 2 h out -> "in 2h", never "in 2h 0m".
        let start = epoch.addingTimeInterval(120 * 60)
        XCTAssertEqual(MeetingTrayIndicator.countdown(start: start, now: epoch), "in 2h")
    }

    func testCountdownPastStartIsNowForm() {
        // Start already reached (meeting in progress) -> localized "now", not a negative countdown.
        let started = epoch.addingTimeInterval(-30)
        XCTAssertEqual(MeetingTrayIndicator.countdown(start: started, now: epoch), "now")
        XCTAssertEqual(MeetingTrayIndicator.countdown(start: epoch, now: epoch), "now")
    }

    // MARK: - Tray label composition (Granola-style "<title> · <countdown>")

    func testTrayLabelJoinsTitleAndCountdown() {
        let start = epoch.addingTimeInterval(39 * 60)
        XCTAssertEqual(
            MeetingTrayIndicator.trayLabel(title: "test", start: start, now: epoch),
            "test · in 39m"
        )
    }

    func testTrayLabelTruncatesTitle() {
        let start = epoch.addingTimeInterval(5 * 60)
        let label = MeetingTrayIndicator.trayLabel(
            title: "Quarterly Planning And Roadmap Review",
            start: start,
            now: epoch,
            maxTitleLength: 10
        )
        XCTAssertTrue(label.contains("\u{2026}"), "expected an ellipsis, got \(label)")
        XCTAssertTrue(label.hasSuffix("in 5m"))
    }

    func testTrayLabelEmojiSafeTruncationUsesCharacters() {
        // Grapheme-cluster truncation: a flag emoji (multi-scalar) counts as one character and is not
        // split. 6 emoji, cap 5 -> 4 emoji + ellipsis == 5 characters.
        let title = String(repeating: "🇩🇪", count: 6)
        let out = MeetingTrayIndicator.truncatedTitle(title, maxLength: 5)
        XCTAssertEqual(out.count, 5)
        XCTAssertTrue(out.hasSuffix("\u{2026}"))
        XCTAssertEqual(String(out.prefix(4)), String(repeating: "🇩🇪", count: 4))
    }

    // MARK: - Recording precedence (recording label wins over the upcoming title)

    func testDisplayRecordingTakesPrecedenceOverUpcoming() {
        let upcoming = event(id: "soon", startsIn: 5 * 60, now: epoch)
        let display = MeetingTrayIndicator.display(
            isRecording: true,
            recordingTitle: "Standup",
            elapsedSeconds: 65,
            upcoming: upcoming,
            now: epoch
        )
        XCTAssertEqual(display, MeetingTrayIndicator.Display.recording(label: "Standup · 1:05"))
    }

    func testDisplayUpcomingWhenNotRecording() {
        let upcoming = event(id: "test", startsIn: 39 * 60, now: epoch)
        let display = MeetingTrayIndicator.display(
            isRecording: false,
            recordingTitle: "",
            elapsedSeconds: 0,
            upcoming: upcoming,
            now: epoch
        )
        XCTAssertEqual(display, MeetingTrayIndicator.Display.upcoming(label: "test · in 39m"))
    }

    func testDisplayIdleWhenNoRecordingAndNoUpcoming() {
        let display = MeetingTrayIndicator.display(
            isRecording: false,
            recordingTitle: "",
            elapsedSeconds: 0,
            upcoming: nil,
            now: epoch
        )
        XCTAssertEqual(display, MeetingTrayIndicator.Display.idle)
    }

    func testDisplayIdleWhenRecordingButTitleMissing() {
        // Recording flag with an empty title should not render a bare "· elapsed" label.
        let display = MeetingTrayIndicator.display(
            isRecording: true,
            recordingTitle: "",
            elapsedSeconds: 30,
            upcoming: nil,
            now: epoch
        )
        XCTAssertEqual(display, MeetingTrayIndicator.Display.idle)
    }

    // MARK: - Tray candidate window boundary (owner request 2: default 60-minute window)

    func testTrayCandidateShownJustInsideWindow() {
        // 59 min out -> inside the 60-minute tray window -> shown.
        let events = [event(id: "in59m", startsIn: 59 * 60, now: epoch)]
        XCTAssertEqual(MeetingTrayIndicator.trayCandidate(events: events, now: epoch)?.id, "in59m")
    }

    func testTrayCandidateHiddenJustOutsideWindow() {
        // 61 min out -> beyond the 60-minute tray window -> not shown.
        let events = [event(id: "in61m", startsIn: 61 * 60, now: epoch)]
        XCTAssertNil(MeetingTrayIndicator.trayCandidate(events: events, now: epoch))
    }

    func testTrayCandidatePrefersInProgressMeeting() {
        // An in-progress meeting (started 5 min ago, 30-min duration) wins over a soon-upcoming one.
        let inProgress = event(id: "current", startsIn: -5 * 60, now: epoch)
        let soon = event(id: "soon", startsIn: 5 * 60, now: epoch)
        let candidate = MeetingTrayIndicator.trayCandidate(events: [soon, inProgress], now: epoch)
        XCTAssertEqual(candidate?.id, "current")
    }

    func testTrayCandidateExcludesEndedAndAllDay() {
        // Ended (before now) and all-day events are never tray candidates.
        let ended = event(id: "ended", startsIn: -120 * 60, now: epoch)   // 2 h ago, 30-min duration
        let allDay = event(id: "allDay", startsIn: 10 * 60, allDay: true, now: epoch)
        XCTAssertNil(MeetingTrayIndicator.trayCandidate(events: [ended, allDay], now: epoch))
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
        for key in [
            "meetings.tray.upcoming.inMinutes",
            "meetings.tray.upcoming.inHours",
            "meetings.tray.upcoming.inHoursMinutes",
            "meetings.tray.countdown.now",
            "meetings.menu.recording",
            "meetings.menu.upcoming"
        ] {
            let en = try TestSupport.localizedCatalogValue(for: key, language: "en")
            let de = try TestSupport.localizedCatalogValue(for: key, language: "de")
            XCTAssertFalse(en.isEmpty, "missing EN for \(key)")
            XCTAssertFalse(de.isEmpty, "missing DE for \(key)")
        }
    }
}
