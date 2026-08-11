import SwiftUI

/// Settings › Meetings › Google Accounts ([Google Phase 1 · M2], spec §M2). Connect/disconnect
/// Google accounts for the upcoming calendar integration (D-G2 flow):
///
/// - "OAuth client" disclosure for the pasted client ID/secret — no hardcoded credentials
///   anywhere (D-G5); Connect stays disabled until both are present, with an explanatory line
///   pointing at the Appendix A runbook.
/// - One row per connected account (email + display name) with a status badge; `Reconnect`
///   appears on `.needsReauth` (runs `reauthorize(accountID:additionalScopes: [])`), `Disconnect`
///   always.
/// - "Add Google Account…" drives `GoogleAuthService.connectAccount()` with a progress row and a
///   cancel affordance (`cancelConnect()` stops the loopback listener); failures surface as an
///   inline error line.
///
/// Row logic lives in `GoogleAccountRowState` / `GoogleConnectErrorPresenter` so the view stays
/// logic-free (`GoogleAccountRowStateTests`).
struct GoogleAccountsSection: View {
    @ObservedObject private var accountStore = ServiceContainer.shared.googleAccountStore
    private let authService = ServiceContainer.shared.googleAuthService

    /// Local drafts of the client credentials, seeded from the store on appear and written
    /// through on change (`GoogleAccountStore` stays the single writer of the persisted values —
    /// the drafts only exist so SwiftUI has bindable state).
    @State private var clientIDDraft = ""
    @State private var clientSecretDraft = ""
    /// Auto-expanded on appear while unconfigured so first-run users find the credential fields.
    @State private var isClientExpanded = false
    /// A connect/reauthorize flow is waiting for the browser redirect.
    @State private var isConnecting = false
    /// Inline error from the last failed connect/reauthorize (nil after cancel — not an error).
    @State private var connectError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "google.accounts.sectionTitle"))
                .font(.headline)

            clientDisclosure

            if !accountStore.accounts.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(accountStore.accounts) { account in
                        accountRow(account)
                        if account.id != accountStore.accounts.last?.id {
                            Divider()
                        }
                    }
                }
            }

            if isConnecting {
                connectingRow
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Button(String(localized: "google.accounts.addAccount")) {
                        connect()
                    }
                    .disabled(!isConfigured)
                    if !isConfigured {
                        Text(String(localized: "google.accounts.notConfigured"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let connectError {
                Text(connectError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear(perform: load)
    }

    /// Configured = both credential drafts non-blank. Mirrors `GoogleAccountStore.isConfigured`
    /// (the drafts are written through on every change) without a Keychain read per render.
    private var isConfigured: Bool {
        !clientIDDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !clientSecretDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - OAuth client configuration (D-G5: pasted, never hardcoded)

    private var clientDisclosure: some View {
        DisclosureGroup(isExpanded: $isClientExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "google.accounts.clientID"))
                        .font(.callout)
                    TextField(String(localized: "google.accounts.clientID"), text: $clientIDDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 420)
                        .onChange(of: clientIDDraft) { _, newValue in
                            accountStore.clientID = newValue
                        }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "google.accounts.clientSecret"))
                        .font(.callout)
                    SecureField(String(localized: "google.accounts.clientSecret"), text: $clientSecretDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 420)
                        .onChange(of: clientSecretDraft) { _, newValue in
                            accountStore.clientSecret = newValue
                        }
                }
                Text(String(localized: "google.accounts.clientHelp"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 6)
        } label: {
            Text(String(localized: "google.accounts.clientSection"))
                .font(.callout)
        }
    }

    // MARK: - Account rows

    private func accountRow(_ account: GoogleAccount) -> some View {
        let rowState = GoogleAccountRowState.make(for: account)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(account.email)
                    .font(.callout)
                if let name = account.displayName, !name.isEmpty {
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            statusBadge(rowState, status: account.status)
            if rowState.showsReconnect {
                Button(String(localized: "google.accounts.reconnect")) {
                    reconnect(account)
                }
            }
            if rowState.showsDisconnect {
                Button(String(localized: "google.accounts.disconnect")) {
                    disconnect(account)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func statusBadge(_ rowState: GoogleAccountRowState, status: GoogleAccountStatus) -> some View {
        let tint: Color = status == .connected ? .green : .orange
        return Text(String(localized: String.LocalizationValue(rowState.badgeKey)))
            .font(.caption)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
    }

    // MARK: - Connect / reconnect / disconnect

    private var connectingRow: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(String(localized: "google.accounts.connecting"))
                .font(.callout)
                .foregroundStyle(.secondary)
            Button(String(localized: "google.accounts.cancel")) {
                // Stops the loopback listener and fails the pending wait with `.cancelled`
                // (D-G2) — which the presenter suppresses, so no error line appears.
                authService.cancelConnect()
            }
        }
    }

    private func connect() {
        runAuthFlow { try await authService.connectAccount() }
    }

    private func reconnect(_ account: GoogleAccount) {
        // Empty `additionalScopes`: same grant, fresh refresh token (M1 handoff contract).
        runAuthFlow { try await authService.reauthorize(accountID: account.id, additionalScopes: []) }
    }

    private func disconnect(_ account: GoogleAccount) {
        Task {
            await authService.disconnect(accountID: account.id)
        }
    }

    /// Shared driver for connect/reauthorize: progress state around the flow, inline error on
    /// failure (`nil` from the presenter — a user cancel — shows nothing).
    ///
    /// Cancel tolerance (M1 re-review): a Cancel that lands after the browser redirect cannot
    /// abort the token exchange — `connectAccount()` may still *succeed* and upsert an account.
    /// That is fine here by construction: the row list renders straight from `$accounts` (so a
    /// post-cancel row simply appears), and `isConnecting` is cleared when the flow task itself
    /// finishes — success or throw — never by the Cancel button, so the progress row always
    /// resolves cleanly.
    private func runAuthFlow(_ flow: @escaping () async throws -> Void) {
        connectError = nil
        isConnecting = true
        Task {
            do {
                try await flow()
            } catch {
                connectError = GoogleConnectErrorPresenter.message(for: error)
            }
            isConnecting = false
        }
    }

    private func load() {
        clientIDDraft = accountStore.clientID ?? ""
        clientSecretDraft = accountStore.clientSecret ?? ""
        isClientExpanded = !accountStore.isConfigured
    }
}

/// Pure `GoogleAccount` → row view-state mapping (M2 spec): which status badge the row shows and
/// which buttons it offers. Extracted from the view so the mapping is testable without SwiftUI
/// (`GoogleAccountRowStateTests`).
struct GoogleAccountRowState: Equatable {
    /// Localization key of the status badge (rendered via `String.LocalizationValue`).
    let badgeKey: String
    let showsReconnect: Bool
    let showsDisconnect: Bool

    static func make(for account: GoogleAccount) -> GoogleAccountRowState {
        switch account.status {
        case .connected:
            GoogleAccountRowState(
                badgeKey: "google.accounts.statusConnected",
                showsReconnect: false,
                showsDisconnect: true
            )
        case .needsReauth:
            GoogleAccountRowState(
                badgeKey: "google.accounts.statusNeedsReauth",
                showsReconnect: true,
                showsDisconnect: true
            )
        }
    }
}

/// Maps a connect/reauthorize failure to the section's inline error line. M1 ships debug-facing
/// `errorDescription`s only ("M2 localizes what it surfaces"), so the localized copy lives here.
/// `nil` = show nothing — a user-initiated cancel is not an error.
enum GoogleConnectErrorPresenter {
    static func message(for error: Error) -> String? {
        guard let authError = error as? GoogleAuthError else {
            return String(
                format: String(localized: "google.accounts.error.generic"),
                error.localizedDescription
            )
        }
        switch authError {
        case .cancelled:
            return nil
        case .timedOut:
            return String(localized: "google.accounts.error.timedOut")
        case .notConfigured:
            return String(localized: "google.accounts.notConfigured")
        case .stateMismatch, .exchangeFailed, .refreshFailed, .needsReauth:
            return String(
                format: String(localized: "google.accounts.error.generic"),
                authError.errorDescription ?? ""
            )
        }
    }
}
