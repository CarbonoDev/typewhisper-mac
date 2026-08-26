import XCTest
@testable import TypeWhisper

/// [Google Phase 1 · M4] The D-G4 `hasAnyCalendarSource` availability rule as a pure static:
/// the calendar UI renders when the primary (EventKit) provider is authorized OR ≥ 1 Google
/// account is `.connected` — a `.needsReauth` account is not a working source.
final class CalendarSourceAvailabilityTests: XCTestCase {
    private func account(_ status: GoogleAccountStatus) -> GoogleAccount {
        GoogleAccount(
            id: "sub-\(status.rawValue)",
            email: "user@example.com",
            displayName: nil,
            grantedScopes: ["openid"],
            connectedAt: Date(timeIntervalSince1970: 1_700_000_000),
            statusRaw: status.rawValue
        )
    }

    func testAuthorizedPrimaryWithoutAccountsIsAvailable() {
        XCTAssertTrue(MeetingsViewModel.hasAnyCalendarSource(authorization: .authorized, accounts: []))
    }

    func testDeniedPrimaryWithConnectedAccountIsAvailable() {
        XCTAssertTrue(
            MeetingsViewModel.hasAnyCalendarSource(authorization: .denied, accounts: [account(.connected)])
        )
    }

    func testDeniedPrimaryWithOnlyNeedsReauthAccountsIsUnavailable() {
        XCTAssertFalse(
            MeetingsViewModel.hasAnyCalendarSource(authorization: .denied, accounts: [account(.needsReauth)])
        )
    }

    func testNotDeterminedPrimaryWithoutAccountsIsUnavailable() {
        XCTAssertFalse(MeetingsViewModel.hasAnyCalendarSource(authorization: .notDetermined, accounts: []))
    }

    func testNotDeterminedPrimaryWithConnectedAccountIsAvailable() {
        XCTAssertTrue(
            MeetingsViewModel.hasAnyCalendarSource(authorization: .notDetermined, accounts: [account(.connected)])
        )
    }

    func testRestrictedPrimaryMixedAccountsUsesTheConnectedOne() {
        XCTAssertTrue(
            MeetingsViewModel.hasAnyCalendarSource(
                authorization: .restricted,
                accounts: [account(.needsReauth), account(.connected)]
            )
        )
    }

    // MARK: - Per-source problem row (PR #7 review finding 5)

    func testEventKitDeniedWithGoogleConnectedShowsTheProblemRow() {
        // The working configuration D-G4 keeps out of the connect-card path — but the user's
        // iCloud/Exchange/local events are silently missing, so say so.
        XCTAssertTrue(
            MeetingsViewModel.showsSystemCalendarProblem(
                authorization: .denied,
                accounts: [account(.connected)],
                dismissed: false
            )
        )
        XCTAssertTrue(
            MeetingsViewModel.showsSystemCalendarProblem(
                authorization: .restricted,
                accounts: [account(.connected)],
                dismissed: false
            )
        )
    }

    func testEventKitDeniedWithoutAWorkingGoogleAccountLeavesItToTheConnectCard() {
        XCTAssertFalse(
            MeetingsViewModel.showsSystemCalendarProblem(
                authorization: .denied,
                accounts: [],
                dismissed: false
            )
        )
        XCTAssertFalse(
            MeetingsViewModel.showsSystemCalendarProblem(
                authorization: .denied,
                accounts: [account(.needsReauth)],
                dismissed: false
            )
        )
    }

    func testHealthyEventKitNeverShowsTheProblemRow() {
        XCTAssertFalse(
            MeetingsViewModel.showsSystemCalendarProblem(
                authorization: .authorized,
                accounts: [account(.connected)],
                dismissed: false
            ),
            "both sources fine"
        )
        XCTAssertFalse(
            MeetingsViewModel.showsSystemCalendarProblem(
                authorization: .authorized,
                accounts: [account(.needsReauth)],
                dismissed: false
            ),
            "a Google account needing reauth surfaces on its own settings row"
        )
        XCTAssertFalse(
            MeetingsViewModel.showsSystemCalendarProblem(
                authorization: .notDetermined,
                accounts: [account(.connected)],
                dismissed: false
            ),
            "undecided is not a problem — the Calendars section offers the prompt"
        )
    }

    func testDismissalHidesTheProblemRow() {
        XCTAssertFalse(
            MeetingsViewModel.showsSystemCalendarProblem(
                authorization: .denied,
                accounts: [account(.connected)],
                dismissed: true
            )
        )
    }
}
