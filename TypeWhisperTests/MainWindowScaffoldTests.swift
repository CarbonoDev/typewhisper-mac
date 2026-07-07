import XCTest
@testable import TypeWhisper

/// UI Step 0 (Track A) scaffold tests: route/coordinator contract, managed-window prefix matching
/// for the new `main` scene, pure launch-window precedence, the focus bridge, and EN+DE coverage of
/// the new `mainwindow.*` strings.

// MARK: - Route + coordinator + focus bridge

@MainActor
final class MainWindowRouteTests: XCTestCase {
    func testRouteEquality() {
        let id = UUID()
        XCTAssertEqual(MainWindowRoute.meeting(id), .meeting(id))
        XCTAssertNotEqual(MainWindowRoute.meeting(id), .meeting(UUID()))
        XCTAssertEqual(MainWindowRoute.home, .home)
        XCTAssertNotEqual(MainWindowRoute.home, .meetings)
        XCTAssertEqual(MainWindowRoute.spaceFolder("a/b"), .spaceFolder("a/b"))
        XCTAssertNotEqual(MainWindowRoute.spaceFolder("a/b"), .spaceNote("a/b"))
    }

    func testCoordinatorOpenMeetingSetsMeetingRoute() {
        let coordinator = MainWindowCoordinator()
        let id = UUID()
        coordinator.openMeeting(id: id)
        XCTAssertEqual(coordinator.route, .meeting(id))
    }

    func testCoordinatorShowSetsArbitraryRoute() {
        let coordinator = MainWindowCoordinator()
        coordinator.show(.meetings)
        XCTAssertEqual(coordinator.route, .meetings)
        coordinator.show(.home)
        XCTAssertEqual(coordinator.route, .home)
    }

    func testFocusBridgePureMapping() {
        let id = UUID()
        XCTAssertEqual(MainWindowCoordinator.focusRoute(forPendingMeetingID: id), .meeting(id))
        XCTAssertNil(MainWindowCoordinator.focusRoute(forPendingMeetingID: nil))
    }

    func testFocusBridgeAppliesRouteFromPendingID() {
        // Simulates the shell's `onChange(of: pendingFocusMeetingID)` bridge: a pending id becomes a
        // `.meeting(id)` route.
        let coordinator = MainWindowCoordinator()
        let id = UUID()
        if let route = MainWindowCoordinator.focusRoute(forPendingMeetingID: id) {
            coordinator.route = route
        }
        XCTAssertEqual(coordinator.route, .meeting(id))
    }
}

// MARK: - Managed-window matching (prefix-safe for "main")

final class ManagedWindowMatchingTests: XCTestCase {
    func testMainWindowMatchedByPrefix() {
        XCTAssertTrue(ManagedWindowMatching.isManaged(identifier: "main-AppWindow-1"))
        XCTAssertTrue(ManagedWindowMatching.matches(windowIdentifier: "main-AppWindow-1", requestedID: AppWindowID.main))
    }

    func testMainRequestDoesNotMatchNonMainSubstringWindows() {
        // "main" as an interior substring must NOT satisfy a main request (prefix-only).
        XCTAssertFalse(ManagedWindowMatching.matches(windowIdentifier: "domain-panel", requestedID: AppWindowID.main))
        XCTAssertFalse(ManagedWindowMatching.matches(windowIdentifier: "RemainderWindow", requestedID: AppWindowID.main))
    }

    func testPreExistingScenesStillManaged() {
        for id in ["settings-AppWindow-1", "setup-AppWindow-1", "history-AppWindow-1",
                   "errors-AppWindow-1", "meetings-AppWindow-1"] {
            XCTAssertTrue(ManagedWindowMatching.isManaged(identifier: id), "expected \(id) managed")
        }
    }

    func testPreExistingScenesMatchTheirRequestID() {
        XCTAssertTrue(ManagedWindowMatching.matches(windowIdentifier: "settings-AppWindow-1", requestedID: AppWindowID.settings))
        XCTAssertTrue(ManagedWindowMatching.matches(windowIdentifier: "meetings-AppWindow-1", requestedID: AppWindowID.meetings))
        // A main-scene window must not answer a "meetings" request and vice-versa.
        XCTAssertFalse(ManagedWindowMatching.matches(windowIdentifier: "main-AppWindow-1", requestedID: AppWindowID.meetings))
        XCTAssertFalse(ManagedWindowMatching.matches(windowIdentifier: "meetings-AppWindow-1", requestedID: AppWindowID.main))
    }

    func testPanelsAndUnknownWindowsAreNotManaged() {
        for id in ["OverlayIndicatorPanel", "NotchIndicatorPanel", "MinimalIndicatorPanel",
                   "PromptPalettePanel", "SelectionPalettePanel", "com.apple.SwiftUI.windowGroup", ""] {
            XCTAssertFalse(ManagedWindowMatching.isManaged(identifier: id), "expected \(id) NOT managed")
        }
    }
}

// MARK: - Launch-window precedence (pure)

final class LaunchBehaviorTests: XCTestCase {
    private func decide(setup: Bool, prompt: Bool, enabled: Bool, showAtLaunch: Bool) -> LaunchWindowDecision.Window {
        LaunchWindowDecision.decide(
            isFirstRunSetupIncomplete: setup,
            postUpdatePromptPending: prompt,
            mainWindowEnabled: enabled,
            showMainWindowAtLaunch: showAtLaunch
        )
    }

    func testSetupWinsOverEverything() {
        // Setup is highest precedence regardless of the other three flags (4 combinations covered).
        for prompt in [false, true] {
            for showAtLaunch in [false, true] {
                XCTAssertEqual(decide(setup: true, prompt: prompt, enabled: true, showAtLaunch: showAtLaunch), .setup)
            }
        }
    }

    func testPostUpdatePromptWinsOverMain() {
        XCTAssertEqual(decide(setup: false, prompt: true, enabled: true, showAtLaunch: true), .settings)
        XCTAssertEqual(decide(setup: false, prompt: true, enabled: false, showAtLaunch: true), .settings)
    }

    func testMainOpensOnlyWhenEnabledAndToggledOn() {
        XCTAssertEqual(decide(setup: false, prompt: false, enabled: true, showAtLaunch: true), .main)
    }

    func testNoneWhenDisabledOrToggledOff() {
        XCTAssertEqual(decide(setup: false, prompt: false, enabled: false, showAtLaunch: true), .none)
        XCTAssertEqual(decide(setup: false, prompt: false, enabled: true, showAtLaunch: false), .none)
        XCTAssertEqual(decide(setup: false, prompt: false, enabled: false, showAtLaunch: false), .none)
    }
}

// MARK: - Localization coverage

final class MainWindowLocalizationTests: XCTestCase {
    func testMainWindowStringsHaveEnglishAndGermanEntries() throws {
        let keys = [
            "mainwindow.title",
            "mainwindow.selectPrompt.title",
            "mainwindow.selectPrompt.message",
            "mainwindow.search.placeholder",
            "mainwindow.sidebar.home",
            "mainwindow.sidebar.meetings",
            "mainwindow.sidebar.settings",
            "mainwindow.liveBand.accessibility",
            "mainwindow.meetings.title",
            "mainwindow.newMeeting.import",
            "mainwindow.meetings.empty.title",
            "mainwindow.meetings.empty.message",
            "mainwindow.home.stub.title",
            "mainwindow.home.stub.message"
        ]
        for key in keys {
            XCTAssertFalse(try TestSupport.localizedCatalogValue(for: key, language: "en").isEmpty, "EN missing for \(key)")
            XCTAssertFalse(try TestSupport.localizedCatalogValue(for: key, language: "de").isEmpty, "DE missing for \(key)")
        }
    }
}
