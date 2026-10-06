import Foundation

/// [Perf Phase 2] The seam for the two transcript/output facts the meeting lists need. They read
/// `Meeting`'s denormalised fact columns (`Meeting+Facts.swift`); a column that is unset or claims
/// "nothing" falls back to the relationship, which faults a whole to-many (one SQL round-trip per
/// meeting) — so callers still derive them lazily (per visible row, or only while a state facet
/// needs them) and cache the result per `(id, updatedAt)` plus `columnStamp`.
@MainActor
enum MeetingRelationshipFacts {
    /// Whether the meeting has at least one transcript segment.
    static func hasTranscript(_ meeting: Meeting) -> Bool {
        meeting.hasTranscript
    }

    /// The kinds of the meeting's outputs.
    static func outputKinds(_ meeting: Meeting) -> Set<MeetingOutputKind> {
        meeting.outputKinds
    }

    /// The fact columns a cached value was read under. Fact writes (the post-launch backfill and
    /// `MeetingService.reconcileFacts` healing drift) do not bump `updatedAt`, so a cache keyed on
    /// `updatedAt` alone could keep a value read from a drifted column after it is healed; caches
    /// also compare this stamp. Plain column reads — no relationship fault.
    struct ColumnStamp: Equatable {
        var segmentCount: Int?
        var outputKindsRaw: String?
    }

    static func columnStamp(_ meeting: Meeting) -> ColumnStamp {
        ColumnStamp(segmentCount: meeting.factSegmentCount, outputKindsRaw: meeting.factOutputKindsRaw)
    }
}
