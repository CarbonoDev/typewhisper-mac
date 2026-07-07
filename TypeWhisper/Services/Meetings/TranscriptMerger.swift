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

        // 1) Align clocks: shift the imported timeline onto the captured clock when an anchor exists.
        let offset = estimateClockOffset(
            existing: existing,
            imported: imported,
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
        for candidate in aligned {
            if isDuplicate(
                candidate,
                existing: existing,
                overlapThreshold: overlapThreshold,
                textThreshold: textThreshold,
                corroborationThreshold: corroborationThreshold,
                minContentTokens: minContentTokens
            ) {
                continue
            }
            kept.append(candidate)
        }

        return stableSortByStart(existing + kept)
    }

    // MARK: - Clock alignment

    /// Estimate the offset that maps the imported timeline onto the captured clock by anchoring on
    /// the best fuzzy text match between an imported and a captured segment (both with real
    /// durations). Returns `nil` when the two transcripts share no sufficiently-similar segment — in
    /// that case there is no overlap to align and the supplied timestamps are used as-is.
    private static func estimateClockOffset(
        existing: [Segment],
        imported: [Segment],
        anchorThreshold: Double,
        minContentTokens: Int
    ) -> Double? {
        var best: (similarity: Double, offset: Double, capturedStart: Double, importedStart: Double)?
        for candidate in imported where candidate.end > candidate.start {
            let candidateTokens = Set(contentTokens(candidate.text))
            guard candidateTokens.count >= minContentTokens else { continue }
            for other in existing where other.end > other.start {
                let otherTokens = Set(contentTokens(other.text))
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

    /// A candidate is a duplicate of some captured segment when either (a) it overlaps that segment
    /// in time **and** shares enough content tokens with it (corroboration), or (b) — absent a usable
    /// time overlap — most of its content tokens appear in that single captured segment. Comparison
    /// is pairwise (locality-aware), never against a whole-transcript token bag.
    private static func isDuplicate(
        _ candidate: Segment,
        existing: [Segment],
        overlapThreshold: Double,
        textThreshold: Double,
        corroborationThreshold: Double,
        minContentTokens: Int
    ) -> Bool {
        let tokens = contentTokens(candidate.text)
        // Nothing meaningful to add (empty/stop-words only) → treat as a duplicate.
        guard !tokens.isEmpty else { return true }
        // Too little signal to safely call a duplicate → keep (never lose content on a chance match).
        guard tokens.count >= minContentTokens else { return false }

        for other in existing {
            let otherTokens = Set(contentTokens(other.text))
            guard !otherTokens.isEmpty else { continue }
            let present = tokens.filter { otherTokens.contains($0) }.count
            let textRatio = Double(present) / Double(tokens.count)

            let overlapFraction = timeOverlapFraction(candidate, other)
            if overlapFraction >= overlapThreshold {
                // Time overlap alone is not proof (two clocks); require content corroboration.
                if textRatio >= corroborationThreshold { return true }
            } else if textRatio >= textThreshold {
                // No usable time overlap: a strong pairwise text match marks a duplicate.
                return true
            }
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
