import XCTest
@testable import TypeWhisper

/// Unit tests for the meeting-start notification body composition (plan AD9 / Track D). The
/// notification center is nil under tests, so the body-building logic is exercised directly via
/// `notificationBody(for:now:)`.
@MainActor
final class MeetingStartNotificationServiceTests: XCTestCase {
    private func event(id: String = "evt-1", title: String = "Acme Sync") -> CalendarEventDTO {
        let start = Date()
        return CalendarEventDTO(
            id: id,
            title: title,
            startDate: start,
            endDate: start.addingTimeInterval(1800)
        )
    }

    private var briefReadyLine: String {
        String(localized: "meetings.brief.auto.notification.briefReady")
    }

    private func baseBody(for event: CalendarEventDTO) -> String {
        String(format: String(localized: "meetings.notification.starting.body"), event.title)
    }

    func testBodyOmitsBriefLineWhenLookupIsNil() {
        let service = MeetingStartNotificationService(center: nil)
        // No lookup injected (v1 behavior).
        let evt = event()
        let body = service.notificationBody(for: evt)
        XCTAssertEqual(body, baseBody(for: evt))
        XCTAssertFalse(body.contains(briefReadyLine))
    }

    func testBodyOmitsBriefLineWhenLookupReturnsFalse() {
        let service = MeetingStartNotificationService(center: nil)
        service.freshBriefLookup = { _, _ in false }
        let evt = event()
        let body = service.notificationBody(for: evt)
        XCTAssertEqual(body, baseBody(for: evt))
        XCTAssertFalse(body.contains(briefReadyLine))
    }

    func testBodyAppendsBriefLineWhenLookupReturnsTrue() {
        let service = MeetingStartNotificationService(center: nil)
        var receivedID: String?
        service.freshBriefLookup = { id, _ in
            receivedID = id
            return true
        }
        let evt = event(id: "evt-fresh")
        let body = service.notificationBody(for: evt)
        XCTAssertTrue(body.hasPrefix(baseBody(for: evt)))
        XCTAssertTrue(body.contains(briefReadyLine))
        XCTAssertEqual(receivedID, "evt-fresh", "lookup must be keyed by the event id")
    }
}
