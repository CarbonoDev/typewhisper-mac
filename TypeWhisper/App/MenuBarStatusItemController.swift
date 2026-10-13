import AppKit
import SwiftUI

/// The single seam through which the app touches status-item visibility, so the rule "visibility is
/// written at creation and when the preference changes — never otherwise" is unit-testable.
@MainActor
protocol StatusItemVisibilityControlling: AnyObject {
    var isVisible: Bool { get set }
}

extension NSStatusItem: StatusItemVisibilityControlling {}

/// Binds `UserDefaultsKeys.showMenuBarIcon` to a status item's `isVisible`. Writes once at creation
/// and again only when the preference value actually changes; label re-renders, menu rebuilds and
/// unrelated defaults writes never touch it, so a menu bar manager (Bartender, Ice, Glow) that hides
/// or moves the item is not undone behind its back.
@MainActor
final class MenuBarIconVisibilityBinding {
    private let item: StatusItemVisibilityControlling
    private let defaults: UserDefaults
    private var appliedPreference: Bool
    private var observation: NSKeyValueObservation?

    init(item: StatusItemVisibilityControlling, defaults: UserDefaults = .standard) {
        self.item = item
        self.defaults = defaults
        appliedPreference = Self.preference(in: defaults)
        item.isVisible = appliedPreference
        observation = defaults.observe(\.showMenuBarIcon, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                self?.preferenceMayHaveChanged()
            }
        }
    }

    func preferenceMayHaveChanged() {
        let preference = Self.preference(in: defaults)
        guard preference != appliedPreference else { return }
        appliedPreference = preference
        item.isVisible = preference
    }

    static func preference(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: UserDefaultsKeys.showMenuBarIcon) as? Bool ?? true
    }
}

/// Owns MeetingWhisper's menu bar item in AppKit (replacing SwiftUI's `MenuBarExtra`). A stable
/// `autosaveName` lets macOS — and menu bar managers, which write the owning app's
/// `NSStatusItem Preferred Position/Visible <autosaveName>` defaults — persist position and
/// visibility; and unlike `MenuBarExtra(isInserted:)`, nothing re-asserts `isVisible` when the label
/// re-renders (every second while a meeting is upcoming/ongoing/recording).
///
/// The label is the existing SwiftUI `MenuBarExtraLabel`, hosted in the status button; the menu is a
/// native `NSMenu` rebuilt from `MenuBarMenuModel` each time it opens.
@MainActor
final class MenuBarStatusItemController: NSObject, NSMenuDelegate {
    /// Same in Debug and Release: the dev build has its own bundle id, so the defaults don't collide.
    static let autosaveName = "MeetingWhisper"
    /// Horizontal padding on each side of the hosted label, matching a standard status item.
    private static let horizontalPadding: CGFloat = 4

    private static var installed: MenuBarStatusItemController?

    /// Creates the status item once per process; later calls are no-ops.
    static func installIfNeeded() {
        guard installed == nil, !AppConstants.isRunningTests else { return }
        installed = MenuBarStatusItemController()
    }

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var visibilityBinding: MenuBarIconVisibilityBinding?
    private var labelHost: StatusItemLabelHostingView?
    /// Created lazily on first menu open, mirroring the SwiftUI view's `@StateObject`.
    private var menuState: MenuBarState?
    /// The meeting the tray entry pointed at when the menu was last built; actions act on it.
    private var meetingTarget: MenuBarMeetingTarget?

    private override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        statusItem.autosaveName = Self.autosaveName
        statusItem.behavior = []
        visibilityBinding = MenuBarIconVisibilityBinding(item: statusItem)

        menu.delegate = self
        statusItem.menu = menu
        installLabel()
    }

    // MARK: - Label

    private func installLabel() {
        guard let button = statusItem.button else { return }
        let host = StatusItemLabelHostingView(rootView: AnyView(MenuBarExtraLabel().fixedSize()))
        host.sizingOptions = [.intrinsicContentSize]
        host.translatesAutoresizingMaskIntoConstraints = false
        host.onIntrinsicSizeChange = { [weak self] in self?.fitLengthToLabel() }
        button.addSubview(host)
        NSLayoutConstraint.activate([
            host.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            host.centerYAnchor.constraint(equalTo: button.centerYAnchor)
        ])
        labelHost = host
        fitLengthToLabel()
    }

    /// The item's width follows the label (icon-only ↔ "title · in 12m"). Only `length` is touched,
    /// never visibility or position.
    private func fitLengthToLabel() {
        guard let labelHost else { return }
        let width = ceil(labelHost.fittingSize.width) + Self.horizontalPadding * 2
        guard abs(statusItem.length - width) > 0.5 else { return }
        statusItem.length = width
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        MenuBarMenuBuilder.populate(
            menu,
            with: MenuBarMenuModel.entries(for: currentInputs()),
            target: self,
            action: #selector(performMenuCommand(_:))
        )
    }

    private func currentInputs() -> MenuBarMenuInputs {
        let state = menuState ?? MenuBarState()
        menuState = state
        meetingTarget = MenuBarMeetingTarget.current()

        return MenuBarMenuInputs(
            statusText: state.statusText,
            statusImage: state.statusImage,
            meeting: meetingTarget?.menuInputs,
            recorderState: state.recorderState,
            canToggleRecorder: state.canToggleRecorder,
            dictationHotkeysPaused: state.dictationHotkeysPaused,
            isModelReady: state.isModelReady,
            hasRecentTranscriptions: state.hasRecentTranscriptions,
            canCopyLastTranscription: state.canCopyLastTranscription,
            canReadBackLastTranscription: DictationViewModel.shared.lastTranscribedText != nil,
            canCheckForUpdates: UpdateChecker.shared?.canCheckForUpdates() == true,
            recentTranscriptionsShortcut: state.recentTranscriptionsMenuShortcut.map(MenuBarMenuShortcut.init(descriptor:)),
            copyLastTranscriptionShortcut: state.copyLastTranscriptionMenuShortcut.map(MenuBarMenuShortcut.init(descriptor:)),
            recorderToggleShortcut: state.recorderToggleMenuShortcut.map(MenuBarMenuShortcut.init(descriptor:))
        )
    }

    @objc private func performMenuCommand(_ sender: NSMenuItem) {
        guard let command = MenuBarMenuBuilder.command(of: sender) else { return }
        switch command {
        case .item(let item):
            MenuBarMenuActions.perform(item)
        case .openAndJoinMeeting:
            meetingTarget?.openAndJoin()
        case .openMeetingInChrome:
            meetingTarget?.openInChrome()
        case .quit:
            NSApplication.shared.terminate(nil)
        }
    }
}

/// `NSHostingView` that lets clicks fall through to the status button (so it opens the menu and
/// highlights) and reports intrinsic-size changes so the item can track the label's width.
final class StatusItemLabelHostingView: NSHostingView<AnyView> {
    var onIntrinsicSizeChange: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in
            self?.onIntrinsicSizeChange?()
        }
    }
}
