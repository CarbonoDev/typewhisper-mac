import XCTest
import Combine
@testable import TypeWhisper

/// The D-M7 per-account Gmail flag on `GoogleAccountStore`: dynamic-key round-trip,
/// `objectWillChange` announcement (the flag never rides the `accounts` index), and cleanup on
/// `remove(accountID:)`. Ephemeral defaults suite + in-memory secret store (§7).
@MainActor
final class GoogleAccountStoreGmailFlagTests: XCTestCase {
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

    override func setUp() {
        super.setUp()
        suiteName = "GoogleAccountStoreGmailFlagTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeStore() -> GoogleAccountStore {
        GoogleAccountStore(defaults: defaults, secretStore: InMemorySecretStore())
    }

    private func upsert(_ sub: String, into store: GoogleAccountStore) throws {
        try store.upsert(
            GoogleAccount(
                id: sub,
                email: "\(sub)@example.com",
                displayName: nil,
                grantedScopes: ["openid"],
                connectedAt: Date(timeIntervalSince1970: 1_700_000_000),
                statusRaw: GoogleAccountStatus.connected.rawValue
            ),
            refreshToken: "rt-\(sub)"
        )
    }

    func testFlagDefaultsToFalseAndRoundTripsPerAccount() throws {
        let store = makeStore()
        try upsert("sub-1", into: store)
        try upsert("sub-2", into: store)

        XCTAssertFalse(store.isGmailEnabled(for: "sub-1"), "off until the user opts in")

        store.setGmailEnabled(true, for: "sub-1")
        XCTAssertTrue(store.isGmailEnabled(for: "sub-1"))
        XCTAssertFalse(store.isGmailEnabled(for: "sub-2"), "flags are per account")
        XCTAssertTrue(
            defaults.bool(forKey: "google.account.sub-1.gmailEnabled"),
            "the D-M7 dynamic key, written only by the store"
        )

        store.setGmailEnabled(false, for: "sub-1")
        XCTAssertFalse(store.isGmailEnabled(for: "sub-1"))
        XCTAssertNil(defaults.object(forKey: "google.account.sub-1.gmailEnabled"), "false clears the key")
    }

    func testSetAnnouncesViaObjectWillChangeWithoutRepublishingAccounts() throws {
        let store = makeStore()
        try upsert("sub-1", into: store)

        var willChangeCount = 0
        var accountsPublishes = 0
        var cancellables = Set<AnyCancellable>()
        store.objectWillChange.sink { _ in willChangeCount += 1 }.store(in: &cancellables)
        store.$accounts.dropFirst().sink { _ in accountsPublishes += 1 }.store(in: &cancellables)

        store.setGmailEnabled(true, for: "sub-1")

        XCTAssertEqual(willChangeCount, 1, "toggle flips announce via objectWillChange (D-M7)")
        XCTAssertEqual(accountsPublishes, 0, "the flag never rides the accounts index")
    }

    func testRemoveClearsTheFlagKey() throws {
        let store = makeStore()
        try upsert("sub-1", into: store)
        store.setGmailEnabled(true, for: "sub-1")

        store.remove(accountID: "sub-1")

        XCTAssertNil(defaults.object(forKey: "google.account.sub-1.gmailEnabled"))
        try upsert("sub-1", into: store)
        XCTAssertFalse(store.isGmailEnabled(for: "sub-1"), "a re-added account starts with Gmail off")
    }
}
