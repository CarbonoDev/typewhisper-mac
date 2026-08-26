import XCTest
@testable import TypeWhisper

/// [M3-Participants] Directory-backed prior-meeting matching (plan D8) and display-time rename
/// resolution (plan D6). Both operate over a `MeetingService` wired to a `ParticipantDirectoryService`
/// exactly the way `ServiceContainer` wires them (ingest seam + `resolvePersonIDs` seam).
@MainActor
final class ParticipantDirectoryMatchingTests: XCTestCase {
    private func makeWired() throws -> (MeetingService, ParticipantDirectoryService, URL) {
        let dir = try TestSupport.makeTemporaryDirectory()
        let meetingService = MeetingService(appSupportDirectory: dir)
        let directory = ParticipantDirectoryService(appSupportDirectory: dir)
        meetingService.onAttendeesIngested = { [weak directory] attendees in
            directory?.ingest(attendees)
        }
        meetingService.resolvePersonIDs = { [weak directory] attendees in
            directory?.resolvePersonIDs(for: attendees) ?? []
        }
        return (meetingService, directory, dir)
    }

    // MARK: - Prior-matching over the email-less archive (plan D8)

    func testPriorMeetingsUnionOnEmaillessArchive() throws {
        let (meetingService, directory, dir) = try makeWired()
        defer { TestSupport.remove(dir) }

        // Two imported, email-LESS meetings that share only a name — the owner's archive shape.
        let older = meetingService.createMeeting(
            title: "1:1 (imported)",
            source: .importedTranscript,
            attendees: [Attendee(name: "Alex")]
        )
        let newer = meetingService.createMeeting(
            title: "1:1 follow-up",
            source: .importedTranscript,
            attendees: [Attendee(name: "Alex")]
        )

        // The directory unified the two "Alex" attendees into one provisional person.
        XCTAssertEqual(directory.persons.count, 1)

        let related = meetingService.priorMeetings(matching: newer)
        XCTAssertTrue(
            related.contains { $0.id == older.id },
            "an email-less archive meeting surfaces its sibling via shared resolved Person identity"
        )
    }

    func testPriorMeetingsUnionViaResolverFactorySeam() throws {
        // [M4 — M3 review minor] `ServiceContainer` wires the factory seam so `priorMeetings` builds the
        // directory resolution index once per query and reuses it for the target + every candidate
        // (was O(meetings × persons) on the MainActor). The union result must be identical to the
        // per-call seam.
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let meetingService = MeetingService(appSupportDirectory: dir)
        let directory = ParticipantDirectoryService(appSupportDirectory: dir)
        meetingService.onAttendeesIngested = { [weak directory] attendees in
            directory?.ingest(attendees)
        }
        // Wire the factory seam ONLY (leave the per-call seam nil) so this test exercises the factory path.
        meetingService.makePersonIDResolver = { [weak directory] in
            directory?.makePersonIDResolver() ?? { _ in [] }
        }

        let older = meetingService.createMeeting(
            title: "1:1 (imported)", source: .importedTranscript, attendees: [Attendee(name: "Alex")]
        )
        let newer = meetingService.createMeeting(
            title: "1:1 follow-up", source: .importedTranscript, attendees: [Attendee(name: "Alex")]
        )
        XCTAssertEqual(directory.persons.count, 1)

        let related = meetingService.priorMeetings(matching: newer)
        XCTAssertTrue(
            related.contains { $0.id == older.id },
            "the factory seam resolves the same shared-identity union as the per-call seam"
        )
    }

    func testPriorMeetingsUnwiredSeamFallsBackToEmailOrSeries() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        // No directory wiring at all (resolvePersonIDs == nil) — the union must be a no-op, leaving
        // exactly the email-OR-series behavior.
        let meetingService = MeetingService(appSupportDirectory: dir)
        let a = meetingService.createMeeting(title: "A", attendees: [Attendee(name: "Alex")])
        let b = meetingService.createMeeting(title: "B", attendees: [Attendee(name: "Alex")])
        XCTAssertTrue(
            meetingService.priorMeetings(matching: b).isEmpty,
            "email-less name-only meetings do not match without the directory seam"
        )
        _ = a
    }

    // MARK: - Rename felt at display time, no JSON rewrite (plan D6)

    func testRenameFeltAtDisplayTimeWithoutJSONRewrite() throws {
        let (meetingService, directory, dir) = try makeWired()
        defer { TestSupport.remove(dir) }

        let meeting = meetingService.createMeeting(
            title: "Sync",
            attendees: [Attendee(name: "Alice", email: "alice@x.com")]
        )
        let originalJSON = meeting.attendeesJSON
        let person = try XCTUnwrap(directory.persons.first)

        directory.rename(person, to: "Alicia")

        // Display resolution reflects the new label…
        XCTAssertEqual(
            directory.currentDisplayName(for: Attendee(name: "Alice", email: "alice@x.com")),
            "Alicia",
            "a rename is felt at display time for the same identity"
        )
        // …while the meeting's stored roster snapshot is byte-for-byte unchanged.
        XCTAssertEqual(meeting.attendeesJSON, originalJSON, "renaming never rewrites historical attendeesJSON")
        XCTAssertEqual(meeting.attendees.first?.name, "Alice", "the snapshot still carries the capture-time name")
    }

    func testRenameFoldsOldNameSoNameOnlyAttendeeStillResolves() throws {
        let (meetingService, directory, dir) = try makeWired()
        defer { TestSupport.remove(dir) }

        // A name-only provisional person, then rename it.
        _ = meetingService.createMeeting(title: "Ad-hoc", attendees: [Attendee(name: "Bob")])
        let person = try XCTUnwrap(directory.persons.first)
        directory.rename(person, to: "Robert")

        // A later attendee that still carries the OLD spelling resolves to the renamed person and shows
        // the new label (the old name was folded into aliases).
        XCTAssertEqual(
            directory.currentDisplayName(for: Attendee(name: "Bob")),
            "Robert"
        )
    }
}
