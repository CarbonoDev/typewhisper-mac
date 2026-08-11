import AppKit
import Foundation
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "MeetingJoinLauncher")

/// Where a meeting join link should open — the result of the pure resolution below.
enum MeetingJoinDestination: Equatable, Sendable {
    case systemBrowser
    case chromeProfile(directory: String)
}

/// The one helper every join affordance calls ([Google Phase 1 · join links]): opens a meeting's
/// conference URL in the *correct* Chrome profile for the owning Google account, instead of the
/// last-used profile that a plain `openURL` lands in.
///
/// Resolution (pure, `MeetingJoinLauncherTests`): the event/meeting's account `sub` (parsed from
/// its namespaced ID; EventKit-bare IDs have none) → the account's `GoogleAccountLinkOpening`
/// preference → a `ChromeProfile` validated against the currently detected profiles. Anything
/// unresolvable — no sub, no account, no matching/existing profile, Chrome absent — falls back to
/// the system default browser, so the no-Chrome case behaves exactly as before this feature.
@MainActor
enum MeetingJoinLauncher {
    // MARK: - Pure resolution

    /// Decide where to open. `preference` is `nil` when the sub resolved to no connected account
    /// (or there was no sub at all). An explicitly chosen Chrome profile that no longer exists in
    /// `profiles` falls back to the system browser — launching `--profile-directory=` with a
    /// deleted directory would silently *create* a fresh profile, which is worse than the
    /// fallback.
    nonisolated static func destination(
        accountSub: String?,
        accountEmail: String?,
        preference: GoogleAccountLinkOpening?,
        profiles: [ChromeProfile]
    ) -> MeetingJoinDestination {
        guard accountSub != nil, let preference else { return .systemBrowser }
        switch preference {
        case .system:
            return .systemBrowser
        case .chromeProfile(let directory):
            return profiles.contains { $0.directory == directory }
                ? .chromeProfile(directory: directory)
                : .systemBrowser
        case .auto:
            guard
                let accountEmail,
                let match = ChromeProfileDetector.autoMatch(profiles: profiles, accountEmail: accountEmail)
            else { return .systemBrowser }
            return .chromeProfile(directory: match.directory)
        }
    }

    // MARK: - Launch (IO)

    /// Open `url` for the account behind `accountSub` (pass the sub parsed via
    /// `GoogleCalendarID.accountSub(fromNamespacedID:)`; `nil` for EventKit events keeps today's
    /// system-browser behavior).
    static func open(url: URL, accountSub: String?) {
        let store = ServiceContainer.shared.googleAccountStore
        let account = accountSub.flatMap { store.account(id: $0) }
        let resolved = destination(
            accountSub: accountSub,
            accountEmail: account?.email,
            preference: account.map { store.linkOpeningPreference(for: $0.id) },
            profiles: ChromeProfileDetector.detectProfiles()
        )
        switch resolved {
        case .systemBrowser:
            NSWorkspace.shared.open(url)
        case .chromeProfile(let directory):
            launchChrome(profileDirectory: directory, url: url)
        }
    }

    /// `open -na "Google Chrome" --args --profile-directory=<dir> <url>` — the documented way to
    /// target a specific profile (the app is unsandboxed, so spawning `/usr/bin/open` is fine).
    /// Both failure modes fall back to the system browser: a synchronous spawn failure
    /// immediately, and a non-zero exit (e.g. Chrome uninstalled after its `Local State` was
    /// read) via the termination handler.
    private static func launchChrome(profileDirectory: String, url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [
            "-na", "Google Chrome",
            "--args", "--profile-directory=\(profileDirectory)", url.absoluteString
        ]
        process.terminationHandler = { finished in
            guard finished.terminationStatus != 0 else { return }
            logger.warning("Chrome launch failed (exit \(finished.terminationStatus)); falling back to system browser")
            DispatchQueue.main.async {
                NSWorkspace.shared.open(url)
            }
        }
        do {
            try process.run()
        } catch {
            logger.warning("Could not spawn /usr/bin/open: \(error.localizedDescription); falling back to system browser")
            NSWorkspace.shared.open(url)
        }
    }
}
