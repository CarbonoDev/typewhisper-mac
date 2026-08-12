import XCTest
@testable import TypeWhisper

/// Pure view-state mapping for the Google accounts settings section (M2): badge key + button set
/// per account status (`GoogleAccountRowState`) and the connect-error presenter's
/// suppress-vs-show decisions (`GoogleConnectErrorPresenter`). No SwiftUI, no real
/// Keychain/UserDefaults (§7).
final class GoogleAccountRowStateTests: XCTestCase {
    private func account(status: GoogleAccountStatus) -> GoogleAccount {
        GoogleAccount(
            id: "sub-1",
            email: "ada@example.com",
            displayName: "Ada",
            grantedScopes: ["openid", "email"],
            connectedAt: Date(timeIntervalSince1970: 1_700_000_000),
            statusRaw: status.rawValue
        )
    }

    // MARK: - Row state

    func testConnectedRowShowsConnectedBadgeAndOnlyDisconnect() {
        let state = GoogleAccountRowState.make(for: account(status: .connected))
        XCTAssertEqual(state.badgeKey, "google.accounts.statusConnected")
        XCTAssertFalse(state.showsReconnect, "Reconnect only appears on .needsReauth")
        XCTAssertTrue(state.showsDisconnect)
    }

    func testNeedsReauthRowShowsAttentionBadgeReconnectAndDisconnect() {
        let state = GoogleAccountRowState.make(for: account(status: .needsReauth))
        XCTAssertEqual(state.badgeKey, "google.accounts.statusNeedsReauth")
        XCTAssertTrue(state.showsReconnect)
        XCTAssertTrue(state.showsDisconnect)
    }

    func testUnknownStatusRawFallsBackToConnectedRowState() {
        // `GoogleAccount.status` maps unknown raw values to `.connected` (forward compatibility);
        // the row must follow that mapping rather than crash or invent a third state.
        var row = account(status: .connected)
        row.statusRaw = "some-future-status"
        let state = GoogleAccountRowState.make(for: row)
        XCTAssertEqual(state.badgeKey, "google.accounts.statusConnected")
        XCTAssertFalse(state.showsReconnect)
    }

    // MARK: - Drive-feature affordances ([Google Phase 2 · M3], D-D8)

    func testConnectedRowShowsDriveToggleAndBackfillFollowsTheFlag() {
        let off = GoogleAccountRowState.make(for: account(status: .connected), isDriveImportEnabled: false)
        XCTAssertTrue(off.showsDriveToggle)
        XCTAssertFalse(off.showsDriveBackfill, "backfill entry point requires the toggle on")

        let on = GoogleAccountRowState.make(for: account(status: .connected), isDriveImportEnabled: true)
        XCTAssertTrue(on.showsDriveToggle)
        XCTAssertTrue(on.showsDriveBackfill)
    }

    func testNeedsReauthRowHidesDriveAffordancesEvenWhenEnabled() {
        // A dead grant can neither poll nor consent-extend — reconnect first.
        let state = GoogleAccountRowState.make(for: account(status: .needsReauth), isDriveImportEnabled: true)
        XCTAssertFalse(state.showsDriveToggle)
        XCTAssertFalse(state.showsDriveBackfill)
    }

    // MARK: - Connect-error presenter

    func testCancelledIsSuppressed() {
        // A user-initiated cancel is not an error — the section shows nothing (D-G2 cancel
        // affordance; also the path taken when Cancel races a completed redirect).
        XCTAssertNil(GoogleConnectErrorPresenter.message(for: GoogleAuthError.cancelled))
    }

    func testTimeoutHasADedicatedMessage() {
        let message = GoogleConnectErrorPresenter.message(for: GoogleAuthError.timedOut)
        XCTAssertNotNil(message)
        XCTAssertFalse(message?.isEmpty ?? true)
    }

    func testNotConfiguredReusesTheNotConfiguredHint() {
        let message = GoogleConnectErrorPresenter.message(for: GoogleAuthError.notConfigured)
        XCTAssertEqual(message, String(localized: "google.accounts.notConfigured"))
    }

    func testExchangeFailureUsesGenericMessageCarryingTheDetail() {
        let message = GoogleConnectErrorPresenter.message(
            for: GoogleAuthError.exchangeFailed("invalid_client")
        )
        XCTAssertNotNil(message)
        XCTAssertTrue(
            message?.contains("invalid_client") ?? false,
            "the OAuth error detail must survive into the surfaced message"
        )
    }

    func testNonAuthErrorFallsBackToGenericMessage() {
        let error = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorNotConnectedToInternet,
            userInfo: [NSLocalizedDescriptionKey: "The Internet connection appears to be offline."]
        )
        let message = GoogleConnectErrorPresenter.message(for: error)
        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("offline") ?? false)
    }
}
