import XCTest
@testable import TypeWhisper

/// [Google Phase 1 · M4] Pure D-G6 twin-calendar detection: the EventKit CalDAV mirrors of a
/// connected Google account's calendars, the `google:`-prefix partition of a fanned-in calendar
/// list, and the prompt-evaluation rule (unhandled accounts only, skipped without EventKit).
final class TwinCalendarDetectorTests: XCTestCase {
    private func calendar(
        id: String,
        title: String,
        sourceName: String
    ) -> CalendarInfo {
        CalendarInfo(id: id, title: title, sourceName: sourceName, color: .fallback)
    }

    private func account(sub: String, email: String, status: GoogleAccountStatus = .connected) -> GoogleAccount {
        GoogleAccount(
            id: sub,
            email: email,
            displayName: nil,
            grantedScopes: ["openid"],
            connectedAt: Date(timeIntervalSince1970: 1_700_000_000),
            statusRaw: status.rawValue
        )
    }

    // MARK: - Twin matrix (D-G6 heuristics)

    func testGoogleSourceWithMatchingTitleIsTwin() {
        let eventKit = [calendar(id: "ek-1", title: "Team", sourceName: "Google")]
        let google = [calendar(id: "google:sub-1:team", title: "Team", sourceName: "marco@example.com")]

        let twins = TwinCalendarDetector.twins(eventKit: eventKit, google: google, accountEmail: "marco@example.com")

        XCTAssertEqual(twins.map(\.id), ["ek-1"])
    }

    func testEmailTitledPrimaryCalendarIsTwinEvenWithoutTitleMatch() {
        // Google primary calendars are titled with the account email; the EventKit side often
        // mirrors that even when the Google list titles it differently (e.g. "Marco R.").
        let eventKit = [calendar(id: "ek-primary", title: "marco@example.com", sourceName: "Google")]
        let google = [calendar(id: "google:sub-1:primary", title: "Marco R.", sourceName: "marco@example.com")]

        let twins = TwinCalendarDetector.twins(eventKit: eventKit, google: google, accountEmail: "marco@example.com")

        XCTAssertEqual(twins.map(\.id), ["ek-primary"])
    }

    func testSourceNamedWithAccountEmailMatches() {
        // EKSource is titled with the account email on some configurations (D-G6).
        let eventKit = [calendar(id: "ek-1", title: "Team", sourceName: "marco@example.com")]
        let google = [calendar(id: "google:sub-1:team", title: "Team", sourceName: "marco@example.com")]

        let twins = TwinCalendarDetector.twins(eventKit: eventKit, google: google, accountEmail: "marco@example.com")

        XCTAssertEqual(twins.map(\.id), ["ek-1"])
    }

    func testNonGoogleSourceIsNeverATwin() {
        // Same title, but the source is iCloud — an independent calendar, not a CalDAV mirror.
        let eventKit = [calendar(id: "ek-1", title: "Team", sourceName: "iCloud")]
        let google = [calendar(id: "google:sub-1:team", title: "Team", sourceName: "marco@example.com")]

        XCTAssertTrue(
            TwinCalendarDetector.twins(eventKit: eventKit, google: google, accountEmail: "marco@example.com").isEmpty
        )
    }

    func testGoogleSourceWithoutTitleMatchIsNotATwin() {
        let eventKit = [calendar(id: "ek-1", title: "Completely different", sourceName: "Google")]
        let google = [calendar(id: "google:sub-1:team", title: "Team", sourceName: "marco@example.com")]

        XCTAssertTrue(
            TwinCalendarDetector.twins(eventKit: eventKit, google: google, accountEmail: "marco@example.com").isEmpty
        )
    }

    func testMatchingIsCaseInsensitive() {
        let eventKit = [
            calendar(id: "ek-1", title: "TEAM", sourceName: "GMAIL"),
            calendar(id: "ek-2", title: "Marco@Example.COM", sourceName: "gOOgle")
        ]
        let google = [calendar(id: "google:sub-1:team", title: "team", sourceName: "marco@example.com")]

        let twins = TwinCalendarDetector.twins(eventKit: eventKit, google: google, accountEmail: "MARCO@example.com")

        XCTAssertEqual(twins.map(\.id), ["ek-1", "ek-2"])
    }

    func testEmptyAccountEmailNeverMatches() {
        let eventKit = [calendar(id: "ek-1", title: "", sourceName: "Google")]
        XCTAssertTrue(TwinCalendarDetector.twins(eventKit: eventKit, google: [], accountEmail: "").isEmpty)
    }

    // MARK: - Partition by the D-G3 prefix

    func testPartitionSplitsBareAndNamespacedIDsPerAccount() {
        let eventKitCal = calendar(id: "0BB6045C-UUID", title: "Work", sourceName: "iCloud")
        let mineCal = calendar(id: GoogleCalendarID.calendarID(sub: "sub-1", raw: "team"), title: "Team", sourceName: "a@x.com")
        let otherCal = calendar(id: GoogleCalendarID.calendarID(sub: "sub-2", raw: "team"), title: "Team", sourceName: "b@x.com")

        let (eventKit, google) = TwinCalendarDetector.partition(
            [eventKitCal, mineCal, otherCal],
            accountSub: "sub-1"
        )

        XCTAssertEqual(eventKit.map(\.id), [eventKitCal.id])
        XCTAssertEqual(google.map(\.id), [mineCal.id])
    }

    // MARK: - Prompt evaluation (trigger semantics)

    func testPromptsSkippedWhenEventKitNotAuthorized() {
        let calendars = [
            calendar(id: "ek-1", title: "Team", sourceName: "Google"),
            calendar(id: GoogleCalendarID.calendarID(sub: "sub-1", raw: "team"), title: "Team", sourceName: "m@x.com")
        ]

        let prompts = TwinCalendarDetector.prompts(
            accounts: [account(sub: "sub-1", email: "m@x.com")],
            eventKitAuthorized: false,
            calendars: calendars,
            isHandled: { _ in false }
        )

        XCTAssertTrue(prompts.isEmpty)
    }

    func testPromptOnlyForUnhandledAccountsWithTwins() {
        let calendars = [
            calendar(id: "ek-1", title: "Team", sourceName: "Google"),
            calendar(id: GoogleCalendarID.calendarID(sub: "handled", raw: "team"), title: "Team", sourceName: "h@x.com"),
            calendar(id: GoogleCalendarID.calendarID(sub: "fresh", raw: "team"), title: "Team", sourceName: "f@x.com"),
            calendar(id: GoogleCalendarID.calendarID(sub: "no-twins", raw: "other"), title: "Elsewhere", sourceName: "n@x.com")
        ]
        let accounts = [
            account(sub: "handled", email: "h@x.com"),
            account(sub: "fresh", email: "f@x.com"),
            account(sub: "no-twins", email: "n@x.com")
        ]

        let prompts = TwinCalendarDetector.prompts(
            accounts: accounts,
            eventKitAuthorized: true,
            calendars: calendars,
            isHandled: { $0 == "handled" }
        )

        // "handled" is filtered; "no-twins" has no matching EventKit calendar (its Google
        // calendar's title matches nothing) and stays unhandled for later re-evaluation.
        XCTAssertEqual(prompts.map(\.accountID), ["fresh"])
        XCTAssertEqual(prompts.first?.accountEmail, "f@x.com")
        XCTAssertEqual(prompts.first?.twins.map(\.id), ["ek-1"])
    }

    // MARK: - Prompt caption ([M4 review fix 2])

    /// The prompt must name exactly which macOS calendars "Hide duplicates" would deselect —
    /// the D-G6 heuristic can cross-match another account's CalDAV calendars, so the choice is
    /// informed consent over a concrete list, not a blind default.
    func testTwinTitlesListJoinsTitlesForThePromptCaption() {
        let prompt = TwinCalendarPrompt(
            accountID: "sub-1",
            accountEmail: "m@x.com",
            twins: [
                calendar(id: "ek-1", title: "marco@example.com", sourceName: "Google"),
                calendar(id: "ek-2", title: "Birthdays", sourceName: "Google")
            ]
        )
        XCTAssertEqual(prompt.twinTitlesList, "marco@example.com, Birthdays")

        let single = TwinCalendarPrompt(
            accountID: "sub-1",
            accountEmail: "m@x.com",
            twins: [calendar(id: "ek-1", title: "Team", sourceName: "Google")]
        )
        XCTAssertEqual(single.twinTitlesList, "Team")
    }

    // MARK: - Localization coverage (EN + DE)

    func testTwinPromptStringsHaveEnglishAndGermanEntries() throws {
        let keys = [
            "google.twins.title",
            "google.twins.message",
            "google.twins.hide",
            "google.twins.keep",
            "google.twins.affected",
            "meetings.calendar.macosGroup",
            "meetings.calendar.calendarsGrantAccess"
        ]
        for key in keys {
            XCTAssertFalse(try TestSupport.localizedCatalogValue(for: key, language: "en").isEmpty, "EN missing for \(key)")
            XCTAssertFalse(try TestSupport.localizedCatalogValue(for: key, language: "de").isEmpty, "DE missing for \(key)")
        }
    }
}
