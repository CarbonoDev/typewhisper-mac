import Foundation
import SwiftUI

// MARK: - Day bucketing

/// Where a meeting's day falls relative to "now" for the Home timeline's section headers
/// (plan Track C / D6). Kept as a pure value (with the start-of-day date it was computed from) so
/// grouping is unit-testable with fixed dates and the localized/formatted header title is derived
/// separately in the view layer.
enum MeetingDayBucket: Hashable {
    /// A future day (e.g. a scheduled meeting the user engaged from "Coming up") — labeled
    /// Tomorrow / weekday / date. Kept distinct from `.today` so future-dated rows never appear
    /// under a second, duplicate "Today" header at the top of the timeline.
    case future(Date)
    case today
    case yesterday
    /// Within the last week (excluding today/yesterday) — labeled by weekday name.
    case earlierThisWeek(Date)
    /// Older than a week — labeled by date.
    case older(Date)
}

/// One day's worth of meetings in the Home timeline, newest day first, meetings newest-first within.
struct MeetingDayGroup: Identifiable {
    /// Stable per-day key (`yyyy-MM-dd` in the grouping calendar), also the SwiftUI list identity.
    let id: String
    /// Start-of-day for this group, used for both ordering and bucket classification.
    let date: Date
    let meetings: [Meeting]
}

// MARK: - State badges

/// A compact status badge shown on a Home timeline row (plan D6:
/// "Brief ready / Summary + Extended / Running long / In vault").
enum MeetingBadge: Hashable {
    case runningLong
    case briefReady
    case summary
    case extended
    case inVault

    var displayName: String {
        switch self {
        case .runningLong: return String(localized: "home.badge.runningLong")
        case .briefReady: return String(localized: "home.badge.briefReady")
        case .summary: return String(localized: "home.badge.summary")
        case .extended: return String(localized: "home.badge.extended")
        case .inVault: return String(localized: "home.badge.inVault")
        }
    }

    var systemImage: String {
        switch self {
        case .runningLong: return "clock.badge.exclamationmark"
        case .briefReady: return "doc.text.magnifyingglass"
        case .summary: return "list.bullet.rectangle"
        case .extended: return "doc.richtext"
        case .inVault: return "tray.full"
        }
    }

    var tint: Color {
        switch self {
        case .runningLong: return .orange
        case .briefReady: return .green
        case .summary: return .accentColor
        case .extended: return .purple
        case .inVault: return .teal
        }
    }
}

/// The plain facts a meeting contributes to its badge set. Extracted from a `Meeting` (+ the
/// running-long seam) so `badges(for:)` stays a pure, container-free function that tests can drive
/// with literal values.
struct MeetingBadgeFacts: Equatable {
    var hasSummary: Bool
    var hasExtended: Bool
    var hasBrief: Bool
    var isInVault: Bool
    var isRunningLong: Bool
}

extension MeetingsViewModel {
    // MARK: - Day grouping (pure)

    /// Group meetings into per-day buckets, newest day first, newest-within-day first. A meeting's
    /// day is its `startDate` when known, else `createdAt` (imported/ad-hoc meetings without a
    /// scheduled time still land on the day they were made).
    static func homeDayGroups(
        from meetings: [Meeting],
        calendar: Calendar = .current
    ) -> [MeetingDayGroup] {
        let keyFormatter = DateFormatter()
        keyFormatter.calendar = calendar
        keyFormatter.timeZone = calendar.timeZone
        keyFormatter.locale = Locale(identifier: "en_US_POSIX")
        keyFormatter.dateFormat = "yyyy-MM-dd"

        var byDay: [String: (date: Date, meetings: [Meeting])] = [:]
        for meeting in meetings {
            let effective = meeting.startDate ?? meeting.createdAt
            let startOfDay = calendar.startOfDay(for: effective)
            let key = keyFormatter.string(from: startOfDay)
            byDay[key, default: (startOfDay, [])].meetings.append(meeting)
        }

        return byDay
            .map { key, value in
                let sorted = value.meetings.sorted {
                    ($0.startDate ?? $0.createdAt) > ($1.startDate ?? $1.createdAt)
                }
                return MeetingDayGroup(id: key, date: value.date, meetings: sorted)
            }
            .sorted { $0.date > $1.date }
    }

    /// Classify a date's day relative to `now` for the timeline section header (pure).
    static func homeDayBucket(
        for date: Date,
        now: Date,
        calendar: Calendar = .current
    ) -> MeetingDayBucket {
        let startNow = calendar.startOfDay(for: now)
        let startDate = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: startDate, to: startNow).day ?? 0
        if days < 0 { return .future(startDate) }
        if days == 0 { return .today }
        if days == 1 { return .yesterday }
        if days < 7 { return .earlierThisWeek(startDate) }
        return .older(startDate)
    }

    // MARK: - Badges (pure)

    /// Map a meeting's facts to its ordered badge set. Order is intentional and asserted in tests:
    /// running-long (most time-sensitive) first, then brief, then the summary/extended outputs, then
    /// the vault marker.
    static func homeBadges(for facts: MeetingBadgeFacts) -> [MeetingBadge] {
        var badges: [MeetingBadge] = []
        if facts.isRunningLong { badges.append(.runningLong) }
        if facts.hasBrief { badges.append(.briefReady) }
        if facts.hasSummary { badges.append(.summary) }
        if facts.hasExtended { badges.append(.extended) }
        if facts.isInVault { badges.append(.inVault) }
        return badges
    }

    /// Extract the badge facts from a live `Meeting`. `isRunningLong` comes from the seam
    /// (`HomeFeedViewModel`) because it depends on "now" and, later, M10's real running-long API.
    static func homeBadgeFacts(for meeting: Meeting, isRunningLong: Bool) -> MeetingBadgeFacts {
        let kinds = Set(meeting.outputs.map(\.kind))
        let folder = (meeting.obsidianFolder ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return MeetingBadgeFacts(
            hasSummary: kinds.contains(.summary),
            hasExtended: kinds.contains(.extended),
            hasBrief: kinds.contains(.brief),
            isInVault: !folder.isEmpty,
            isRunningLong: isRunningLong
        )
    }
}
