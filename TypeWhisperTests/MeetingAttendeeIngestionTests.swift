import XCTest
@testable import TypeWhisper

/// [M2-Participants] `MeetingService`'s attendee choke points (`addAttendee`/`removeAttendee` +
/// `createMeeting`/`linkToCalendarEvent`) and their fold into the participant directory through the
/// `onAttendeesIngested` seam wired the way `ServiceContainer` wires it (plan D7).
@MainActor
final class MeetingAttendeeIngestionTests: XCTestCase {
    private func makeWired() throws -> (MeetingService, ParticipantDirectoryService, URL) {
        let dir = try TestSupport.makeTemporaryDirectory()
        let meetingService = MeetingService(appSupportDirectory: dir)
        let directory = ParticipantDirectoryService(appSupportDirectory: dir)
        meetingService.onAttendeesIngested = { [weak directory] attendees in
            directory?.ingest(attendees)
        }
        return (meetingService, directory, dir)
    }

    func testAddAttendeeRoundTripAndIngests() throws {
        let (meetingService, directory, dir) = try makeWired()
        defer { TestSupport.remove(dir) }
        let meeting = meetingService.createMeeting(title: "Ad-hoc", source: .adHoc)

        XCTAssertTrue(meetingService.addAttendee(Attendee(name: "Alice", email: "alice@x.com"), to: meeting))
        XCTAssertEqual(meeting.attendees.map(\.name), ["Alice"])
        XCTAssertEqual(directory.persons.map(\.emailKey), ["alice@x.com"])
    }

    func testAddAttendeeDeduplicates() throws {
        let (meetingService, directory, dir) = try makeWired()
        defer { TestSupport.remove(dir) }
        let meeting = meetingService.createMeeting(title: "Ad-hoc", source: .adHoc)

        XCTAssertTrue(meetingService.addAttendee(Attendee(name: "Alice", email: "alice@x.com"), to: meeting))
        XCTAssertFalse(
            meetingService.addAttendee(Attendee(name: "Alice", email: "alice@x.com"), to: meeting),
            "re-adding the same attendee is a no-op"
        )
        XCTAssertEqual(meeting.attendees.count, 1)
        XCTAssertEqual(directory.persons.count, 1)
    }

    func testRemoveAttendeeKeepsPerson() throws {
        let (meetingService, directory, dir) = try makeWired()
        defer { TestSupport.remove(dir) }
        let meeting = meetingService.createMeeting(title: "Ad-hoc", source: .adHoc)
        let alice = Attendee(name: "Alice", email: "alice@x.com")
        meetingService.addAttendee(alice, to: meeting)
        XCTAssertEqual(directory.persons.count, 1)

        XCTAssertTrue(meetingService.removeAttendee(alice, from: meeting))
        XCTAssertTrue(meeting.attendees.isEmpty)
        XCTAssertEqual(directory.persons.count, 1, "removing an attendee must never delete the Person")

        XCTAssertFalse(meetingService.removeAttendee(alice, from: meeting), "removing again is a no-op")
    }

    func testCreateMeetingWithAttendeesIngests() throws {
        let (meetingService, directory, dir) = try makeWired()
        defer { TestSupport.remove(dir) }
        meetingService.createMeeting(
            title: "Kickoff",
            attendees: [Attendee(name: "Alice", email: "alice@x.com"), Attendee(name: "Bob")]
        )
        XCTAssertEqual(directory.persons.count, 2)
    }

    func testLinkToCalendarEventIngests() throws {
        let (meetingService, directory, dir) = try makeWired()
        defer { TestSupport.remove(dir) }
        let meeting = meetingService.createMeeting(title: "Ad-hoc", source: .adHoc)
        XCTAssertTrue(directory.persons.isEmpty)

        meetingService.linkToCalendarEvent(
            calendarEventID: "evt-1",
            seriesID: nil,
            title: "Linked",
            startDate: Date(),
            endDate: nil,
            attendees: [Attendee(name: "Carol", email: "carol@x.com")],
            for: meeting
        )
        XCTAssertEqual(directory.persons.map(\.emailKey), ["carol@x.com"])
    }
}
