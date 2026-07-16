import XCTest
@testable import TypeWhisper

/// [M2-Participants] Store isolation, ingestion accumulation, idempotent backfill, derived stats, and
/// manual merge/split/delete for the participant directory (plan D4/D5/D7/D9).
@MainActor
final class ParticipantDirectoryServiceTests: XCTestCase {
    private func makeService() throws -> (ParticipantDirectoryService, URL) {
        let dir = try TestSupport.makeTemporaryDirectory()
        return (ParticipantDirectoryService(appSupportDirectory: dir), dir)
    }

    private func person(_ service: ParticipantDirectoryService, email: String) -> Person? {
        service.persons.first { $0.emailKey == email }
    }

    // MARK: - Ingestion

    func testIngestCreatesEmailAndProvisionalPersons() throws {
        let (service, dir) = try makeService()
        defer { TestSupport.remove(dir) }

        service.ingest([Attendee(name: "Alice", email: "alice@x.com"), Attendee(name: "Bob")])
        XCTAssertEqual(service.persons.count, 2)
        XCTAssertEqual(person(service, email: "alice@x.com")?.displayName, "Alice")
        let bob = service.persons.first { $0.emailKey == nil }
        XCTAssertEqual(bob?.displayName, "Bob")
    }

    func testUpsertFoldsAliasAndNeverClobbersDisplayName() throws {
        let (service, dir) = try makeService()
        defer { TestSupport.remove(dir) }

        service.ingest([Attendee(name: "Robert", email: "r@x.com")])
        service.ingest([Attendee(name: "Bob", email: "R@X.COM")]) // same email, casing differs
        XCTAssertEqual(service.persons.count, 1)
        let p = try XCTUnwrap(person(service, email: "r@x.com"))
        XCTAssertEqual(p.displayName, "Robert", "displayName must never be clobbered")
        XCTAssertEqual(p.aliases, ["Bob"])
    }

    func testIngestIsIdempotent() throws {
        let (service, dir) = try makeService()
        defer { TestSupport.remove(dir) }

        let roster = [Attendee(name: "Alice", email: "alice@x.com"), Attendee(name: "Bob")]
        service.ingest(roster)
        let firstIDs = Set(service.persons.map(\.id))
        service.ingest(roster)
        XCTAssertEqual(Set(service.persons.map(\.id)), firstIDs, "re-ingesting the same roster is a no-op")
        XCTAssertEqual(service.persons.count, 2)
    }

    func testLateEmailPromotesSingleProvisional() throws {
        let (service, dir) = try makeService()
        defer { TestSupport.remove(dir) }

        service.ingest([Attendee(name: "Alex")])            // provisional
        service.ingest([Attendee(name: "Alex", email: "alex@x.com")]) // late email
        XCTAssertEqual(service.persons.count, 1, "the provisional must be promoted in place, not duplicated")
        XCTAssertEqual(person(service, email: "alex@x.com")?.displayName, "Alex")
    }

    func testTwoDistinctEmailsNeverMerge() throws {
        let (service, dir) = try makeService()
        defer { TestSupport.remove(dir) }

        service.ingest([Attendee(name: "Sam", email: "a@x.com")])
        service.ingest([Attendee(name: "Sam", email: "b@y.com")])
        XCTAssertEqual(service.persons.count, 2, "two distinct emails with the same name never auto-merge")
    }

    func testSingleBatchNameThenEmailCollisionCreatesOnePerson() throws {
        let (service, dir) = try makeService()
        defer { TestSupport.remove(dir) }

        // Both coexist in one roster because `Attendee.id` is `email ?? name`. Resolving each against a
        // live working set (not a stale snapshot) must promote the provisional in place, not duplicate.
        service.ingest([Attendee(name: "Alex"), Attendee(name: "Alex", email: "alex@x.com")])
        XCTAssertEqual(service.persons.count, 1, "name-only + email variant of one name must converge in a single batch")
        XCTAssertEqual(person(service, email: "alex@x.com")?.displayName, "Alex")
    }

    func testSingleBatchTwoSameKeyNameOnlyCreatesOnePerson() throws {
        let (service, dir) = try makeService()
        defer { TestSupport.remove(dir) }

        // Two same-name-key provisionals in one batch would never auto-converge (later ingest sees 2
        // matches → ambiguous). The live working set must recognise the first as an existing match.
        service.ingest([Attendee(name: "Alex"), Attendee(name: "alex")])
        XCTAssertEqual(service.persons.count, 1, "two same-key name-only attendees in one batch must not duplicate")
    }

    func testOrderIndependence() throws {
        let dirA = try TestSupport.makeTemporaryDirectory()
        let dirB = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dirA); TestSupport.remove(dirB) }

        let a = ParticipantDirectoryService(appSupportDirectory: dirA)
        a.ingest([Attendee(name: "Alex")])
        a.ingest([Attendee(name: "Alex", email: "alex@x.com")])

        let b = ParticipantDirectoryService(appSupportDirectory: dirB)
        b.ingest([Attendee(name: "Alex", email: "alex@x.com")])
        b.ingest([Attendee(name: "Alex")])

        XCTAssertEqual(a.persons.map(\.emailKey), ["alex@x.com"])
        XCTAssertEqual(b.persons.map(\.emailKey), ["alex@x.com"])
        XCTAssertEqual(a.persons.map(\.displayName), b.persons.map(\.displayName))
    }

    // MARK: - Backfill

    func testBackfillIsIdempotent() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let meetingService = MeetingService(appSupportDirectory: dir)
        meetingService.createMeeting(
            title: "Sync", attendees: [Attendee(name: "Alice", email: "alice@x.com"), Attendee(name: "Bob")]
        )
        meetingService.createMeeting(title: "1:1", attendees: [Attendee(name: "Alice", email: "alice@x.com")])

        let directory = ParticipantDirectoryService(appSupportDirectory: dir)
        await directory.backfill(from: meetingService.meetings)
        let idsAfterFirst = Set(directory.persons.map(\.id))
        XCTAssertEqual(directory.persons.count, 2)

        await directory.backfill(from: meetingService.meetings)
        XCTAssertEqual(Set(directory.persons.map(\.id)), idsAfterFirst, "re-running backfill must be a no-op")
    }

    func testBackfillDoesNotResurrectManuallyMergedPerson() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let meetingService = MeetingService(appSupportDirectory: dir)
        // Two meetings whose rosters carry the two emails that a later manual merge unifies.
        meetingService.createMeeting(title: "Sync", attendees: [Attendee(name: "Sam", email: "a@x.com")])
        meetingService.createMeeting(title: "1:1", attendees: [Attendee(name: "Samuel", email: "b@y.com")])

        let directory = ParticipantDirectoryService(appSupportDirectory: dir)
        await directory.backfill(from: meetingService.meetings)
        XCTAssertEqual(directory.persons.count, 2)

        let winner = try XCTUnwrap(person(directory, email: "a@x.com"))
        let loser = try XCTUnwrap(person(directory, email: "b@y.com"))
        directory.merge(loser, into: winner)
        XCTAssertEqual(directory.persons.count, 1)

        // The every-launch backfill re-sees b@y.com in historical attendeesJSON; the resolver must map it
        // to the surviving owner via altEmails instead of recreating the merged-away person.
        await directory.backfill(from: meetingService.meetings)
        XCTAssertEqual(directory.persons.count, 1, "re-running backfill after a manual merge must not resurrect the loser")
        XCTAssertTrue(try XCTUnwrap(person(directory, email: "a@x.com")).altEmails.contains("b@y.com"))
    }

    // MARK: - Derived stats (plan D9)

    func testDerivedStatsCountAndLastSeen() throws {
        let alice = Person(emailKey: "alice@x.com", displayName: "Alice")
        let bob = Person(displayName: "Bob")

        let d1 = Date(timeIntervalSince1970: 1_000)
        let d2 = Date(timeIntervalSince1970: 2_000)
        let m1 = Meeting(title: "Sync", startDate: d1)
        m1.attendees = [Attendee(name: "Alice", email: "alice@x.com"), Attendee(name: "Bob")]
        let m2 = Meeting(title: "1:1", startDate: d2)
        m2.attendees = [Attendee(name: "Alice", email: "alice@x.com")]

        let stats = ParticipantDirectoryService.derivedStats(persons: [alice, bob], meetings: [m1, m2])
        XCTAssertEqual(stats[alice.id], PersonStats(meetingCount: 2, lastSeen: d2))
        XCTAssertEqual(stats[bob.id], PersonStats(meetingCount: 1, lastSeen: d1))
    }

    func testDerivedStatsCountsAPersonOncePerMeeting() throws {
        let alice = Person(emailKey: "alice@x.com", displayName: "Alice")
        let m = Meeting(title: "Dup", startDate: Date(timeIntervalSince1970: 500))
        // Same human appears twice (once by email, once by matching name).
        m.attendees = [Attendee(name: "Alice", email: "alice@x.com"), Attendee(name: "Alice")]
        let stats = ParticipantDirectoryService.derivedStats(persons: [alice], meetings: [m])
        XCTAssertEqual(stats[alice.id]?.meetingCount, 1)
    }

    // MARK: - Manual merge / split / delete

    func testManualMergeRecordsAltEmailsAndFoldsNames() throws {
        let (service, dir) = try makeService()
        defer { TestSupport.remove(dir) }

        service.ingest([Attendee(name: "Sam", email: "a@x.com")])
        service.ingest([Attendee(name: "Samuel", email: "b@y.com")])
        let winner = try XCTUnwrap(person(service, email: "a@x.com"))
        let loser = try XCTUnwrap(person(service, email: "b@y.com"))

        service.merge(loser, into: winner)
        XCTAssertEqual(service.persons.count, 1)
        let survivor = try XCTUnwrap(person(service, email: "a@x.com"))
        XCTAssertTrue(survivor.altEmails.contains("b@y.com"), "manual merge records the loser's email")
        XCTAssertTrue(survivor.aliases.contains("Samuel"), "manual merge folds the loser's name")
    }

    func testMergeEmailPersonIntoProvisionalSurvivesReingest() throws {
        let (service, dir) = try makeService()
        defer { TestSupport.remove(dir) }

        // The legal (either-direction) manual merge that folds an email-owner into a provisional: the
        // survivor is provisional (emailKey == nil) but carries b@y.com as an altEmail. Re-ingesting the
        // historical attendee (as the every-launch backfill does) must resolve to the survivor via the
        // altEmails fallback — never a self-`.merge(loserID: W, winnerID: W)` that deletes the winner.
        service.ingest([Attendee(name: "Alex")])                     // provisional survivor-to-be
        service.ingest([Attendee(name: "Sam", email: "b@y.com")])    // email person
        let provisional = try XCTUnwrap(service.persons.first { $0.emailKey == nil })
        let emailPerson = try XCTUnwrap(person(service, email: "b@y.com"))
        service.merge(emailPerson, into: provisional)
        XCTAssertEqual(service.persons.count, 1)
        let winnerID = provisional.id
        XCTAssertTrue(provisional.altEmails.contains("b@y.com"))

        // Re-ingest the historical attendee — the backfill re-encounter that previously self-merged.
        service.ingest([Attendee(name: "Sam", email: "b@y.com")])
        XCTAssertEqual(service.persons.count, 1, "re-ingest must not delete the merged survivor")
        XCTAssertEqual(service.persons.first?.id, winnerID, "the merged survivor's id must persist")
    }

    func testSplitRestoresSeparatePerson() throws {
        let (service, dir) = try makeService()
        defer { TestSupport.remove(dir) }

        service.ingest([Attendee(name: "Sam", email: "a@x.com")])
        service.ingest([Attendee(name: "Samuel", email: "b@y.com")])
        let winner = try XCTUnwrap(person(service, email: "a@x.com"))
        let loser = try XCTUnwrap(person(service, email: "b@y.com"))
        service.merge(loser, into: winner)

        let restored = service.split(email: "b@y.com", from: winner)
        XCTAssertNotNil(restored)
        XCTAssertEqual(service.persons.count, 2)
        XCTAssertFalse(try XCTUnwrap(person(service, email: "a@x.com")).altEmails.contains("b@y.com"))
        XCTAssertNil(service.split(email: "nope@z.com", from: winner), "splitting an unknown email is a no-op")
    }

    func testDeleteRemovesPerson() throws {
        let (service, dir) = try makeService()
        defer { TestSupport.remove(dir) }
        service.ingest([Attendee(name: "Alice", email: "alice@x.com")])
        let p = try XCTUnwrap(person(service, email: "alice@x.com"))
        service.delete(p)
        XCTAssertTrue(service.persons.isEmpty)
    }

    // MARK: - Store isolation

    func testSecondInstanceRequeriesPersistedPersons() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let first = ParticipantDirectoryService(appSupportDirectory: dir)
        first.ingest([Attendee(name: "Alice", email: "alice@x.com")])

        let second = ParticipantDirectoryService(appSupportDirectory: dir)
        XCTAssertEqual(second.persons.map(\.emailKey), ["alice@x.com"])
    }

    func testIngestDoesNotTouchMeetingsStore() throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }
        let meetingService = MeetingService(appSupportDirectory: dir)
        _ = meetingService.createMeeting(title: "Existing", source: .adHoc, state: .scheduled)

        let directory = ParticipantDirectoryService(appSupportDirectory: dir)
        directory.ingest([Attendee(name: "Alice", email: "alice@x.com")])

        let reader = MeetingService(appSupportDirectory: dir)
        XCTAssertEqual(reader.meetings.map(\.title), ["Existing"])
    }
}
