import XCTest
@testable import TypeWhisper

/// [Google Phase 1 · M5] `CalendarService.meetingProjection(for:)` carries the rich event detail
/// (`eventNotes` → `calendarNotes`, `conferencingURL`) onto the projection, and stays nil-safe for
/// events without it (spec §5 M5).
@MainActor
final class CalendarProjectionRichDetailTests: XCTestCase {
    private func makeEvent(
        eventNotes: String? = nil,
        conferencingURL: String? = nil
    ) -> CalendarEventDTO {
        CalendarEventDTO(
            id: "evt-1",
            title: "Weekly Sync",
            startDate: Date(timeIntervalSince1970: 1_000_000),
            endDate: Date(timeIntervalSince1970: 1_003_600),
            seriesID: "series-A",
            attendees: [Attendee(name: "Marco", email: "marco@example.com")],
            eventNotes: eventNotes,
            conferencingURL: conferencingURL
        )
    }

    func testProjectionCarriesNotesAndConferencingURL() {
        let event = makeEvent(
            eventNotes: "Agenda:\n1. Roadmap\n2. Hiring",
            conferencingURL: "https://meet.google.com/abc-defg-hij"
        )

        let projection = CalendarService.meetingProjection(for: event)

        XCTAssertEqual(projection.calendarNotes, "Agenda:\n1. Roadmap\n2. Hiring")
        XCTAssertEqual(projection.conferencingURL, "https://meet.google.com/abc-defg-hij")
        // The pre-M5 fields keep projecting unchanged alongside the new ones.
        XCTAssertEqual(projection.title, "Weekly Sync")
        XCTAssertEqual(projection.calendarEventID, "evt-1")
        XCTAssertEqual(projection.seriesID, "series-A")
        XCTAssertEqual(projection.attendees.count, 1)
    }

    func testProjectionIsNilSafeWithoutRichDetail() {
        let projection = CalendarService.meetingProjection(for: makeEvent())

        XCTAssertNil(projection.calendarNotes)
        XCTAssertNil(projection.conferencingURL)
    }
}
