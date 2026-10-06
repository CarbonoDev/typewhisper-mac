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

    // MARK: - Self-exclusion (bugfix)

    /// The regression this guards: the user is an attendee of every meeting they hold, so matching on
    /// the raw roster intersected on their own address and made EVERY past meeting "related" — which
    /// flooded pre-meeting briefs with unrelated history.
    func testPriorMeetingsDoesNotMatchOnSelfAlone() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let meetingService = MeetingService(appSupportDirectory: dir)

        let me = Attendee(name: "Owner", email: "owner@example.com", isSelf: true)
        _ = meetingService.createMeeting(
            title: "Budget review",
            attendees: [me, Attendee(name: "Alex", email: "alex@example.com")]
        )
        let fresh = meetingService.createMeeting(
            title: "Intro call",
            attendees: [me, Attendee(name: "Dana", email: "dana@newco.com")]
        )

        XCTAssertTrue(
            meetingService.priorMeetings(matching: fresh).isEmpty,
            "two meetings sharing only the user are unrelated"
        )
    }

    /// The other half of the contract: subtracting self must not cost a genuine match.
    func testPriorMeetingsStillMatchesSharedOtherAttendeeDespiteSelf() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let meetingService = MeetingService(appSupportDirectory: dir)

        let me = Attendee(name: "Owner", email: "owner@example.com", isSelf: true)
        let alex = Attendee(name: "Alex", email: "alex@example.com")
        let older = meetingService.createMeeting(title: "Kickoff", attendees: [me, alex])
        let newer = meetingService.createMeeting(title: "Follow-up", attendees: [me, alex])

        XCTAssertTrue(
            meetingService.priorMeetings(matching: newer).contains { $0.id == older.id },
            "a shared non-self attendee still relates two meetings"
        )
    }

    /// `isSelf` is stored only when definitively true, so the flag alone misses a manually added
    /// roster or a second account. The connected-account seam covers that gap (the D-M2 pattern).
    func testPriorMeetingsExcludesSelfViaConnectedAccountEmailWithoutFlag() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let meetingService = MeetingService(appSupportDirectory: dir)
        meetingService.connectedAccountEmails = { ["Owner@Example.com"] }

        // No `isSelf` flag anywhere — self is recognizable only by the connected-account address,
        // and the comparison must be case-insensitive.
        let me = Attendee(name: "Owner", email: "owner@example.com")
        _ = meetingService.createMeeting(
            title: "Budget review",
            attendees: [me, Attendee(name: "Alex", email: "alex@example.com")]
        )
        let fresh = meetingService.createMeeting(
            title: "Intro call",
            attendees: [me, Attendee(name: "Dana", email: "dana@newco.com")]
        )

        XCTAssertTrue(
            meetingService.priorMeetings(matching: fresh).isEmpty,
            "the connected-account address identifies self even with no isSelf flag"
        )
    }

    /// The resolved-identity path (plan D8) needs the same subtraction: the user resolves to a
    /// directory `Person` too, so an unfiltered roster matched on self here even where the
    /// email path did not — the email-less archive is exactly where this path carries the weight.
    func testPriorMeetingsDoesNotUnionOnSelfIdentity() throws {
        let (meetingService, directory, dir) = try makeWired()
        defer { TestSupport.remove(dir) }

        let me = Attendee(name: "Owner", isSelf: true)
        _ = meetingService.createMeeting(
            title: "Budget review (imported)",
            source: .importedTranscript,
            attendees: [me, Attendee(name: "Alex")]
        )
        let fresh = meetingService.createMeeting(
            title: "Intro call (imported)",
            source: .importedTranscript,
            attendees: [me, Attendee(name: "Dana")]
        )
        XCTAssertFalse(directory.persons.isEmpty, "the directory resolved the email-less rosters")

        XCTAssertTrue(
            meetingService.priorMeetings(matching: fresh).isEmpty,
            "a shared self identity does not relate two email-less meetings"
        )
    }

    /// A solo event has no other attendee to match on; `seriesID` must remain its relatedness signal.
    func testPriorMeetingsStillMatchesSeriesForSoloMeeting() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let meetingService = MeetingService(appSupportDirectory: dir)

        let me = Attendee(name: "Owner", email: "owner@example.com", isSelf: true)
        let older = meetingService.createMeeting(
            title: "Focus block", seriesID: "series-1", attendees: [me]
        )
        let newer = meetingService.createMeeting(
            title: "Focus block", seriesID: "series-1", attendees: [me]
        )

        XCTAssertTrue(
            meetingService.priorMeetings(matching: newer).contains { $0.id == older.id },
            "recurrence still relates a solo event once self is subtracted"
        )
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
