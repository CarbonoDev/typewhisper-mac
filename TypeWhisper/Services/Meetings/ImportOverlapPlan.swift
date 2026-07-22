import Foundation

/// Pure overlap policy for merge-importing a transcript into a meeting that already holds *live*
/// segments (`.liveCapture` / `.liveCaptions`) — a planner in the `SpeakerSourcePlan` mold: no I/O,
/// no SwiftData, every decision a function of its inputs, so the policy is unit-testable on its own.
///
/// ## Why text dedupe alone is not enough
/// `TranscriptMerger`'s dedupe is text-based, which catches an import that *restates* captured
/// content verbatim but cannot catch **two different transcriptions of the same audio** (e.g. a
/// Gemini Notes export imported over a Meet live-caption timeline): the words differ enough that
/// both survive, interleaved — noise. Timing, not text, is the reliable signal there.
///
/// ## The policy
/// When the imported transcript carries **real timing**, it is authoritative for its covered span
/// `[min start, max end]`: existing live segments whose midpoint falls inside that span are dropped
/// before the merge; live segments outside the span survive (they cover what the import does not).
/// Non-live segments (`.importedAudio` / `.importedTranscript`) are never dropped here — they were
/// reconciled by their own earlier merge. When the import has **no recoverable timing** the plan is
/// a no-op and the merge falls back to the append + text-dedupe behavior — never guess.
///
/// ## Clocks and sequencing
/// The plan is applied *inside* `TranscriptMerger.mergeAuthoritativeImport`, **after** its clock
/// alignment and **before** its dedupe, so `imported` here is the clock-aligned timeline: when the
/// merger finds a text anchor between the import and captured content, the span comparison happens
/// on the captured clock; when no anchor exists, raw times are used — which is still a shared clock
/// for the caption case, because live-caption times are meeting-relative by API contract
/// (`POST /v1/meetings/live/{id}/segments`: "seconds relative to the meeting start") and a Gemini
/// export's section timestamps are likewise meeting-relative. An anchorless late-join
/// `.liveCapture` timeline can sit on a shifted (capture-relative) clock; that matters only when
/// the import covers a partial span — a full-meeting export (the common Gemini case) covers every
/// live row regardless. Documented v1 limitation, biased toward the stated policy: the import owns
/// its span.
///
/// ## Caption speaker timeline
/// Dropping overlapped `.liveCaptions` rows is deliberate and differs from final re-transcription:
/// `replaceSegments(of:source:)` must preserve the caption speaker timeline because a re-transcribed
/// audio pass has *no* speaker names of its own. A Gemini export carries its **own per-turn speaker
/// names**, so the imported rows replace both the text and the speaker attribution for the covered
/// span — nothing the captions provided is lost.
///
/// Applied on the merge-import path only (`MeetingService.mergeImport`), never on final
/// re-transcription.
enum ImportOverlapPlan {
    /// The plan's output: which existing segments enter the merge, and how many live rows were
    /// dropped as overlapped (surfaced in the import log).
    struct Resolution: Equatable, Sendable {
        var survivingExisting: [TranscriptMerger.Segment]
        var droppedOverlappedCount: Int
    }

    /// Resolve the overlap policy: drop existing live segments whose midpoint falls inside the
    /// imported transcript's covered span. A no-op (everything survives) when the import has no
    /// recoverable timing or the meeting has no live segments in the span.
    static func resolve(
        existing: [TranscriptMerger.Segment],
        imported: [TranscriptMerger.Segment]
    ) -> Resolution {
        guard let span = coveredSpan(of: imported) else {
            return Resolution(survivingExisting: existing, droppedOverlappedCount: 0)
        }
        var surviving: [TranscriptMerger.Segment] = []
        surviving.reserveCapacity(existing.count)
        var dropped = 0
        for segment in existing {
            let isLive = segment.source == .liveCapture || segment.source == .liveCaptions
            let midpoint = (segment.start + segment.end) / 2
            if isLive, span.contains(midpoint) {
                dropped += 1
            } else {
                surviving.append(segment)
            }
        }
        return Resolution(survivingExisting: surviving, droppedOverlappedCount: dropped)
    }

    /// The imported transcript's covered time span, or nil when it has no recoverable timing.
    /// "Real timing" means at least one segment with a positive duration or a non-zero start, and a
    /// span of positive length — an all-zero (plain-text) import yields nil, triggering the
    /// fallback-to-append path.
    static func coveredSpan(of imported: [TranscriptMerger.Segment]) -> ClosedRange<Double>? {
        let timed = imported.filter { $0.end > $0.start || $0.start > 0 }
        guard let minStart = timed.map(\.start).min(),
              let maxEnd = timed.map({ max($0.start, $0.end) }).max(),
              maxEnd > minStart else { return nil }
        return minStart...maxEnd
    }
}
