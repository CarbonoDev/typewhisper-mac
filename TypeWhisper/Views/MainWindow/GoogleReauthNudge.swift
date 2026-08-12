import SwiftUI

/// Pure visibility rule for the Home reauth nudge ([Google Phase 2 · M3], D-D8):
/// `[GoogleAccount] → nudge state`, unit-tested without SwiftUI (`GoogleReauthNudgeRuleTests`).
/// Under Testing mode (D-D1) every refresh token expires weekly, so `.needsReauth` is a routine
/// state that must be visible where the user lives — the Home feed — not only inside Settings.
struct GoogleReauthNudgeState: Equatable {
    /// The first `.needsReauth` account (connect order) — the one the inline Reconnect targets.
    var accountID: String
    var accountEmail: String
    /// Total `.needsReauth` accounts; the nudge re-renders for the next one after a reconnect.
    var needingCount: Int
}

enum GoogleReauthNudgeRule {
    /// `nil` = render nothing (no account needs reconnecting).
    static func state(for accounts: [GoogleAccount]) -> GoogleReauthNudgeState? {
        let needing = accounts.filter { $0.status == .needsReauth }
        guard let first = needing.first else { return nil }
        return GoogleReauthNudgeState(
            accountID: first.id,
            accountEmail: first.email,
            needingCount: needing.count
        )
    }
}

/// Compact banner at the top of the Home feed whenever ≥ 1 account is `.needsReauth` (D-D8):
/// "Google account needs reconnecting — <email> stopped syncing." with an inline **Reconnect**
/// that runs the same reauthorize as the settings row — feature scopes included via
/// `GoogleFeatureScopes`, so one click restores calendar *and* Drive in a single consent pass —
/// and a second button routing to Settings. The view is logic-free: visibility is
/// `GoogleReauthNudgeRule`, the flow is the auth service's, error copy is the shared presenter's.
struct GoogleReauthNudge: View {
    @ObservedObject private var accountStore = ServiceContainer.shared.googleAccountStore
    @ObservedObject private var authService = ServiceContainer.shared.googleAuthService

    /// Inline error from the last failed reconnect (`nil` after a cancel — not an error).
    @State private var reconnectError: String?

    var body: some View {
        if let state = GoogleReauthNudgeRule.state(for: accountStore.accounts) {
            VStack(alignment: .leading, spacing: MeetingTheme.s2) {
                Label(
                    String(localized: "google.reauth.nudgeTitle"),
                    systemImage: "person.crop.circle.badge.exclamationmark"
                )
                .font(.callout.weight(.semibold))
                Text(String(format: String(localized: "google.reauth.nudgeMessage"), state.accountEmail))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button(String(localized: "google.reauth.nudgeReconnect")) {
                        reconnect(accountID: state.accountID)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    // The Phase 1 gating precedent: one auth flow at a time; Cancel-then-retry
                    // lives in Settings.
                    .disabled(authService.isAuthorizing)
                    Button(String(localized: "google.reauth.nudgeSettings")) {
                        ManagedAppWindowOpener.shared.open(id: AppWindowID.settings)
                    }
                    .controlSize(.small)
                    if authService.isAuthorizing {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                if let reconnectError {
                    Text(reconnectError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: MeetingTheme.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: MeetingTheme.cardRadius)
                    .stroke(Color.orange.opacity(0.25), lineWidth: 1)
            )
        }
    }

    /// The same reauthorize the settings row runs, with the account's enabled-feature scopes
    /// composed in (D-D8) — success flips the account `.connected`, which removes the nudge (or
    /// advances it to the next `.needsReauth` account) via the published accounts index.
    private func reconnect(accountID: String) {
        reconnectError = nil
        Task {
            do {
                let scopes = accountStore.account(id: accountID).map {
                    GoogleFeatureScopes.additionalScopes(for: $0, store: accountStore)
                } ?? []
                try await authService.reauthorize(accountID: accountID, additionalScopes: scopes)
                // A declined feature checkbox must not leave the feature "on" with an unscoped
                // token (review fix — the settings Reconnect does the same). The nudge has no
                // per-feature error line, so the disabled feature surfaces through the same
                // localized explanation.
                let declined = GoogleFeatureScopes.disableFeaturesWithMissingScopes(
                    accountID: accountID, store: accountStore
                )
                // [Google Phase 3 · M6] Gmail rides the same table, so a declined Gmail checkbox
                // turns the search off here too. Both features can be declined in one consent
                // pass, so the explanations concatenate instead of one silently winning.
                let explanations = [
                    declined.contains(.driveImport)
                        ? String(localized: "google.drive.reconnectScopeDenied") : nil,
                    declined.contains(.gmail)
                        ? String(localized: "google.gmail.reconnectScopeDenied") : nil
                ].compactMap { $0 }
                if !explanations.isEmpty {
                    reconnectError = explanations.joined(separator: "\n")
                }
            } catch {
                reconnectError = GoogleConnectErrorPresenter.message(for: error)
            }
        }
    }
}
