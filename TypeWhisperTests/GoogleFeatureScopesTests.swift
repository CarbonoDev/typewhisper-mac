import XCTest
@testable import TypeWhisper

/// The pure D-D8 surfaces ([Google Phase 2 · M3]): feature-scope composition for reconnects
/// (`GoogleFeatureScopes`) and the Drive-toggle enable flow's ordering contract
/// (`GoogleDriveToggleFlow` — reauthorize FIRST, flag only on success, syncNow last; any
/// failure leaves the flag off). Fake secret store + unique defaults suite; no network.
@MainActor
final class GoogleFeatureScopesTests: XCTestCase {
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
    private var ledgerDirectory: URL!

    override func setUp() {
        super.setUp()
        suiteName = "GoogleFeatureScopesTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        ledgerDirectory = try? TestSupport.makeTemporaryDirectory(prefix: "FeatureScopesLedger")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        if let ledgerDirectory { TestSupport.remove(ledgerDirectory) }
        super.tearDown()
    }

    private func makeLedger() -> GoogleDriveImportLedger {
        GoogleDriveImportLedger(
            fileURL: ledgerDirectory.appendingPathComponent("google-drive-imports.json")
        )
    }

    private func makeStore() -> GoogleAccountStore {
        GoogleAccountStore(defaults: defaults, secretStore: InMemorySecretStore())
    }

    private func account(sub: String, scopes: [String] = ["openid", "email"]) -> GoogleAccount {
        GoogleAccount(
            id: sub,
            email: "\(sub)@example.com",
            displayName: nil,
            grantedScopes: scopes,
            connectedAt: Date(timeIntervalSince1970: 1_700_000_000),
            statusRaw: GoogleAccountStatus.connected.rawValue
        )
    }

    // MARK: - Scope composition (D-D8)

    func testNoEnabledFeaturesComposeNoAdditionalScopes() throws {
        let store = makeStore()
        let account = account(sub: "sub-1")
        try store.upsert(account, refreshToken: "rt")

        XCTAssertEqual(GoogleFeatureScopes.additionalScopes(for: account, store: store), [])
    }

    func testDriveToggleOnComposesTheDriveScope() throws {
        let store = makeStore()
        let account = account(sub: "sub-1")
        try store.upsert(account, refreshToken: "rt")
        store.setDriveImportEnabled(true, for: "sub-1")

        XCTAssertEqual(
            GoogleFeatureScopes.additionalScopes(for: account, store: store),
            [GoogleDriveAPI.readonlyScope]
        )
    }

    func testGmailToggleOnComposesTheGmailScope() throws {
        // [Google Phase 3 · M6] Gmail wired into the D-D8 seam: Reconnect / nudge consent passes
        // re-carry the Gmail scope for toggled-on accounts.
        let store = makeStore()
        let account = account(sub: "sub-1")
        try store.upsert(account, refreshToken: "rt")
        store.setGmailEnabled(true, for: "sub-1")

        XCTAssertEqual(
            GoogleFeatureScopes.additionalScopes(for: account, store: store),
            [GmailContextService.gmailScope]
        )
    }

    func testBothFeatureTogglesComposeBothScopes() throws {
        let store = makeStore()
        let account = account(sub: "sub-1")
        try store.upsert(account, refreshToken: "rt")
        store.setDriveImportEnabled(true, for: "sub-1")
        store.setGmailEnabled(true, for: "sub-1")

        XCTAssertEqual(
            GoogleFeatureScopes.additionalScopes(for: account, store: store),
            [GoogleDriveAPI.readonlyScope, GmailContextService.gmailScope],
            "one consent pass restores calendar + Drive + Gmail together"
        )
    }

    func testCompositionIsPerAccount() throws {
        let store = makeStore()
        let enabled = account(sub: "sub-on")
        let disabled = account(sub: "sub-off")
        try store.upsert(enabled, refreshToken: "rt-1")
        try store.upsert(disabled, refreshToken: "rt-2")
        store.setDriveImportEnabled(true, for: "sub-on")

        XCTAssertEqual(
            GoogleFeatureScopes.additionalScopes(for: enabled, store: store),
            [GoogleDriveAPI.readonlyScope]
        )
        XCTAssertEqual(GoogleFeatureScopes.additionalScopes(for: disabled, store: store), [],
                       "another account's toggle never leaks into this one's scopes")
    }

    // MARK: - Post-reauthorize scope verification (review fix, 2026-08-12)

    /// Reconnect requests the Drive scope but the user unchecks the box on the consent screen:
    /// without verification the account comes back `.connected` with the toggle still on, and the
    /// engine polls forever with an unscoped token (a permanent 403 loop, no remedy shown).
    func testDeclinedFeatureScopeTurnsTheFeatureOffAndIsReported() throws {
        let store = makeStore()
        let reconnected = account(sub: "sub-1", scopes: ["openid", "email"])
        try store.upsert(reconnected, refreshToken: "rt")
        store.setDriveImportEnabled(true, for: "sub-1")

        let declined = GoogleFeatureScopes.disableFeaturesWithMissingScopes(
            accountID: "sub-1", store: store
        )

        XCTAssertEqual(declined, [.driveImport])
        XCTAssertFalse(store.isDriveImportEnabled(for: "sub-1"),
                       "the feature must not stay on without its scope")
    }

    func testGrantedFeatureScopeLeavesTheToggleAlone() throws {
        let store = makeStore()
        let reconnected = account(sub: "sub-1", scopes: ["openid", GoogleDriveAPI.readonlyScope])
        try store.upsert(reconnected, refreshToken: "rt")
        store.setDriveImportEnabled(true, for: "sub-1")

        XCTAssertEqual(
            GoogleFeatureScopes.disableFeaturesWithMissingScopes(accountID: "sub-1", store: store),
            []
        )
        XCTAssertTrue(store.isDriveImportEnabled(for: "sub-1"))
    }

    /// [Google Phase 3 · M6] Gmail is a row in the same table, so it inherits the verification:
    /// a Reconnect whose consent pass dropped the Gmail checkbox turns the search off instead of
    /// leaving it polling with an unscoped token.
    func testDeclinedGmailScopeTurnsTheGmailToggleOff() throws {
        let store = makeStore()
        let reconnected = account(sub: "sub-1", scopes: ["openid", "email"])
        try store.upsert(reconnected, refreshToken: "rt")
        store.setGmailEnabled(true, for: "sub-1")

        let declined = GoogleFeatureScopes.disableFeaturesWithMissingScopes(
            accountID: "sub-1", store: store
        )

        XCTAssertEqual(declined, [.gmail])
        XCTAssertFalse(store.isGmailEnabled(for: "sub-1"))
    }

    /// One consent pass can decline both checkboxes — both must be reported, so the call sites
    /// can show both explanations rather than one silently winning.
    func testBothDeclinedFeaturesAreReportedTogether() throws {
        let store = makeStore()
        let reconnected = account(sub: "sub-1", scopes: ["openid"])
        try store.upsert(reconnected, refreshToken: "rt")
        store.setDriveImportEnabled(true, for: "sub-1")
        store.setGmailEnabled(true, for: "sub-1")

        XCTAssertEqual(
            GoogleFeatureScopes.disableFeaturesWithMissingScopes(accountID: "sub-1", store: store),
            [.driveImport, .gmail]
        )
        XCTAssertFalse(store.isDriveImportEnabled(for: "sub-1"))
        XCTAssertFalse(store.isGmailEnabled(for: "sub-1"))
    }

    /// The granted half survives when only the other is declined.
    func testGrantedGmailScopeSurvivesADeclinedDriveScope() throws {
        let store = makeStore()
        let reconnected = account(sub: "sub-1", scopes: ["openid", GmailContextService.gmailScope])
        try store.upsert(reconnected, refreshToken: "rt")
        store.setDriveImportEnabled(true, for: "sub-1")
        store.setGmailEnabled(true, for: "sub-1")

        XCTAssertEqual(
            GoogleFeatureScopes.disableFeaturesWithMissingScopes(accountID: "sub-1", store: store),
            [.driveImport]
        )
        XCTAssertTrue(store.isGmailEnabled(for: "sub-1"))
    }

    /// A disabled feature is never "declined" — verification only ever inspects what is on.
    func testDisabledFeaturesAreNotReportedAsDeclined() throws {
        let store = makeStore()
        try store.upsert(account(sub: "sub-1"), refreshToken: "rt")

        XCTAssertEqual(
            GoogleFeatureScopes.disableFeaturesWithMissingScopes(accountID: "sub-1", store: store),
            []
        )
    }

    // MARK: - Toggle enable flow (D-D8 ordering contract)

    func testOffClearsTheFlagImmediatelyWithoutReauthorize() async throws {
        let store = makeStore()
        let account = account(sub: "sub-1")
        try store.upsert(account, refreshToken: "rt")
        store.setDriveImportEnabled(true, for: "sub-1")
        var events: [String] = []

        try await GoogleDriveToggleFlow.setEnabled(
            false, account: account, store: store,
            ledger: makeLedger(),
            reauthorize: { _, _ in events.append("reauthorize") },
            syncNow: { events.append("syncNow") }
        )

        XCTAssertFalse(store.isDriveImportEnabled(for: "sub-1"))
        XCTAssertEqual(events, [], "OFF is a local flag clear — no token changes, no sync kick")
    }

    func testOnWithScopeAlreadyGrantedSkipsReauthorizeAndSyncs() async throws {
        let store = makeStore()
        let account = account(sub: "sub-1", scopes: ["openid", GoogleDriveAPI.readonlyScope])
        try store.upsert(account, refreshToken: "rt")
        var events: [String] = []

        try await GoogleDriveToggleFlow.setEnabled(
            true, account: account, store: store,
            ledger: makeLedger(),
            reauthorize: { _, _ in events.append("reauthorize") },
            syncNow: { events.append("syncNow") }
        )

        XCTAssertTrue(store.isDriveImportEnabled(for: "sub-1"))
        XCTAssertEqual(events, ["syncNow"], "no consent round-trip when the scope is already granted")
    }

    func testOnWithoutScopeReauthorizesFirstThenFlagsThenSyncs() async throws {
        let store = makeStore()
        let account = account(sub: "sub-1")
        try store.upsert(account, refreshToken: "rt")
        var events: [String] = []

        try await GoogleDriveToggleFlow.setEnabled(
            true, account: account, store: store,
            ledger: makeLedger(),
            reauthorize: { accountID, scopes in
                XCTAssertEqual(scopes, [GoogleDriveAPI.readonlyScope])
                XCTAssertFalse(store.isDriveImportEnabled(for: accountID),
                               "the flag must not be set before the consent flow succeeds")
                events.append("reauthorize")
                // The real flow's exchange upserts the account with the granted scope (the
                // store unions scopes) — mirror that here.
                try store.upsert(
                    self.account(sub: accountID, scopes: [GoogleDriveAPI.readonlyScope]),
                    refreshToken: "rt-fresh"
                )
            },
            syncNow: { events.append("syncNow") }
        )

        XCTAssertTrue(store.isDriveImportEnabled(for: "sub-1"))
        XCTAssertEqual(events, ["reauthorize", "syncNow"], "reauthorize FIRST, sync kick LAST")
    }

    func testReauthorizeThrowLeavesTheFlagOffAndSkipsSync() async throws {
        let store = makeStore()
        let account = account(sub: "sub-1")
        try store.upsert(account, refreshToken: "rt")
        var syncCalled = false

        do {
            try await GoogleDriveToggleFlow.setEnabled(
                true, account: account, store: store,
                ledger: makeLedger(),
                reauthorize: { _, _ in throw GoogleAuthError.cancelled },
                syncNow: { syncCalled = true }
            )
            XCTFail("expected the reauthorize throw to propagate")
        } catch {
            XCTAssertEqual(error as? GoogleAuthError, .cancelled)
        }
        XCTAssertFalse(store.isDriveImportEnabled(for: "sub-1"), "a failed consent never enables")
        XCTAssertFalse(syncCalled)
    }

    func testScopeNotGrantedThrowsScopeDeniedAndLeavesTheFlagOff() async throws {
        let store = makeStore()
        let account = account(sub: "sub-1")
        try store.upsert(account, refreshToken: "rt")

        do {
            try await GoogleDriveToggleFlow.setEnabled(
                true, account: account, store: store,
                ledger: makeLedger(),
                // The flow "succeeds" but the user unchecked the Drive box: the re-read account
                // still lacks the scope.
                reauthorize: { _, _ in },
                syncNow: { XCTFail("must not sync after a scope denial") }
            )
            XCTFail("expected scopeDenied")
        } catch {
            XCTAssertEqual(error as? GoogleDriveToggleFlow.FlowError, .scopeDenied)
        }
        XCTAssertFalse(store.isDriveImportEnabled(for: "sub-1"))
    }
}
