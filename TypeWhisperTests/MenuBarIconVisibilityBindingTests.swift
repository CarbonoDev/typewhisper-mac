import XCTest
@testable import TypeWhisper

/// `MenuBarIconVisibilityBinding` writes the status item's `isVisible` at creation and only when the
/// "show menu bar icon" preference changes — never otherwise — so a menu bar manager's hide sticks.
@MainActor
final class MenuBarIconVisibilityBindingTests: XCTestCase {
    private final class FakeStatusItem: StatusItemVisibilityControlling {
        var writes: [Bool] = []
        var isVisible: Bool = true {
            didSet { writes.append(isVisible) }
        }
    }

    private lazy var defaults: UserDefaults = {
        let suiteName = "MenuBarIconVisibilityBindingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        return defaults
    }()

    func testInitialVisibilityDefaultsToShownWhenUnset() {
        let item = FakeStatusItem()
        _ = MenuBarIconVisibilityBinding(item: item, defaults: defaults)
        XCTAssertEqual(item.writes, [true])
    }

    func testInitialVisibilityFollowsStoredPreference() {
        defaults.set(false, forKey: UserDefaultsKeys.showMenuBarIcon)
        let item = FakeStatusItem()
        _ = MenuBarIconVisibilityBinding(item: item, defaults: defaults)
        XCTAssertEqual(item.writes, [false])
    }

    func testUnchangedPreferenceNeverRewritesVisibility() {
        let item = FakeStatusItem()
        let binding = MenuBarIconVisibilityBinding(item: item, defaults: defaults)
        // A manager hides the item behind our back; label/menu churn re-checks must not undo it.
        item.isVisible = false
        item.writes.removeAll()
        binding.preferenceMayHaveChanged()
        defaults.set("x", forKey: "someUnrelatedKey")
        binding.preferenceMayHaveChanged()
        XCTAssertEqual(item.writes, [])
        XCTAssertFalse(item.isVisible)
    }

    func testPreferenceChangeTogglesVisibility() {
        let item = FakeStatusItem()
        let binding = MenuBarIconVisibilityBinding(item: item, defaults: defaults)
        defaults.set(false, forKey: UserDefaultsKeys.showMenuBarIcon)
        binding.preferenceMayHaveChanged()
        defaults.set(true, forKey: UserDefaultsKeys.showMenuBarIcon)
        binding.preferenceMayHaveChanged()
        XCTAssertEqual(item.writes, [true, false, true])
    }

    func testPreferenceChangeIsObservedWithoutExplicitCall() async {
        let item = FakeStatusItem()
        let binding = MenuBarIconVisibilityBinding(item: item, defaults: defaults)
        defaults.set(false, forKey: UserDefaultsKeys.showMenuBarIcon)
        for _ in 0..<50 where item.writes.count < 2 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(item.writes, [true, false])
        withExtendedLifetime(binding) {}
    }
}
