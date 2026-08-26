import XCTest
@testable import TypeWhisper

/// `GmailToggleState` — the pure D-M7 toggle mapping and the ON-flow ordering seam: consent
/// first, flag only after success. Ephemeral defaults + in-memory secret store (§7); the fake
/// reauthorize closure stands in for `GoogleAuthService` so no flow ever runs.
@MainActor
final class GmailToggleStateTests: XCTestCase {
    private final class InMemorySecretStore: GoogleSecretStoring {
        private var secrets: [String: String] = [:]
        func save(_ secret: String, service: String) throws { secrets[service] = secret }
        func load(service: String) -> String? { secrets[service] }
        func delete(service: String) throws { secrets[service] = nil }
        func deleteAll(prefix: String) throws {
            secrets = secrets.filter { !$0.key.hasPrefix(prefix) }
        }
    }

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "GmailToggleStateTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

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

    private func makeStore() -> GoogleAccountStore {
        GoogleAccountStore(defaults: defaults, secretStore: InMemorySecretStore())
    }

    private let gmailScopes = ["openid", GmailContextService.gmailScope]

    // MARK: - make (pure mapping)

    func testIsOnMirrorsTheStoredFlag() {
        XCTAssertEqual(
            GmailToggleState.make(for: account(scopes: gmailScopes), flagged: true),
            GmailToggleState(isOn: true, needsReauthFlow: false)
        )
        XCTAssertEqual(
            GmailToggleState.make(for: account(scopes: gmailScopes), flagged: false),
            GmailToggleState(isOn: false, needsReauthFlow: false)
        )
    }

    func testNeedsReauthFlowExactlyWhenTheGmailScopeWasNeverGranted() {
        XCTAssertEqual(
            GmailToggleState.make(for: account(scopes: ["openid"]), flagged: false),
            GmailToggleState(isOn: false, needsReauthFlow: true)
        )
        XCTAssertEqual(
            GmailToggleState.make(for: account(scopes: ["openid"]), flagged: true),
            GmailToggleState(isOn: true, needsReauthFlow: true)
        )
    }

    func testNeedsReauthAccountStillReflectsStoredEnabledness() {
        // Eligibility gating (status == .connected) lives in the fetch layer — the toggle shows
        // the stored choice so reconnecting heals search without re-toggling (D-M7).
        let state = GmailToggleState.make(
            for: account(scopes: gmailScopes, status: .needsReauth),
            flagged: true
        )
        XCTAssertTrue(state.isOn)
        XCTAssertFalse(state.needsReauthFlow, "scope already granted — reconnect, not re-consent")
    }

    // MARK: - enable (ON-flow ordering)

    func testEnableWithMissingScopeRunsConsentThenSetsFlag() async throws {
        let store = makeStore()
        let subject = account(scopes: ["openid"])
        try store.upsert(subject, refreshToken: "rt")
        var requested: [(String, [String])] = []

        // The fake consent behaves like the real flow: the exchange upserts the account with the
        // widened grant (scope union via `store.upsert`).
        try await GmailToggleState.enable(account: subject, store: store) { [gmailScopes] id, scopes in
            requested.append((id, scopes))
            XCTAssertFalse(store.isGmailEnabled(for: id), "flag must not be set before consent returns")
            try store.upsert(self.account(scopes: gmailScopes), refreshToken: "rt2")
        }

        XCTAssertEqual(requested.map(\.0), ["sub-1"])
        XCTAssertEqual(requested.map(\.1), [[GmailContextService.gmailScope]])
        XCTAssertTrue(store.isGmailEnabled(for: "sub-1"), "flag lands only after success")
    }

    func testEnableLeavesFlagOffWhenConsentSucceedsWithoutGrantingTheScope() async throws {
        // Granular consent (M2 review): the user unticks the Gmail checkbox on Google's consent
        // screen — the flow returns successfully, but the scope never lands in the grant.
        let store = makeStore()
        let subject = account(scopes: ["openid"])
        try store.upsert(subject, refreshToken: "rt")
        var consentRuns = 0

        try await GmailToggleState.enable(account: subject, store: store) { _, _ in
            consentRuns += 1 // succeeds, upserts nothing new — scope still missing
        }

        XCTAssertEqual(consentRuns, 1)
        XCTAssertFalse(store.isGmailEnabled(for: "sub-1"), "no grant ⇒ the toggle stays off, silently")
    }

    func testEnableLeavesFlagOffWhenReauthorizeThrows() async throws {
        let store = makeStore()
        let subject = account(scopes: ["openid"])
        try store.upsert(subject, refreshToken: "rt")

        do {
            try await GmailToggleState.enable(account: subject, store: store) { _, _ in
                throw GoogleAuthError.cancelled
            }
            XCTFail("expected the reauthorize failure to propagate")
        } catch let error as GoogleAuthError {
            XCTAssertEqual(error, .cancelled)
        }

        XCTAssertFalse(store.isGmailEnabled(for: "sub-1"), "a cancelled consent leaves the toggle off")
    }

    /// [Google Phase 3 · M6 restack] Phase 1's fix made `reauthorize` throw `.wrongAccount` when
    /// the user picks a different account in Google's chooser (it no longer leaves a mismatched
    /// account connected). The Gmail toggle drives the same reauthorize, so that must reach the
    /// user as the specific "you signed in as X, but Y needs reconnecting" line — not the generic
    /// error frame, which would send them looking for a Gmail problem that does not exist.
    func testEnableSurfacesAWrongAccountConsentSpecifically() async throws {
        let store = makeStore()
        let subject = account(scopes: ["openid"])
        try store.upsert(subject, refreshToken: "rt")
        let mismatch = GoogleAuthError.wrongAccount(
            expectedEmail: "work@example.com", signedInEmail: "personal@example.com"
        )

        var thrown: Error?
        do {
            try await GmailToggleState.enable(account: subject, store: store) { _, _ in
                throw mismatch
            }
            XCTFail("expected the wrong-account failure to propagate")
        } catch {
            thrown = error
        }

        XCTAssertEqual(thrown as? GoogleAuthError, mismatch)
        XCTAssertFalse(store.isGmailEnabled(for: "sub-1"), "a mismatched sign-in leaves the toggle off")

        let message = try XCTUnwrap(GoogleConnectErrorPresenter.message(for: mismatch))
        XCTAssertTrue(message.contains("personal@example.com"), "names who actually signed in")
        XCTAssertTrue(message.contains("work@example.com"), "names the account still needing a reconnect")
    }

    func testEnableWithGrantedScopeSkipsConsentEntirely() async throws {
        let store = makeStore()
        let subject = account(scopes: gmailScopes)
        try store.upsert(subject, refreshToken: "rt")
        var consentRuns = 0

        try await GmailToggleState.enable(account: subject, store: store) { _, _ in
            consentRuns += 1
        }

        XCTAssertEqual(consentRuns, 0, "scope already granted ⇒ no consent prompt")
        XCTAssertTrue(store.isGmailEnabled(for: "sub-1"))
    }
}
