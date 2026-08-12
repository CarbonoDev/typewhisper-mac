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
    /// Observed for `isAuthorizing` (M2 review finding 1): the flow-active flag lives on the
    /// service — where restart/cancel races are already resolved by session identity — not in
    /// view `@State`, so it stays correct across overlapping flows and survives the settings
    /// pane being closed and reopened mid-connect.
    @ObservedObject private var authService = ServiceContainer.shared.googleAuthService
    /// Observed for the M3 sync status line (`lastSyncAt`/`lastSyncError`) and "Refresh now".
    @ObservedObject private var syncEngine = ServiceContainer.shared.googleCalendarSyncEngine
    /// Observed for the pending twin-calendar prompts ([Google Phase 1 · M4], D-G6). The VM owns
    /// evaluation (it observes the snapshot-change notification app-wide, so detection is not
    /// tied to this section being visible) and routes both resolutions through the calendar
    /// selection choke point / the account store's handled-mark.
    @ObservedObject private var meetingsViewModel = MeetingsViewModel.shared

    /// Local drafts of the client credentials, seeded from the store on appear and written
    /// through on change (`GoogleAccountStore` stays the single writer of the persisted values —
    /// the drafts only exist so SwiftUI has bindable state).
    @State private var clientIDDraft = ""
    @State private var clientSecretDraft = ""
    /// Auto-expanded on appear while unconfigured so first-run users find the credential fields.
    @State private var isClientExpanded = false
    /// Inline error from the last failed connect/reauthorize (nil after cancel — not an error).
    @State private var connectError: String?
    /// [Join links] Chrome profiles detected on appear (one `Local State` read), feeding each
    /// account row's "Open links in" picker. Empty when Chrome is not installed — the picker then
    /// offers only Automatic / System browser, so the no-Chrome case is unchanged.
    @State private var chromeProfiles: [ChromeProfile] = []

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
                syncStatusRow
            }

            ForEach(meetingsViewModel.twinCalendarPrompts) { prompt in
                twinPromptView(prompt)
            }

            if authService.isAuthorizing {
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
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
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
                    // Same gating as "Add Google Account…" (M2 review finding 1): starting a second
                    // flow mid-wait belongs to the explicit Cancel-then-retry path, not a row button.
                    .disabled(authService.isAuthorizing)
                }
                if rowState.showsDisconnect {
                    Button(String(localized: "google.accounts.disconnect")) {
                        disconnect(account)
                    }
                }
            }
            linkOpeningPicker(account)
        }
        .padding(.vertical, 6)
    }

    // MARK: - Join-link opening preference ([Join links])

    /// Per-account "Open links in" choice: Automatic (Chrome profile auto-matched by the signed-in
    /// email, else system browser), the system browser, or an explicit detected Chrome profile.
    /// Reads/writes through `GoogleAccountStore` (single writer of the `google.*` keys).
    private func linkOpeningPicker(_ account: GoogleAccount) -> some View {
        let current = accountStore.linkOpeningPreference(for: account.id)
        return Picker(
            String(localized: "google.links.openIn"),
            selection: Binding(
                get: { current.rawValue },
                set: { raw in
                    accountStore.setLinkOpeningPreference(
                        GoogleAccountLinkOpening(rawValue: raw),
                        for: account.id
                    )
                }
            )
        ) {
            Text(String(localized: "google.links.auto"))
                .tag(GoogleAccountLinkOpening.auto.rawValue)
            Text(String(localized: "google.links.system"))
                .tag(GoogleAccountLinkOpening.system.rawValue)
            ForEach(chromeProfiles) { profile in
                Text(chromeProfileLabel(profile))
                    .tag(GoogleAccountLinkOpening.chromeProfile(directory: profile.directory).rawValue)
            }
            // A persisted profile that is no longer detected (deleted/renamed in Chrome) still
            // renders as the selection — an invisible selection would silently reset the picker.
            // The launcher already falls back to the system browser for it at open time.
            if case .chromeProfile(let directory) = current,
               !chromeProfiles.contains(where: { $0.directory == directory }) {
                Text(String(format: String(localized: "google.links.chromeProfile"), directory))
                    .tag(current.rawValue)
            }
        }
        .pickerStyle(.menu)
        .controlSize(.small)
        .font(.caption)
        .frame(maxWidth: 360, alignment: .leading)
    }

    private func chromeProfileLabel(_ profile: ChromeProfile) -> String {
        let detail = profile.email.map { "\(profile.displayName) (\($0))" } ?? profile.displayName
        return String(format: String(localized: "google.links.chromeProfile"), detail)
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

    // MARK: - Calendar sync status ([Google Phase 1 · M3], D-G7)

    /// Last-sync time + "Refresh now" under the account rows, with the engine's sync error (if
    /// any) inline. Rendered only while accounts exist — with none connected the engine has
    /// nothing to sync.
    private var syncStatusRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let lastSyncAt = syncEngine.lastSyncAt {
                    Text(String(
                        format: String(localized: "google.calendar.lastSync"),
                        lastSyncAt.formatted(date: .abbreviated, time: .shortened)
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Button(String(localized: "google.calendar.refreshNow")) {
                    Task { await syncEngine.syncNow() }
                }
                .controlSize(.small)
            }
            if let syncError = syncEngine.lastSyncError {
                Text(syncError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.top, 2)
    }

    // MARK: - Twin-calendar prompt ([Google Phase 1 · M4], D-G6)

    /// One-time inline prompt shown when a connected account's Google calendars are also synced
    /// into macOS Calendar via CalDAV. **Hide duplicates** (default) deselects the EventKit twins
    /// through the normal selection path — coarse, visible, and reversible in the Calendars list;
    /// **Keep both** does nothing. Either choice marks the account handled, so the prompt never
    /// returns for it.
    private func twinPromptView(_ prompt: TwinCalendarPrompt) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                String(localized: "google.twins.title"),
                systemImage: "calendar.badge.exclamationmark"
            )
            .font(.callout.weight(.semibold))
            Text(String(format: String(localized: "google.twins.message"), prompt.accountEmail))
                .font(.caption)
                .foregroundStyle(.secondary)
            // [M4 review fix 2] Name the exact macOS calendars "Hide duplicates" would deselect —
            // the detector can cross-match another account's CalDAV calendars, so the choice must
            // be informed consent, not a blind default.
            Text(String(format: String(localized: "google.twins.affected"), prompt.twinTitlesList))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button(String(localized: "google.twins.hide")) {
                    meetingsViewModel.resolveTwinPrompt(prompt, hideDuplicates: true)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button(String(localized: "google.twins.keep")) {
                    meetingsViewModel.resolveTwinPrompt(prompt, hideDuplicates: false)
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
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
        // M2 review finding 4 (documented, accepted): Disconnect stays enabled while a
        // reauthorize for this same account is pending. Disconnecting does not abort that flow —
        // if the user then finishes the browser sign-in anyway, the exchange upserts the account
        // again (M1's dedupe-by-sub contract), which is the correct outcome for "completed a
        // Google sign-in": the row simply reappears as `.connected`.
        Task {
            await authService.disconnect(accountID: account.id)
        }
    }

    /// Shared driver for connect/reauthorize: clears the previous inline error, runs the flow,
    /// surfaces a failure through the presenter (`nil` — a user cancel — shows nothing). Progress
    /// state is not managed here: the view renders `authService.isAuthorizing`, which the service
    /// derives from its session identity (M2 review finding 1), so an overlapping flow's unwind
    /// can never hide a successor's progress row.
    ///
    /// Cancel tolerance (M1 re-review): a Cancel that lands after the browser redirect cannot
    /// abort the token exchange — `connectAccount()` may still *succeed* and upsert an account.
    /// That is fine here by construction: the row list renders straight from `$accounts` (so a
    /// post-cancel row simply appears), and `isAuthorizing` clears when the flow itself resolves,
    /// never on the Cancel click, so the progress row always resolves cleanly.
    private func runAuthFlow(_ flow: @escaping () async throws -> Void) {
        connectError = nil
        Task {
            do {
                try await flow()
            } catch {
                connectError = GoogleConnectErrorPresenter.message(for: error)
            }
        }
    }

    private func load() {
        clientIDDraft = accountStore.clientID ?? ""
        clientSecretDraft = accountStore.clientSecret ?? ""
        isClientExpanded = !accountStore.isConfigured
        // [Join links] One Local State read per appearance; missing Chrome ⇒ empty (no error).
        chromeProfiles = ChromeProfileDetector.detectProfiles()
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
        case .loopbackUnavailable:
            // PR #7 review finding 10: a listener that never bound is a *local* problem — never
            // report it as a redirect timeout, which sends the user off to debug their browser.
            return String(localized: "google.accounts.error.loopbackUnavailable")
        case .wrongAccount(let expectedEmail, let signedInEmail):
            // PR #7 review finding 2: name both accounts — the user picked the wrong one in
            // Google's chooser, and the requested account still needs reconnecting.
            return String(
                format: String(localized: "google.accounts.error.wrongAccount"),
                signedInEmail,
                expectedEmail
            )
        case .notConfigured:
            return String(localized: "google.accounts.notConfigured")
        case .stateMismatch, .exchangeFailed, .refreshFailed, .needsReauth:
            // M2 review finding 3 (documented, accepted): the `%@` detail is M1's debug-facing
            // English `errorDescription` inside a localized frame. Deliberate for Phase 1 — the
            // detail is an OAuth error code / HTTP status useful verbatim in bug reports, and
            // localizing the taxonomy belongs to the service, not this presenter.
            return String(
                format: String(localized: "google.accounts.error.generic"),
                authError.errorDescription ?? ""
            )
        }
    }
}
