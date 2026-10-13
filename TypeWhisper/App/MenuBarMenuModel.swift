import AppKit

/// What a status-item menu row does when chosen. Equatable so the menu model is unit-testable
/// without invoking anything; `MenuBarStatusItemController` dispatches it.
enum MenuBarMenuCommand: Equatable {
    case item(MenuBarMenuItem)
    /// The tray meeting entry: open the meeting's document and join its call.
    case openAndJoinMeeting
    /// The sibling "just take me to the call" entry.
    case openMeetingInChrome
    case quit
}

struct MenuBarMenuShortcut: Equatable {
    let keyEquivalent: String
    let modifiers: NSEvent.ModifierFlags

    init(_ keyEquivalent: String, modifiers: NSEvent.ModifierFlags = .command) {
        self.keyEquivalent = keyEquivalent
        self.modifiers = modifiers
    }

    init(descriptor: HotkeyService.MenuShortcutDescriptor) {
        self.init(
            String(descriptor.keyEquivalent),
            modifiers: descriptor.modifiers.intersection([.command, .option, .control, .shift, .function])
        )
    }
}

/// One row of the status-item menu. `command == nil` is an informational row (the status line),
/// rendered disabled exactly as the SwiftUI `.menu` style rendered a bare `Label`.
struct MenuBarMenuRow: Equatable {
    var title: String
    var systemImage: String?
    var shortcut: MenuBarMenuShortcut?
    var isEnabled: Bool = true
    var toolTip: String?
    var command: MenuBarMenuCommand?
}

enum MenuBarMenuEntry: Equatable {
    case row(MenuBarMenuRow)
    case separator
}

/// The values the status-item menu is built from — a plain snapshot so the layout is pure.
struct MenuBarMenuInputs: Equatable {
    /// The tray meeting entry (recording > ongoing > upcoming), nil when none applies.
    struct Meeting: Equatable {
        enum Kind: Equatable { case recording, ongoing, upcoming }

        var kind: Kind
        /// The meeting's own title; the row title is formatted from it per `kind`.
        var title: String
        var hasConferenceLink: Bool
        /// The "Open in Chrome" sibling is shown only for a launchable join URL.
        var canOpenInChrome: Bool
    }

    var statusText: String
    var statusImage: String
    var meeting: Meeting?
    var recorderState: AudioRecorderViewModel.RecorderState = .idle
    var canToggleRecorder: Bool = true
    var dictationHotkeysPaused: Bool = false
    var isModelReady: Bool = true
    var hasRecentTranscriptions: Bool = false
    var canCopyLastTranscription: Bool = false
    var canReadBackLastTranscription: Bool = false
    var canCheckForUpdates: Bool = false
    var recentTranscriptionsShortcut: MenuBarMenuShortcut?
    var copyLastTranscriptionShortcut: MenuBarMenuShortcut?
    var recorderToggleShortcut: MenuBarMenuShortcut?
}

/// The AppKit status-item menu as data. Mirrors `MenuBarView` row for row (status line · tray
/// meeting entry · `MenuBarLayout.groups()` divider-separated · Quit) so the native `NSMenu` and the
/// SwiftUI view never disagree about titles, images, shortcuts or enabled state.
enum MenuBarMenuModel {
    static func entries(for inputs: MenuBarMenuInputs) -> [MenuBarMenuEntry] {
        var entries: [MenuBarMenuEntry] = [
            .row(MenuBarMenuRow(title: inputs.statusText, systemImage: inputs.statusImage, isEnabled: false)),
            .separator
        ]

        if let meeting = inputs.meeting {
            // Literal keys per kind, not one interpolated key: the string extractor only sees literals.
            let format = switch meeting.kind {
            case .recording: String(localized: "meetings.menu.recording")
            case .ongoing: String(localized: "meetings.menu.ongoing")
            case .upcoming: String(localized: "meetings.menu.upcoming")
            }
            entries.append(.row(MenuBarMenuRow(
                title: String(format: format, meeting.title),
                systemImage: meeting.hasConferenceLink ? "video" : (meeting.kind == .recording ? "record.circle" : "calendar"),
                toolTip: String(localized: "meetings.menu.openAndJoin"),
                command: .openAndJoinMeeting
            )))
            if meeting.canOpenInChrome {
                entries.append(.row(MenuBarMenuRow(
                    title: String(localized: "meetings.menu.openInChrome"),
                    systemImage: "safari",
                    toolTip: String(localized: "meetings.menu.openInChrome.help"),
                    command: .openMeetingInChrome
                )))
            }
            entries.append(.separator)
        }

        for (index, group) in MenuBarLayout.groups().enumerated() {
            if index > 0 {
                entries.append(.separator)
            }
            entries.append(contentsOf: group.map { .row(row(for: $0, inputs: inputs)) })
        }

        entries.append(.separator)
        entries.append(.row(MenuBarMenuRow(
            title: String(localized: "Quit"),
            shortcut: MenuBarMenuShortcut("q"),
            command: .quit
        )))
        return entries
    }

    static func row(for item: MenuBarMenuItem, inputs: MenuBarMenuInputs) -> MenuBarMenuRow {
        let command = MenuBarMenuCommand.item(item)
        switch item {
        case .settings:
            return MenuBarMenuRow(
                title: String(localized: "Settings..."), systemImage: "gear",
                shortcut: MenuBarMenuShortcut(","), command: command
            )
        case .startMeetingRecording:
            return MenuBarMenuRow(
                title: String(localized: "meetings.menu.startRecording"), systemImage: "record.circle",
                command: command
            )
        case .openMainWindow:
            return MenuBarMenuRow(
                title: String(localized: "menubar.openMainWindow"), systemImage: "macwindow", command: command
            )
        case .history:
            return MenuBarMenuRow(
                title: String(localized: "History"), systemImage: "clock.arrow.circlepath", command: command
            )
        case .errorLog:
            return MenuBarMenuRow(
                title: String(localized: "Error Log"), systemImage: "exclamationmark.triangle", command: command
            )
        case .toggleRecorder:
            return MenuBarMenuRow(
                title: recorderToggleTitle(inputs.recorderState),
                systemImage: recorderToggleSystemImage(inputs.recorderState),
                shortcut: inputs.recorderToggleShortcut,
                isEnabled: inputs.canToggleRecorder,
                command: command
            )
        case .toggleDictationHotkeysPause:
            return MenuBarMenuRow(
                title: inputs.dictationHotkeysPaused
                    ? String(localized: "Resume Dictation Hotkeys")
                    : String(localized: "Pause Dictation Hotkeys"),
                systemImage: inputs.dictationHotkeysPaused ? "play.circle" : "pause.circle",
                command: command
            )
        case .transcribeFile:
            return MenuBarMenuRow(
                title: String(localized: "Transcribe File..."), systemImage: "doc.text",
                isEnabled: inputs.isModelReady, command: command
            )
        case .recoverLastRecording:
            return MenuBarMenuRow(
                title: String(localized: "Recover Last Recording"), systemImage: "waveform", command: command
            )
        case .recentTranscriptions:
            return MenuBarMenuRow(
                title: String(localized: "Recent Transcriptions"), systemImage: "clock.arrow.circlepath",
                shortcut: inputs.recentTranscriptionsShortcut,
                isEnabled: inputs.hasRecentTranscriptions, command: command
            )
        case .copyLastTranscription:
            return MenuBarMenuRow(
                title: String(localized: "Copy Last Transcription"), systemImage: "doc.on.doc",
                shortcut: inputs.copyLastTranscriptionShortcut,
                isEnabled: inputs.canCopyLastTranscription, command: command
            )
        case .readBackLastTranscription:
            return MenuBarMenuRow(
                title: String(localized: "Read Back Last Transcription"), systemImage: "speaker.wave.2",
                shortcut: MenuBarMenuShortcut("r", modifiers: [.command, .shift]),
                isEnabled: inputs.canReadBackLastTranscription, command: command
            )
        case .checkForUpdates:
            return MenuBarMenuRow(
                title: String(localized: "Check for Updates..."),
                isEnabled: inputs.canCheckForUpdates, command: command
            )
        }
    }

    static func recorderToggleTitle(_ state: AudioRecorderViewModel.RecorderState) -> String {
        switch state {
        case .idle: String(localized: "recorder.startRecording")
        case .recording: String(localized: "recorder.stopRecording")
        case .finalizing: String(localized: "recorder.transcribing")
        }
    }

    static func recorderToggleSystemImage(_ state: AudioRecorderViewModel.RecorderState) -> String {
        switch state {
        case .idle: "record.circle"
        case .recording: "stop.fill"
        case .finalizing: "arrow.triangle.2.circlepath"
        }
    }
}

/// Maps the menu model onto an `NSMenu`. Items target `target`/`action`; each actionable item
/// carries its `MenuBarMenuCommand` in `representedObject` (boxed) for dispatch.
@MainActor
enum MenuBarMenuBuilder {
    final class CommandBox: NSObject {
        let command: MenuBarMenuCommand
        init(_ command: MenuBarMenuCommand) { self.command = command }
    }

    static func populate(_ menu: NSMenu, with entries: [MenuBarMenuEntry], target: AnyObject?, action: Selector) {
        menu.autoenablesItems = false
        menu.removeAllItems()
        for entry in entries {
            switch entry {
            case .separator:
                menu.addItem(.separator())
            case .row(let row):
                menu.addItem(menuItem(for: row, target: target, action: action))
            }
        }
    }

    static func menuItem(for row: MenuBarMenuRow, target: AnyObject?, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(
            title: row.title,
            action: row.command == nil ? nil : action,
            keyEquivalent: row.shortcut?.keyEquivalent ?? ""
        )
        if let shortcut = row.shortcut {
            item.keyEquivalentModifierMask = shortcut.modifiers
        }
        if let systemImage = row.systemImage {
            item.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        }
        item.toolTip = row.toolTip
        item.isEnabled = row.command != nil && row.isEnabled
        if let command = row.command {
            item.target = target
            item.representedObject = CommandBox(command)
        }
        return item
    }

    static func command(of item: NSMenuItem) -> MenuBarMenuCommand? {
        (item.representedObject as? CommandBox)?.command
    }
}
