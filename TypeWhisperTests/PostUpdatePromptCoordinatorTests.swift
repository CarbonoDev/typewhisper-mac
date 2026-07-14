import XCTest
@testable import TypeWhisper

@MainActor
final class PostUpdatePromptCoordinatorTests: XCTestCase {
    // TypeWhisper is free and open source: the post-update licensing prompt has been
    // removed, so the coordinator must never ask to present it. #883's windowless-login policy is
    // enforced by `LaunchWindowDecision` (the single launch authority), so its
    // `InitialWindowPresentationPolicy` tests are intentionally not ported here.

    func testPromptIsNeverPresentedOnFreshInstall() throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let license = LicenseService(defaults: defaults)
        let coordinator = PostUpdatePromptCoordinator(
            defaults: defaults,
            licenseService: license,
            currentReleaseFingerprint: "1.3.0+123@stable"
        )

        XCTAssertFalse(coordinator.shouldPresentPrompt)
        // The release marker is still seeded so update detection keeps working.
        XCTAssertEqual(defaults.string(forKey: UserDefaultsKeys.lastSeenReleaseFingerprint), "1.3.0+123@stable")
    }

    func testPromptIsNeverPresentedRegardlessOfUsageIntent() throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: UserDefaultsKeys.welcomeSheetShown)
        defaults.set(UsageIntent.team.rawValue, forKey: UserDefaultsKeys.usageIntent)
        defaults.set("1.2.9+99@stable", forKey: UserDefaultsKeys.lastSeenReleaseFingerprint)

        let license = LicenseService(defaults: defaults)
        let coordinator = PostUpdatePromptCoordinator(
            defaults: defaults,
            licenseService: license,
            currentReleaseFingerprint: "1.3.0+123@stable"
        )

        XCTAssertFalse(coordinator.shouldPresentPrompt)
        XCTAssertNil(coordinator.activeSheetRoute)
    }

    func testSettingsNavigationCoordinatorPublishesLicenseTargets() throws {
        let coordinator = SettingsNavigationCoordinator()

        coordinator.navigateToLicense(target: .activationKey)
        let activationRequest = try XCTUnwrap(coordinator.request)
        XCTAssertEqual(activationRequest.tab, .license)
        XCTAssertEqual(activationRequest.licenseTarget, .activationKey)

        coordinator.navigateToLicense(target: .supporter)
        let supporterRequest = try XCTUnwrap(coordinator.request)
        XCTAssertEqual(supporterRequest.tab, .license)
        XCTAssertEqual(supporterRequest.licenseTarget, .supporter)
        XCTAssertNotEqual(activationRequest.id, supporterRequest.id)

        coordinator.navigate(to: .license, licenseTarget: .top)
        let topRequest = try XCTUnwrap(coordinator.request)
        XCTAssertEqual(topRequest.tab, .license)
        XCTAssertEqual(topRequest.licenseTarget, .top)
    }

    private func makeIsolatedDefaults() throws -> (UserDefaults, String) {
        let suiteName = "TypeWhisperTests.PostUpdatePrompt.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw XCTSkip("Failed to create isolated defaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
