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
    /// One per-account feature that composes an OAuth scope. Phase 3 adds `case gmail` here plus
    /// its row in `all` — both the request side and the verification side then follow for free.
    enum Feature: String, CaseIterable {
        case driveImport

        var scope: String {
            switch self {
            case .driveImport: GoogleDriveAPI.readonlyScope
            }
        }

        @MainActor
        func isEnabled(_ accountID: String, in store: GoogleAccountStore) -> Bool {
            switch self {
            case .driveImport: store.isDriveImportEnabled(for: accountID)
            }
        }

        @MainActor
        func disable(_ accountID: String, in store: GoogleAccountStore) {
            switch self {
            case .driveImport: store.setDriveImportEnabled(false, for: accountID)
            }
        }
    }

    static func additionalScopes(for account: GoogleAccount, store: GoogleAccountStore) -> [String] {
        Feature.allCases
            .filter { $0.isEnabled(account.id, in: store) }
            .map(\.scope)
    }

    /// Post-reauthorize verification (review fix, 2026-08-12). `reauthorize` requesting a feature
    /// scope proves nothing: Google's consent screen lets the user **uncheck** an individual
    /// scope and still complete the sign-in, and the account then comes back `.connected` with the
    /// feature toggle still on — so the sync engine keeps polling with an unscoped token and
    /// wedges in a permanent 403 loop with no hint that toggling off and on is the fix.
    ///
    /// `GoogleDriveToggleFlow.setEnabled` already verified its own grant; this is the same check
    /// for every *other* reauthorize entry point (the settings row's Reconnect, the Home nudge).
    /// Any enabled feature whose scope is missing from the re-read account is turned OFF and
    /// returned, so the caller can explain what happened.
    @discardableResult
    static func disableFeaturesWithMissingScopes(
        accountID: String,
        store: GoogleAccountStore
    ) -> [Feature] {
        guard let account = store.account(id: accountID) else { return [] }
        let declined = Feature.allCases.filter {
            $0.isEnabled(accountID, in: store) && !account.grantedScopes.contains($0.scope)
        }
        for feature in declined {
            feature.disable(accountID, in: store)
        }
        return declined
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
/// - **OFF**: the flag clears immediately, **and the account's ledger cycle state (watermark +
///   pending guards) is dropped** (review fix) so a later re-enable re-seeds per D-D6 instead of
///   resuming from a months-old watermark and mass-importing everything published while the
///   feature was off. Import entries survive, so nothing that already landed can land twice. No
///   token changes (the granted scope is harmless) and the engine skips the account next cycle.
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
        ledger: GoogleDriveImportLedger,
        reauthorize: (_ accountID: String, _ additionalScopes: [String]) async throws -> Void,
        syncNow: () async -> Void
    ) async throws {
        guard enabled else {
            store.setDriveImportEnabled(false, for: account.id)
            // D-D6: a stopped account must forget where it stopped, or re-enabling replays every
            // transcript published in between. The engine sweeps this too, but eagerly here so an
            // off→on flip inside one cycle cannot slip past the sweep.
            ledger.forgetCycleState(forSub: account.id)
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
