import Foundation

/// Pure, deterministic merge of an imported transcript into an existing meeting's segments
/// (plan D12). Captured content is authoritative and is **never dropped**; imported segments that
/// merely restate already-captured content are omitted so the overlap region is not duplicated
/// (plan reminder 3 — a user who joined late imports the full transcript). Non-overlapping imported
/// segments (e.g. the pre-capture gap for a late joiner) are kept and time-ordered into place.
///
/// ## Two clocks
/// Captured segments are **capture-session-relative** (0-based; `MeetingCaptureService` offsets only
/// by `sessionTimeOffset` across *restarted* sessions on the same meeting, never by the join time),
/// while an imported Meet transcript is **meeting-relative**. For a late joiner these two clocks are
/// different, so raw time overlap is **not** proof of duplication: imported pre-capture segments at
/// meeting times `0..T` numerically overlap captured segments at capture times `0..T'` while
/// containing entirely new content. The merge therefore:
///
///  1. **Estimates the clock offset** by anchoring on the best fuzzy text match between an imported
///     and a captured segment (both must carry a real duration). The offset (`captured.start -
///     imported.start`) shifts the whole imported timeline onto the captured clock *before* both
///     dedup and ordering, so the merged transcript is chronological on a single clock. When no
///     anchor is found the two transcripts share no overlapping content, so the imported timeline is
///     left as-is and ordering falls back to the supplied timestamps.
///  2. **Dedups pairwise, with corroboration.** An imported segment is dropped only when it matches a
///     *specific* captured segment — never against a global bag of all captured tokens (which would
///     wrongly drop short/generic imported lines whose few words appear *somewhere* in a long
///     transcript). A time overlap counts as a duplicate only if that same captured segment also
///     shares enough content tokens (corroboration); where timestamps are missing/coarse (plain-text
///     imports are all-zero), a strong pairwise text match alone marks a duplicate. Very short
///     imported segments are kept unless empty, so no content is lost on a coincidental match.
///
/// Both sources keep their `source` tag so each stays individually inspectable in the UI.
enum TranscriptMerger {
    /// A neutral value segment the merger operates on (no SwiftData references, so it is unit-
    /// testable in isolation). The service maps `MeetingSegment`/`TranscriptionSegment` into it.
    struct Segment: Equatable, Sendable {
        var text: String
        var start: Double
        var end: Double
        var speakerLabel: String?
        var speakerConfidence: Double?
        var source: MeetingSegmentSource

        init(
            text: String,
            start: Double,
            end: Double,
            speakerLabel: String? = nil,
            speakerConfidence: Double? = nil,
            source: MeetingSegmentSource
        ) {
            self.text = text
            self.start = start
            self.end = end
            self.speakerLabel = speakerLabel
            self.speakerConfidence = speakerConfidence
            self.source = source
        }
    }

    /// Merge `imported` into `existing`, returning the time-ordered, deduped union.
    ///
    /// - `overlapThreshold`: fraction (0–1) of the shorter segment that must overlap in time (after
    ///   clock alignment) for a pair to be a *time* candidate.
    /// - `textThreshold`: fraction (0–1) of an imported segment's content words that must appear in a
    ///   single captured segment to count as a *text-only* duplicate (no time corroboration).
    /// - `corroborationThreshold`: fraction (0–1) of content-word overlap required alongside a time
    ///   overlap before the pair is treated as a duplicate. Guards the blocking failure mode where a
    ///   different-clock imported segment numerically overlaps captured audio.
    /// - `anchorThreshold`: minimum fuzzy text similarity between an imported and a captured segment
    ///   (both with real durations) to accept them as the clock-offset anchor.
    /// - `minContentTokens`: an imported segment with fewer content tokens than this is never dropped
    ///   as a duplicate (too little signal to be sure), and is never used as an anchor.
    static func merge(
        existing: [Segment],
        imported: [Segment],
        overlapThreshold: Double = 0.5,
        textThreshold: Double = 0.8,
        corroborationThreshold: Double = 0.5,
        anchorThreshold: Double = 0.6,
        minContentTokens: Int = 2
    ) -> [Segment] {
        guard !imported.isEmpty else { return stableSortByStart(existing) }
        guard !existing.isEmpty else { return stableSortByStart(imported) }

        // Precompute content-token sets once (M8 review 2): both `estimateClockOffset` and
        // `isDuplicate` previously retokenized every existing segment inside their inner loops
        // (O(n·m) — a 2h×2h merge froze the UI). Tokenize each segment exactly once here and pass
        // the sets down. Existing sets are index-aligned with `existing`; imported arrays/sets are
        // index-aligned with `imported` (and therefore with `aligned`, which only shifts times).
        let existingTokenSets = existing.map { Set(contentTokens($0.text)) }
        let importedTokenArrays = imported.map { contentTokens($0.text) }
        let importedTokenSets = importedTokenArrays.map { Set($0) }

        // 1) Align clocks: shift the imported timeline onto the captured clock when an anchor exists.
        let offset = estimateClockOffset(
            existing: existing,
            existingTokenSets: existingTokenSets,
            imported: imported,
            importedTokenSets: importedTokenSets,
            anchorThreshold: anchorThreshold,
            minContentTokens: minContentTokens
        )
        let aligned: [Segment]
        if let offset, offset != 0 {
            aligned = imported.map {
                var shifted = $0
                shifted.start += offset
                shifted.end += offset
                return shifted
            }
        } else {
            aligned = imported
        }

        // 2) Pairwise, corroborated dedup against the captured segments.
        var kept: [Segment] = []
        kept.reserveCapacity(aligned.count)
        for (index, candidate) in aligned.enumerated() {
            if isDuplicate(
                candidate,
                candidateTokens: importedTokenArrays[index],
                existing: existing,
                existingTokenSets: existingTokenSets,
                overlapThreshold: overlapThreshold,
                textThreshold: textThreshold,
                corroborationThreshold: corroborationThreshold,
                minContentTokens: minContentTokens
            ) {
                continue
            }
            kept.append(candidate)
        }

        let combined = stableSortByStart(existing + kept)

        // 3) Clock-alignment can map imported segments to negative times (M8 review 1): a late joiner
        // captures a 0-based clock while importing a meeting-relative transcript, so the estimated
        // offset is negative and the pre-capture gap lands at negative starts. Every timestamp
        // formatter clamps to 0, which would collapse the whole imported first half to 00:00. Shift
        // the merged set uniformly so its minimum start is 0, preserving relative timing and order.
        let minStart = combined.map(\.start).min() ?? 0
        let shift = -min(0, minStart)
        guard shift != 0 else { return combined }
        return combined.map {
            var lifted = $0
            lifted.start += shift
            lifted.end += shift
            return lifted
        }
    }

    // MARK: - Clock alignment

    /// Estimate the offset that maps the imported timeline onto the captured clock by anchoring on
    /// the best fuzzy text match between an imported and a captured segment (both with real
    /// durations). Returns `nil` when the two transcripts share no sufficiently-similar segment — in
    /// that case there is no overlap to align and the supplied timestamps are used as-is.
    private static func estimateClockOffset(
        existing: [Segment],
        existingTokenSets: [Set<String>],
        imported: [Segment],
        importedTokenSets: [Set<String>],
        anchorThreshold: Double,
        minContentTokens: Int
    ) -> Double? {
        var best: (similarity: Double, offset: Double, capturedStart: Double, importedStart: Double)?
        for (candidateIndex, candidate) in imported.enumerated() where candidate.end > candidate.start {
            let candidateTokens = importedTokenSets[candidateIndex]
            guard candidateTokens.count >= minContentTokens else { continue }
            for (otherIndex, other) in existing.enumerated() where other.end > other.start {
                let otherTokens = existingTokenSets[otherIndex]
                guard otherTokens.count >= minContentTokens else { continue }
                let intersection = candidateTokens.intersection(otherTokens).count
                guard intersection > 0 else { continue }
                // Containment of the smaller token set — robust to segmentation differences.
                let similarity = Double(intersection) / Double(min(candidateTokens.count, otherTokens.count))
                guard similarity >= anchorThreshold else { continue }

                let offset = other.start - candidate.start
                if let current = best {
                    let better = similarity > current.similarity
                        || (similarity == current.similarity && other.start < current.capturedStart)
                        || (similarity == current.similarity && other.start == current.capturedStart
                            && candidate.start < current.importedStart)
                    if better {
                        best = (similarity, offset, other.start, candidate.start)
                    }
                } else {
                    best = (similarity, offset, other.start, candidate.start)
                }
            }
        }
        return best?.offset
    }

    // MARK: - Dedup

    /// A candidate is a duplicate of the captured transcript when either (a) it overlaps captured
    /// audio in time **and** most of its content tokens appear across the *union* of all captured
    /// segments it overlaps (corroboration), or (b) — absent a usable time overlap — most of its
    /// content tokens appear in a single captured segment. The union in (a) is the M8 review 3 fix:
    /// one long imported turn (e.g. a Meet utterance) can time-overlap 3+ short captured segments,
    /// each restating only a fraction of it, so per-segment corroboration stays below threshold and
    /// the turn escapes dedup — duplicating the overlap region. Corroborating against the union of
    /// all time-overlapping captured segments catches it. The text-only path (b) stays pairwise so a
    /// short generic line is never dropped because its few words are scattered across the transcript.
    private static func isDuplicate(
        _ candidate: Segment,
        candidateTokens: [String],
        existing: [Segment],
        existingTokenSets: [Set<String>],
        overlapThreshold: Double,
        textThreshold: Double,
        corroborationThreshold: Double,
        minContentTokens: Int
    ) -> Bool {
        let tokens = candidateTokens
        // Nothing meaningful to add (empty/stop-words only) → treat as a duplicate.
        guard !tokens.isEmpty else { return true }
        // Too little signal to safely call a duplicate → keep (never lose content on a chance match).
        guard tokens.count >= minContentTokens else { return false }

        var overlappingUnion = Set<String>()
        var hasTimeOverlap = false
        for (index, other) in existing.enumerated() {
            let otherTokens = existingTokenSets[index]
            guard !otherTokens.isEmpty else { continue }

            let overlapFraction = timeOverlapFraction(candidate, other)
            if overlapFraction >= overlapThreshold {
                // Accumulate every time-overlapping captured segment's tokens; corroborate once,
                // below, against their union (locality-aware but robust to segmentation mismatch).
                hasTimeOverlap = true
                overlappingUnion.formUnion(otherTokens)
            } else {
                // No usable time overlap with this segment: a strong pairwise text match alone marks
                // a duplicate (covers all-zero-timestamp plain-text imports).
                let present = tokens.filter { otherTokens.contains($0) }.count
                let textRatio = Double(present) / Double(tokens.count)
                if textRatio >= textThreshold { return true }
            }
        }

        if hasTimeOverlap {
            // Time overlap alone is not proof (two clocks); require content corroboration against
            // the union of all captured segments the candidate overlaps.
            let present = tokens.filter { overlappingUnion.contains($0) }.count
            let textRatio = Double(present) / Double(tokens.count)
            if textRatio >= corroborationThreshold { return true }
        }
        return false
    }

    /// Fraction (0–1) of the shorter segment that overlaps the other in time; 0 when either lacks a
    /// real duration or they do not overlap.
    private static func timeOverlapFraction(_ a: Segment, _ b: Segment) -> Double {
        guard a.end > a.start, b.end > b.start else { return 0 }
        let overlap = min(a.end, b.end) - max(a.start, b.start)
        guard overlap > 0 else { return 0 }
        let shorter = max(min(a.end - a.start, b.end - b.start), 0.0001)
        return overlap / shorter
    }

    // MARK: - Ordering

    /// Sort by start time, breaking ties by preserving input order (existing before imported, and
    /// original order within each). Swift's sort is not stable, so an explicit index key is used —
    /// this is what keeps all-zero-timestamp imports deterministic (plan reminder 4).
    private static func stableSortByStart(_ segments: [Segment]) -> [Segment] {
        segments.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.start != rhs.element.start {
                    return lhs.element.start < rhs.element.start
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    // MARK: - Text normalization

    private static let stopWords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "is", "are", "was", "were", "be", "been",
        "to", "of", "in", "on", "for", "with", "at", "by", "it", "this", "that", "as",
        "i", "you", "he", "she", "we", "they", "so", "do", "did", "does", "have", "has"
    ]

    /// Lowercased content words (letters/digits only), stop-words and single characters removed.
    private static func contentTokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 && !stopWords.contains($0) }
    }
}
