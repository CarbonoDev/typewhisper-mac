import Foundation
import Combine

/// A connected Google account (§4). Non-secret metadata only — the refresh token lives in the
/// Keychain under `google.account.<sub>.refresh` (D-G5). `id` is the Google `sub` claim: stable
/// across email changes, so re-adding the same account dedupes instead of duplicating (D-G3).
struct GoogleAccount: Codable, Equatable, Identifiable, Sendable {
    var id: String            // Google `sub`
    var email: String
    var displayName: String?
    var grantedScopes: [String]
    var connectedAt: Date
    var statusRaw: String     // GoogleAccountStatus

    var status: GoogleAccountStatus {
        GoogleAccountStatus(rawValue: statusRaw) ?? .connected
    }
}

/// `connected` = usable; `needsReauth` = the refresh token was rejected (revoked/expired) and the
/// user must run the connect flow again (D-G2 `invalid_grant` handling).
enum GoogleAccountStatus: String, Codable, Sendable {
    case connected
    case needsReauth
}

/// Single writer of all Google account state (D-G5): the JSON account index and OAuth client ID in
/// UserDefaults, plus refresh tokens and the client secret in the Keychain (via the injected
/// `GoogleSecretStoring` seam). Every `google.*` defaults key and every `google.*` Keychain
/// service is written only here, mirroring how each meetings service solely owns its store.
/// No SwiftData store — accounts are a handful of small non-relational records (D-G5).
@MainActor
final class GoogleAccountStore: ObservableObject {
    /// Keychain service names (prefixed with `AppConstants.keychainServicePrefix` inside
    /// `KeychainService`, so Debug/Release never collide).
    enum SecretService {
        static let clientSecret = "google.oauth.client-secret"
        static func refreshToken(sub: String) -> String { "google.account.\(sub).refresh" }
        /// Disconnect sweeps this whole prefix so any future per-account secrets go too (D-G5).
        static func accountPrefix(sub: String) -> String { "google.account.\(sub)." }
    }

    /// The connected accounts, in connect order. Persisted as JSON under
    /// `UserDefaultsKeys.googleAccountsIndex`; published for the settings UI and (from M4) the
    /// `hasAnyCalendarSource` availability flag.
    @Published private(set) var accounts: [GoogleAccount] = []

    private let defaults: UserDefaults
    private let secretStore: GoogleSecretStoring

    init(
        defaults: UserDefaults = .standard,
        secretStore: GoogleSecretStoring = KeychainGoogleSecretStore()
    ) {
        self.defaults = defaults
        self.secretStore = secretStore
        accounts = Self.loadIndex(from: defaults)
    }

    // MARK: - OAuth client configuration

    /// The pasted Google OAuth client ID — a public identifier, so plain UserDefaults (D-G5).
    var clientID: String? {
        get {
            let value = defaults.string(forKey: UserDefaultsKeys.googleOAuthClientID)
            return (value?.isEmpty ?? true) ? nil : value
        }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty {
                defaults.set(trimmed, forKey: UserDefaultsKeys.googleOAuthClientID)
            } else {
                defaults.removeObject(forKey: UserDefaultsKeys.googleOAuthClientID)
            }
        }
    }

    /// The pasted client secret. Google treats Desktop-app secrets as non-confidential (D-G2), but
    /// it still doesn't belong in defaults — Keychain via the secret seam.
    var clientSecret: String? {
        get { secretStore.load(service: SecretService.clientSecret) }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty {
                try? secretStore.save(trimmed, service: SecretService.clientSecret)
            } else {
                try? secretStore.delete(service: SecretService.clientSecret)
            }
        }
    }

    /// Whether the connect flow can run — both client credentials pasted (M2 gates the Connect
    /// button on this).
    var isConfigured: Bool {
        clientID != nil && clientSecret != nil
    }

    // MARK: - Accounts

    func account(id: String) -> GoogleAccount? {
        accounts.first { $0.id == id }
    }

    /// Inserts or updates an account, deduped by `sub`. On a re-add the scopes are unioned (the
    /// incremental-scope contract, §9 — Google merges grants server-side, the index mirrors that)
    /// and the stored refresh token is replaced with the fresh one.
    func upsert(_ account: GoogleAccount, refreshToken: String) {
        var incoming = account
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            let existing = accounts[index]
            var scopes = existing.grantedScopes
            for scope in account.grantedScopes where !scopes.contains(scope) {
                scopes.append(scope)
            }
            incoming.grantedScopes = scopes
            accounts[index] = incoming
        } else {
            accounts.append(incoming)
        }
        try? secretStore.save(refreshToken, service: SecretService.refreshToken(sub: account.id))
        persistIndex()
    }

    /// Removes the account from the index and sweeps its whole Keychain prefix (D-G5).
    func remove(accountID: String) {
        accounts.removeAll { $0.id == accountID }
        try? secretStore.deleteAll(prefix: SecretService.accountPrefix(sub: accountID))
        persistIndex()
    }

    func refreshToken(for accountID: String) -> String? {
        secretStore.load(service: SecretService.refreshToken(sub: accountID))
    }

    func setStatus(_ status: GoogleAccountStatus, for accountID: String) {
        guard let index = accounts.firstIndex(where: { $0.id == accountID }) else { return }
        accounts[index].statusRaw = status.rawValue
        persistIndex()
    }

    // MARK: - Twin-calendar prompt bookkeeping (D-G6, consumed in M4)

    /// Records that the one-time duplicate-calendars prompt ran for this account (either choice).
    /// Sole writer of the `googleTwinPromptHandled` defaults key.
    func markTwinPromptHandled(_ accountID: String) {
        var handled = defaults.stringArray(forKey: UserDefaultsKeys.googleTwinPromptHandled) ?? []
        guard !handled.contains(accountID) else { return }
        handled.append(accountID)
        defaults.set(handled, forKey: UserDefaultsKeys.googleTwinPromptHandled)
    }

    func isTwinPromptHandled(_ accountID: String) -> Bool {
        (defaults.stringArray(forKey: UserDefaultsKeys.googleTwinPromptHandled) ?? [])
            .contains(accountID)
    }

    // MARK: - Persistence

    private func persistIndex() {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        defaults.set(data, forKey: UserDefaultsKeys.googleAccountsIndex)
    }

    private static func loadIndex(from defaults: UserDefaults) -> [GoogleAccount] {
        guard let data = defaults.data(forKey: UserDefaultsKeys.googleAccountsIndex),
              let accounts = try? JSONDecoder().decode([GoogleAccount].self, from: data) else {
            return []
        }
        return accounts
    }
}
