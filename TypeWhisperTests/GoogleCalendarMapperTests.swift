import XCTest
@testable import TypeWhisper

/// Pure Google-JSON → `CalendarInfo`/`CalendarEventDTO` mapping over fixture JSON (spec M3):
/// D-G3 namespacing, all-day handling, cancelled-instance dropping, the D-G8 seriesID rule,
/// conference-URL precedence, attendee mapping, HTML-stripped notes, hex-color parsing, and the
/// normative calendar-attribution invariant (every DTO carries non-nil calendarID/Name/Color).
final class GoogleCalendarMapperTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    // MARK: - Fixtures

    private func decodeEvent(_ json: String) throws -> GoogleCalendarAPI.GCalEvent {
        try JSONDecoder().decode(GoogleCalendarAPI.GCalEvent.self, from: Data(json.utf8))
    }

    private func decodeCalendarEntry(_ json: String) throws -> GoogleCalendarAPI.GCalCalendarListEntry {
        try JSONDecoder().decode(GoogleCalendarAPI.GCalCalendarListEntry.self, from: Data(json.utf8))
    }

    private func fixtureCalendar() throws -> CalendarInfo {
        let entry = try decodeCalendarEntry(#"""
        {"id": "work@group.calendar.google.com", "summary": "Work", "backgroundColor": "#9fe1e7", "accessRole": "owner"}
        """#)
        return GoogleCalendarMapper.calendarInfo(from: entry, sub: "sub-1", accountEmail: "ada@example.com")
    }

    private func mapped(_ eventJSON: String) throws -> CalendarEventDTO? {
        let calendar = try fixtureCalendar()
        return GoogleCalendarMapper.eventDTO(
            from: try decodeEvent(eventJSON),
            calendar: calendar,
            sub: "sub-1",
            accountEmail: "ada@example.com",
            allDayTimeZone: utc
        )
    }

    private static let baseTimedEvent = #"""
    {"id": "evt-1", "status": "confirmed", "summary": "Design sync",
     "start": {"dateTime": "2026-08-10T10:00:00Z"}, "end": {"dateTime": "2026-08-10T11:00:00Z"}}
    """#

    // MARK: - CalendarInfo

    func testCalendarInfoNamespacingSourceAndColor() throws {
        let info = try fixtureCalendar()
        XCTAssertEqual(info.id, "google:sub-1:work@group.calendar.google.com", "D-G3 namespaced calendar ID")
        XCTAssertEqual(info.title, "Work")
        XCTAssertEqual(info.sourceName, "ada@example.com", "sourceName = account email drives split-by-account")
        XCTAssertEqual(info.color.red, Double(0x9F) / 255, accuracy: 0.001)
        XCTAssertEqual(info.color.green, Double(0xE1) / 255, accuracy: 0.001)
        XCTAssertEqual(info.color.blue, Double(0xE7) / 255, accuracy: 0.001)
    }

    func testCalendarInfoColorFallbackAndTitleFallback() throws {
        let noColor = try decodeCalendarEntry(#"{"id": "ada@example.com", "primary": true}"#)
        let info = GoogleCalendarMapper.calendarInfo(from: noColor, sub: "sub-1", accountEmail: "ada@example.com")
        XCTAssertEqual(info.color, .fallback, "absent backgroundColor falls back")
        XCTAssertEqual(info.title, "ada@example.com", "missing summary falls back to the raw calendar ID")

        XCTAssertNil(GoogleCalendarMapper.color(fromHex: "zzz"))
        XCTAssertNil(GoogleCalendarMapper.color(fromHex: nil))
        XCTAssertNotNil(GoogleCalendarMapper.color(fromHex: "9fe1e7"), "leading # is optional")
    }

    // MARK: - Event basics

    func testEventIDIsNamespacedAndDatesParsed() throws {
        let dto = try XCTUnwrap(mapped(Self.baseTimedEvent))
        XCTAssertEqual(dto.id, "google:sub-1:evt-1", "D-G3 namespaced event ID")
        XCTAssertEqual(dto.title, "Design sync")
        XCTAssertFalse(dto.isAllDay)
        // Anchor exact instants via the same RFC 3339 parser contract:
        XCTAssertEqual(dto.startDate, GoogleCalendarAPI.date(fromRFC3339: "2026-08-10T10:00:00Z"))
        XCTAssertEqual(dto.endDate, GoogleCalendarAPI.date(fromRFC3339: "2026-08-10T11:00:00Z"))
    }

    func testTimedEventWithUTCOffsetParses() throws {
        let dto = try XCTUnwrap(mapped(#"""
        {"id": "evt-tz", "status": "confirmed", "summary": "Offset",
         "start": {"dateTime": "2026-08-10T10:00:00-06:00"}, "end": {"dateTime": "2026-08-10T11:00:00-06:00"}}
        """#))
        XCTAssertEqual(dto.startDate, GoogleCalendarAPI.date(fromRFC3339: "2026-08-10T16:00:00Z"))
    }

    func testCancelledInstanceIsDropped() throws {
        XCTAssertNil(try mapped(#"""
        {"id": "evt-x", "status": "cancelled",
         "start": {"dateTime": "2026-08-10T10:00:00Z"}, "end": {"dateTime": "2026-08-10T11:00:00Z"}}
        """#))
    }

    func testEventWithoutParseableDatesIsDropped() throws {
        XCTAssertNil(try mapped(#"{"id": "evt-broken", "status": "confirmed", "summary": "No dates"}"#))
    }

    func testAllDayEvent() throws {
        let dto = try XCTUnwrap(mapped(#"""
        {"id": "evt-allday", "status": "confirmed", "summary": "Offsite",
         "start": {"date": "2026-08-10"}, "end": {"date": "2026-08-11"}}
        """#))
        XCTAssertTrue(dto.isAllDay, "date-only start means all-day")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        XCTAssertEqual(dto.startDate, calendar.date(from: DateComponents(year: 2026, month: 8, day: 10)))
        XCTAssertEqual(dto.endDate, calendar.date(from: DateComponents(year: 2026, month: 8, day: 11)))
    }

    // MARK: - Calendar attribution (normative, spec M3)

    func testEveryDTOCarriesCalendarAttribution() throws {
        // `republish()` treats calendarID == nil as always-selected, so an unset calendarID would
        // make Google events un-deselectable; calendarName feeds capture-context rules.
        let calendar = try fixtureCalendar()
        let dto = try XCTUnwrap(mapped(Self.baseTimedEvent))
        XCTAssertNotNil(dto.calendarID)
        XCTAssertNotNil(dto.calendarName)
        XCTAssertNotNil(dto.calendarColor)
        XCTAssertEqual(dto.calendarID, calendar.id, "namespaced owning-calendar ID")
        XCTAssertEqual(dto.calendarName, calendar.title)
        XCTAssertEqual(dto.calendarColor, calendar.color)
        XCTAssertEqual(dto.accountLabel, "ada@example.com")
    }

    // MARK: - Series ID (D-G8)

    func testRecurringInstanceCarriesBareICalUIDAsSeriesID() throws {
        let dto = try XCTUnwrap(mapped(#"""
        {"id": "series1_20260810T100000Z", "status": "confirmed", "summary": "Weekly",
         "recurringEventId": "series1", "iCalUID": "series1@google.com",
         "start": {"dateTime": "2026-08-10T10:00:00Z"}, "end": {"dateTime": "2026-08-10T11:00:00Z"}}
        """#))
        XCTAssertEqual(dto.seriesID, "series1@google.com", "bare iCalUID — deliberately NOT namespaced (D-G8)")
        XCTAssertFalse(dto.seriesID!.hasPrefix("google:"))
    }

    func testNonRecurringEventHasNilSeriesID() throws {
        let dto = try XCTUnwrap(mapped(#"""
        {"id": "evt-1", "status": "confirmed", "summary": "One-off", "iCalUID": "oneoff@google.com",
         "start": {"dateTime": "2026-08-10T10:00:00Z"}, "end": {"dateTime": "2026-08-10T11:00:00Z"}}
        """#))
        XCTAssertNil(dto.seriesID, "matches the EventKit provider's recurring-only rule")
    }

    // MARK: - Conference URL precedence

    func testConferenceDataVideoEntryBeatsHangoutLink() throws {
        let dto = try XCTUnwrap(mapped(#"""
        {"id": "evt-1", "status": "confirmed", "summary": "Call",
         "hangoutLink": "https://meet.google.com/legacy",
         "conferenceData": {"entryPoints": [
            {"entryPointType": "phone", "uri": "tel:+1-555-0100"},
            {"entryPointType": "video", "uri": "https://meet.google.com/abc-defg-hij"}]},
         "start": {"dateTime": "2026-08-10T10:00:00Z"}, "end": {"dateTime": "2026-08-10T11:00:00Z"}}
        """#))
        XCTAssertEqual(dto.conferencingURL, "https://meet.google.com/abc-defg-hij")
    }

    func testHangoutLinkFallbackWhenNoVideoEntryPoint() throws {
        let dto = try XCTUnwrap(mapped(#"""
        {"id": "evt-1", "status": "confirmed", "summary": "Call",
         "hangoutLink": "https://meet.google.com/legacy",
         "conferenceData": {"entryPoints": [{"entryPointType": "phone", "uri": "tel:+1-555-0100"}]},
         "start": {"dateTime": "2026-08-10T10:00:00Z"}, "end": {"dateTime": "2026-08-10T11:00:00Z"}}
        """#))
        XCTAssertEqual(dto.conferencingURL, "https://meet.google.com/legacy")
    }

    func testNoConferenceInformationYieldsNil() throws {
        let dto = try XCTUnwrap(mapped(Self.baseTimedEvent))
        XCTAssertNil(dto.conferencingURL)
    }

    // MARK: - Attendees

    func testAttendeeMappingIncludingSelfOrganizerAndResponseStatus() throws {
        let dto = try XCTUnwrap(mapped(#"""
        {"id": "evt-1", "status": "confirmed", "summary": "Sync",
         "attendees": [
            {"email": "ada@example.com", "displayName": "Ada Lovelace", "self": true, "organizer": true, "responseStatus": "accepted"},
            {"email": "grace@example.com", "responseStatus": "tentative"},
            {"displayName": "Room 4"}],
         "start": {"dateTime": "2026-08-10T10:00:00Z"}, "end": {"dateTime": "2026-08-10T11:00:00Z"}}
        """#))
        XCTAssertEqual(dto.attendees.count, 3)

        let ada = dto.attendees[0]
        XCTAssertEqual(ada.name, "Ada Lovelace")
        XCTAssertEqual(ada.email, "ada@example.com")
        XCTAssertEqual(ada.isSelf, true)
        XCTAssertEqual(ada.isOrganizer, true)
        XCTAssertEqual(ada.responseStatusRaw, "accepted")
        XCTAssertEqual(ada.responseStatus, .accepted)

        let grace = dto.attendees[1]
        XCTAssertEqual(grace.name, "grace@example.com", "missing displayName falls back to email")
        XCTAssertNil(grace.isSelf, "non-self stays nil (EventKit convention: only true is stored)")
        XCTAssertNil(grace.isOrganizer)
        XCTAssertEqual(grace.responseStatus, .tentative)

        let room = dto.attendees[2]
        XCTAssertEqual(room.name, "Room 4")
        XCTAssertNil(room.email)
        XCTAssertNil(room.responseStatus)
    }

    func testResourceAttendeesAreExcludedFromTheRoster() throws {
        // Real room-booking shape (PR #7 review finding 6): rooms and equipment arrive as
        // attendees flagged `resource: true` and must never reach the participants directory.
        let dto = try XCTUnwrap(mapped(#"""
        {"id": "evt-1", "status": "confirmed", "summary": "Sync",
         "attendees": [
            {"email": "ada@example.com", "displayName": "Ada Lovelace", "self": true, "organizer": true, "responseStatus": "accepted"},
            {"email": "c_188abcdef@resource.calendar.google.com", "displayName": "Conf Room 3 (10)", "resource": true, "responseStatus": "accepted"},
            {"email": "projector@resource.calendar.google.com", "displayName": "Projector", "resource": true, "responseStatus": "needsAction"},
            {"email": "grace@example.com", "responseStatus": "tentative"}],
         "start": {"dateTime": "2026-08-10T10:00:00Z"}, "end": {"dateTime": "2026-08-10T11:00:00Z"}}
        """#))

        XCTAssertEqual(
            dto.attendees.map(\.name),
            ["Ada Lovelace", "grace@example.com"],
            "rooms and equipment are not participants"
        )
    }

    func testAttendeeWithoutResourceFlagIsStillAPerson() throws {
        // `resource` absent (the common case) and `resource: false` both mean "human".
        let dto = try XCTUnwrap(mapped(#"""
        {"id": "evt-1", "status": "confirmed", "summary": "Sync",
         "attendees": [
            {"email": "grace@example.com", "resource": false},
            {"displayName": "Room 4"}],
         "start": {"dateTime": "2026-08-10T10:00:00Z"}, "end": {"dateTime": "2026-08-10T11:00:00Z"}}
        """#))
        XCTAssertEqual(dto.attendees.map(\.name), ["grace@example.com", "Room 4"])
    }

    // MARK: - Notes (HTML → plain text)

    func testEventNotesAreHTMLStripped() throws {
        let dto = try XCTUnwrap(mapped(#"""
        {"id": "evt-1", "status": "confirmed", "summary": "Sync",
         "description": "<p>Agenda:</p><ul><li>Roadmap &amp; budget</li><li>Q&amp;A</li></ul><br>See you!",
         "start": {"dateTime": "2026-08-10T10:00:00Z"}, "end": {"dateTime": "2026-08-10T11:00:00Z"}}
        """#))
        let notes = try XCTUnwrap(dto.eventNotes)
        XCTAssertFalse(notes.contains("<"), "no tags survive")
        XCTAssertTrue(notes.contains("Agenda:"))
        XCTAssertTrue(notes.contains("Roadmap & budget"), "entities decoded")
        XCTAssertTrue(notes.contains("See you!"))
    }

    func testPlainTextDescriptionPassesThroughAndEmptyBecomesNil() throws {
        let plain = try XCTUnwrap(mapped(#"""
        {"id": "evt-1", "status": "confirmed", "summary": "Sync", "description": "Just plain text",
         "start": {"dateTime": "2026-08-10T10:00:00Z"}, "end": {"dateTime": "2026-08-10T11:00:00Z"}}
        """#))
        XCTAssertEqual(plain.eventNotes, "Just plain text")

        let noNotes = try XCTUnwrap(mapped(Self.baseTimedEvent))
        XCTAssertNil(noNotes.eventNotes)

        let blank = try XCTUnwrap(mapped(#"""
        {"id": "evt-1", "status": "confirmed", "summary": "Sync", "description": "  ",
         "start": {"dateTime": "2026-08-10T10:00:00Z"}, "end": {"dateTime": "2026-08-10T11:00:00Z"}}
        """#))
        XCTAssertNil(blank.eventNotes, "whitespace-only notes collapse to nil")
    }

    // MARK: - Notes: angle-bracketed plain text (PR #7 review finding 8)

    func testAngleBracketedPlainTextSurvivesUntouched() throws {
        let dto = try XCTUnwrap(mapped(#"""
        {"id": "evt-1", "status": "confirmed", "summary": "Sync",
         "description": "Dial-in host John <john@example.com>, budget < 5000 > target",
         "start": {"dateTime": "2026-08-10T10:00:00Z"}, "end": {"dateTime": "2026-08-10T11:00:00Z"}}
        """#))
        XCTAssertEqual(
            dto.eventNotes,
            "Dial-in host John <john@example.com>, budget < 5000 > target",
            "non-HTML angle-bracketed text must not be stripped — the notes are snapshotted forever"
        )
    }

    func testPlainTextHeuristicAndStrippingBoundaries() {
        XCTAssertFalse(GoogleCalendarMapper.looksLikeHTML("John <john@example.com>"))
        XCTAssertFalse(GoogleCalendarMapper.looksLikeHTML("budget < 5000 > target"))
        XCTAssertFalse(GoogleCalendarMapper.looksLikeHTML("a <-- b"))
        XCTAssertTrue(GoogleCalendarMapper.looksLikeHTML("<p>hi</p>"))
        XCTAssertTrue(GoogleCalendarMapper.looksLikeHTML("line<br>break"))
        XCTAssertTrue(GoogleCalendarMapper.looksLikeHTML(#"<a href="https://x.example">link</a>"#))

        // Real HTML still reduces to plain text …
        XCTAssertEqual(
            GoogleCalendarMapper.plainText(fromHTML: "<div>Agenda</div><br>Notes &amp; more"),
            "Agenda\n\nNotes & more"
        )
        // … and inside real HTML, an escaped address is decoded rather than deleted.
        XCTAssertEqual(
            GoogleCalendarMapper.plainText(fromHTML: "<p>Host John &lt;john@example.com&gt;</p>"),
            "Host John <john@example.com>"
        )
        // Mixed content: the tag goes, the non-tag angle brackets stay.
        XCTAssertEqual(
            GoogleCalendarMapper.plainText(fromHTML: "<b>Budget</b> < 5000 > target"),
            "Budget < 5000 > target"
        )
        // Entities still decode in plain text, `&amp;` last so `&amp;lt;` never double-decodes.
        XCTAssertEqual(GoogleCalendarMapper.plainText(fromHTML: "A &amp;lt; B"), "A &lt; B")
    }

    // MARK: - GoogleCalendarID

    func testAccountSubRoundTrip() {
        let id = GoogleCalendarID.eventID(sub: "sub-42", raw: "evt_20260810")
        XCTAssertEqual(id, "google:sub-42:evt_20260810")
        XCTAssertEqual(GoogleCalendarID.accountSub(fromNamespacedID: id), "sub-42")
        XCTAssertNil(GoogleCalendarID.accountSub(fromNamespacedID: "ABC-123-UUID"), "bare EventKit IDs parse to nil")
        XCTAssertNil(GoogleCalendarID.accountSub(fromNamespacedID: "google::raw"), "empty sub is invalid")
    }
}
