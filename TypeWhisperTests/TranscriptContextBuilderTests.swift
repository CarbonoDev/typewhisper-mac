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
}
