import XCTest
@testable import TypeWhisper

/// Unit tests for the pure lexical retriever (plan M5). Determinism, stop-word handling,
/// tie-breaking, empty-query and relevance ordering.
final class LexicalRetrieverTests: XCTestCase {
    private func doc(_ id: String, _ text: String) -> LexicalRetriever.Document {
        LexicalRetriever.Document(id: id, text: text)
    }

    func testOnTopicDocumentRanksFirst() {
        let documents = [
            doc("cooking", "Recipes for dinner, pasta and salads for the weekend."),
            doc("roadmap", "We discussed the quarterly roadmap and the budget for Acme."),
            doc("hr", "Vacation policy and the holiday calendar for next year.")
        ]
        let results = LexicalRetriever.rank(query: "acme roadmap budget", documents: documents)
        XCTAssertEqual(results.first?.id, "roadmap")
    }

    func testStopWordsAreIgnored() {
        // A document that shares only stop-words with the query must not score.
        let documents = [
            doc("stop", "the and of to in it is a an for"),
            doc("real", "budget forecast for the acme roadmap")
        ]
        let results = LexicalRetriever.rank(query: "the acme and the budget", documents: documents)
        XCTAssertEqual(results.map(\.id), ["real"], "stop-words must not produce a match")
    }

    func testEmptyOrStopWordOnlyQueryReturnsNothing() {
        let documents = [doc("a", "acme roadmap budget")]
        XCTAssertTrue(LexicalRetriever.rank(query: "", documents: documents).isEmpty)
        XCTAssertTrue(LexicalRetriever.rank(query: "   ", documents: documents).isEmpty)
        XCTAssertTrue(LexicalRetriever.rank(query: "the and of", documents: documents).isEmpty)
    }

    func testTiesBreakOnInputOrderDeterministically() {
        // Both documents match the single query term exactly once → equal score. The earlier
        // input wins the tie, and the ordering is identical across repeated calls.
        let documents = [
            doc("first", "acme notes"),
            doc("second", "acme summary")
        ]
        let a = LexicalRetriever.rank(query: "acme", documents: documents)
        let b = LexicalRetriever.rank(query: "acme", documents: documents)
        XCTAssertEqual(a.map(\.id), ["first", "second"])
        XCTAssertEqual(a, b, "ranking must be deterministic")
    }

    func testHigherFrequencyScoresHigher() {
        let documents = [
            doc("once", "acme is mentioned here"),
            doc("thrice", "acme acme acme repeated")
        ]
        let results = LexicalRetriever.rank(query: "acme", documents: documents)
        XCTAssertEqual(results.first?.id, "thrice")
        XCTAssertEqual(results.first?.score, 3)
    }

    func testLimitIsRespected() {
        let documents = (0..<10).map { doc("d\($0)", "acme roadmap") }
        let results = LexicalRetriever.rank(query: "acme roadmap", documents: documents, limit: 3)
        XCTAssertEqual(results.count, 3)
    }

    func testZeroLimitReturnsNothing() {
        let documents = [doc("a", "acme")]
        XCTAssertTrue(LexicalRetriever.rank(query: "acme", documents: documents, limit: 0).isEmpty)
    }

    func testTokenizeDropsSingleCharactersAndStopWords() {
        let tokens = LexicalRetriever.tokenize("The a I roadmap-budget, plan!")
        XCTAssertEqual(tokens, ["roadmap", "budget", "plan"])
    }
}
