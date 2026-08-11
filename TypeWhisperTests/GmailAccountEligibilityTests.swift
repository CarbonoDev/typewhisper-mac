import XCTest
@testable import TypeWhisper

/// `GmailAccountEligibility` — the pure D-M7 effective-enablement rule:
/// connected ∧ scope granted ∧ per-account flag.
final class GmailAccountEligibilityTests: XCTestCase {
    private func account(
        scopes: [String],
        status: GoogleAccountStatus = .connected
    ) -> GoogleAccount {
        GoogleAccount(
            id: "sub-1",
            email: "ada@example.com",
            displayName: nil,
            grantedScopes: scopes,
            connectedAt: Date(timeIntervalSince1970: 1_700_000_000),
            statusRaw: status.rawValue
        )
    }

    func testEnabledRequiresAllThreeConditions() {
        let gmailScopes = ["openid", GmailContextService.gmailScope]
        XCTAssertTrue(GmailAccountEligibility.isEnabled(account: account(scopes: gmailScopes), flagged: true))

        XCTAssertFalse(
            GmailAccountEligibility.isEnabled(account: account(scopes: gmailScopes), flagged: false),
            "granted scope but toggle off"
        )
        XCTAssertFalse(
            GmailAccountEligibility.isEnabled(account: account(scopes: ["openid"]), flagged: true),
            "toggle on but scope never granted"
        )
        XCTAssertFalse(
            GmailAccountEligibility.isEnabled(
                account: account(scopes: gmailScopes, status: .needsReauth), flagged: true
            ),
            "a .needsReauth account is never searched (D-M7)"
        )
    }

    func testScopeConstantIsTheReadonlyGmailScope() {
        // D-M7: the constant lives on GmailContextService, deliberately NOT on GoogleAuthService.
        XCTAssertEqual(GmailContextService.gmailScope, "https://www.googleapis.com/auth/gmail.readonly")
    }
}
