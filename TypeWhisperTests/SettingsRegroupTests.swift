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

        // Grouped rows and alias tabs are disjoint (aliases never get their own row).
        XCTAssertTrue(Set(grouped).isDisjoint(with: SettingsGrouping.aliasTabs))

        // Nothing is dropped: grouped rows ∪ aliases == every SettingsTab case.
        XCTAssertEqual(
            Set(grouped).union(SettingsGrouping.aliasTabs),
            Set(SettingsTab.allCases),
            "Some SettingsTab case is neither grouped nor an alias"
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
        XCTAssertEqual(group(of: .license), .application)
        XCTAssertEqual(group(of: .advanced), .application)
        XCTAssertEqual(group(of: .about), .application)
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
        // navigateToLicense (post-update / all three license targets), navigateToHistory,
        // navigateToIntegrations, showFilePickerFromMenu, and the profiles/prompts/workflows
        // collapse all resolve to one of these tabs — each must be a grouped sidebar row.
        let destinations: [SettingsTab] = [.license, .history, .integrations, .fileTranscription, .workflows]
        for tab in destinations {
            XCTAssertTrue(
                SettingsGrouping.allGroupedTabs.contains(tab),
                "Deep-link destination \(tab) is not a visible grouped row"
            )
        }
    }
}

// MARK: - Menu bar slim (Track D · D8)

/// The slim menu-bar item set: History / Error Log / Transcribe File are removed; Start Meeting
/// Recording and Open TypeWhisper are present; the meetings target follows the rollout flag.
final class MenuBarItemsTests: XCTestCase {
    func testSlimItemSetWhileRolloutFlagOff() {
        XCTAssertEqual(
            MenuBarLayout.items(mainWindowEnabled: false),
            [.startMeetingRecording, .toggleRecorder, .toggleDictationHotkeysPause, .recentTranscriptions, .meetings, .settings]
        )
    }

    func testSlimItemSetWhileRolloutFlagOn() {
        XCTAssertEqual(
            MenuBarLayout.items(mainWindowEnabled: true),
            [.startMeetingRecording, .toggleRecorder, .toggleDictationHotkeysPause, .recentTranscriptions, .openMainWindow, .settings]
        )
    }

    func testSixVisibleMiddleEntries() {
        // Status line + Quit are rendered outside the layout → eight visible entries total (D8).
        XCTAssertEqual(MenuBarLayout.items(mainWindowEnabled: false).count, 6)
        XCTAssertEqual(MenuBarLayout.items(mainWindowEnabled: true).count, 6)
    }

    func testRemovedItemsAreAbsent() {
        for enabled in [true, false] {
            let items = MenuBarLayout.items(mainWindowEnabled: enabled)
            XCTAssertFalse(items.contains(.history))
            XCTAssertFalse(items.contains(.errorLog))
            XCTAssertFalse(items.contains(.transcribeFile))
            XCTAssertFalse(items.contains(.checkForUpdates))
        }
    }

    func testStartMeetingRecordingIsPresent() {
        XCTAssertTrue(MenuBarLayout.items(mainWindowEnabled: true).contains(.startMeetingRecording))
        XCTAssertTrue(MenuBarLayout.items(mainWindowEnabled: false).contains(.startMeetingRecording))
    }

    func testOpenTypeWhisperTargetsTheMainWindow() {
        XCTAssertEqual(MenuBarMenuItem.openMainWindow.managedWindowTarget, AppWindowID.main)
        XCTAssertEqual(AppWindowID.main, "main")
    }

    func testLegacyMeetingsEntryTargetsTheOldWindowWhileFlagOff() {
        XCTAssertTrue(MenuBarLayout.items(mainWindowEnabled: false).contains(.meetings))
        XCTAssertEqual(MenuBarMenuItem.meetings.managedWindowTarget, AppWindowID.meetings)
    }

    func testDividerGroupingIsStable() {
        XCTAssertEqual(
            MenuBarLayout.groups(mainWindowEnabled: true).map(\.count),
            [1, 3, 2]
        )
    }
}
