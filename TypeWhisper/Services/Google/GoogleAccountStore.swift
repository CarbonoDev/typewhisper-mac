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

/// Per-account choice of where this account's meeting join links open ([Google Phase 1 · join
/// links]). Persisted as a raw string under `google.account.<sub>.chromeProfile` (written only by
/// `GoogleAccountStore`, D-G5): `"auto"` | `"system"` | `"chrome:<profileDirectory>"`.
enum GoogleAccountLinkOpening: Equatable, Sendable {
    /// Default: the Chrome profile whose signed-in email matches the account
    /// (`ChromeProfileDetector.autoMatch`), else the system browser.
    case auto
    /// Always the system default browser.
    case system
    /// Always this Chrome profile (a `--profile-directory=` value).
    case chromeProfile(directory: String)

    private static let chromePrefix = "chrome:"

    var rawValue: String {
        switch self {
        case .auto: return "auto"
        case .system: return "system"
        case .chromeProfile(let directory): return Self.chromePrefix + directory
        }
    }

    /// Unknown/legacy raw values read as `.auto` — the safe default, since auto still validates
    /// any Chrome launch against the currently detected profiles.
    init(rawValue: String) {
        if rawValue == "system" {
            self = .system
        } else if rawValue.hasPrefix(Self.chromePrefix), rawValue.count > Self.chromePrefix.count {
            self = .chromeProfile(directory: String(rawValue.dropFirst(Self.chromePrefix.count)))
        } else {
            self = .auto
        }
    }
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
    ///
    /// The token is saved **first** and a Keychain failure propagates (SR review): an account row
    /// without its refresh token would report `.connected` while silently unable to ever refresh,
    /// so the index is only touched once the secret is durably stored.
    func upsert(_ account: GoogleAccount, refreshToken: String) throws {
        try secretStore.save(refreshToken, service: SecretService.refreshToken(sub: account.id))
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
        persistIndex()
    }

    /// Removes the account from the index and sweeps its whole Keychain prefix (D-G5) plus its
    /// per-account defaults keys (the Keychain prefix sweep cannot reach UserDefaults, so the
    /// link-opening preference is removed explicitly here).
    func remove(accountID: String) {
        accounts.removeAll { $0.id == accountID }
        try? secretStore.deleteAll(prefix: SecretService.accountPrefix(sub: accountID))
        defaults.removeObject(forKey: Self.linkOpeningKey(sub: accountID))
        defaults.removeObject(forKey: Self.driveImportKey(sub: accountID))
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

    // MARK: - Join-link opening preference ([Google Phase 1 · join links])

    /// The per-account defaults key. Dynamic (one per `sub`), so it lives here beside the
    /// analogous `SecretService` helpers rather than as a `UserDefaultsKeys` constant; the store
    /// stays the sole writer of every `google.*` defaults key (D-G5).
    private static func linkOpeningKey(sub: String) -> String {
        "google.account.\(sub).chromeProfile"
    }

    /// Where this account's meeting join links open. Absent key ⇒ `.auto` (the default).
    func linkOpeningPreference(for accountID: String) -> GoogleAccountLinkOpening {
        guard let raw = defaults.string(forKey: Self.linkOpeningKey(sub: accountID)) else {
            return .auto
        }
        return GoogleAccountLinkOpening(rawValue: raw)
    }

    /// Persists the preference (`.auto` clears the key back to the default). Announces via
    /// `objectWillChange` so the settings picker re-renders — the preference deliberately does not
    /// ride the `accounts` index (it is not account *identity*, and republishing the index would
    /// ripple into the sync engine's account-change trigger).
    func setLinkOpeningPreference(_ preference: GoogleAccountLinkOpening, for accountID: String) {
        objectWillChange.send()
        if preference == .auto {
            defaults.removeObject(forKey: Self.linkOpeningKey(sub: accountID))
        } else {
            defaults.set(preference.rawValue, forKey: Self.linkOpeningKey(sub: accountID))
        }
    }

    // MARK: - Drive import toggle ([Google Phase 2 · M2], D-D8)

    /// The per-account defaults key ("1"/absent) — the exact `chromeProfile` precedent: dynamic
    /// per-`sub`, written only here, swept by `remove(accountID:)`.
    private static func driveImportKey(sub: String) -> String {
        "google.account.\(sub).driveImport"
    }

    /// Whether Drive transcript auto-import is enabled for this account. Absent key ⇒ `false`
    /// (default off — the Drive engine polls nothing until the M3 UI turns a toggle on).
    func isDriveImportEnabled(for accountID: String) -> Bool {
        defaults.string(forKey: Self.driveImportKey(sub: accountID)) == "1"
    }

    /// Persists the toggle (`false` clears the key back to the default). Announces via
    /// `objectWillChange`, not the accounts index (enabled-ness is not account identity, and
    /// republishing the index would ripple into the sync engines' account-change triggers) —
    /// the D-D8 enable flow calls the Drive engine's `syncNow()` explicitly instead.
    func setDriveImportEnabled(_ enabled: Bool, for accountID: String) {
        objectWillChange.send()
        if enabled {
            defaults.set("1", forKey: Self.driveImportKey(sub: accountID))
        } else {
            defaults.removeObject(forKey: Self.driveImportKey(sub: accountID))
        }
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
