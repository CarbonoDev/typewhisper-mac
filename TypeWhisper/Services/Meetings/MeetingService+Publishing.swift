import Foundation
import Combine

/// How a `MeetingService` write affects the published `meetings` array (Perf 1C).
///
/// The published array is a *list* of live SwiftData objects. A write that only changes fields of
/// a meeting already in it (transcript append, outputs, notes, title, speaker map, state, …) is
/// visible to every view that reads those fields through SwiftData's own Observation tracking:
/// `Meeting` is `@Observable`, and inserting/deleting a segment, note, or output fires its parent
/// relationship (locked by `MeetingServicePublishingTests`). Refetching and republishing the whole
/// array for such a write only re-faulted every object and invalidated every `MeetingsViewModel`
/// observer — every 4 s during a live caption session.
enum MeetingListChange {
    /// Fields of meetings already in the list changed. Saved; the list is refetched only if a sort
    /// key (`startDate`/`createdAt`) moved so the published order is no longer the fetch order.
    case inPlace
    /// Membership changed (insert/delete), or a fact the `$meetings` subscribers derive from the
    /// whole list changed (folders/tags feed `MeetingOrganizationIndex`): refetch and republish.
    case list
}

/// Mutable bookkeeping behind the publishing rules, held by `MeetingService` so the logic can live
/// in this extension (the main file is over the size limit).
@MainActor
final class MeetingListPublishingState {
    /// `performBatch` nesting depth.
    var batchDepth = 0
    /// A refetch happened inside the current batch whose value list subscribers have not seen yet.
    var republishPending = false
    /// Next `MeetingSegment.order` per meeting for the live-append path, so a ~4 s caption flush
    /// does not fault every segment to find the max. Invalidated structurally by the segment row
    /// choke points in `MeetingService+Publishing.swift` (all segment writes go through
    /// `MeetingService`, the single writer of the store).
    var nextSegmentOrder: [UUID: Int] = [:]
    /// Meetings whose denormalised facts must be recomputed from their relationships after the
    /// next save (see `MeetingService+Facts.swift`).
    var staleFacts: [UUID: Meeting] = [:]
}

extension MeetingService {
    /// Persist the pending changes, then bring the published list up to date for `change`. Every
    /// write is still saved immediately — the transcript is never lost; only the refetch/republish
    /// is skipped (in-place writes) or coalesced (inside `performBatch`).
    func commitWrite(_ change: MeetingListChange) {
        // Stale facts are recomputed into the same transaction (one save per write): pending
        // deletes are still in the relationships but flagged `isDeleted`, which the computed facts
        // skip, so the recompute is already correct before the save.
        refreshStaleFacts()
        save()
        let refetched: Bool
        switch change {
        case .list:
            fetchMeetings()
            refetched = true
        case .inPlace:
            refetched = !Self.isInFetchOrder(meetings)
            if refetched { fetchMeetings() }
        }
        if refetched, listPublishing.batchDepth > 0 {
            listPublishing.republishPending = true
        }
    }

    /// Run `body` so that however many writes it makes, `meetingsListPublisher` subscribers (the
    /// `MeetingsViewModel` mirror and `MeetingOrganizationIndex`) see one republish, when the
    /// outermost batch ends. For bulk writers: Drive transcript import, merges, backup import.
    ///
    /// Inside the batch `meetings` itself stays exact — membership changes are still refetched
    /// per write — because bulk writers dedupe against it mid-loop (the Drive matcher snapshot,
    /// the brief scheduler's `calendarEventID` lookup). Synchronous on purpose: a batch spanning an
    /// `await` would also hold back the republish of unrelated writes made meanwhile (a meeting
    /// the user creates while a backfill is paused on the network).
    @discardableResult
    func performBatch<T>(_ body: () throws -> T) rethrows -> T {
        listPublishing.batchDepth += 1
        defer {
            listPublishing.batchDepth -= 1
            if listPublishing.batchDepth == 0, listPublishing.republishPending {
                listPublishing.republishPending = false
                republishMeetings()
            }
        }
        return try body()
    }

    /// `$meetings` without the values produced mid-`performBatch`. For subscribers that derive state
    /// from the whole list; a plain read of `meetings` is always current.
    var meetingsListPublisher: AnyPublisher<[Meeting], Never> {
        $meetings
            // `$meetings` only ever emits from the MainActor writer.
            .filter { [listPublishing] _ in MainActor.assumeIsolated { listPublishing.batchDepth == 0 } }
            .eraseToAnyPublisher()
    }

    /// Whether `meetings` is still ordered as `fetchMeetings()` would return it: `startDate`
    /// descending with `nil` last (SQLite sorts NULL lowest), then `createdAt` descending. Reads two
    /// attributes per already-loaded meeting — no relationship faults.
    static func isInFetchOrder(_ meetings: [Meeting]) -> Bool {
        guard meetings.count > 1 else { return true }
        for index in 1..<meetings.count where fetchOrderPrecedes(meetings[index], meetings[index - 1]) {
            return false
        }
        return true
    }

    /// Strict "a sorts before b" under the fetch descriptor's order.
    static func fetchOrderPrecedes(_ a: Meeting, _ b: Meeting) -> Bool {
        switch (a.startDate, b.startDate) {
        case let (lhs?, rhs?) where lhs != rhs: return lhs > rhs
        case (.some, .none): return true
        case (.none, .some): return false
        default: return a.createdAt > b.createdAt
        }
    }

    // MARK: - Live-append order cache

    /// The `order` the next appended segment of `meeting` takes; advances the cache by `count`.
    /// Scans the relationship once per meeting, then serves the rest of the session from the cache.
    func reserveSegmentOrders(_ count: Int, for meeting: Meeting) -> Int {
        let start = listPublishing.nextSegmentOrder[meeting.id]
            ?? ((meeting.segments.map(\.order).max() ?? -1) + 1)
        listPublishing.nextSegmentOrder[meeting.id] = start + count
        return start
    }

    /// Drop the cached next order for `meeting`, so the next append recomputes it from the store.
    func forgetSegmentOrder(for meeting: Meeting) {
        listPublishing.nextSegmentOrder[meeting.id] = nil
    }

    /// `childrenChanged(of:)` for every meeting `segments` belong to (`renumber` calls this, so any
    /// path that rewrites `order` invalidates without remembering to).
    func childrenChanged(of segments: [MeetingSegment]) {
        var seen = Set<UUID>()
        for meeting in segments.compactMap(\.meeting) where seen.insert(meeting.id).inserted {
            childrenChanged(of: meeting)
        }
    }

    /// A write rewrote `meeting`'s segments or outputs other than by the live append: drop its
    /// cached next order and recompute its denormalised facts after the next save.
    func childrenChanged(of meeting: Meeting) {
        forgetSegmentOrder(for: meeting)
        markFactsStale(meeting)
    }

    // MARK: - Child row choke points
    //
    // Invariant for the order cache and the denormalised facts: `appendStableSegments` and
    // `addOutput` are the only writers that insert a child without going through these (they keep
    // both incrementally); every segment insert/delete goes through `insertSegment`/`deleteSegment`;
    // every rewrite of `order` (including re-parenting in a merge) goes through `renumber`; every
    // other in-place edit of segment `end`/`speakerLabel` or output insert/delete calls
    // `childrenChanged(of:)`; every meeting delete (the cascade) calls `forgetSegmentOrder`.

    /// Insert a segment row written with its own `order` (replace, merge-import, backup restore).
    func insertSegment(_ segment: MeetingSegment, into meeting: Meeting) {
        segment.meeting = meeting
        modelContext.insert(segment)
        childrenChanged(of: meeting)
    }

    /// Delete a segment row.
    func deleteSegment(_ segment: MeetingSegment) {
        if let meeting = segment.meeting { childrenChanged(of: meeting) }
        modelContext.delete(segment)
    }
}
