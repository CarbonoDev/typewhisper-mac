import XCTest
@testable import TypeWhisper

final class TranscriptMergerTests: XCTestCase {

    private func captured(_ text: String, _ start: Double, _ end: Double) -> TranscriptMerger.Segment {
        TranscriptMerger.Segment(text: text, start: start, end: end, source: .liveCapture)
    }

    private func imported(_ text: String, _ start: Double, _ end: Double) -> TranscriptMerger.Segment {
        TranscriptMerger.Segment(text: text, start: start, end: end, source: .importedTranscript)
    }

    // MARK: - Late-join gap fill + timestamp-overlap dedup (shared clock)

    func testLateJoinImportFillsPreCaptureGapAndDedupsOverlapByTimestamp() {
        // Captured only the second half (from t=300). Imported is the full meeting.
        let existing = [
            captured("Second half point one.", 300, 330),
            captured("Second half point two.", 330, 360)
        ]
        let imported = [
            imported("Opening remarks about scope.", 0, 60),
            imported("Early discussion of budget planning.", 60, 120),
            imported("Second half point one.", 300, 330),   // overlaps captured in time
            imported("Second half point two.", 330, 360)    // overlaps captured in time
        ]

        let merged = TranscriptMerger.merge(existing: existing, imported: imported)

        // The two pre-capture imported segments are kept; the two overlapping ones are dropped.
        XCTAssertEqual(merged.count, 4)
        let texts = merged.map(\.text)
        XCTAssertEqual(texts, [
            "Opening remarks about scope.",
            "Early discussion of budget planning.",
            "Second half point one.",
            "Second half point two."
        ])
        // The overlap region resolves to the captured segments (never duplicated).
        let overlapSegments = merged.filter { $0.text.hasPrefix("Second half") }
        XCTAssertEqual(overlapSegments.count, 2)
        XCTAssertTrue(overlapSegments.allSatisfy { $0.source == .liveCapture })
        // The gap-fill imported segments retain their imported source tag.
        let gapFill = merged.prefix(2)
        XCTAssertTrue(gapFill.allSatisfy { $0.source == .importedTranscript })
    }

    // MARK: - Real late-join shape: 0-based captured clock vs meeting-relative import

    /// The flagship M8 scenario with the shape the capture pipeline actually produces: captured
    /// segments are capture-session-relative (0-based, because capture started mid-meeting), while
    /// the imported Meet transcript is meeting-relative. Raw time overlap here is a trap — the
    /// imported pre-capture gap (meeting times 0..T) numerically overlaps the 0-based captured
    /// segments despite being entirely new content. The merger must align the clocks (anchoring on
    /// the shared "Second half…" content), keep the gap, drop the true overlap, and stay chronological.
    func testLateJoinWithZeroBasedCaptureClockKeepsGapAndOrdersCoherently() {
        // Captured only the second half; capture clock is 0-based (join time is NOT added).
        let existing = [
            captured("Second half point one.", 0, 30),
            captured("Second half point two.", 30, 60)
        ]
        // Imported is the full meeting on the meeting clock (the "Second half" is at meeting t=300).
        let imported = [
            imported("Opening remarks about scope.", 0, 60),
            imported("Early discussion of budget planning.", 60, 120),
            imported("Second half point one.", 300, 330),
            imported("Second half point two.", 330, 360)
        ]

        let merged = TranscriptMerger.merge(existing: existing, imported: imported)

        // The pre-capture gap content survives (it is NOT silently dropped as a "time duplicate").
        let texts = merged.map(\.text)
        XCTAssertEqual(texts, [
            "Opening remarks about scope.",
            "Early discussion of budget planning.",
            "Second half point one.",
            "Second half point two."
        ])
        // Ordering is coherent: the two gap-fillers come first, then the captured second half.
        let gapFill = merged.prefix(2)
        XCTAssertTrue(gapFill.allSatisfy { $0.source == .importedTranscript })
        let secondHalf = merged.suffix(2)
        XCTAssertTrue(secondHalf.allSatisfy { $0.text.hasPrefix("Second half") })
        XCTAssertTrue(secondHalf.allSatisfy { $0.source == .liveCapture })
        // The overlap is deduped to the captured source exactly once each — no duplication.
        XCTAssertEqual(merged.filter { $0.text.hasPrefix("Second half") }.count, 2)
        XCTAssertEqual(merged.filter { $0.source == .importedTranscript }.count, 2)
    }

    /// A short, generic imported segment must not be dropped just because its few content words
    /// appear *somewhere* in a long captured transcript (locality-aware, corroborated dedup).
    func testGenericImportedSegmentNotDroppedByGlobalTokenCollision() {
        let existing = [
            captured("Let's move the roadmap discussion to next week.", 0, 5),
            captured("We will move the office next quarter to the new item.", 5, 10),
            captured("The next agenda item is the budget.", 10, 15)
        ]
        // Every content word ("let", "move", "next", "item") appears somewhere above, but no single
        // captured segment restates this line — it is genuinely new and must be kept.
        let imported = [imported("Let's move on to the next item.", 0, 0)]

        let merged = TranscriptMerger.merge(existing: existing, imported: imported)

        XCTAssertEqual(merged.filter { $0.source == .importedTranscript }.count, 1)
        XCTAssertEqual(merged.filter { $0.source == .liveCapture }.count, 3)
    }

    // MARK: - Missing-timestamp overlap deduped via text

    func testMissingTimestampOverlapIsDedupedByText() {
        // Captured has real timing; the imported (plain-text) transcript is all-zero timestamps.
        let existing = [
            captured("We decided to ship the meetings feature next week.", 0, 5),
            captured("Marco will own the schema review.", 5, 9)
        ]
        let imported = [
            // Restates captured content (zero timestamps) → text-duplicate, dropped.
            imported("We decided to ship the meetings feature next week.", 0, 0),
            // Genuinely new content not present in captured → kept.
            imported("A brand new topic about hiring plans emerged afterwards.", 0, 0)
        ]

        let merged = TranscriptMerger.merge(existing: existing, imported: imported)

        let importedKept = merged.filter { $0.source == .importedTranscript }
        XCTAssertEqual(importedKept.count, 1)
        XCTAssertEqual(importedKept.first?.text, "A brand new topic about hiring plans emerged afterwards.")
        // Captured content is never dropped.
        XCTAssertEqual(merged.filter { $0.source == .liveCapture }.count, 2)
    }

    // MARK: - Both sources tagged and captured never lost

    func testCapturedContentNeverLostAndSourcesTagged() {
        let existing = [captured("Captured one.", 10, 15), captured("Captured two.", 15, 20)]
        let imported = [imported("Imported earlier context.", 0, 5)]

        let merged = TranscriptMerger.merge(existing: existing, imported: imported)
        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(merged.filter { $0.source == .liveCapture }.count, 2)
        XCTAssertEqual(merged.filter { $0.source == .importedTranscript }.count, 1)
        XCTAssertEqual(merged.first?.text, "Imported earlier context.")
    }

    // MARK: - Ordering is stable for equal (zero) start times

    func testStableOrderingForAllZeroTimestamps() {
        // All zero timestamps (plain-text import into an empty-timestamp meeting): order must be
        // deterministic — existing before imported, and input order preserved within each.
        let existing = [captured("E1 unique alpha.", 0, 0), captured("E2 unique bravo.", 0, 0)]
        let imported = [
            imported("I1 unique charlie.", 0, 0),
            imported("I2 unique delta.", 0, 0)
        ]

        let merged = TranscriptMerger.merge(existing: existing, imported: imported)
        XCTAssertEqual(merged.map(\.text), [
            "E1 unique alpha.",
            "E2 unique bravo.",
            "I1 unique charlie.",
            "I2 unique delta."
        ])

        // Deterministic across repeated runs.
        for _ in 0..<5 {
            let again = TranscriptMerger.merge(existing: existing, imported: imported)
            XCTAssertEqual(again.map(\.text), merged.map(\.text))
        }
    }

    // MARK: - Time-ordered interleaving

    func testMergeInterleavesByTimestamp() {
        let existing = [captured("Captured at fifty.", 50, 55)]
        let imported = [
            imported("Imported at ten.", 10, 15),
            imported("Imported at ninety.", 90, 95)
        ]
        let merged = TranscriptMerger.merge(existing: existing, imported: imported)
        XCTAssertEqual(merged.map(\.start), [10, 50, 90])
    }

    // MARK: - Empty imported is a no-op (existing returned, ordered)

    func testEmptyImportedReturnsExistingOrdered() {
        let existing = [captured("Later.", 20, 25), captured("Earlier.", 5, 10)]
        let merged = TranscriptMerger.merge(existing: existing, imported: [])
        XCTAssertEqual(merged.map(\.start), [5, 20])
    }
}
