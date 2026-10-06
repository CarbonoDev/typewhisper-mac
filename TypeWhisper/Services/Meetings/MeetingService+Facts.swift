import Foundation
import SwiftData
import os.log

private let factsLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "MeetingFacts")

/// Maintenance of the denormalised fact columns on `Meeting` (perf plan Phase 2; read API in
/// `Meeting+Facts.swift`). `MeetingService` is the single writer:
///
/// - the live append and `addOutput` update the columns incrementally, in the write's own save;
/// - every other child write goes through a choke point (`insertSegment`, `deleteSegment`,
///   `renumber`, `childrenChanged(of:)`) that marks the meeting stale, and `commitWrite` recomputes
///   stale meetings from their relationships right after it saves;
/// - `reconcileFacts()` (`MeetingService+FactsBackfill.swift`) backfills rows written before the
///   columns existed and heals any drift against the store, once per launch after the first frame,
///   in turns budgeted by rows read; it is idempotent and safe to interrupt.
///
/// Fact writes never bump `updatedAt`: they describe the children, they are not an edit.
extension MeetingService {
    // MARK: - Incremental (hot paths)

    /// The live append's update: incremental when the columns are set, left for the backfill when
    /// they are not (readers fall back to the relationship meanwhile).
    func factsDidAppend(_ segments: [MeetingSegment], to meeting: Meeting) {
        guard let stored = meeting.storedTranscriptFacts else { return }
        meeting.storeTranscriptFacts(stored.appending(segments))
    }

    func factsDidAddOutput(_ kind: MeetingOutputKind, to meeting: Meeting) {
        guard let stored = meeting.storedOutputKinds else { return }
        meeting.storeOutputKinds(stored.union([kind]))
    }

    // MARK: - Stale → recompute

    func markFactsStale(_ meeting: Meeting) {
        listPublishing.staleFacts[meeting.id] = meeting
    }

    /// Recompute every meeting marked stale since the last save (called by `commitWrite`, after
    /// its save, so deleted children have left the relationships). Saves again only if a column
    /// actually changed.
    func refreshStaleFacts() {
        guard !listPublishing.staleFacts.isEmpty else { return }
        let stale = listPublishing.staleFacts.values
        listPublishing.staleFacts.removeAll()
        var changed = false
        for meeting in stale where meeting.modelContext != nil && !meeting.isDeleted {
            changed = recomputeFacts(for: meeting) || changed
        }
        if changed { save() }
    }

    /// Recompute `meeting`'s columns from its relationships. Returns whether anything changed.
    @discardableResult
    func recomputeFacts(for meeting: Meeting) -> Bool {
        let before = (meeting.factSegmentCount, meeting.factTranscriptEnd, meeting.factSpeakerLabelsRaw, meeting.factOutputKindsRaw)
        meeting.storeTranscriptFacts(meeting.computedTranscriptFacts())
        meeting.storeOutputKinds(meeting.computedOutputKinds())
        let after = (meeting.factSegmentCount, meeting.factTranscriptEnd, meeting.factSpeakerLabelsRaw, meeting.factOutputKindsRaw)
        return before != after
    }

    // MARK: - Self-heal (one meeting)

    /// Reconcile one meeting synchronously: unset columns are computed from the relationships, set
    /// ones are checked against the store and recomputed on disagreement (the relationship wins).
    /// Does not save. Returns whether a column changed. The launch pass
    /// (`MeetingService+FactsBackfill.swift`) does the same work in budgeted, paged turns.
    @discardableResult
    func reconcileFacts(for meeting: Meeting) -> Bool {
        guard meeting.hasStoredFacts,
              let count = storeSegmentCount(of: meeting.id),
              let kinds = storeOutputKinds(of: meeting.id)
        else {
            return recomputeFacts(for: meeting)
        }
        if count != meeting.factSegmentCount || kinds != meeting.storedOutputKinds {
            return recomputeFacts(for: meeting)
        }
        return false
    }

    /// `COUNT` of the meeting's segment rows in the store, without faulting the relationship.
    func storeSegmentCount(of meetingID: UUID) -> Int? {
        let descriptor = FetchDescriptor<MeetingSegment>(predicate: #Predicate { $0.meeting?.id == meetingID })
        return try? modelContext.fetchCount(descriptor)
    }

    /// The meeting's output kinds straight from the store (only `kindRaw` is fetched).
    func storeOutputKinds(of meetingID: UUID) -> Set<MeetingOutputKind>? {
        var descriptor = FetchDescriptor<MeetingOutput>(predicate: #Predicate { $0.meeting?.id == meetingID })
        descriptor.propertiesToFetch = [\.kindRaw]
        guard let outputs = try? modelContext.fetch(descriptor) else { return nil }
        return Set(outputs.map(\.kind))
    }
}
