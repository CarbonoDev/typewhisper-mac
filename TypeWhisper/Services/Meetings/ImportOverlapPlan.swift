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
/// When the imported transcript carries **real timing**, it is authoritative for **the stretches it
/// actually covers** — not for the hull of its timestamps. The import's own segments are merged into
/// *covered runs* (adjacent segments joined across gaps no longer than `runGapTolerance`, i.e. the
/// pauses that punctuate ordinary speech), and only existing live segments whose midpoint falls
/// inside one of those runs are dropped before the merge. Live segments outside every run survive:
/// they cover what the import does not, and **captured content is never dropped where the import has
/// nothing to put in its place** — a Gemini export that skipped ten minutes mid-meeting must not
/// erase the captions for those ten minutes. Non-live segments (`.importedAudio` /
/// `.importedTranscript`) are never dropped here — they were reconciled by their own earlier merge.
/// When the import has **no recoverable timing** the plan is a no-op and the merge falls back to the
/// append + text-dedupe behavior — never guess.
///
/// ## Clocks and sequencing
/// The plan is applied *inside* `TranscriptMerger.mergeAuthoritativeImport`, **after** its clock
/// alignment and **before** its dedupe, so `imported` here is the clock-aligned timeline: when the
/// merger finds a text anchor between the import and captured content, the comparison happens on the
/// captured clock (`clockAnchored: true`). When no anchor exists, raw times are used — a shared clock
/// for captions, because live-caption times are meeting-relative by API contract
/// (`POST /v1/meetings/live/{id}/segments`: "seconds relative to the meeting start") and a Gemini
/// export's section timestamps are likewise meeting-relative, but **not** for `.liveCapture`: a
/// late-join capture is capture-relative (0-based at join time), so its rows would be compared
/// against the import on two different clocks and the wrong rows deleted. So an anchorless merge
/// (`clockAnchored: false`) only drops `.liveCaptions` rows, whose clock the API contract pins to the
/// same origin as the import's; `.liveCapture` rows survive and fall through to text dedupe.
///
/// ## Caption speaker timeline
/// Dropping overlapped `.liveCaptions` rows is deliberate and differs from final re-transcription:
/// `replaceSegments(of:source:)` must preserve the caption speaker timeline because a re-transcribed
/// audio pass has *no* speaker names of its own. A Gemini export carries its **own per-turn speaker
/// names**, so the imported rows replace both the text and the speaker attribution for the runs they
/// cover — nothing the captions provided *there* is lost. Outside those runs the captions are the
/// only record of what was said, which is why the policy is run-scoped and not hull-scoped.
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

    /// How far two imported segments may sit apart and still count as one continuous covered run.
    /// Sized to bridge the pauses inside a conversation (a beat between turns, a question being
    /// considered) without bridging a stretch the import simply has no content for: at two minutes,
    /// a transcription that skipped a chunk of the meeting leaves a real hole in the coverage, and
    /// the live rows sitting in that hole survive.
    static let runGapTolerance: Double = 120

    /// How much time a single imported turn is believed to *cover*, at most.
    ///
    /// Transcript end times are rarely measured: `TranscriptFileParser` backfills each turn's end
    /// from the next turn's start (Meet-style exports carry no end times at all), so a turn that
    /// happens to precede a long stretch the export skipped is handed an end hours later. Taken
    /// literally, that one turn would "cover" the whole skipped stretch and delete every live row
    /// inside it. Three minutes is well past any single spoken utterance, so capping here costs
    /// nothing on a dense transcript (consecutive turns re-extend the run anyway) and turns the
    /// backfilled tail of a skipped stretch back into the hole it really is.
    static let maxSegmentCoverage: Double = 180

    /// Resolve the overlap policy: drop existing live segments whose midpoint falls inside one of the
    /// import's covered runs. A no-op (everything survives) when the import has no recoverable timing
    /// or the meeting has no droppable live segments inside a run.
    ///
    /// - Parameter clockAnchored: whether `imported` was shifted onto the existing segments' clock by
    ///   a text anchor. When `false` the two timelines are only known to share an origin for
    ///   `.liveCaptions` (meeting-relative by API contract), so `.liveCapture` rows are never dropped.
    static func resolve(
        existing: [TranscriptMerger.Segment],
        imported: [TranscriptMerger.Segment],
        clockAnchored: Bool,
        gapTolerance: Double = runGapTolerance
    ) -> Resolution {
        let runs = coveredRuns(of: imported, gapTolerance: gapTolerance)
        guard !runs.isEmpty else {
            return Resolution(survivingExisting: existing, droppedOverlappedCount: 0)
        }
        var surviving: [TranscriptMerger.Segment] = []
        surviving.reserveCapacity(existing.count)
        var dropped = 0
        for segment in existing {
            let midpoint = (segment.start + segment.end) / 2
            if isDroppable(segment, clockAnchored: clockAnchored),
               runs.contains(where: { $0.contains(midpoint) }) {
                dropped += 1
            } else {
                surviving.append(segment)
            }
        }
        return Resolution(survivingExisting: surviving, droppedOverlappedCount: dropped)
    }

    /// Whether an existing segment is a candidate for the overlap drop at all — see the clock
    /// discussion above: captions share the import's origin by contract, a capture may not.
    private static func isDroppable(_ segment: TranscriptMerger.Segment, clockAnchored: Bool) -> Bool {
        switch segment.source {
        case .liveCaptions: return true
        case .liveCapture: return clockAnchored
        case .importedAudio, .importedTranscript: return false
        }
    }

    /// The stretches the imported transcript actually covers: its timed segments (each capped at
    /// `maxSegmentCoverage`, see there), sorted and merged across gaps of at most `gapTolerance`.
    /// Empty when the import has no recoverable timing. "Real timing" means at least one segment with
    /// a positive duration or a non-zero start, and an overall span of positive length — an all-zero
    /// (plain-text) import yields no runs, triggering the fallback-to-append path.
    static func coveredRuns(
        of imported: [TranscriptMerger.Segment],
        gapTolerance: Double = runGapTolerance,
        maxCoverage: Double = maxSegmentCoverage
    ) -> [ClosedRange<Double>] {
        let timed = imported
            .filter { $0.end > $0.start || $0.start > 0 }
            .map { (start: $0.start, end: min(max($0.start, $0.end), $0.start + maxCoverage)) }
            .sorted { $0.start < $1.start }
        guard let first = timed.first,
              let hullEnd = timed.map(\.end).max(),
              hullEnd > first.start else { return [] }

        var runs: [ClosedRange<Double>] = []
        var currentStart = first.start
        var currentEnd = first.end
        for segment in timed.dropFirst() {
            if segment.start - currentEnd <= gapTolerance {
                currentEnd = max(currentEnd, segment.end)
            } else {
                runs.append(currentStart...currentEnd)
                currentStart = segment.start
                currentEnd = segment.end
            }
        }
        runs.append(currentStart...currentEnd)
        return runs
    }

    /// The hull of the covered runs — what the import spans end to end, holes included. Kept for
    /// logging and diagnostics; the *policy* runs on `coveredRuns`, never on this.
    static func coveredSpan(of imported: [TranscriptMerger.Segment]) -> ClosedRange<Double>? {
        let runs = coveredRuns(of: imported)
        guard let first = runs.first, let last = runs.last else { return nil }
        return first.lowerBound...last.upperBound
    }
}
