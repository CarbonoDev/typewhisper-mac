import XCTest
@testable import TypeWhisper

/// The Home reauth nudge's pure visibility rule ([Google Phase 2 · M3], D-D8):
/// `[GoogleAccount] → nudge state`. The view is logic-free, so this covers the whole decision.
final class GoogleReauthNudgeRuleTests: XCTestCase {
    private func account(sub: String, status: GoogleAccountStatus) -> GoogleAccount {
        GoogleAccount(
            id: sub,
            email: "\(sub)@example.com",
            displayName: nil,
            grantedScopes: ["openid"],
            connectedAt: Date(timeIntervalSince1970: 1_700_000_000),
            statusRaw: status.rawValue
        )
    }

    func testNoAccountsRendersNothing() {
        XCTAssertNil(GoogleReauthNudgeRule.state(for: []))
    }

    func testAllConnectedRendersNothing() {
        let accounts = [
            account(sub: "sub-1", status: .connected),
            account(sub: "sub-2", status: .connected),
        ]
        XCTAssertNil(GoogleReauthNudgeRule.state(for: accounts))
    }

    func testSingleNeedsReauthSurfacesThatAccount() {
        let accounts = [
            account(sub: "sub-1", status: .connected),
            account(sub: "sub-2", status: .needsReauth),
        ]
        XCTAssertEqual(
            GoogleReauthNudgeRule.state(for: accounts),
            GoogleReauthNudgeState(
                accountID: "sub-2",
                accountEmail: "sub-2@example.com",
                needingCount: 1
            )
        )
    }

    func testMultipleNeedingSurfaceTheFirstInConnectOrderWithTheFullCount() {
        // The weekly Testing-mode expiry (D-D1) flips every account at once — the nudge targets
        // the first and re-renders for the next after each reconnect.
        let accounts = [
            account(sub: "sub-1", status: .needsReauth),
            account(sub: "sub-2", status: .connected),
            account(sub: "sub-3", status: .needsReauth),
        ]
        XCTAssertEqual(
            GoogleReauthNudgeRule.state(for: accounts),
            GoogleReauthNudgeState(
                accountID: "sub-1",
                accountEmail: "sub-1@example.com",
                needingCount: 2
            )
        )
    }
}
