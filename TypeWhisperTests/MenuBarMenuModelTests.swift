import AppKit
import XCTest
@testable import TypeWhisper

/// The AppKit status-item menu as data (`MenuBarMenuModel`) and its `NSMenu` mapping
/// (`MenuBarMenuBuilder`): rows mirror `MenuBarView` — status line, optional tray meeting entry,
/// the `MenuBarLayout` groups divider-separated, then Quit.
@MainActor
final class MenuBarMenuModelTests: XCTestCase {
    private func inputs(meeting: MenuBarMenuInputs.Meeting? = nil) -> MenuBarMenuInputs {
        MenuBarMenuInputs(statusText: "Parakeet ready", statusImage: "checkmark.circle.fill", meeting: meeting)
    }

    private func rows(_ entries: [MenuBarMenuEntry]) -> [MenuBarMenuRow] {
        entries.compactMap { if case .row(let row) = $0 { row } else { nil } }
    }

    private func shape(_ entries: [MenuBarMenuEntry]) -> [String] {
        entries.map { entry in
            switch entry {
            case .separator: "-"
            case .row(let row):
                switch row.command {
                case nil: "status"
                case .item(let item): "\(item)"
                case .openAndJoinMeeting: "openAndJoinMeeting"
                case .openMeetingInChrome: "openMeetingInChrome"
                case .quit: "quit"
                }
            }
        }
    }

    // MARK: - Model

    func testLayoutWithoutMeetingMirrorsGroupsWithSeparators() {
        let entries = MenuBarMenuModel.entries(for: inputs())
        XCTAssertEqual(shape(entries), [
            "status", "-",
            "startMeetingRecording", "-",
            "toggleRecorder",
            "toggleDictationHotkeysPause",
            "recentTranscriptions", "-",
            "openMainWindow",
            "settings", "-",
            "quit"
        ])
    }

    func testStatusLineIsDisabledAndCarriesNoCommand() {
        let status = rows(MenuBarMenuModel.entries(for: inputs()))[0]
        XCTAssertEqual(status.title, "Parakeet ready")
        XCTAssertEqual(status.systemImage, "checkmark.circle.fill")
        XCTAssertNil(status.command)
        XCTAssertFalse(status.isEnabled)
    }

    func testFixedShortcutsForSettingsAndQuit() {
        let all = rows(MenuBarMenuModel.entries(for: inputs()))
        XCTAssertEqual(all.first { $0.command == .item(.settings) }?.shortcut, MenuBarMenuShortcut(","))
        XCTAssertEqual(all.first { $0.command == .quit }?.shortcut, MenuBarMenuShortcut("q"))
        XCTAssertEqual(all.first { $0.command == .quit }?.title, String(localized: "Quit"))
    }

    func testConfiguredShortcutsAndEnabledStateFlowThrough() {
        var input = inputs()
        input.canToggleRecorder = false
        input.hasRecentTranscriptions = true
        input.recorderToggleShortcut = MenuBarMenuShortcut("r", modifiers: [.command, .option])
        input.recentTranscriptionsShortcut = MenuBarMenuShortcut("t", modifiers: [.control])
        let all = rows(MenuBarMenuModel.entries(for: input))

        let recorder = all.first { $0.command == .item(.toggleRecorder) }
        XCTAssertEqual(recorder?.isEnabled, false)
        XCTAssertEqual(recorder?.shortcut, MenuBarMenuShortcut("r", modifiers: [.command, .option]))

        let recent = all.first { $0.command == .item(.recentTranscriptions) }
        XCTAssertEqual(recent?.isEnabled, true)
        XCTAssertEqual(recent?.shortcut, MenuBarMenuShortcut("t", modifiers: [.control]))
    }

    func testRecentTranscriptionsDisabledWithoutHistory() {
        let recent = rows(MenuBarMenuModel.entries(for: inputs())).first { $0.command == .item(.recentTranscriptions) }
        XCTAssertEqual(recent?.isEnabled, false)
    }

    func testRecorderAndPauseRowsFollowState() {
        var input = inputs()
        input.recorderState = .recording
        input.dictationHotkeysPaused = true
        let all = rows(MenuBarMenuModel.entries(for: input))

        let recorder = all.first { $0.command == .item(.toggleRecorder) }
        XCTAssertEqual(recorder?.title, String(localized: "recorder.stopRecording"))
        XCTAssertEqual(recorder?.systemImage, "stop.fill")

        let pause = all.first { $0.command == .item(.toggleDictationHotkeysPause) }
        XCTAssertEqual(pause?.title, String(localized: "Resume Dictation Hotkeys"))
        XCTAssertEqual(pause?.systemImage, "play.circle")
    }

    func testMeetingEntryWithChromeSiblingPrecedesGroups() {
        let meeting = MenuBarMenuInputs.Meeting(kind: .upcoming, title: "Standup", hasConferenceLink: true, canOpenInChrome: true)
        let entries = MenuBarMenuModel.entries(for: inputs(meeting: meeting))
        XCTAssertEqual(Array(shape(entries).prefix(6)), [
            "status", "-", "openAndJoinMeeting", "openMeetingInChrome", "-",
            "startMeetingRecording"
        ])
        let entry = rows(entries)[1]
        XCTAssertEqual(entry.title, String(format: String(localized: "meetings.menu.upcoming"), "Standup"))
        XCTAssertEqual(entry.systemImage, "video")
        XCTAssertEqual(entry.toolTip, String(localized: "meetings.menu.openAndJoin"))
    }

    func testRecordingMeetingWithoutLinkHasNoChromeSibling() {
        let meeting = MenuBarMenuInputs.Meeting(kind: .recording, title: "Sync", hasConferenceLink: false, canOpenInChrome: false)
        let entries = MenuBarMenuModel.entries(for: inputs(meeting: meeting))
        XCTAssertFalse(shape(entries).contains("openMeetingInChrome"))
        let entry = rows(entries)[1]
        XCTAssertEqual(entry.title, String(format: String(localized: "meetings.menu.recording"), "Sync"))
        XCTAssertEqual(entry.systemImage, "record.circle")
    }

    func testOngoingMeetingUsesCalendarGlyphAndOngoingFormat() {
        let meeting = MenuBarMenuInputs.Meeting(kind: .ongoing, title: "1:1", hasConferenceLink: false, canOpenInChrome: false)
        let entry = rows(MenuBarMenuModel.entries(for: inputs(meeting: meeting)))[1]
        XCTAssertEqual(entry.title, String(format: String(localized: "meetings.menu.ongoing"), "1:1"))
        XCTAssertEqual(entry.systemImage, "calendar")
    }

    func testDescriptorShortcutKeepsOnlyDeviceIndependentModifiers() {
        let descriptor = HotkeyService.MenuShortcutDescriptor(keyEquivalent: "k", modifiers: [.command, .shift, .capsLock])
        XCTAssertEqual(MenuBarMenuShortcut(descriptor: descriptor), MenuBarMenuShortcut("k", modifiers: [.command, .shift]))
    }

    // MARK: - NSMenu mapping

    func testBuilderMapsTitlesShortcutsEnabledStateAndSeparators() {
        var input = inputs()
        input.recorderToggleShortcut = MenuBarMenuShortcut("r", modifiers: [.command, .option])
        input.canToggleRecorder = false
        let entries = MenuBarMenuModel.entries(for: input)
        let menu = NSMenu()
        let target = NSObject()
        MenuBarMenuBuilder.populate(menu, with: entries, target: target, action: #selector(NSObject.description))

        XCTAssertFalse(menu.autoenablesItems)
        XCTAssertEqual(menu.items.count, entries.count)
        for (item, entry) in zip(menu.items, entries) {
            switch entry {
            case .separator:
                XCTAssertTrue(item.isSeparatorItem)
            case .row(let row):
                XCTAssertEqual(item.title, row.title)
                XCTAssertEqual(item.keyEquivalent, row.shortcut?.keyEquivalent ?? "")
                if let shortcut = row.shortcut {
                    XCTAssertEqual(item.keyEquivalentModifierMask, shortcut.modifiers)
                }
                XCTAssertEqual(item.isEnabled, row.command != nil && row.isEnabled)
                XCTAssertEqual(MenuBarMenuBuilder.command(of: item), row.command)
                XCTAssertEqual(item.toolTip, row.toolTip)
                if row.command != nil {
                    XCTAssertTrue(item.target === target)
                    XCTAssertNotNil(item.action)
                } else {
                    XCTAssertNil(item.action)
                }
            }
        }

        let recorder = menu.items.first { MenuBarMenuBuilder.command(of: $0) == .item(.toggleRecorder) }
        XCTAssertEqual(recorder?.isEnabled, false)
        XCTAssertEqual(recorder?.keyEquivalent, "r")
        XCTAssertEqual(recorder?.keyEquivalentModifierMask, [.command, .option])
    }

    func testRepopulatingReplacesPreviousItems() {
        let menu = NSMenu()
        let meeting = MenuBarMenuInputs.Meeting(kind: .upcoming, title: "A", hasConferenceLink: false, canOpenInChrome: false)
        MenuBarMenuBuilder.populate(menu, with: MenuBarMenuModel.entries(for: inputs(meeting: meeting)), target: nil, action: #selector(NSObject.description))
        let withMeeting = menu.items.count
        MenuBarMenuBuilder.populate(menu, with: MenuBarMenuModel.entries(for: inputs()), target: nil, action: #selector(NSObject.description))
        XCTAssertEqual(menu.items.count, withMeeting - 2, "meeting row + its separator dropped")
    }
}
