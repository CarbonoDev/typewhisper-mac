import AppKit
import Combine
import SwiftUI

/// Layout shared by the floating call controls and the panel that hosts them.
enum MeetCallControlMetrics {
    static let puckDiameter: CGFloat = 44
    static let secondaryDiameter: CGFloat = 32
    static let pillPadding: CGFloat = 6
    static let spacing: CGFloat = 6
    /// Room for the pill at its widest (mic + camera + return-to-call) plus its shadow.
    static let panelSize = NSSize(width: 176, height: 72)
    /// Distance from the pill's outer edge to the mic button's center.
    static var puckInset: CGFloat { pillPadding + puckDiameter / 2 }
    /// Transparent margin between the panel's edge and the pill, leaving room for the shadow.
    static let shadowMargin: CGFloat = 8
}

/// What the panel tells its content about where it sits.
@MainActor
final class MeetCallControlPanelModel: ObservableObject {
    /// The mic button hugs the panel's trailing edge and the extra buttons open toward the leading
    /// side — used on the right half of the screen so the pill never opens off-screen.
    @Published var trailingAligned = false
}

/// The floating mute control: a red (muted) or green (live) microphone button that toggles the
/// user's Meet microphone from any app. Hovering reveals the camera toggle and a way back to the
/// call; dragging the microphone button moves the whole control.
struct MeetCallControlView: View {
    @ObservedObject var service: MeetCallControlService
    @ObservedObject var model: MeetCallControlPanelModel
    let onDragChanged: () -> Void
    /// Returns `true` when the gesture moved the panel, `false` when it was a plain click.
    let onDragEnded: () -> Bool

    @State private var hovering = false

    var body: some View {
        let alignment: Alignment = model.trailingAligned ? .trailing : .leading
        pill
            .padding(MeetCallControlMetrics.shadowMargin)
            .frame(
                width: MeetCallControlMetrics.panelSize.width,
                height: MeetCallControlMetrics.panelSize.height,
                alignment: alignment
            )
    }

    @ViewBuilder
    private var pill: some View {
        if let state = service.current?.state {
            HStack(spacing: MeetCallControlMetrics.spacing) {
                if model.trailingAligned {
                    if hovering { secondaryButtons(state) }
                    micButton(muted: state.micMuted)
                } else {
                    micButton(muted: state.micMuted)
                    if hovering { secondaryButtons(state) }
                }
            }
            .padding(MeetCallControlMetrics.pillPadding)
            .background(Capsule().fill(Color.black.opacity(0.78)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 5, y: 2)
            .onHover { inside in
                withAnimation(.easeOut(duration: 0.12)) { hovering = inside }
            }
        }
    }

    private func micButton(muted: Bool) -> some View {
        let label = muted ? String(localized: "Unmute microphone") : String(localized: "Mute microphone")
        return Circle()
            .fill(muted ? Color.red : Color.green)
            .frame(width: MeetCallControlMetrics.puckDiameter, height: MeetCallControlMetrics.puckDiameter)
            .overlay(
                Image(systemName: muted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .contentShape(Circle())
            // One gesture for both: a press that never travels is a click, one that does drags
            // the panel. A `Button` here would swallow the drag.
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { _ in onDragChanged() }
                    .onEnded { _ in
                        if !onDragEnded() { service.toggleMic() }
                    }
            )
            .help(label)
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { service.toggleMic() }
    }

    @ViewBuilder
    private func secondaryButtons(_ state: MeetCallControlState) -> some View {
        if let cameraOff = state.cameraOff {
            secondaryButton(
                systemImage: cameraOff ? "video.slash.fill" : "video.fill",
                tint: cameraOff ? .red : .white,
                label: cameraOff ? String(localized: "Turn camera on") : String(localized: "Turn camera off"),
                action: { service.toggleCamera() }
            )
        }
        secondaryButton(
            systemImage: "arrow.up.forward.square",
            tint: .white,
            label: String(localized: "Return to call"),
            action: { service.focusCall() }
        )
    }

    private func secondaryButton(
        systemImage: String,
        tint: Color,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(
                    width: MeetCallControlMetrics.secondaryDiameter,
                    height: MeetCallControlMetrics.secondaryDiameter
                )
                .background(Circle().fill(Color.white.opacity(0.14)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Settings line saying which Meet Bridge build is connected, and when it needs a reload.
struct MeetBridgeStatusLabel: View {
    let status: MeetBridgeVersion.Status

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: needsReload ? "exclamationmark.triangle.fill" : "puzzlepiece.extension")
                .foregroundStyle(needsReload ? Color.orange : Color.secondary)
                .accessibilityHidden(true)
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
    }

    private var needsReload: Bool {
        switch status {
        case .unversioned, .outdated: true
        case .notSeen, .current: false
        }
    }

    private var text: String {
        let shipped = MeetBridgeVersion.shipped
        switch status {
        case .notSeen:
            return String(localized: "Meet Bridge extension: not connected since the app started.")
        case .unversioned:
            return String(
                format: String(localized: "Meet Bridge extension: an older version is connected that does not report its version. This build ships %@ — reload the extension on chrome://extensions."),
                shipped
            )
        case .outdated(let version):
            return String(
                format: String(localized: "Meet Bridge extension: version %1$@ is connected, but this build ships %2$@ — reload the extension on chrome://extensions."),
                version, shipped
            )
        case .current(let version):
            return String(format: String(localized: "Meet Bridge extension: version %@ is connected."), version)
        }
    }
}

private final class MeetCallControlHostingView<Content: View>: NSHostingView<Content> {
    // The panel never becomes key, so the first click has to count.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class MeetCallControlPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: MeetCallControlMetrics.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
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
/// everyone has gone), and remembers where the user dragged them.
@MainActor
final class MeetCallControlPanelController {
    /// Settings toggle; on unless the user turned it off.
    static let enabledDefaultsKey = "meetCallControlFloatingEnabled"
    /// Where the microphone button's center sits, in screen coordinates ("x,y").
    private static let anchorDefaultsKey = "meetCallControlPanelAnchor"
    /// A press that travels less than this is a click, not a drag.
    private static let dragThreshold: CGFloat = 4

    private let service: MeetCallControlService
    /// The presence API's `in_meeting`, asked afresh each time.
    private let isMeetingRunning: () -> Bool
    private let defaults: UserDefaults
    private let model = MeetCallControlPanelModel()
    private var panel: MeetCallControlPanel?
    private var anchor: NSPoint?
    private var dragStart: (mouse: NSPoint, anchor: NSPoint)?
    private var didDrag = false
    private var cancellables: Set<AnyCancellable> = []
    private var meetingCheck: AnyCancellable?

    init(
        service: MeetCallControlService,
        isMeetingRunning: @escaping () -> Bool,
        defaults: UserDefaults = .standard
    ) {
        self.service = service
        self.isMeetingRunning = isMeetingRunning
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
            .sink { [weak self] _ in self?.updateVisibility() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.place() }
            .store(in: &cancellables)
    }

    private var isEnabled: Bool {
        defaults.object(forKey: Self.enabledDefaultsKey) as? Bool ?? true
    }

    private func updateVisibility() {
        // "A meeting is running" changes without telling anyone (the last other person leaves, a
        // quiet call ages out), so it is re-asked on a slow tick for as long as a call is offered.
        if isEnabled, service.current != nil {
            if meetingCheck == nil {
                meetingCheck = Timer.publish(every: 3, on: .main, in: .common)
                    .autoconnect()
                    .sink { [weak self] _ in self?.updateVisibility() }
            }
        } else {
            meetingCheck = nil
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
            onDragChanged: { [weak self] in self?.dragChanged() },
            onDragEnded: { [weak self] in self?.dragEnded() ?? false }
        )
        let hostingView = MeetCallControlHostingView(rootView: view)
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        self.panel = panel
        return panel
    }

    // MARK: - Placement

    private func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func storedAnchor() -> NSPoint? {
        guard let parts = defaults.string(forKey: Self.anchorDefaultsKey)?.split(separator: ","),
              parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else {
            return nil
        }
        return NSPoint(x: x, y: y)
    }

    /// Put the panel where the anchor says, pulled back on-screen if the display layout changed.
    private func place() {
        guard let panel else { return }
        var point = anchor ?? storedAnchor() ?? .zero
        let hadAnchor = anchor != nil || storedAnchor() != nil
        guard let screen = screen(containing: point) else { return }
        let reach = MeetCallControlMetrics.puckInset + MeetCallControlMetrics.shadowMargin
        let visible = screen.visibleFrame.insetBy(dx: reach, dy: reach)
        if hadAnchor {
            point.x = min(max(point.x, visible.minX), visible.maxX)
            point.y = min(max(point.y, visible.minY), visible.maxY)
        } else {
            // First run: right edge, a little above the middle — clear of the Dock and menu bar.
            point = NSPoint(x: visible.maxX - 16, y: visible.midY + visible.height * 0.15)
        }
        anchor = point
        model.trailingAligned = point.x > screen.frame.midX
        panel.setFrameOrigin(origin(for: point))
    }

    /// The panel origin that puts the microphone button's center on `anchor`.
    private func origin(for anchor: NSPoint) -> NSPoint {
        let size = MeetCallControlMetrics.panelSize
        let reach = MeetCallControlMetrics.puckInset + MeetCallControlMetrics.shadowMargin
        let x = model.trailingAligned ? anchor.x + reach - size.width : anchor.x - reach
        return NSPoint(x: x, y: anchor.y - size.height / 2)
    }

    // MARK: - Dragging

    private func dragChanged() {
        guard let panel, let anchor else { return }
        // Screen coordinates, not the gesture's: the gesture's own space moves with the panel.
        let mouse = NSEvent.mouseLocation
        if dragStart == nil {
            dragStart = (mouse: mouse, anchor: anchor)
            didDrag = false
        }
        guard let dragStart else { return }
        let dx = mouse.x - dragStart.mouse.x
        let dy = mouse.y - dragStart.mouse.y
        if !didDrag, hypot(dx, dy) < Self.dragThreshold { return }
        didDrag = true
        let moved = NSPoint(x: dragStart.anchor.x + dx, y: dragStart.anchor.y + dy)
        self.anchor = moved
        // The side the pill opens toward is only re-decided on release, so it never flips mid-drag.
        panel.setFrameOrigin(origin(for: moved))
    }

    private func dragEnded() -> Bool {
        defer { dragStart = nil }
        guard dragStart != nil, didDrag else { return false }
        didDrag = false
        place()
        if let anchor {
            defaults.set("\(Int(anchor.x.rounded())),\(Int(anchor.y.rounded()))", forKey: Self.anchorDefaultsKey)
        }
        return true
    }
}
