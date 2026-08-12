import Foundation

/// Pure D-D8 scope composition ([Google Phase 2 · M3]): the additional OAuth scopes an account's
/// **enabled features** require, consulted by every reauthorize entry point (the settings row's
/// Reconnect, the Home reauth nudge). Under Testing mode (D-D1) refresh tokens die weekly and a
/// Reconnect mints a *new* grant — `include_granted_scopes=true` asks Google to merge prior
/// grants, but composing from the enabled features means one click restores calendar **and**
/// every feature scope in a single consent pass without leaning on that alone.
///
/// Extensible per feature: each enabled feature appends its scope (source of truth: the
/// account store's per-feature toggle accessors). Later phases append theirs here.
@MainActor
enum GoogleFeatureScopes {
    static func additionalScopes(for account: GoogleAccount, store: GoogleAccountStore) -> [String] {
        var scopes: [String] = []
        if store.isDriveImportEnabled(for: account.id) {
            scopes.append(GoogleDriveAPI.readonlyScope)
        }
        return scopes
    }
}

/// The D-D8 enable flow, extracted from the settings view so its **ordering contract** is
/// testable without SwiftUI ([Google Phase 2 · M3]):
///
/// - **ON**: when the account lacks the Drive scope, `reauthorize` runs FIRST; the toggle key is
///   set only after the flow succeeds **and** the re-read account actually carries the scope
///   (Google can silently decline an unchecked checkbox — the "scope-not-granted" branch), then
///   `syncNow` runs so the first discovery happens immediately. A throw anywhere leaves the flag
///   off — the binding re-reads the store, so the toggle visually reverts on its own.
/// - **OFF**: the flag clears immediately; no token changes (the granted scope is harmless) and
///   the engine skips the account next cycle.
@MainActor
enum GoogleDriveToggleFlow {
    enum FlowError: Error, Equatable {
        /// The reauthorize flow completed but the account still lacks the Drive scope — the user
        /// declined the checkbox. Presented via `google.drive.scopeDenied`.
        case scopeDenied
    }

    static func setEnabled(
        _ enabled: Bool,
        account: GoogleAccount,
        store: GoogleAccountStore,
        reauthorize: (_ accountID: String, _ additionalScopes: [String]) async throws -> Void,
        syncNow: () async -> Void
    ) async throws {
        guard enabled else {
            store.setDriveImportEnabled(false, for: account.id)
            return
        }
        if !account.grantedScopes.contains(GoogleDriveAPI.readonlyScope) {
            try await reauthorize(account.id, [GoogleDriveAPI.readonlyScope])
            // Re-read the upserted account: the store unions scopes on upsert (Phase 1 §9), so a
            // granted checkbox is visible here; a declined one is the scopeDenied branch.
            guard store.account(id: account.id)?.grantedScopes.contains(GoogleDriveAPI.readonlyScope) == true
            else {
                throw FlowError.scopeDenied
            }
        }
        store.setDriveImportEnabled(true, for: account.id)
        // The engine does not observe the toggle (deliberate — D-D8): kick the first cycle here.
        await syncNow()
    }
}
