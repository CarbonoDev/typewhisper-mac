import XCTest
@testable import TypeWhisper

/// [M2-Participants] Exhaustive branch coverage of the pure identity resolver (plan D5). Every rule is
/// exercised deterministically against value snapshots — no store, no MainActor state.
final class PersonIdentityTests: XCTestCase {
    private func snapshot(
        _ id: UUID = UUID(),
        email: String? = nil,
        name: String,
        aliases: [String] = [],
        altEmails: [String] = []
    ) -> PersonIdentity.Snapshot {
        PersonIdentity.Snapshot(id: id, emailKey: email, displayName: name, aliases: aliases, altEmails: altEmails)
    }

    // MARK: - Merge-recorded secondary emails (plan Part A #11)

    func testEmailMatchingAnAltEmailResolvesToOwnerNotCreate() {
        // A merged-away email lives in the survivor's `altEmails`; re-encountering it (e.g. the
        // every-launch backfill) must resolve to that owner, never `.create` a duplicate.
        let owner = snapshot(email: "a@x.com", name: "Sam", altEmails: ["b@y.com"])
        let outcome = PersonIdentity.resolve(incoming("Samuel", "b@y.com"), existing: [owner])
        switch outcome {
        case .create:
            XCTFail("A merge-recorded secondary email must not create a duplicate person, got \(outcome)")
        case let .update(id, adoptEmailKey, _):
            XCTAssertEqual(id, owner.id)
            XCTAssertNil(adoptEmailKey, "the owner's primary email must never be clobbered")
        case .none, .merge:
            break // also acceptable — no duplicate person minted
        }
    }

    func testEmailMatchingAltEmailOnProvisionalOwnerDoesNotSelfMerge() {
        // The state a legal manual merge(emailPerson, into: provisional) produces: a provisional owner
        // (emailKey == nil) that carries the merged email as a secondary and the merged name as an alias.
        // Re-encountering that email must resolve to the owner via the altEmails fallback — never a
        // self-`.merge(loserID: W, winnerID: W)`, which the service would apply as a delete of the winner.
        let owner = snapshot(email: nil, name: "Alex", aliases: ["Sam"], altEmails: ["b@y.com"])
        let outcome = PersonIdentity.resolve(incoming("Sam", "b@y.com"), existing: [owner])
        if case let .merge(loserID, winnerID, _) = outcome {
            XCTFail("Owner must not be its own merge loser (loser=\(loserID) winner=\(winnerID))")
        }
        // "Sam" is already an alias of the owner, so there is nothing to fold either → `.none`.
        XCTAssertEqual(outcome, .none)
    }

    private func incoming(_ name: String, _ email: String? = nil) -> PersonIdentity.Incoming {
        guard let value = PersonIdentity.incoming(name: name, email: email) else {
            XCTFail("Expected a usable incoming attendee for name=\(name) email=\(String(describing: email))")
            return PersonIdentity.Incoming(displayName: name, emailKey: email)
        }
        return value
    }

    // MARK: - Normalization

    func testEmailNormalization() {
        XCTAssertEqual(PersonIdentity.normalizeEmail("  A@X.com "), "a@x.com")
        XCTAssertNil(PersonIdentity.normalizeEmail("   "))
        XCTAssertNil(PersonIdentity.normalizeEmail(nil))
    }

    func testIncomingFallsBackToEmailWhenNameBlank() {
        let value = PersonIdentity.incoming(name: "   ", email: "a@x.com")
        XCTAssertEqual(value, PersonIdentity.Incoming(displayName: "a@x.com", emailKey: "a@x.com"))
        XCTAssertNil(PersonIdentity.incoming(name: "   ", email: "  "))
    }

    // MARK: - Rule 1/2: upsert by email + alias folding + no-clobber displayName

    func testUpsertByEmailFoldsNewNameAsAlias() {
        let id = UUID()
        let existing = [snapshot(id, email: "a@x.com", name: "Robert")]
        let outcome = PersonIdentity.resolve(incoming("Bob", "a@x.com"), existing: existing)
        // Folds "Bob" as an alias; adopts no new email; never clobbers "Robert".
        XCTAssertEqual(outcome, .update(id: id, adoptEmailKey: nil, addAliases: ["Bob"]))
    }

    func testUpsertByEmailIsNoopWhenNameAlreadyKnown() {
        let existing = [snapshot(email: "a@x.com", name: "Robert", aliases: ["Bob"])]
        // "Bob" already an alias → nothing to fold (idempotent, no-clobber).
        XCTAssertEqual(PersonIdentity.resolve(incoming("Bob", "a@x.com"), existing: existing), .none)
        XCTAssertEqual(PersonIdentity.resolve(incoming("Robert", "A@X.COM"), existing: existing), .none)
    }

    // MARK: - Rule 2: provisional create

    func testNameOnlyCreatesProvisional() {
        XCTAssertEqual(
            PersonIdentity.resolve(incoming("Alex"), existing: []),
            .create(emailKey: nil, displayName: "Alex")
        )
    }

    func testNameOnlyReusesSingleMatchAsNoop() {
        let existing = [snapshot(email: "alex@x.com", name: "Alex")]
        // Order-independence: a name-only "Alex" when an email person "Alex" exists must not duplicate.
        XCTAssertEqual(PersonIdentity.resolve(incoming("Alex"), existing: existing), .none)
    }

    // MARK: - Rule 3: single-unambiguous promotion

    func testLateEmailPromotesSingleProvisionalInPlace() {
        let id = UUID()
        let existing = [snapshot(id, email: nil, name: "Alex")]
        let outcome = PersonIdentity.resolve(incoming("Alex", "alex@x.com"), existing: existing)
        XCTAssertEqual(outcome, .update(id: id, adoptEmailKey: "alex@x.com", addAliases: []))
    }

    // MARK: - Rule 3 (merge variant): merge provisional into existing email person

    func testLateEmailMergesProvisionalIntoEmailOwner() {
        let winner = UUID()
        let loser = UUID()
        let existing = [
            snapshot(winner, email: "alex@x.com", name: "Alex Kim"),
            snapshot(loser, email: nil, name: "Alex")
        ]
        let outcome = PersonIdentity.resolve(incoming("Alex", "alex@x.com"), existing: existing)
        XCTAssertEqual(outcome, .merge(loserID: loser, winnerID: winner, addAliases: ["Alex"]))
    }

    // MARK: - Rule 4: ambiguity means no auto action

    func testNameOnlyAmbiguousMatchIsNoop() {
        let existing = [
            snapshot(email: nil, name: "Alex"),
            snapshot(email: nil, name: "alex") // same name key → two matches
        ]
        XCTAssertEqual(PersonIdentity.resolve(incoming("Alex"), existing: existing), .none)
    }

    func testLateEmailWithAmbiguousProvisionalsCreatesFreshPerson() {
        let existing = [
            snapshot(email: nil, name: "Alex"),
            snapshot(email: nil, name: "Alex")
        ]
        // Two candidates → no promote/merge; a brand-new email person is created, provisionals untouched.
        XCTAssertEqual(
            PersonIdentity.resolve(incoming("Alex", "alex@x.com"), existing: existing),
            .create(emailKey: "alex@x.com", displayName: "Alex")
        )
    }

    // MARK: - Rule 5: two distinct emails never auto-merge

    func testDistinctEmailSameNameNeverMerges() {
        let existing = [snapshot(email: "a@x.com", name: "Sam")]
        // A name match that already owns a *different* email is not a promotion candidate.
        XCTAssertEqual(
            PersonIdentity.resolve(incoming("Sam", "b@y.com"), existing: existing),
            .create(emailKey: "b@y.com", displayName: "Sam")
        )
    }

    // MARK: - Idempotency

    func testResolveOfAlreadyRepresentedAttendeeIsNoop() {
        let existing = [snapshot(email: "a@x.com", name: "Robert", aliases: ["Bob"])]
        let first = PersonIdentity.resolve(incoming("Bob", "a@x.com"), existing: existing)
        XCTAssertEqual(first, .none)
    }
}
