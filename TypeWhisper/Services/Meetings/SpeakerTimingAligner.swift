import Foundation

/// Pure, deterministic timing-transfer aligner for the keep-live timing re-pass (speaker-recognition
/// amendment M9-SPK-B / D-A6). Transfers refined per-segment start/end times from a well-timed
/// **reference** transcription onto the **kept** live text — the live text is never changed, only its
/// timings are refined so downstream diarization/overlap assignment keys on real speech times (G7,
/// the owner's "chunking misalignment"), instead of on the coarse batch-boundary spans the live
/// recorder writes.
///
/// The transfer is a single monotonic, greedy token-overlap pass: each live segment is matched, in
/// order, against the forward run of reference tokens whose normalized text equals its own; the
/// segment takes `start` = the first matched reference token's start and `end` = the last matched
/// token's end. Because the reference cursor only ever advances, segment order is preserved and an
/// identical repeated phrase maps to successive reference occurrences (never back to the first). A
/// live segment that matches nothing is never dropped or reordered: its time is interpolated between
/// its resolved neighbours, or — when no neighbour resolved (the pathological no-overlap case) — it
/// keeps its original time.
enum SpeakerTimingAligner {
    /// A kept live transcript segment. Its `text` is authoritative and never changed; only its times
    /// are refined. `id` ties the refined timing back to the stored `MeetingSegment`.
    struct LiveSegment: Equatable, Sendable {
        let id: UUID
        let text: String
        let start: Double
        let end: Double
    }

    /// A single timed token from the reference transcription. Tokens are compared by their normalized
    /// text; their times are the authoritative source the live segments adopt.
    struct ReferenceToken: Equatable, Sendable {
        let text: String
        let start: Double
        let end: Double
    }

    /// The times-only output for one live segment (the caller writes `start`/`end` only, never text).
    struct RefinedTiming: Equatable, Sendable {
        let id: UUID
        let start: Double
        let end: Double
    }

    // MARK: - Transfer

    /// Transfer refined timings from `reference` tokens onto `live` segments (order-preserving,
    /// monotonic). Returns one `RefinedTiming` per live segment, in input order. Never drops, adds, or
    /// reorders a segment.
    static func transfer(live: [LiveSegment], reference: [ReferenceToken]) -> [RefinedTiming] {
        guard !live.isEmpty else { return [] }

        let refNorm = reference.map { normalizedToken($0.text) }

        // Phase 1 — monotonic greedy token match. `nil` = the segment matched nothing (filled in
        // phase 2). The reference cursor only advances, so order is preserved and repeated phrases map
        // to successive occurrences.
        var matched: [(start: Double, end: Double)?] = Array(repeating: nil, count: live.count)
        var cursor = 0
        for (index, segment) in live.enumerated() {
            let tokens = tokenize(segment.text)
            var localCursor = cursor
            var firstStart: Double?
            var lastEnd = 0.0
            for token in tokens {
                var j = localCursor
                while j < refNorm.count && refNorm[j] != token { j += 1 }
                guard j < refNorm.count else { continue }
                if firstStart == nil { firstStart = reference[j].start }
                lastEnd = reference[j].end
                localCursor = j + 1
            }
            if let firstStart {
                matched[index] = (firstStart, max(lastEnd, firstStart))
                cursor = localCursor
            }
        }

        // Phase 2 — emit, filling unmatched runs by interpolation between resolved neighbours (or
        // keeping original times when there is no anchor at all).
        var result: [RefinedTiming] = []
        result.reserveCapacity(live.count)
        var i = 0
        while i < live.count {
            if let m = matched[i] {
                result.append(RefinedTiming(id: live[i].id, start: m.start, end: m.end))
                i += 1
                continue
            }
            // Maximal run of consecutive unmatched segments `[i, k)`. Runs are maximal, so segment
            // `i - 1` (when it exists) is always resolved, and `matched[k]` (when `k < count`) too.
            var k = i
            while k < live.count && matched[k] == nil { k += 1 }
            let prevEnd = i > 0 ? matched[i - 1]?.end : nil
            let nextStart = k < live.count ? matched[k]?.start : nil
            fillRun(live: live, range: i..<k, prevEnd: prevEnd, nextStart: nextStart, into: &result)
            i = k
        }
        return result
    }

    /// Fill an unmatched run `[range]`, appending its timings in forward order.
    private static func fillRun(
        live: [LiveSegment],
        range: Range<Int>,
        prevEnd: Double?,
        nextStart: Double?,
        into result: inout [RefinedTiming]
    ) {
        let count = range.count
        switch (prevEnd, nextStart) {
        case let (prev?, next?) where next > prev:
            // Both anchors and a positive gap → distribute `[prev, next]` evenly, order preserved.
            let slice = (next - prev) / Double(count)
            for (offset, idx) in range.enumerated() {
                let start = prev + Double(offset) * slice
                let end = prev + Double(offset + 1) * slice
                result.append(RefinedTiming(id: live[idx].id, start: start, end: end))
            }

        case let (prev?, _):
            // Only a preceding anchor (or a degenerate/zero-or-negative gap) → lay the segments out
            // after `prev`, preserving each segment's own duration and monotonic order.
            var start = prev
            for idx in range {
                let duration = max(0, live[idx].end - live[idx].start)
                result.append(RefinedTiming(id: live[idx].id, start: start, end: start + duration))
                start += duration
            }

        case let (nil, next?):
            // Only a following anchor (an unmatched run at the very start) → lay the segments out to
            // end at `next`, preserving durations. Build backward, then emit forward.
            var buffer: [RefinedTiming] = []
            var end = next
            for idx in range.reversed() {
                let duration = max(0, live[idx].end - live[idx].start)
                let start = end - duration
                buffer.append(RefinedTiming(id: live[idx].id, start: start, end: end))
                end = start
            }
            result.append(contentsOf: buffer.reversed())

        case (nil, nil):
            // Pathological no-overlap (nothing in the whole transcript resolved) → keep original times.
            for idx in range {
                result.append(RefinedTiming(id: live[idx].id, start: live[idx].start, end: live[idx].end))
            }
        }
    }

    // MARK: - Reference tokenization

    /// Convert reference transcription segments (segment-level timing only, as Whisper-style engines
    /// return) into a flat stream of per-word timed `ReferenceToken`s by linear interpolation across
    /// each segment's span. Empty/whitespace segments contribute nothing.
    static func referenceTokens(from segments: [(text: String, start: Double, end: Double)]) -> [ReferenceToken] {
        var tokens: [ReferenceToken] = []
        for segment in segments {
            let words = tokenize(segment.text)
            guard !words.isEmpty else { continue }
            let span = max(0, segment.end - segment.start)
            let count = words.count
            for (index, word) in words.enumerated() {
                let start = segment.start + span * Double(index) / Double(count)
                let end = segment.start + span * Double(index + 1) / Double(count)
                tokens.append(ReferenceToken(text: word, start: start, end: end))
            }
        }
        return tokens
    }

    // MARK: - Normalization

    /// Split `text` into normalized word tokens: whitespace-delimited, lowercased, with surrounding
    /// punctuation stripped, empties dropped. Whitespace is the word boundary (so `"don't"` stays one
    /// token `"dont"` rather than splitting into `"don"`/`"t"`), keeping live and reference streams
    /// comparable.
    static func tokenize(_ text: String) -> [String] {
        text
            .split(whereSeparator: { $0.isWhitespace })
            .map { normalizedToken(String($0)) }
            .filter { !$0.isEmpty }
    }

    /// Normalize a single token: lowercase and keep only alphanumerics (drops punctuation/symbols).
    static func normalizedToken(_ token: String) -> String {
        String(token.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}
