import AppKit
import Combine
import SwiftUI

private final class MeetCallControlHostingView<Content: View>: NSHostingView<Content> {
    // The panel never becomes key, so the first click has to count.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class MeetCallControlPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: MeetCallControlMetrics().panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        // Movable so `performDrag` may move it; with no title bar and no background dragging, the
        // mic button's press area is the only thing that starts a drag.
        isMovable = true
        isMovableByWindowBackground = false
        level = FloatingPanelSpacePolicy.floatingIndicatorWindowLevel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Best-effort, like the dictation indicators: keep the control out of a shared screen.
        sharingType = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Shows the floating call controls while the Meet bridge has a controllable call *and* the app
/// counts a meeting as running (so not while waiting alone in a room, or in a tab left open after
/// everyone has gone). It remembers where the user dragged them as a position relative to the
/// screen, sizes them for the screen they are on, and can keep them on the active screen.
@MainActor
final class MeetCallControlPanelController {
    /// Settings toggle; on unless the user turned it off.
    static let enabledDefaultsKey = "meetCallControlFloatingEnabled"
    /// Settings toggle; off by default (the controls stay on the screen they were dragged to).
    static let followsActiveScreenDefaultsKey = "meetCallControlFollowsActiveScreen"
    /// The mic button's position relative to its screen (`MeetCallControlPosition.encoded`).
    private static let positionDefaultsKey = "meetCallControlPanelPosition"
    /// The display the controls live on when they do not follow the active screen.
    private static let displayDefaultsKey = "meetCallControlPanelDisplay"
    /// Pre-relative builds stored the button's center in absolute screen coordinates ("x,y").
    private static let legacyAnchorDefaultsKey = "meetCallControlPanelAnchor"
    /// The panel has come to rest once it has not moved for this long.
    private static let settleDelay: Duration = .milliseconds(300)

    private let service: MeetCallControlService
    /// The presence API's `in_meeting`, asked afresh each time.
    private let isMeetingRunning: () -> Bool
    /// The screen the user is working on, by the same rule as the dictation indicators.
    private let activeScreen: () -> NSScreen?
    private let defaults: UserDefaults
    private let model = MeetCallControlPanelModel()
    private var panel: MeetCallControlPanel?
    /// Where `place()` last put the panel; a frame that differs was moved by the user.
    private var placedFrame: NSRect?
    private var isDragging = false
    private var settleTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var periodicCheck: AnyCancellable?
    private var globalMouseMonitor: Any?

    init(
        service: MeetCallControlService,
        isMeetingRunning: @escaping () -> Bool,
        activeScreen: (() -> NSScreen?)? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.service = service
        self.isMeetingRunning = isMeetingRunning
        let resolver = IndicatorScreenResolver()
        self.activeScreen = activeScreen ?? { resolver.resolveScreen(for: .activeScreen) }
        self.defaults = defaults
    }

    func start() {
        service.$current
            .map { $0 != nil }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateVisibility() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: defaults)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.place() }
            .store(in: &cancellables)

        // What can change which screen is the active one: another app or Space comes forward, or
        // the user clicks somewhere. The periodic check below catches the rest.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            workspace.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.followActiveScreen() }
                .store(in: &cancellables)
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            DispatchQueue.main.async { self?.followActiveScreen() }
        }
    }

    // MARK: - Settings

    private var isEnabled: Bool {
        defaults.object(forKey: Self.enabledDefaultsKey) as? Bool ?? true
    }

    private var followsActiveScreen: Bool {
        defaults.bool(forKey: Self.followsActiveScreenDefaultsKey)
    }

    private var sizeSetting: MeetCallControlSize {
        defaults.string(forKey: MeetCallControlSize.defaultsKey).flatMap(MeetCallControlSize.init(rawValue:)) ?? .automatic
    }

    // MARK: - Visibility

    /// A setting changed: show or hide, and re-place in case it was the size or the follow toggle.
    private func refresh() {
        updateVisibility()
        place()
    }

    private func updateVisibility() {
        // "A meeting is running" and "which screen is active" both change without telling anyone
        // (the last other person leaves, the pointer moves to another display), so they are
        // re-asked on a slow tick for as long as a call is offered.
        if isEnabled, service.current != nil {
            if periodicCheck == nil {
                periodicCheck = Timer.publish(every: 3, on: .main, in: .common)
                    .autoconnect()
                    .sink { [weak self] _ in
                        self?.updateVisibility()
                        self?.followActiveScreen()
                    }
            }
        } else {
            periodicCheck = nil
        }

        guard isEnabled, service.current != nil, isMeetingRunning() else {
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? makePanel()
        guard !panel.isVisible else { return }
        place()
        panel.orderFrontRegardless()
    }

    private func makePanel() -> MeetCallControlPanel {
        let panel = MeetCallControlPanel()
        let view = MeetCallControlView(
            service: service,
            model: model,
            onDragBegan: { [weak self] in self?.dragBegan() },
            onDragEnded: { [weak self] in self?.scheduleSettle() }
        )
        let hostingView = MeetCallControlHostingView(rootView: view)
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        NotificationCenter.default.publisher(for: NSWindow.didMoveNotification, object: panel)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.panelDidMove() }
            .store(in: &cancellables)
        self.panel = panel
        return panel
    }

    // MARK: - Placement

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private static func facts(for screen: NSScreen) -> MeetCallControlScreenFacts {
        let id = displayID(of: screen)
        let width = id.map { Double(CGDisplayScreenSize($0).width) } ?? 0
        return MeetCallControlScreenFacts(
            isBuiltIn: id.map { CGDisplayIsBuiltin($0) != 0 } ?? false,
            name: screen.localizedName,
            physicalWidthMM: width > 0 ? width : nil
        )
    }

    private func legacyAnchor() -> NSPoint? {
        guard let parts = defaults.string(forKey: Self.legacyAnchorDefaultsKey)?.split(separator: ","),
              parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else {
            return nil
        }
        return NSPoint(x: x, y: y)
    }

    /// The screen the controls live on when they do not follow the active one: where they were
    /// last dropped, falling back to the main screen when that display is gone.
    private func homeScreen() -> NSScreen? {
        if defaults.object(forKey: Self.displayDefaultsKey) != nil {
            let stored = CGDirectDisplayID(truncatingIfNeeded: defaults.integer(forKey: Self.displayDefaultsKey))
            if let screen = NSScreen.screens.first(where: { Self.displayID(of: $0) == stored }) { return screen }
        } else if let legacy = legacyAnchor(),
                  let screen = NSScreen.screens.first(where: { $0.frame.contains(legacy) }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private func targetScreen() -> NSScreen? {
        (followsActiveScreen ? activeScreen() : nil) ?? homeScreen()
    }

    private func storedPosition() -> MeetCallControlPosition {
        if let position = MeetCallControlPosition(encoded: defaults.string(forKey: Self.positionDefaultsKey)) {
            return position
        }
        if let legacy = legacyAnchor(), let screen = NSScreen.screens.first(where: { $0.frame.contains(legacy) }) {
            return MeetCallControlPosition(anchor: legacy, in: screen.visibleFrame)
        }
        return .initial
    }

    /// Size the panel for its screen and put the mic button on the stored position there.
    private func place() {
        guard let panel, !isDragging, let screen = targetScreen() else { return }
        let metrics = MeetCallControlMetrics(
            scale: MeetCallControlMetrics.scale(for: sizeSetting, on: Self.facts(for: screen))
        )
        let visible = screen.visibleFrame
        let anchor = storedPosition().anchor(in: visible, reach: metrics.reach)
        let trailingAligned = anchor.x > visible.midX
        if model.metrics != metrics { model.metrics = metrics }
        if model.trailingAligned != trailingAligned { model.trailingAligned = trailingAligned }

        let frame = NSRect(
            origin: metrics.origin(forAnchor: anchor, trailingAligned: trailingAligned),
            size: metrics.panelSize
        )
        placedFrame = frame
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    private func followActiveScreen() {
        guard followsActiveScreen, let panel, panel.isVisible else { return }
        place()
    }

    // MARK: - Dragging

    private func dragBegan() {
        isDragging = true
        settleTask?.cancel()
    }

    /// The window server moves the panel during a drag. A frame that is not where `place()` put it
    /// is the user's doing, however the drag was started and whether or not its end is reported.
    private func panelDidMove() {
        guard let panel, panel.frame != placedFrame else { return }
        isDragging = true
        scheduleSettle()
    }

    /// Adopt the panel's new spot once it has stopped moving.
    private func scheduleSettle() {
        settleTask?.cancel()
        settleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled else { return }
            self?.settleDrag()
        }
    }

    private func settleDrag() {
        guard isDragging else { return }
        // Still held down: the pause is not the end of the drag.
        if NSEvent.pressedMouseButtons & 1 != 0 {
            scheduleSettle()
            return
        }
        isDragging = false
        guard let panel else { return }
        let anchor = model.metrics.anchor(forOrigin: panel.frame.origin, trailingAligned: model.trailingAligned)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? panel.screen {
            defaults.set(
                MeetCallControlPosition(anchor: anchor, in: screen.visibleFrame).encoded,
                forKey: Self.positionDefaultsKey
            )
            if let id = Self.displayID(of: screen) {
                defaults.set(Int(id), forKey: Self.displayDefaultsKey)
            }
        }
        // Snap back on-screen, re-decide which side the pill opens toward, and resize for the
        // screen it landed on.
        place()
    }
}
