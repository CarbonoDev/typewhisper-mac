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
}
