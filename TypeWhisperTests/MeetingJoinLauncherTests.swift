import XCTest
@testable import TypeWhisper

/// [Join links] The pure launch-destination resolution matrix — preference + detected profiles +
/// account attribution → destination. No Process, no filesystem, no NSWorkspace.
final class MeetingJoinLauncherTests: XCTestCase {
    private let profiles = [
        ChromeProfile(directory: "Default", email: "personal@gmail.com", displayName: "Personal"),
        ChromeProfile(directory: "Profile 2", email: "marco@simbiosis.team", displayName: "Work")
    ]

    func testNoAccountSubFallsBackToSystemBrowser() {
        // EventKit events carry bare IDs → no sub → today's behavior, regardless of profiles.
        XCTAssertEqual(
            MeetingJoinLauncher.destination(
                accountSub: nil,
                accountEmail: nil,
                preference: nil,
                profiles: profiles
            ),
            .systemBrowser
        )
    }

    func testSubWithoutConnectedAccountFallsBackToSystemBrowser() {
        // A namespaced ID whose account was disconnected resolves to no preference.
        XCTAssertEqual(
            MeetingJoinLauncher.destination(
                accountSub: "sub-gone",
                accountEmail: nil,
                preference: nil,
                profiles: profiles
            ),
            .systemBrowser
        )
    }

    func testAutoWithSingleEmailMatchPicksThatProfile() {
        XCTAssertEqual(
            MeetingJoinLauncher.destination(
                accountSub: "sub-1",
                accountEmail: "marco@simbiosis.team",
                preference: .auto,
                profiles: profiles
            ),
            .chromeProfile(directory: "Profile 2")
        )
    }

    func testAutoWithoutMatchFallsBackToSystemBrowser() {
        XCTAssertEqual(
            MeetingJoinLauncher.destination(
                accountSub: "sub-1",
                accountEmail: "nobody@elsewhere.com",
                preference: .auto,
                profiles: profiles
            ),
            .systemBrowser
        )
        // No Chrome installed (empty profile list) — must not regress to an error.
        XCTAssertEqual(
            MeetingJoinLauncher.destination(
                accountSub: "sub-1",
                accountEmail: "marco@simbiosis.team",
                preference: .auto,
                profiles: []
            ),
            .systemBrowser
        )
    }

    func testExplicitSystemPreferenceAlwaysUsesSystemBrowser() {
        XCTAssertEqual(
            MeetingJoinLauncher.destination(
                accountSub: "sub-1",
                accountEmail: "marco@simbiosis.team",
                preference: .system,
                profiles: profiles
            ),
            .systemBrowser
        )
    }

    func testExplicitExistingProfileIsUsed() {
        XCTAssertEqual(
            MeetingJoinLauncher.destination(
                accountSub: "sub-1",
                accountEmail: "marco@simbiosis.team",
                preference: .chromeProfile(directory: "Default"),
                profiles: profiles
            ),
            .chromeProfile(directory: "Default")
        )
    }

    func testExplicitMissingProfileFallsBackToSystemBrowser() {
        // Launching --profile-directory with a deleted directory would silently CREATE a fresh
        // Chrome profile — validate against the detected list and fall back instead.
        XCTAssertEqual(
            MeetingJoinLauncher.destination(
                accountSub: "sub-1",
                accountEmail: "marco@simbiosis.team",
                preference: .chromeProfile(directory: "Profile 99"),
                profiles: profiles
            ),
            .systemBrowser
        )
    }

    // MARK: - Localization coverage (EN + DE)

    func testJoinLinkStringsHaveEnglishAndGermanEntries() throws {
        let keys = [
            "google.links.openIn",
            "google.links.auto",
            "google.links.system",
            "google.links.chromeProfile"
        ]
        for key in keys {
            XCTAssertFalse(try TestSupport.localizedCatalogValue(for: key, language: "en").isEmpty, "EN missing for \(key)")
            XCTAssertFalse(try TestSupport.localizedCatalogValue(for: key, language: "de").isEmpty, "DE missing for \(key)")
        }
    }
}
