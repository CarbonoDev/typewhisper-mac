import XCTest
@testable import TypeWhisper

/// The pure candidate → `EmailRow` presentation mapping ([Google Phase 3 · M5], D-M6): sender
/// display-name parsing, relative date label, and the account caption appearing only when more
/// than one account contributed candidates.
final class EmailRowPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_786_399_200) // 2026-08-10T22:00:00Z

    private func candidate(
        id: String = "google:subA:m1",
        messageID: String = "m1",
        accountSub: String = "subA",
        accountEmail: String = "suba@example.com",
        subject: String = "Contract",
        from: String = "Ada Lovelace <ada@x.com>",
        date: Date = Date(timeIntervalSince1970: 1_786_300_000),
        snippet: String = "the snippet"
    ) -> EmailCandidate {
        EmailCandidate(
            id: id, messageID: messageID, accountSub: accountSub, accountEmail: accountEmail,
            threadID: "t1", subject: subject, from: from, date: date, snippet: snippet
        )
    }

    // MARK: - Sender display

    func testSenderDisplayNameParsesDisplayForms() {
        XCTAssertEqual(MeetingsViewModel.senderDisplayName(from: "Ada Lovelace <ada@x.com>"), "Ada Lovelace")
        XCTAssertEqual(MeetingsViewModel.senderDisplayName(from: "\"Lovelace, Ada\" <ada@x.com>"), "Lovelace, Ada")
        XCTAssertEqual(MeetingsViewModel.senderDisplayName(from: "ada@x.com"), "ada@x.com", "bare address passes through")
        XCTAssertEqual(MeetingsViewModel.senderDisplayName(from: "<ada@x.com>"), "ada@x.com", "empty display name falls back to the address")
    }

    // MARK: - Row mapping

    func testRowCarriesOpenAffordanceFieldsWithoutParsing() throws {
        let rows = MeetingsViewModel.emailRows(from: [candidate()], now: now)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.id, "google:subA:m1")
        XCTAssertEqual(row.messageID, "m1", "raw message id straight off the candidate (M1 contract)")
        XCTAssertEqual(row.accountSub, "subA")
        XCTAssertEqual(row.accountEmail, "suba@example.com")
        XCTAssertEqual(row.subject, "Contract")
        XCTAssertEqual(row.snippet, "the snippet")
        XCTAssertFalse(row.dateLabel.isEmpty, "relative date label renders")
    }

    func testAccountCaptionOnlyWhenMoreThanOneAccountContributed() {
        let singleAccount = MeetingsViewModel.emailRows(
            from: [candidate(id: "google:subA:m1"), candidate(id: "google:subA:m2", messageID: "m2")],
            now: now
        )
        XCTAssertTrue(singleAccount.allSatisfy { $0.accountCaption == nil }, "one account ⇒ no caption noise")

        let merged = MeetingsViewModel.emailRows(
            from: [
                candidate(id: "google:subA:m1"),
                candidate(id: "google:subB:m9", messageID: "m9", accountSub: "subB", accountEmail: "subb@example.com"),
            ],
            now: now
        )
        XCTAssertEqual(merged.map(\.accountCaption), ["suba@example.com", "subb@example.com"])
    }

    func testRowOrderMirrorsCandidateOrder() {
        let rows = MeetingsViewModel.emailRows(
            from: [
                candidate(id: "google:subA:new", messageID: "new", date: Date(timeIntervalSince1970: 1_786_390_000)),
                candidate(id: "google:subA:old", messageID: "old", date: Date(timeIntervalSince1970: 1_786_000_000)),
            ],
            now: now
        )
        XCTAssertEqual(rows.map(\.messageID), ["new", "old"], "the service's date-descending order is preserved")
    }
}
