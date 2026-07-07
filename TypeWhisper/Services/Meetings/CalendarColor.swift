import SwiftUI

#if canImport(AppKit)
import AppKit
#endif

/// A calendar's display color captured as plain sRGB RGBA components (0…1). Deliberately a
/// `Codable`/`Sendable` value type rather than `NSColor`/`CGColor` so it can cross the fakeable
/// `CalendarEventProviding` seam and be asserted in tests without AppKit-backed color objects
/// (M11 color coding). `EventKitCalendarProvider` maps `EKCalendar.color` into this once, at the
/// provider boundary.
struct CalendarColor: Equatable, Sendable, Codable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Neutral fallback used when a calendar exposes no color (or the components can't be read).
    static let fallback = CalendarColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)

    /// SwiftUI color for the dot/bar in event rows and the settings list. Built in the sRGB space
    /// to match the component representation exactly.
    var swiftUIColor: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    #if canImport(AppKit)
    /// Map an `NSColor` (as returned by `EKCalendar.color`) into sRGB components. Converts through
    /// the sRGB space first so device/named colors yield stable components; falls back to a neutral
    /// gray when conversion fails (e.g. a pattern color).
    init(nsColor: NSColor) {
        guard let srgb = nsColor.usingColorSpace(.sRGB) else {
            self = .fallback
            return
        }
        self.red = Double(srgb.redComponent)
        self.green = Double(srgb.greenComponent)
        self.blue = Double(srgb.blueComponent)
        self.alpha = Double(srgb.alphaComponent)
    }
    #endif
}
