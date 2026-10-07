import XCTest
@testable import TypeWhisper

@MainActor
final class LiveSessionEventMatcherTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let code = "abc-defg-hij"

    private func event(
        _ id: String,
        title: String = "Sprint Planning",
        startOffset: TimeInterval,
        duration: TimeInterval = 3600,
        url: String? = nil
    ) -> CalendarEventDTO {
        let start = now.addingTimeInterval(startOffset)
        return CalendarEventDTO(
            id: id,
            title: title,
            startDate: start,
            endDate: start.addingTimeInterval(duration),
            conferencingURL: url
        )
    }

    private func match(
        _ events: [CalendarEventDTO],
        sessionKey: String? = "zzz-zzzz-zzz",
        title: String? = "Sprint Planning"
    ) -> (event: CalendarEventDTO, score: Double)? {
        LiveSessionEventMatcher.bestMatch(sessionKey: sessionKey, title: title, sessionStart: now, events: events)
    }

    // MARK: - Meet code

    func testMeetCodeMatchWinsOverBetterTitledEvent() {
        let titled = event("titled", title: "Sprint Planning", startOffset: 0)
        let coded = event("coded", title: "Something Else", startOffset: 0, url: "https://meet.google.com/\(code)")
        let result = match([titled, coded], sessionKey: code)
        XCTAssertEqual(result?.event.id, "coded")
        XCTAssertEqual(result?.score, LiveSessionEventMatcher.meetCodeMatchConfidence)
    }

    func testAmongSameCodeOccurrencesNearestStartWins() {
        let url = "https://meet.google.com/\(code)"
        let earlier = event("earlier", startOffset: -40 * 60, url: url)
        let current = event("current", startOffset: 5 * 60, url: url)
        XCTAssertEqual(match([earlier, current], sessionKey: code)?.event.id, "current")
    }

    func testCodeMatchOnAnotherDayIsNil() {
        let tomorrow = event("tomorrow", title: "Other", startOffset: 24 * 3600, url: "https://meet.google.com/\(code)")
        XCTAssertNil(match([tomorrow], sessionKey: code, title: nil))
    }

    func testCodeMatchToleratesURLVariants() {
        let variants = [
            "https://meet.google.com/abc-defg-hij?authuser=1",
            "meet.google.com/abc-defg-hij",
            "https://meet.google.com/ABC-DEFG-HIJ/",
            "http://meet.google.com/abc-defg-hij#x"
        ]
        for url in variants {
            XCTAssertEqual(LiveSessionEventMatcher.meetCode(fromConferencingURL: url), "abc-defg-hij", url)
            let coded = event("coded", title: "Unrelated", startOffset: 0, url: url)
            XCTAssertEqual(match([coded], sessionKey: "ABC-defg-hij", title: nil)?.event.id, "coded", url)
        }
        XCTAssertNil(LiveSessionEventMatcher.meetCode(fromConferencingURL: "https://zoom.us/j/123"))
        XCTAssertNil(LiveSessionEventMatcher.meetCode(fromConferencingURL: "https://meet.google.com/"))
    }

    // MARK: - Title within the live window

    func testExactTitle24HoursAwayIsNil() {
        XCTAssertNil(match([event("tomorrow", startOffset: 24 * 3600)]))
        XCTAssertNil(match([event("yesterday", startOffset: -24 * 3600)]))
    }

    func testExactTitleStartingIn10MinutesMatches() {
        XCTAssertEqual(match([event("soon", startOffset: 10 * 60)])?.event.id, "soon")
    }

    func testExactTitleStartingIn30MinutesIsNil() {
        XCTAssertNil(match([event("later", startOffset: 30 * 60)]))
    }

    func testInProgressEventMatches() {
        XCTAssertEqual(match([event("running", startOffset: -40 * 60)])?.event.id, "running")
    }

    func testEventEnded20MinutesAgoMatches() {
        let ended = event("ended", startOffset: -80 * 60, duration: 3600)
        XCTAssertEqual(match([ended])?.event.id, "ended")
    }

    func testEventEnded3HoursAgoIsNil() {
        let ended = event("ended", startOffset: -4 * 3600, duration: 3600)
        XCTAssertNil(match([ended]))
    }

    func testUnrelatedTitleInWindowIsNil() {
        XCTAssertNil(match([event("other", title: "Dentist", startOffset: 0)]))
    }

    func testNoTitleAndNoCodeMatchIsNil() {
        XCTAssertNil(match([event("now", startOffset: 0)], title: nil))
    }

    func testRecurringTitleLinksTodayNotTomorrow() {
        // The 2026-10-07 regression: a call ending at 11:04 linked to tomorrow's 11:00 occurrence.
        let today = event("today", startOffset: -60 * 60)
        let tomorrow = event("tomorrow", startOffset: 23 * 3600)
        XCTAssertEqual(match([tomorrow, today])?.event.id, "today")
    }
}
