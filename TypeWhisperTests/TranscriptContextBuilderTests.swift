import XCTest
@testable import TypeWhisper

@MainActor
final class TranscriptContextBuilderTests: XCTestCase {
    // MARK: - Chunking

    func testShortTranscriptIsASingleChunkPreservingText() {
        let text = "This is a short transcript that fits comfortably."
        let chunks = TranscriptContextBuilder.chunk(text, charBudget: 16_000)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks.first, text)
    }

    func testChunkerRespectsBudgetAndNeverSplitsWords() {
        // 300 words, each padded so the whole thing far exceeds the tiny budget.
        let words = (0..<300).map { "word\($0)verylong" }
        let text = words.joined(separator: " ")
        let budget = 120
        let chunks = TranscriptContextBuilder.chunk(text, charBudget: budget)

        XCTAssertGreaterThan(chunks.count, 1)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.count, budget, "chunk exceeded budget: \(chunk.count)")
        }
        // Every original word survives intact (never split mid-word) and order is preserved.
        let recombined = chunks.joined(separator: " ").split(separator: " ").map(String.init)
        XCTAssertEqual(recombined, words)
    }

    func testWordLongerThanBudgetIsEmittedWholeNotTruncated() {
        let giant = String(repeating: "a", count: 200)
        let chunks = TranscriptContextBuilder.chunk("small \(giant) tail", charBudget: 50)
        XCTAssertTrue(chunks.contains(giant), "an over-budget word must survive whole")
    }

    func testTwoHourScaleTranscriptYieldsBoundedMapCount() {
        // ~2h of speech ≈ ~18k words. Rendered as one big transcript, chunked at the default
        // budget, the map count must stay small and bounded (not one-chunk-per-segment).
        let sentence = "We discussed the quarterly roadmap and agreed on the next milestone. "
        let transcript = String(repeating: sentence, count: 1_500) // ~100k chars
        let chunks = TranscriptContextBuilder.chunk(transcript)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertLessThan(chunks.count, 50, "map count should be bounded, got \(chunks.count)")
    }

    func testEmptyTranscriptYieldsNoChunks() {
        XCTAssertTrue(TranscriptContextBuilder.chunk("   \n  ").isEmpty)
    }

    // MARK: - Rendering

    func testRenderTranscriptOrdersByStartAndAppliesSpeaker() {
        let segments = [
            TranscriptContextBuilder.Segment(start: 5, text: "Second."),
            TranscriptContextBuilder.Segment(start: 0, text: "First.", speaker: "Marco"),
            TranscriptContextBuilder.Segment(start: 10, text: "Third.")
        ]
        let rendered = TranscriptContextBuilder.renderTranscript(segments)
        XCTAssertEqual(rendered, "Marco: First.\nSecond.\nThird.")
    }

    func testRenderNotesTimestampsWhenOffsetKnown() {
        let notes = [
            TranscriptContextBuilder.Note(offset: 65, text: "Follow up."),
            TranscriptContextBuilder.Note(offset: nil, text: "No offset.")
        ]
        let rendered = TranscriptContextBuilder.renderNotes(notes)
        XCTAssertEqual(rendered, "[01:05] Follow up.\nNo offset.")
    }

    // MARK: - Assembly (notes toggle)

    func testAssembleAppendsNotesBlockWhenPresent() {
        let assembled = TranscriptContextBuilder.assemble(transcript: "Transcript body.", notes: "A note.")
        XCTAssertTrue(assembled.hasPrefix("Transcript body."))
        XCTAssertTrue(assembled.contains("A note."))
    }

    func testAssembleOmitsNotesBlockWhenEmpty() {
        let assembled = TranscriptContextBuilder.assemble(transcript: "Transcript body.", notes: "")
        XCTAssertEqual(assembled, "Transcript body.")
    }

    // MARK: - Bounded reduce input (M4 review finding 3)

    func testBoundedAssembleEqualsPlainAssembleWhenWithinBudget() {
        let bounded = TranscriptContextBuilder.boundedAssemble(
            transcript: "Body.", notes: "Note.", charBudget: 16_000
        )
        XCTAssertEqual(bounded, TranscriptContextBuilder.assemble(transcript: "Body.", notes: "Note."))
    }

    func testBoundedAssembleTruncatesOversizeReduceInputToBudget() {
        // Joined partial summaries that overflow the budget (the exact case the map/reduce reduce
        // step can hit once there are enough chunks).
        let partials = (0..<200)
            .map { "Partial summary number \($0) covering the meeting discussion in detail." }
            .joined(separator: "\n\n")
        let budget = 500
        let bounded = TranscriptContextBuilder.boundedAssemble(
            transcript: partials, notes: "A NOTE_MARKER here.", charBudget: budget
        )
        XCTAssertLessThanOrEqual(bounded.count, budget, "the reduce input must be bounded to the budget")
        // Higher-signal notes survive the transcript truncation.
        XCTAssertTrue(bounded.contains("A NOTE_MARKER here."))
    }

    func testBoundedAssembleTruncatesOversizedNotesToStayWithinBudget() {
        // Notes larger than the budget must not be emitted whole — previously the preserved notes
        // block blew the guarantee (M5-carried review finding 3). The notes block is capped at
        // ~half the budget and the total stays bounded.
        let transcript = String(repeating: "word ", count: 2_000)
        let notes = String(repeating: "NOTE_WORD ", count: 2_000)
        let budget = 400
        let bounded = TranscriptContextBuilder.boundedAssemble(
            transcript: transcript, notes: notes, charBudget: budget
        )
        XCTAssertLessThanOrEqual(bounded.count, budget, "oversized notes must not break the budget guarantee")
        // Some notes content still survives (the notes block was truncated, not dropped).
        XCTAssertTrue(bounded.contains("NOTE_WORD"))
    }

    func testBoundedAssembleWithoutNotesStaysWithinBudget() {
        let partials = String(repeating: "word ", count: 5_000)
        let budget = 400
        let bounded = TranscriptContextBuilder.boundedAssemble(
            transcript: partials, notes: "", charBudget: budget
        )
        XCTAssertLessThanOrEqual(bounded.count, budget)
    }

    func testTruncateWordsNeverSplitsAWord() {
        let text = "alpha beta gamma delta"
        let truncated = TranscriptContextBuilder.truncateWords(text, to: 12)
        XCTAssertLessThanOrEqual(truncated.count, 12)
        XCTAssertTrue(text.hasPrefix(truncated))
        XCTAssertEqual(truncated, "alpha beta")
    }
}
