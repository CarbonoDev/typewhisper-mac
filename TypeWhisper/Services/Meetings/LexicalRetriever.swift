import Foundation

/// Pure, deterministic, offline lexical ranking (plan D7). Ranks candidate documents against a
/// free-text query by term-frequency overlap — no tokenizer model, no embeddings, no network. It
/// backs the pre-meeting brief's vault retrieval (M5) and is reused by in-meeting Q&A (M6).
///
/// The ranking is stable: documents are scored by summed query-term frequency, and ties break on
/// the candidate's original input order so the same query always returns the same ordering.
enum LexicalRetriever {
    /// A rankable candidate: an opaque `id`, its searchable `text`, and its position in the input
    /// (used only as a deterministic tie-breaker).
    struct Document: Sendable {
        let id: String
        let text: String

        init(id: String, text: String) {
            self.id = id
            self.text = text
        }
    }

    /// A scored result. `score` is the summed frequency of query terms in the document; results
    /// with a zero score (no query term present) are never returned.
    struct Result: Sendable, Equatable {
        let id: String
        let score: Int
    }

    /// A conservative English stop-word set. Deliberately small and offline: it removes the highest
    /// frequency function words so ranking is driven by content terms, without pretending to be a
    /// full linguistic stop list.
    static let stopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "but", "by", "for", "from", "has", "have",
        "he", "her", "his", "i", "in", "is", "it", "its", "of", "on", "or", "our", "she", "that",
        "the", "their", "them", "they", "this", "to", "was", "we", "were", "what", "which", "will",
        "with", "you", "your"
    ]

    /// Lowercase, split on non-alphanumeric boundaries, drop stop-words and single characters.
    /// Deterministic and Unicode-lowercasing-only — no stemming.
    static func tokenize(_ text: String) -> [String] {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 && !stopWords.contains($0) }
    }

    /// Rank `documents` by their overlap with `query`, most-relevant first, keeping at most `limit`.
    /// Returns an empty array when the query has no content terms or nothing scores above zero.
    static func rank(query: String, documents: [Document], limit: Int = 5) -> [Result] {
        guard limit > 0 else { return [] }
        let queryTerms = Set(tokenize(query))
        guard !queryTerms.isEmpty else { return [] }

        var scored: [(result: Result, order: Int)] = []
        for (order, document) in documents.enumerated() {
            var score = 0
            for term in tokenize(document.text) where queryTerms.contains(term) {
                score += 1
            }
            if score > 0 {
                scored.append((Result(id: document.id, score: score), order))
            }
        }

        // Higher score first; ties break on original input order (stable, deterministic).
        scored.sort { lhs, rhs in
            if lhs.result.score != rhs.result.score { return lhs.result.score > rhs.result.score }
            return lhs.order < rhs.order
        }
        return scored.prefix(limit).map(\.result)
    }
}
