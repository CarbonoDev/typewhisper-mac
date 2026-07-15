import XCTest
@testable import TypeWhisper

/// Unit tests for the end-of-meeting stop reminder trigger predicate (owner request 2). The
/// notification center is nil under tests, so the once-per-session / no-event-exclusion / past-end
/// logic is exercised directly via `shouldRemind` and `evaluate` with an injected clock.
@MainActor
final class MeetingEndReminderServiceTests: XCTestCase {
    private func service() -> MeetingEndReminderService {
        MeetingEndReminderService(center: nil)
    }

    private let end = Date(timeIntervalSince1970: 1_000_000)

    func testDoesNotRemindBeforeScheduledEnd() {
        let s = service()
        XCTAssertFalse(s.shouldRemind(
            calendarEventID: "evt-1",
            scheduledEnd: end,
            isRecording: true,
            sessionKey: "m1",
            now: end.addingTimeInterval(-60)
        ))
    }

    func testRemindsWhenEndPassedWhileRecording() {
        let s = service()
        XCTAssertTrue(s.shouldRemind(
            calendarEventID: "evt-1",
            scheduledEnd: end,
            isRecording: true,
            sessionKey: "m1",
            now: end
        ), "the reminder fires the moment now reaches the scheduled end")
        XCTAssertTrue(s.shouldRemind(
            calendarEventID: "evt-1",
            scheduledEnd: end,
            isRecording: true,
            sessionKey: "m1",
            now: end.addingTimeInterval(120)
        ))
    }

    func testAdHocMeetingWithoutEventIsExcluded() {
        let s = service()
        // No linked calendar event → no "meeting time" to have ended, even well past the (absent) end.
        XCTAssertFalse(s.shouldRemind(
            calendarEventID: nil,
            scheduledEnd: end,
            isRecording: true,
            sessionKey: "m1",
            now: end.addingTimeInterval(300)
        ))
    }

    func testMissingScheduledEndIsExcluded() {
        let s = service()
        XCTAssertFalse(s.shouldRemind(
            calendarEventID: "evt-1",
            scheduledEnd: nil,
            isRecording: true,
            sessionKey: "m1",
            now: end.addingTimeInterval(300)
        ))
    }

    func testNotRecordingIsExcluded() {
        let s = service()
        XCTAssertFalse(s.shouldRemind(
            calendarEventID: "evt-1",
            scheduledEnd: end,
            isRecording: false,
            sessionKey: "m1",
            now: end.addingTimeInterval(300)
        ))
    }

    func testFiresOnlyOncePerSession() {
        let s = service()
        // First evaluate claims the session (posts a no-op under the nil center).
        s.evaluate(
            meetingTitle: "Acme Sync",
            calendarEventID: "evt-1",
            scheduledEnd: end,
            isRecording: true,
            sessionKey: "m1",
            now: end
        )
        XCTAssertTrue(s.hasReminded(sessionKey: "m1"))
        // Subsequent ticks for the same session must not re-fire.
        XCTAssertFalse(s.shouldRemind(
            calendarEventID: "evt-1",
            scheduledEnd: end,
            isRecording: true,
            sessionKey: "m1",
            now: end.addingTimeInterval(5)
        ))
    }

    func testDifferentSessionRemindsIndependently() {
        let s = service()
        s.evaluate(
            meetingTitle: "Acme Sync",
            calendarEventID: "evt-1",
            scheduledEnd: end,
            isRecording: true,
            sessionKey: "m1",
            now: end
        )
        // A different meeting (different session key) is still eligible.
        XCTAssertTrue(s.shouldRemind(
            calendarEventID: "evt-2",
            scheduledEnd: end,
            isRecording: true,
            sessionKey: "m2",
            now: end
        ))
    }

    func testEndedBodyHasEnglishAndGermanLocalizations() throws {
        let en = try TestSupport.localizedCatalogValue(for: "meetings.notification.ended.body", language: "en")
        let de = try TestSupport.localizedCatalogValue(for: "meetings.notification.ended.body", language: "de")
        XCTAssertFalse(en.isEmpty)
        XCTAssertFalse(de.isEmpty)
        XCTAssertNotEqual(en, de)
    }
}
