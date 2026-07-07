import XCTest
@testable import TypeWhisper

// MARK: - Settings regroup (Track D · D7)

/// The meetings-first settings regroup is non-destructive: all 20 `SettingsTab` cases survive and
/// every one is placed in exactly one of the five groups (Dictation/Meetings/Library/Tools/
/// Application), except the two deep-link alias tabs that collapse into the unified Library row.
final class SettingsGroupingTests: XCTestCase {
    func testAllTwentySettingsTabsExist() {
        XCTAssertEqual(SettingsTab.allCases.count, 20)
    }

    func testEveryTabIsPlacedExactlyOnceOrIsAnAlias() {
        let grouped = SettingsGrouping.allGroupedTabs

        // No tab appears in two groups.
        XCTAssertEqual(grouped.count, Set(grouped).count, "A tab is listed in more than one group")

        // Grouped rows, alias tabs, and deep-link-only tabs are mutually disjoint (neither aliases
        // nor deep-link-only tabs ever get their own sidebar row).
        XCTAssertTrue(Set(grouped).isDisjoint(with: SettingsGrouping.aliasTabs))
        XCTAssertTrue(Set(grouped).isDisjoint(with: SettingsGrouping.deepLinkOnlyTabs))
        XCTAssertTrue(SettingsGrouping.aliasTabs.isDisjoint(with: SettingsGrouping.deepLinkOnlyTabs))

        // Nothing is dropped: grouped rows ∪ aliases ∪ deep-link-only == every SettingsTab case.
        XCTAssertEqual(
            Set(grouped).union(SettingsGrouping.aliasTabs).union(SettingsGrouping.deepLinkOnlyTabs),
            Set(SettingsTab.allCases),
            "Some SettingsTab case is neither grouped, an alias, nor deep-link-only"
        )
    }

    func testGroupsAppearInTheExpectedOrder() {
        XCTAssertEqual(
            SettingsGrouping.orderedGroups.map(\.group),
            [.dictation, .meetings, .library, .tools, .application]
        )
        // The layout is the single source both settings shells consume, so both render identically.
        XCTAssertEqual(SettingsGroup.allCases, [.dictation, .meetings, .library, .tools, .application])
    }

    func testExpectedGroupMembership() {
        func group(of tab: SettingsTab) -> SettingsGroup? {
            SettingsGrouping.orderedGroups.first(where: { $0.tabs.contains(tab) })?.group
        }

        // Old Home dashboard → Dictation › Overview.
        XCTAssertEqual(group(of: .home), .dictation)
        XCTAssertEqual(group(of: .general), .dictation)
        XCTAssertEqual(group(of: .recording), .dictation)
        XCTAssertEqual(group(of: .hotkeys), .dictation)
        XCTAssertEqual(group(of: .dictionary), .dictation)
        XCTAssertEqual(group(of: .snippets), .dictation)
        XCTAssertEqual(group(of: .dictationRecovery), .dictation)

        XCTAssertEqual(group(of: .meetings), .meetings)
        XCTAssertEqual(group(of: .diarization), .meetings)

        XCTAssertEqual(group(of: .workflows), .library)

        // History → Tools; recorder + file transcription live there too.
        XCTAssertEqual(group(of: .recorder), .tools)
        XCTAssertEqual(group(of: .fileTranscription), .tools)
        XCTAssertEqual(group(of: .history), .tools)

        XCTAssertEqual(group(of: .integrations), .application)
        XCTAssertEqual(group(of: .premium), .application)
        XCTAssertEqual(group(of: .advanced), .application)
        XCTAssertEqual(group(of: .about), .application)

        // License is no longer a grouped sidebar row (free & open source): it is deep-link-only.
        XCTAssertNil(group(of: .license))
        XCTAssertTrue(SettingsGrouping.deepLinkOnlyTabs.contains(.license))
    }

    func testEveryGroupTitleIsNonEmpty() {
        for group in SettingsGroup.allCases {
            XCTAssertFalse(group.title.isEmpty, "Group \(group) has no localized title")
        }
    }
}

// MARK: - Settings deep links (Track D · D7)

/// Every verified deep-link caller still lands on a real, grouped row after the regroup.
final class SettingsDeepLinkTests: XCTestCase {
    func testAliasTabsCollapseOntoTheUnifiedWorkflowsRow() {
        XCTAssertEqual(SettingsView.resolvedTab(for: .profiles), .workflows)
        XCTAssertEqual(SettingsView.resolvedTab(for: .prompts), .workflows)
        XCTAssertEqual(SettingsView.resolvedTab(for: .workflows), .workflows)
    }

    func testNonAliasTabsResolveToThemselves() {
        for tab in SettingsTab.allCases where !SettingsGrouping.aliasTabs.contains(tab) {
            XCTAssertEqual(SettingsView.resolvedTab(for: tab), tab)
        }
    }

    func testDeepLinkDestinationsAreVisibleRows() {
        // navigateToHistory, navigateToIntegrations, showFilePickerFromMenu, and the
        // profiles/prompts/workflows collapse all resolve to one of these tabs — each must be a
        // grouped sidebar row.
        let destinations: [SettingsTab] = [.history, .integrations, .fileTranscription, .workflows]
        for tab in destinations {
            XCTAssertTrue(
                SettingsGrouping.allGroupedTabs.contains(tab),
                "Deep-link destination \(tab) is not a visible grouped row"
            )
        }
    }

    func testLicenseDeepLinkResolvesToItselfWithoutASidebarRow() {
        // navigateToLicense (all three targets) still lands on the informational License panel, but
        // the tab is deep-link-only now — it has no grouped sidebar row.
        XCTAssertEqual(SettingsView.resolvedTab(for: .license), .license)
        XCTAssertFalse(SettingsGrouping.allGroupedTabs.contains(.license))
        XCTAssertTrue(SettingsGrouping.deepLinkOnlyTabs.contains(.license))
    }
}

// MARK: - Menu bar slim (Track D · D8)

/// The slim menu-bar item set: History / Error Log / Transcribe File are removed; Start Meeting
/// Recording and Open TypeWhisper are present. The legacy `meetings` window scene was retired
/// (D10), so "Open TypeWhisper" unconditionally targets the meetings-first `main` window.
final class MenuBarItemsTests: XCTestCase {
    func testSlimItemSet() {
        XCTAssertEqual(
            MenuBarLayout.items(),
            [.startMeetingRecording, .toggleRecorder, .toggleDictationHotkeysPause, .recentTranscriptions, .openMainWindow, .settings]
        )
    }

    func testSixVisibleMiddleEntries() {
        // Status line + Quit are rendered outside the layout → eight visible entries total (D8).
        XCTAssertEqual(MenuBarLayout.items().count, 6)
    }

    func testRemovedItemsAreAbsent() {
        let items = MenuBarLayout.items()
        XCTAssertFalse(items.contains(.history))
        XCTAssertFalse(items.contains(.errorLog))
        XCTAssertFalse(items.contains(.transcribeFile))
        XCTAssertFalse(items.contains(.checkForUpdates))
    }

    func testStartMeetingRecordingIsPresent() {
        XCTAssertTrue(MenuBarLayout.items().contains(.startMeetingRecording))
    }

    func testOpenTypeWhisperTargetsTheMainWindow() {
        XCTAssertEqual(MenuBarMenuItem.openMainWindow.managedWindowTarget, AppWindowID.main)
        XCTAssertEqual(AppWindowID.main, "main")
    }

    /// The legacy `meetings` window scene is gone: the slim menu carries `.openMainWindow` (→ the
    /// `main` window) and never a separate meetings entry that would target a deleted scene.
    func testMenuAlwaysTargetsTheMainWindow() {
        let items = MenuBarLayout.items()
        XCTAssertTrue(items.contains(.openMainWindow))
        XCTAssertEqual(MenuBarMenuItem.openMainWindow.managedWindowTarget, AppWindowID.main)
    }

    func testDividerGroupingIsStable() {
        XCTAssertEqual(
            MenuBarLayout.groups().map(\.count),
            [1, 3, 2]
        )
    }

    /// The slim menu removed `.errorLog`, so Settings › Application › Advanced is now the only
    /// opener of the standalone `Window(id: AppWindowID.errors)` error-log scene. Guard that surface
    /// so the error log can't become unreachable again (owner-veto item 2 / D8 follow-up).
    func testAdvancedSettingsExposesTheErrorLogWindow() {
        XCTAssertEqual(AdvancedSettingsView.errorLogWindowID, AppWindowID.errors)
        XCTAssertEqual(AppWindowID.errors, "errors")
    }
}
