import AppKit
import SwiftUI

/// [Sprint 1] The meeting-surface design tokens: one blessed set of fonts, spacing steps, radii,
/// and fills shared by the meeting document (and, in later sprints, the timeline / list surfaces).
/// Views must reach for these instead of re-deriving `.opacity`/padding literals — the pre-redesign
/// screens drifted because every file re-implemented its own chip/card/badge recipe.
enum MeetingTheme {
    // MARK: - Type scale

    /// Document page title (masthead) — serif display.
    static let pageTitle = Font.system(size: 28, weight: .bold, design: .serif)
    /// Compressed title while live capture owns the page.
    static let liveTitle = Font.system(size: 20, weight: .bold, design: .serif)
    /// The uppercase kicker line above the title (`MEETING · TUE 14 JULY`).
    static let kicker = Font.system(size: 11, weight: .semibold)
    static let kickerTracking: CGFloat = 1.2
    /// Uppercase section labels (`ACTION ITEMS`, `APPENDIX`).
    static let sectionLabel = Font.system(size: 11, weight: .semibold)
    static let sectionLabelTracking: CGFloat = 0.8
    /// Byline / metadata line and quiet rows.
    static let meta = Font.system(size: 13)
    /// Provenance footnotes under generated prose.
    static let footnote = Font.system(size: 11)
    /// Timestamps, timers, counts.
    static let mono = Font.system(size: 12).monospacedDigit()

    /// Article typography for generated markdown (brief / summary), serif reading voice.
    static func articleHeading(level: Int) -> Font {
        switch level {
        case 1: return .system(size: 22, weight: .semibold, design: .serif)
        case 2: return .system(size: 17, weight: .semibold, design: .serif)
        default: return .system(size: 15, weight: .semibold)
        }
    }
    static let articleBody = Font.system(size: 15, design: .serif)
    static let articleLineSpacing: CGFloat = 7

    // MARK: - Spacing

    /// The only spacing steps meeting surfaces use.
    static let s1: CGFloat = 4
    static let s2: CGFloat = 8
    static let s3: CGFloat = 12
    static let s4: CGFloat = 16
    static let s5: CGFloat = 24
    static let s6: CGFloat = 32
    static let s7: CGFloat = 48

    /// The reading column: content is centered and measure-limited like a document, not a form.
    static let contentMaxWidth: CGFloat = 640
    static let pagePadding: CGFloat = 28
    /// Gap between top-level page sections (whitespace replaces dividers).
    static let sectionGap: CGFloat = 32

    // MARK: - Radii

    static let rowRadius: CGFloat = 8
    static let cardRadius: CGFloat = 12
    static let barRadius: CGFloat = 14

    // MARK: - Fills & lines

    /// The document's reading ground: a faintly warm paper in light mode (editorial warmth without
    /// leaving the platform), the standard window ground in dark. Scoped to the meeting document.
    static let paperBackground = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.windowBackgroundColor
            : NSColor(red: 0.985, green: 0.98, blue: 0.968, alpha: 1)
    })

    /// Card fill + hairline stroke — the one card recipe.
    static let cardFill = Color.primary.opacity(0.04)
    static let cardStroke = Color.primary.opacity(0.08)
    /// Tinted emphasis card (action items).
    static let tintedCardFill = Color.accentColor.opacity(0.08)
    /// Hover fill for quiet rows.
    static let rowHoverFill = Color.primary.opacity(0.06)
    /// The generated-prose left rule.
    static let proseRule = Color.accentColor.opacity(0.25)
    static let proseRuleWidth: CGFloat = 2

    /// The one blessed chip recipe (survivors: timeline badges, transcript tags).
    static let chipFill = Color.secondary.opacity(0.10)

    // MARK: - Avatar palette

    /// Deterministic, colorblind-differentiable hues for attendee initials.
    static let avatarPalette: [Color] = [
        Color(red: 0.36, green: 0.42, blue: 0.75), // indigo
        Color(red: 0.72, green: 0.42, blue: 0.30), // sienna
        Color(red: 0.28, green: 0.55, blue: 0.47), // teal
        Color(red: 0.62, green: 0.38, blue: 0.60), // plum
        Color(red: 0.75, green: 0.56, blue: 0.25), // ochre
        Color(red: 0.42, green: 0.52, blue: 0.30), // olive
        Color(red: 0.30, green: 0.52, blue: 0.68), // slate blue
        Color(red: 0.66, green: 0.36, blue: 0.42), // rosewood
    ]

    /// Stable hue for a display name (FNV-1a over the lowercase name so the color survives restarts
    /// and never depends on Hashable's per-process seed).
    static func avatarColor(for name: String) -> Color {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in name.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return avatarPalette[Int(hash % UInt64(avatarPalette.count))]
    }
}
