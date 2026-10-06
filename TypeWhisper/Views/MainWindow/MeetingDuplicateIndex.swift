import Foundation

/// [Perf 1C] Memo for `MeetingsListView.duplicateMeetingIDs`, which parses every displayed title
/// and buckets it by day: it ran on every list body evaluation (each selection change, hover-driven
/// republish, live-caption append). The result only depends on each meeting's title and dates, and
/// `MeetingService` bumps `updatedAt` on every write that changes them, so it is recomputed only
/// when the displayed `(id, updatedAt)` sequence or the calendar's zone changes.
///
/// Single-entry: the archive list is the one caller, and its input changes as a whole (filter,
/// sort, a write) rather than alternating between a few lists.
@MainActor
enum MeetingDuplicateIndex {
    private struct Fingerprint: Equatable {
        var entries: [Entry]
        var timeZone: TimeZone
    }

    private struct Entry: Equatable {
        var id: UUID
        var updatedAt: Date
    }

    private static var last: (fingerprint: Fingerprint, ids: Set<UUID>)?

    static func duplicateIDs(in meetings: [Meeting], calendar: Calendar = .current) -> Set<UUID> {
        let fingerprint = Fingerprint(
            entries: meetings.map { Entry(id: $0.id, updatedAt: $0.updatedAt) },
            timeZone: calendar.timeZone
        )
        if let last, last.fingerprint == fingerprint { return last.ids }
        let ids = MeetingsListView.duplicateMeetingIDs(in: meetings, calendar: calendar)
        last = (fingerprint, ids)
        return ids
    }
}
