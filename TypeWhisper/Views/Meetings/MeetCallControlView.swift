import AppKit
import SwiftUI

/// What the panel tells its content about where it sits and how big it is.
@MainActor
final class MeetCallControlPanelModel: ObservableObject {
    /// The mic button hugs the panel's trailing edge and the extra buttons open toward the leading
    /// side — used on the right half of the screen so the pill never opens off-screen.
    @Published var trailingAligned = false
    @Published var metrics = MeetCallControlMetrics()
}

/// The floating mute control: a red (muted) or green (live) microphone button that toggles the
/// user's Meet microphone from any app. Hovering reveals the camera toggle and a way back to the
/// call; dragging the microphone button moves the whole control.
struct MeetCallControlView: View {
    @ObservedObject var service: MeetCallControlService
    @ObservedObject var model: MeetCallControlPanelModel
    let onDragBegan: () -> Void
    let onDragEnded: () -> Void

    @State private var hovering = false

    var body: some View {
        let metrics = model.metrics
        pill(metrics)
            .padding(metrics.shadowMargin)
            .frame(
                width: metrics.panelSize.width,
                height: metrics.panelSize.height,
                alignment: model.trailingAligned ? .trailing : .leading
            )
    }

    @ViewBuilder
    private func pill(_ metrics: MeetCallControlMetrics) -> some View {
        if let state = service.current?.state {
            HStack(spacing: metrics.spacing) {
                if model.trailingAligned {
                    if hovering { secondaryButtons(state, metrics) }
                    micButton(muted: state.micMuted, metrics)
                } else {
                    micButton(muted: state.micMuted, metrics)
                    if hovering { secondaryButtons(state, metrics) }
                }
            }
            .padding(metrics.pillPadding)
            .background(Capsule().fill(Color.black.opacity(0.78)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 5, y: 2)
            .onHover { inside in
                withAnimation(.easeOut(duration: 0.12)) { hovering = inside }
            }
        }
    }

    private func micButton(muted: Bool, _ metrics: MeetCallControlMetrics) -> some View {
        let label = muted ? String(localized: "Unmute microphone") : String(localized: "Mute microphone")
        return Circle()
            .fill(muted ? Color.red : Color.green)
            .frame(width: metrics.puckDiameter, height: metrics.puckDiameter)
            .overlay(
                Image(systemName: muted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: metrics.micIconSize, weight: .semibold))
                    .foregroundStyle(.white)
            )
            // Click and drag are handled in AppKit (see `MeetCallControlPressArea`), not with a
            // SwiftUI gesture: the window server then moves the panel itself, which works for
            // every input that can drag a title bar — a pointer, a Pencil, a finger on a Sidecar
            // iPad — instead of depending on where the mouse pointer happens to be.
            .overlay(
                MeetCallControlPressArea(
                    toolTip: label,
                    onClick: { service.toggleMic() },
                    onDragBegan: onDragBegan,
                    onDragEnded: onDragEnded
                )
                .clipShape(Circle())
            )
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { service.toggleMic() }
    }

    @ViewBuilder
    private func secondaryButtons(_ state: MeetCallControlState, _ metrics: MeetCallControlMetrics) -> some View {
        if let cameraOff = state.cameraOff {
            secondaryButton(
                systemImage: cameraOff ? "video.slash.fill" : "video.fill",
                tint: cameraOff ? .red : .white,
                label: cameraOff ? String(localized: "Turn camera on") : String(localized: "Turn camera off"),
                metrics: metrics,
                action: { service.toggleCamera() }
            )
        }
        secondaryButton(
            systemImage: "arrow.up.forward.square",
            tint: .white,
            label: String(localized: "Return to call"),
            metrics: metrics,
            action: { service.focusCall() }
        )
    }

    private func secondaryButton(
        systemImage: String,
        tint: Color,
        label: String,
        metrics: MeetCallControlMetrics,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: metrics.secondaryIconSize, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: metrics.secondaryDiameter, height: metrics.secondaryDiameter)
                .background(Circle().fill(Color.white.opacity(0.14)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The mic button's hit area. A press that never travels is a click; one that does hands the
/// panel to the window server to drag (`NSWindow.performDrag`).
struct MeetCallControlPressArea: NSViewRepresentable {
    let toolTip: String
    let onClick: () -> Void
    let onDragBegan: () -> Void
    let onDragEnded: () -> Void

    func makeNSView(context: Context) -> MeetCallControlPressView {
        let view = MeetCallControlPressView()
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: MeetCallControlPressView, context: Context) {
        view.toolTip = toolTip
        view.onClick = onClick
        view.onDragBegan = onDragBegan
        view.onDragEnded = onDragEnded
    }
}

final class MeetCallControlPressView: NSView {
    /// A press that travels less than this is a click, not a drag.
    private static let dragThreshold: CGFloat = 4

    var onClick: () -> Void = {}
    var onDragBegan: () -> Void = {}
    var onDragEnded: () -> Void = {}

    /// Where the press started, in screen coordinates (the window moves under a drag).
    private var pressStart: NSPoint?
    private var dragging = false

    // The panel never becomes key, so the first press has to count.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        pressStart = screenPoint(of: event)
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressStart, !dragging, let window else { return }
        let point = screenPoint(of: event)
        guard hypot(point.x - pressStart.x, point.y - pressStart.y) >= Self.dragThreshold else { return }
        dragging = true
        onDragBegan()
        window.performDrag(with: event)
        // When the drag was tracked to its end inside that call, the button is already up and no
        // `mouseUp` follows. Otherwise `mouseUp` (or the panel coming to rest) finishes it.
        if NSEvent.pressedMouseButtons & 1 == 0 { finishDrag() }
    }

    override func mouseUp(with event: NSEvent) {
        if dragging {
            finishDrag()
        } else if pressStart != nil {
            onClick()
        }
        pressStart = nil
    }

    private func finishDrag() {
        guard dragging else { return }
        dragging = false
        pressStart = nil
        onDragEnded()
    }

    private func screenPoint(of event: NSEvent) -> NSPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
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

/// The size and follow-the-screen settings for the floating call controls.
struct MeetCallControlPlacementSettings: View {
    @AppStorage(MeetCallControlSize.defaultsKey) private var size = MeetCallControlSize.automatic.rawValue
    @AppStorage(MeetCallControlPanelController.followsActiveScreenDefaultsKey) private var followsActiveScreen = false

    var body: some View {
        Picker(selection: $size) {
            Text(String(localized: "Automatic (larger on an iPad display)")).tag(MeetCallControlSize.automatic.rawValue)
            Text(String(localized: "Regular")).tag(MeetCallControlSize.regular.rawValue)
            Text(String(localized: "Large")).tag(MeetCallControlSize.large.rawValue)
            Text(String(localized: "Extra large")).tag(MeetCallControlSize.extraLarge.rawValue)
        } label: {
            Text(String(localized: "Call controls size"))
        }

        Toggle(isOn: $followsActiveScreen) {
            SettingsInfoLabel(
                title: String(localized: "Call controls follow the active screen"),
                info: String(localized: "Keeps the floating button on the screen you are working on, at the same spot relative to its edges. When off, it stays on the screen you dragged it to.")
            )
        }
    }
}
