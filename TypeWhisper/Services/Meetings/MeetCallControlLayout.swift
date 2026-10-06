import CoreGraphics
import Foundation

// Pure geometry behind the floating call controls: how big they are on a given screen and where
// they sit on it. Kept free of AppKit so the rules can be tested without a window.

/// The size setting for the floating call controls.
enum MeetCallControlSize: String, CaseIterable, Sendable {
    /// Regular on a desk display, larger on a tablet-sized one (an iPad used through Sidecar),
    /// where the button is pressed with a finger or a Pencil rather than a pointer.
    case automatic
    case regular
    case large
    case extraLarge

    static let defaultsKey = "meetCallControlSize"
}

/// What the sizing rule needs to know about a screen.
struct MeetCallControlScreenFacts: Equatable, Sendable {
    var isBuiltIn: Bool
    var name: String
    /// Physical width in millimetres, when the display reports one.
    var physicalWidthMM: Double?
}

/// Every dimension of the controls, derived from one scale factor so they grow together.
struct MeetCallControlMetrics: Equatable, Sendable {
    var scale: CGFloat = 1

    var puckDiameter: CGFloat { 44 * scale }
    var secondaryDiameter: CGFloat { 32 * scale }
    var pillPadding: CGFloat { 6 * scale }
    var spacing: CGFloat { 6 * scale }
    var micIconSize: CGFloat { 18 * scale }
    var secondaryIconSize: CGFloat { 13 * scale }
    /// Transparent margin between the panel's edge and the pill, leaving room for the shadow.
    var shadowMargin: CGFloat { 8 * scale }
    /// Room for the pill at its widest (mic + camera + return-to-call) plus its shadow.
    var panelSize: CGSize { CGSize(width: 176 * scale, height: 72 * scale) }
    /// Distance from the panel's edge to the mic button's center.
    var reach: CGFloat { shadowMargin + pillPadding + puckDiameter / 2 }

    /// A display this narrow that is not the Mac's own is a tablet: a 12.9" iPad is 262 mm wide,
    /// the smallest portable monitors start around 300 mm.
    static let tabletMaxWidthMM: Double = 290
    static let tabletScale: CGFloat = 1.75

    static func scale(for size: MeetCallControlSize, on screen: MeetCallControlScreenFacts) -> CGFloat {
        switch size {
        case .regular: 1
        case .large: 1.5
        case .extraLarge: 2
        case .automatic: looksLikeTablet(screen) ? tabletScale : 1
        }
    }

    static func looksLikeTablet(_ screen: MeetCallControlScreenFacts) -> Bool {
        guard !screen.isBuiltIn else { return false }
        let name = screen.name.lowercased()
        if name.contains("sidecar") || name.contains("ipad") { return true }
        if let width = screen.physicalWidthMM, width > 0 { return width <= tabletMaxWidthMM }
        return false
    }

    /// The panel origin that puts the mic button's center on `anchor`. With `trailingAligned` the
    /// button hugs the panel's trailing edge (and the extra buttons open toward the leading side).
    func origin(forAnchor anchor: CGPoint, trailingAligned: Bool) -> CGPoint {
        let x = trailingAligned ? anchor.x + reach - panelSize.width : anchor.x - reach
        return CGPoint(x: x, y: anchor.y - panelSize.height / 2)
    }

    /// Inverse of `origin(forAnchor:trailingAligned:)`: where the mic button's center is.
    func anchor(forOrigin origin: CGPoint, trailingAligned: Bool) -> CGPoint {
        let x = trailingAligned ? origin.x + panelSize.width - reach : origin.x + reach
        return CGPoint(x: x, y: origin.y + panelSize.height / 2)
    }
}

/// Where the mic button sits, as fractions of a screen's usable area — so the same spot can be
/// found on a screen of any size, which is what lets the controls follow the active screen.
struct MeetCallControlPosition: Equatable, Sendable {
    /// 0 = left edge, 1 = right edge.
    var fx: Double
    /// 0 = bottom edge, 1 = top edge.
    var fy: Double

    /// First run: right edge, a little above the middle — clear of the Dock and the menu bar.
    static let initial = MeetCallControlPosition(fx: 1, fy: 0.65)

    init(fx: Double, fy: Double) {
        self.fx = min(max(fx.isFinite ? fx : 1, 0), 1)
        self.fy = min(max(fy.isFinite ? fy : 0.65, 0), 1)
    }

    /// The position of a point on screen, relative to that screen's usable area.
    init(anchor: CGPoint, in visible: CGRect) {
        guard visible.width > 0, visible.height > 0 else {
            self = .initial
            return
        }
        self.init(
            fx: Double((anchor.x - visible.minX) / visible.width),
            fy: Double((anchor.y - visible.minY) / visible.height)
        )
    }

    /// The point this position names on a screen, kept far enough from the edges (`reach`) that
    /// the whole button stays on it.
    func anchor(in visible: CGRect, reach: CGFloat) -> CGPoint {
        let inset = visible.insetBy(dx: min(reach, visible.width / 2), dy: min(reach, visible.height / 2))
        let x = visible.minX + CGFloat(fx) * visible.width
        let y = visible.minY + CGFloat(fy) * visible.height
        return CGPoint(x: min(max(x, inset.minX), inset.maxX), y: min(max(y, inset.minY), inset.maxY))
    }

    var encoded: String { String(format: "%.4f,%.4f", fx, fy) }

    init?(encoded: String?) {
        guard let parts = encoded?.split(separator: ","), parts.count == 2,
              let fx = Double(parts[0]), let fy = Double(parts[1]) else {
            return nil
        }
        self.init(fx: fx, fy: fy)
    }
}
