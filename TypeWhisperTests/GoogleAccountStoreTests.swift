import XCTest
@testable import TypeWhisper

/// `GoogleAccountStore` over an ephemeral `UserDefaults` suite and an in-memory secret store —
/// no real Keychain, no standard defaults (§7).
@MainActor
final class GoogleAccountStoreTests: XCTestCase {
    /// In-memory `GoogleSecretStoring` fake recording the prefix sweeps disconnect relies on;
    /// `saveError` simulates a Keychain write failure.
    private final class InMemorySecretStore: GoogleSecretStoring {
        private(set) var secrets: [String: String] = [:]
        private(set) var sweptPrefixes: [String] = []
        var saveError: Error?

        func save(_ secret: String, service: String) throws {
            if let saveError {
                throw saveError
            }
            secrets[service] = secret
        }

        func load(service: String) -> String? {
            secrets[service]
        }

        func delete(service: String) throws {
            secrets[service] = nil
        }

        func deleteAll(prefix: String) throws {
            sweptPrefixes.append(prefix)
            secrets = secrets.filter { !$0.key.hasPrefix(prefix) }
        }
    }

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var secretStore: InMemorySecretStore!

    override func setUp() {
        super.setUp()
        suiteName = "GoogleAccountStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        secretStore = InMemorySecretStore()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeStore() -> GoogleAccountStore {
        GoogleAccountStore(defaults: defaults, secretStore: secretStore)
    }

    private func account(
        sub: String,
        email: String = "ada@example.com",
        scopes: [String] = ["openid", "email"],
        status: GoogleAccountStatus = .connected
    ) -> GoogleAccount {
        GoogleAccount(
            id: sub,
            email: email,
            displayName: "Ada",
            grantedScopes: scopes,
            connectedAt: Date(timeIntervalSince1970: 1_700_000_000),
            statusRaw: status.rawValue
        )
    }

    // MARK: - Upsert / dedupe

    func testUpsertInsertsAndPersistsAcrossInstances() throws {
        let store = makeStore()
        try store.upsert(account(sub: "sub-1"), refreshToken: "rt-1")

        XCTAssertEqual(store.accounts.map(\.id), ["sub-1"])
        XCTAssertEqual(store.refreshToken(for: "sub-1"), "rt-1")

        // A second instance over the same defaults reloads the persisted index.
        let reloaded = makeStore()
        XCTAssertEqual(reloaded.accounts.map(\.id), ["sub-1"])
        XCTAssertEqual(reloaded.accounts.first?.email, "ada@example.com")
    }

    func testUpsertDedupesBySubUnionsScopesAndReplacesToken() throws {
        let store = makeStore()
        try store.upsert(account(sub: "sub-1", scopes: ["openid", "email"]), refreshToken: "rt-old")
        try store.upsert(
            account(sub: "sub-1", email: "ada@new.example", scopes: ["openid", "drive.readonly"]),
            refreshToken: "rt-new"
        )

        XCTAssertEqual(store.accounts.count, 1, "re-add must update in place, never duplicate")
        let row = store.accounts[0]
        XCTAssertEqual(row.email, "ada@new.example")
        XCTAssertEqual(
            row.grantedScopes, ["openid", "email", "drive.readonly"],
            "scopes union on re-add (§9 incremental-scope contract)"
        )
        XCTAssertEqual(store.refreshToken(for: "sub-1"), "rt-new")
    }

    func testUpsertKeepsDistinctAccountsApart() throws {
        let store = makeStore()
        try store.upsert(account(sub: "sub-1"), refreshToken: "rt-1")
        try store.upsert(account(sub: "sub-2", email: "grace@example.com"), refreshToken: "rt-2")

        XCTAssertEqual(store.accounts.map(\.id), ["sub-1", "sub-2"])
        XCTAssertEqual(store.refreshToken(for: "sub-1"), "rt-1")
        XCTAssertEqual(store.refreshToken(for: "sub-2"), "rt-2")
    }

    func testUpsertThrowsAndRecordsNothingWhenSecretSaveFails() {
        // SR review: a row recorded without its refresh token would look .connected while being
        // silently unable to refresh — the save failure must surface and leave the index untouched.
        secretStore.saveError = KeychainError.saveFailed(-25299)
        let store = makeStore()

        XCTAssertThrowsError(try store.upsert(account(sub: "sub-1"), refreshToken: "rt-1"))
        XCTAssertTrue(store.accounts.isEmpty, "no account row without its refresh token")
        XCTAssertTrue(makeStore().accounts.isEmpty, "nothing persisted either")
    }

    // MARK: - Remove

    func testRemoveSweepsTheAccountKeychainPrefix() throws {
        let store = makeStore()
        try store.upsert(account(sub: "sub-1"), refreshToken: "rt-1")
        // A hypothetical future per-account secret under the same prefix must be swept too (D-G5).
        try secretStore.save("extra", service: "google.account.sub-1.future-secret")

        store.remove(accountID: "sub-1")

        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertEqual(secretStore.sweptPrefixes, ["google.account.sub-1."])
        XCTAssertNil(secretStore.load(service: "google.account.sub-1.refresh"))
        XCTAssertNil(secretStore.load(service: "google.account.sub-1.future-secret"))
    }

    // MARK: - Status

    func testSetStatusPersists() throws {
        let store = makeStore()
        try store.upsert(account(sub: "sub-1"), refreshToken: "rt-1")

        store.setStatus(.needsReauth, for: "sub-1")
        XCTAssertEqual(store.accounts.first?.status, .needsReauth)

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.accounts.first?.status, .needsReauth)
    }

    func testSetStatusForUnknownAccountIsANoOp() {
        let store = makeStore()
        store.setStatus(.needsReauth, for: "ghost")
        XCTAssertTrue(store.accounts.isEmpty)
    }

    // MARK: - OAuth client configuration

    func testClientConfigurationRoundTripAndIsConfigured() {
        let store = makeStore()
        XCTAssertFalse(store.isConfigured)

        store.clientID = "client-123.apps.googleusercontent.com"
        XCTAssertFalse(store.isConfigured, "secret still missing")

        store.clientSecret = " secret-abc \n"
        XCTAssertEqual(store.clientSecret, "secret-abc", "whitespace trimmed before storage")
        XCTAssertTrue(store.isConfigured)
        XCTAssertEqual(
            secretStore.load(service: "google.oauth.client-secret"), "secret-abc",
            "client secret goes to the Keychain seam, never defaults (D-G5)"
        )

        store.clientID = ""
        XCTAssertNil(store.clientID, "empty string clears the value")
        XCTAssertFalse(store.isConfigured)
    }

    // MARK: - Twin prompt bookkeeping (D-G6)

    func testTwinPromptHandledRoundTrip() {
        let store = makeStore()
        XCTAssertFalse(store.isTwinPromptHandled("sub-1"))

        store.markTwinPromptHandled("sub-1")
        store.markTwinPromptHandled("sub-1") // idempotent
        XCTAssertTrue(store.isTwinPromptHandled("sub-1"))
        XCTAssertFalse(store.isTwinPromptHandled("sub-2"))

        XCTAssertEqual(
            defaults.stringArray(forKey: UserDefaultsKeys.googleTwinPromptHandled), ["sub-1"]
        )
    }
}
