import Foundation

/// [Perf Phase 2] The seam for the two relationship-backed facts the meeting lists need. Reading
/// either faults a whole to-many relationship (one SQL round-trip per meeting), so callers derive
/// them lazily — per visible row, or only while a state facet needs them — and cache the result per
/// `(id, updatedAt)`. When `Meeting` gains denormalised columns for these facts, each body becomes a
/// one-line read of that column; no caller changes.
@MainActor
enum MeetingRelationshipFacts {
    /// Whether the meeting has at least one transcript segment (faults `segments`).
    static func hasTranscript(_ meeting: Meeting) -> Bool {
        !meeting.segments.isEmpty
    }

    /// The kinds of the meeting's outputs (faults `outputs`). Outputs caught mid-deletion are skipped:
    /// reading `kind` on one traps inside SwiftData.
    static func outputKinds(_ meeting: Meeting) -> Set<MeetingOutputKind> {
        Set(meeting.outputs.lazy.filter { !$0.isDeletedFromStore }.map(\.kind))
    }
}
