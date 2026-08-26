import XCTest
@testable import TypeWhisper

/// `GmailQueryBuilder` — pure D-M1/D-M2 assembly: two-query split with per-clause caps,
/// `subject:(…)` AND-scoping, self-exclusion, and the date-granular window serialization
/// (`before:` = the calendar day AFTER the window-end instant).
final class GmailQueryBuilderTests: XCTestCase {
    /// Fixed UTC calendar so day math never depends on the machine's zone.
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// 2026-08-10T22:00:00Z.
    private let reference = Date(timeIntervalSince1970: 1_786_399_200)

    private var window: GmailQueryBuilder.Window {
        GmailQueryBuilder.window(reference: reference, calendar: utc)
    }

    // MARK: - Window serialization (D-M1 normative rule)

    func testWindowIsFourteenDaysBackAndBeforeNamesTheDayAfterTheEndInstant() {
        let window = self.window
        XCTAssertEqual(window.afterDay, "2026/07/27", "reference − 14 days, at date granularity")
        // Window end = reference + 1 day = 2026-08-11T22:00:00Z; Gmail's `before:` is exclusive,
        // so the day AFTER the end instant keeps the whole window-end day (Aug 11) in range.
        XCTAssertEqual(window.beforeDay, "2026/08/12")
    }

    func testWindowEndAtMidnightStillCoversTheWholeEndDay() {
        // Reference at exactly midnight: end instant = 2026-08-11T00:00:00Z (first second of
        // Aug 11). `before:` must name Aug 12, never Aug 11 — otherwise the end day vanishes.
        let midnightReference = Date(timeIntervalSince1970: 1_786_320_000) // 2026-08-10T00:00:00Z
        let window = GmailQueryBuilder.window(reference: midnightReference, calendar: utc)
        XCTAssertEqual(window.afterDay, "2026/07/27")
        XCTAssertEqual(window.beforeDay, "2026/08/12")
    }

    func testMeetingTodayWindowCoversMidMeetingArrivals() {
        // D-M2: no live special case — for a meeting happening today the serialized window
        // already reaches past all of today.
        let window = self.window
        XCTAssertLessThan(window.afterDay, "2026/08/10")
        XCTAssertGreaterThan(window.beforeDay, "2026/08/10")
    }

    // MARK: - Attendee query

    func testAttendeeQueryPairsFromAndToPerAddress() throws {
        let queries = GmailQueryBuilder.queries(
            attendeeEmails: ["ada@x.com", "bob@y.org"],
            excludedEmails: [],
            titleTerms: "",
            window: window
        )
        let attendee = try XCTUnwrap(queries.attendee)
        XCTAssertTrue(attendee.hasPrefix("(from:ada@x.com OR to:ada@x.com OR from:bob@y.org OR to:bob@y.org) "))
        XCTAssertNil(queries.subject, "no title content terms")
    }

    func testAttendeeQueryCapsAtEightAddresses() throws {
        let emails = (1...10).map { "person\($0)@x.com" }
        let queries = GmailQueryBuilder.queries(
            attendeeEmails: emails, excludedEmails: [], titleTerms: "", window: window
        )
        let attendee = try XCTUnwrap(queries.attendee)
        let fromCount = attendee.components(separatedBy: "from:").count - 1
        XCTAssertEqual(fromCount, 8, "first 8 addresses only (D-M1 cap)")
        XCTAssertTrue(attendee.contains("person8@x.com"))
        XCTAssertFalse(attendee.contains("person9@x.com"))
    }

    func testSelfExclusionIsCaseInsensitiveAndNilsOutAnEmptyClause() {
        // Excluded set = isSelf attendees ∪ all connected-account emails (D-M2), compared
        // case-insensitively — the builder receives the union and subtracts.
        let queries = GmailQueryBuilder.queries(
            attendeeEmails: ["Marco@Simbiosis.Team", "ada@x.com"],
            excludedEmails: ["marco@simbiosis.team"],
            titleTerms: "",
            window: window
        )
        XCTAssertEqual(
            queries.attendee?.hasPrefix("(from:ada@x.com OR to:ada@x.com) "), true,
            "the self address is subtracted regardless of case"
        )

        let allExcluded = GmailQueryBuilder.queries(
            attendeeEmails: ["Marco@Simbiosis.Team"],
            excludedEmails: ["marco@simbiosis.team"],
            titleTerms: "",
            window: window
        )
        XCTAssertNil(allExcluded.attendee, "no addresses remain ⇒ nil query")
    }

    func testDuplicateAddressesCollapseCaseInsensitively() throws {
        let queries = GmailQueryBuilder.queries(
            attendeeEmails: ["ada@x.com", "ADA@X.COM", "ada@x.com "],
            excludedEmails: [],
            titleTerms: "",
            window: window
        )
        let attendee = try XCTUnwrap(queries.attendee)
        XCTAssertEqual(attendee.components(separatedBy: "from:").count - 1, 1)
    }

    // MARK: - Subject query

    func testSubjectQueryIsANDScopedInsideSubjectParensAndCapped() throws {
        // Tokenized (lowercased, stop-worded), capped at 4 content terms, space-separated inside
        // `subject:(…)` — Gmail treats that as AND (the D-M1 flooding guard).
        let queries = GmailQueryBuilder.queries(
            attendeeEmails: [],
            excludedEmails: [],
            titleTerms: "The Weekly Sync with Acme about Budget Planning",
            window: window
        )
        let subject = try XCTUnwrap(queries.subject)
        XCTAssertTrue(subject.hasPrefix("subject:(weekly sync acme about) "), "first 4 content terms, AND-scoped: \(subject)")
        XCTAssertNil(queries.attendee)
    }

    func testStopWordOnlyTitleYieldsNilSubjectQuery() {
        let queries = GmailQueryBuilder.queries(
            attendeeEmails: [], excludedEmails: [], titleTerms: "To The And", window: window
        )
        XCTAssertNil(queries.subject)
        XCTAssertNil(queries.attendee)
        XCTAssertTrue(queries.isEmpty, "both nil ⇒ retrieval returns [] without a network call")
    }

    // MARK: - Shared suffix

    func testBothQueriesCarryWindowAndNoiseFilters() throws {
        let queries = GmailQueryBuilder.queries(
            attendeeEmails: ["ada@x.com"],
            excludedEmails: [],
            titleTerms: "Acme budget",
            window: window
        )
        for query in [try XCTUnwrap(queries.attendee), try XCTUnwrap(queries.subject)] {
            XCTAssertTrue(query.contains("after:2026/07/27"))
            XCTAssertTrue(query.contains("before:2026/08/12"))
            XCTAssertTrue(query.contains("-in:chats"))
            XCTAssertTrue(query.contains("-in:drafts"))
            XCTAssertTrue(query.contains("-category:promotions"))
            XCTAssertTrue(query.contains("-category:social"))
        }
    }

    // MARK: - includedAddresses (the scope-fingerprint helper)

    func testIncludedAddressesPreservesOrderAndTrims() {
        let included = GmailQueryBuilder.includedAddresses(
            attendeeEmails: [" bob@y.org ", "ada@x.com", "self@me.com"],
            excludedEmails: ["SELF@me.com"]
        )
        XCTAssertEqual(included, ["bob@y.org", "ada@x.com"])
    }
}
