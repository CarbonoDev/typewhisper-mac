import Foundation

/// The seam through which the meetings Home feed resolves a display color for a calendar event
/// (plan Track C / D6). M11 already carries the owning calendar's real color on
/// `CalendarEventDTO.calendarColor`; when that is present the provider returns it verbatim, so Home
/// matches macOS Calendar. When it is absent (an event whose provider could not read a color, or a
/// fake in tests), the provider falls back to a **stable** palette slot chosen by hashing the
/// calendar name, so the same calendar always draws the same color and the card never renders a
/// blank bar. Swapping in a different provider changes colors with zero structural change to the
/// views — the whole point of routing color through a protocol.
protocol CalendarColorProviding {
    /// A resolved, non-optional color for the event's color bar and dot label.
    func color(for event: CalendarEventDTO) -> CalendarColor
}

/// Default color source for Home. Prefers the event's real M11 color; otherwise assigns a stable
/// palette slot by hashing the calendar name (falling back to the event title, then a neutral gray).
struct DefaultCalendarColorProvider: CalendarColorProviding {
    /// A small, visually distinct palette reminiscent of macOS Calendar's default colors. Used only
    /// as the fallback when an event exposes no real calendar color.
    static let palette: [CalendarColor] = [
        CalendarColor(red: 0.20, green: 0.47, blue: 0.96), // blue
        CalendarColor(red: 0.30, green: 0.72, blue: 0.42), // green
        CalendarColor(red: 0.96, green: 0.50, blue: 0.19), // orange
        CalendarColor(red: 0.79, green: 0.30, blue: 0.78), // purple
        CalendarColor(red: 0.90, green: 0.28, blue: 0.35), // red
        CalendarColor(red: 0.18, green: 0.68, blue: 0.71), // teal
        CalendarColor(red: 0.62, green: 0.44, blue: 0.24), // brown
        CalendarColor(red: 0.36, green: 0.42, blue: 0.85), // indigo
    ]

    func color(for event: CalendarEventDTO) -> CalendarColor {
        if let real = event.calendarColor {
            return real
        }
        let key = event.calendarName?.isEmpty == false ? event.calendarName! : event.title
        return Self.paletteColor(forName: key)
    }

    /// Deterministic name → palette slot. Uses an FNV-1a hash (not Swift's per-run randomized
    /// `Hasher`) so the mapping is stable across launches and reproducible in tests.
    static func paletteColor(forName name: String) -> CalendarColor {
        guard !palette.isEmpty else { return .fallback }
        guard !name.isEmpty else { return palette[0] }
        var hash: UInt64 = 1_469_598_103_934_665_603 // FNV offset basis
        for byte in name.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211 // FNV prime
        }
        return palette[Int(hash % UInt64(palette.count))]
    }
}
