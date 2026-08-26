import XCTest
@testable import TypeWhisper

/// Speaker-recognition amendment (M9-SPK-B / D-A6) — the pure, hermetic timing-transfer aligner.
/// Drives `SpeakerTimingAligner` on synthetic token streams: exact overlap, drift, interpolation
/// fallback, the pathological no-overlap case, monotonic order preservation, and reference
/// tokenization/normalization. No audio, no SwiftData.
final class SpeakerTimingAlignerTests: XCTestCase {

    private func live(_ text: String, _ start: Double, _ end: Double, id: UUID = UUID()) -> SpeakerTimingAligner.LiveSegment {
        SpeakerTimingAligner.LiveSegment(id: id, text: text, start: start, end: end)
    }

    private func refTokens(_ segments: [(String, Double, Double)]) -> [SpeakerTimingAligner.ReferenceToken] {
        SpeakerTimingAligner.referenceTokens(from: segments.map { (text: $0.0, start: $0.1, end: $0.2) })
    }

    // MARK: - Exact overlap

    func testExactOverlapTransfersReferenceTimes() {
        let a = UUID(), b = UUID()
        let liveSegs = [live("hello world", 0, 5, id: a), live("foo bar", 5, 10, id: b)]
        let reference = refTokens([("hello world", 0, 2), ("foo bar", 2, 4)])

        let refined = SpeakerTimingAligner.transfer(live: liveSegs, reference: reference)

        XCTAssertEqual(refined.map(\.id), [a, b], "order preserved, none dropped")
        XCTAssertEqual(refined[0].start, 0, accuracy: 1e-9)
        XCTAssertEqual(refined[0].end, 2, accuracy: 1e-9)
        XCTAssertEqual(refined[1].start, 2, accuracy: 1e-9)
        XCTAssertEqual(refined[1].end, 4, accuracy: 1e-9)
    }

    // MARK: - Drift (extra/altered reference words around the matched core)

    func testDriftMatchesCoreTokensDespiteSurroundingNoise() {
        let a = UUID()
        // Reference carries filler ("um", "brown", "yes") the live text does not; the core words still
        // match monotonically, and start/end come from the first/last matched token.
        let reference = refTokens([("um the quick brown fox yes", 0, 6)])
        let refined = SpeakerTimingAligner.transfer(live: [live("the quick fox", 0, 5, id: a)], reference: reference)

        XCTAssertEqual(refined.count, 1)
        XCTAssertEqual(refined[0].start, 1, accuracy: 1e-9, "start = 'the' token start")
        XCTAssertEqual(refined[0].end, 5, accuracy: 1e-9, "end = 'fox' token end")
    }

    // MARK: - Interpolation fallback (unmatched middle segment)

    func testUnmatchedMiddleSegmentInterpolatedBetweenNeighbours() {
        let a = UUID(), b = UUID(), c = UUID()
        let liveSegs = [
            live("alpha", 0, 3, id: a),
            live("zzz", 3, 6, id: b),      // matches nothing in the reference
            live("gamma", 6, 9, id: c)
        ]
        let reference = refTokens([("alpha", 0, 1), ("gamma", 10, 11)])

        let refined = SpeakerTimingAligner.transfer(live: liveSegs, reference: reference)

        XCTAssertEqual(refined.map(\.id), [a, b, c], "never dropped or reordered")
        XCTAssertEqual(refined[0].start, 0, accuracy: 1e-9)
        XCTAssertEqual(refined[0].end, 1, accuracy: 1e-9)
        // The lone unmatched segment fills the whole gap between its resolved neighbours.
        XCTAssertEqual(refined[1].start, 1, accuracy: 1e-9)
        XCTAssertEqual(refined[1].end, 10, accuracy: 1e-9)
        XCTAssertEqual(refined[2].start, 10, accuracy: 1e-9)
        XCTAssertEqual(refined[2].end, 11, accuracy: 1e-9)
        // Monotonic non-decreasing timeline.
        XCTAssertLessThanOrEqual(refined[0].end, refined[1].start + 1e-9)
        XCTAssertLessThanOrEqual(refined[1].end, refined[2].start + 1e-9)
    }

    func testMultipleUnmatchedRunDistributesGapEvenly() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let liveSegs = [
            live("start", 0, 1, id: a),
            live("uno", 1, 2, id: b),   // unmatched
            live("dos", 2, 3, id: c),   // unmatched
            live("end", 3, 4, id: d)
        ]
        let reference = refTokens([("start", 0, 2), ("end", 8, 10)])
        let refined = SpeakerTimingAligner.transfer(live: liveSegs, reference: reference)

        // Gap [2, 8] split evenly across the two unmatched segments → 3s each.
        XCTAssertEqual(refined[1].start, 2, accuracy: 1e-9)
        XCTAssertEqual(refined[1].end, 5, accuracy: 1e-9)
        XCTAssertEqual(refined[2].start, 5, accuracy: 1e-9)
        XCTAssertEqual(refined[2].end, 8, accuracy: 1e-9)
    }

    // MARK: - Pathological no-overlap keeps original times

    func testNoOverlapKeepsOriginalTimes() {
        let a = UUID(), b = UUID()
        let liveSegs = [live("aaa", 0, 3, id: a), live("bbb", 3, 6, id: b)]
        let reference = refTokens([("nope none", 0, 4)])   // nothing matches

        let refined = SpeakerTimingAligner.transfer(live: liveSegs, reference: reference)

        XCTAssertEqual(refined[0].start, 0, accuracy: 1e-9)
        XCTAssertEqual(refined[0].end, 3, accuracy: 1e-9)
        XCTAssertEqual(refined[1].start, 3, accuracy: 1e-9)
        XCTAssertEqual(refined[1].end, 6, accuracy: 1e-9)
    }

    func testEmptyReferenceKeepsOriginalTimes() {
        let a = UUID()
        let refined = SpeakerTimingAligner.transfer(live: [live("hello", 1, 4, id: a)], reference: [])
        XCTAssertEqual(refined, [SpeakerTimingAligner.RefinedTiming(id: a, start: 1, end: 4)])
    }

    // MARK: - Monotonic: repeated identical phrases map to successive occurrences

    func testRepeatedIdenticalTextMapsToSuccessiveReferenceOccurrences() {
        let a = UUID(), b = UUID()
        let liveSegs = [live("yes", 0, 2, id: a), live("yes", 2, 4, id: b)]
        let reference = refTokens([("yes yes", 0, 4)])   // yes[0,2] yes[2,4]

        let refined = SpeakerTimingAligner.transfer(live: liveSegs, reference: reference)

        XCTAssertEqual(refined[0].start, 0, accuracy: 1e-9)
        XCTAssertEqual(refined[0].end, 2, accuracy: 1e-9)
        XCTAssertEqual(refined[1].start, 2, accuracy: 1e-9, "the second 'yes' maps forward, not back to the first")
        XCTAssertEqual(refined[1].end, 4, accuracy: 1e-9)
    }

    // MARK: - Boundary runs (only one anchor) preserve duration and order

    func testUnmatchedRunAtStartAnchorsToFollowingSegment() {
        let a = UUID(), b = UUID()
        let liveSegs = [live("zzz", 0, 2, id: a), live("hello", 2, 5, id: b)]
        let reference = refTokens([("hello", 10, 11)])

        let refined = SpeakerTimingAligner.transfer(live: liveSegs, reference: reference)

        XCTAssertEqual(refined[1].start, 10, accuracy: 1e-9)
        XCTAssertEqual(refined[1].end, 11, accuracy: 1e-9)
        // The leading unmatched segment ends at the next anchor, keeping its own 2s duration.
        XCTAssertEqual(refined[0].end, 10, accuracy: 1e-9)
        XCTAssertEqual(refined[0].start, 8, accuracy: 1e-9)
    }

    func testUnmatchedRunAtEndAnchorsToPrecedingSegment() {
        let a = UUID(), b = UUID()
        let liveSegs = [live("hello", 0, 3, id: a), live("zzz", 3, 4, id: b)]
        let reference = refTokens([("hello", 5, 6)])

        let refined = SpeakerTimingAligner.transfer(live: liveSegs, reference: reference)

        XCTAssertEqual(refined[0].start, 5, accuracy: 1e-9)
        XCTAssertEqual(refined[0].end, 6, accuracy: 1e-9)
        // The trailing unmatched segment starts at the previous anchor's end, keeping its 1s duration.
        XCTAssertEqual(refined[1].start, 6, accuracy: 1e-9)
        XCTAssertEqual(refined[1].end, 7, accuracy: 1e-9)
    }

    // MARK: - Leading unmatched run clamps at 0 (never persists a negative start, M9-SPK-B minor)

    func testLeadingUnmatchedRunClampsNegativeStartToZero() {
        let a = UUID(), b = UUID()
        // The leading unmatched segment is 12s long but the following anchor starts at only 10s, so a
        // naive backward layout would place it at [-2, 10]. It must clamp to a non-negative start.
        let liveSegs = [live("zzz", 0, 12, id: a), live("hello", 12, 15, id: b)]
        let reference = refTokens([("hello", 10, 11)])

        let refined = SpeakerTimingAligner.transfer(live: liveSegs, reference: reference)

        XCTAssertEqual(refined[1].start, 10, accuracy: 1e-9)
        XCTAssertEqual(refined[1].end, 11, accuracy: 1e-9)
        XCTAssertEqual(refined[0].start, 0, accuracy: 1e-9, "clamped: never a negative start")
        XCTAssertEqual(refined[0].end, 10, accuracy: 1e-9)
        // No refined segment ever carries a negative time.
        XCTAssertTrue(refined.allSatisfy { $0.start >= 0 && $0.end >= $0.start }, "non-negative and ordered")
    }

    func testMultipleLeadingUnmatchedOverflowStayNonNegativeAndOrdered() {
        let a = UUID(), b = UUID(), c = UUID()
        // Two 8s leading segments overflow a 10s anchor: the later one lands at [2,10], the earlier one
        // clamps to [0,2] rather than [-6,2].
        let liveSegs = [live("uno", 0, 8, id: a), live("dos", 8, 16, id: b), live("hello", 16, 19, id: c)]
        let reference = refTokens([("hello", 10, 11)])

        let refined = SpeakerTimingAligner.transfer(live: liveSegs, reference: reference)

        XCTAssertEqual(refined.map(\.id), [a, b, c], "order preserved")
        XCTAssertEqual(refined[0].start, 0, accuracy: 1e-9)
        XCTAssertEqual(refined[1].end, 10, accuracy: 1e-9)
        XCTAssertEqual(refined[2].start, 10, accuracy: 1e-9)
        XCTAssertTrue(refined.allSatisfy { $0.start >= 0 && $0.end >= $0.start }, "all non-negative, monotone")
        // Monotonic non-decreasing across the run.
        XCTAssertLessThanOrEqual(refined[0].end, refined[1].start + 1e-9)
        XCTAssertLessThanOrEqual(refined[1].end, refined[2].start + 1e-9)
    }

    // MARK: - Reference tokenization & normalization

    func testReferenceTokensInterpolatePerWordAndNormalize() {
        let tokens = SpeakerTimingAligner.referenceTokens(from: [(text: "Hello, WORLD!", start: 0, end: 2)])
        XCTAssertEqual(tokens.map(\.text), ["hello", "world"], "lowercased, punctuation stripped")
        XCTAssertEqual(tokens[0].start, 0, accuracy: 1e-9)
        XCTAssertEqual(tokens[0].end, 1, accuracy: 1e-9)
        XCTAssertEqual(tokens[1].start, 1, accuracy: 1e-9)
        XCTAssertEqual(tokens[1].end, 2, accuracy: 1e-9)
    }

    func testTokenizeKeepsContractionAsOneToken() {
        XCTAssertEqual(SpeakerTimingAligner.tokenize("Don't stop!"), ["dont", "stop"])
    }

    func testEmptyLiveReturnsEmpty() {
        XCTAssertTrue(SpeakerTimingAligner.transfer(live: [], reference: refTokens([("x", 0, 1)])).isEmpty)
    }
}
