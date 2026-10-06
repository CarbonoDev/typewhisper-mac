import Foundation

/// [Perf Phase 2] A meeting output parsed and pre-rendered for display: the outcome / agenda
/// extraction (`MeetingOutputParser`) plus the article's `RenderedMarkdown`. Built once per output
/// content by `RenderedOutputCache`; bodies only read it.
struct RenderedOutput: Equatable, Sendable {
    /// How the document presents the output — each mode is a different extraction of the same
    /// markdown, so it is part of the cache key.
    enum Mode: Hashable, Sendable {
        /// Summary / extended: action items and decisions lift out into cards; the article is the
        /// stripped remainder.
        case outcomes
        /// The brief: suggested talking points lift out as a tick-off agenda.
        case agenda
        /// Rendered untouched (the brief tab of a completed meeting's document).
        case verbatim
    }

    /// Extracted outcomes — `.outcomes` mode only, `nil` otherwise.
    let outcomes: MeetingOutputParser.ExtractedOutcomes?
    /// Extracted talking points — `.agenda` mode only, empty otherwise.
    let agendaItems: [MeetingOutputParser.ActionItem]
    /// The article body: the stripped markdown (or the source verbatim), pre-rendered.
    let article: RenderedMarkdown

    /// Pure build — the same parse the views used to run inline on every body pass.
    static func build(markdown: String, mode: Mode) -> RenderedOutput {
        switch mode {
        case .outcomes:
            let outcomes = MeetingOutputParser.parse(markdown: markdown)
            return RenderedOutput(
                outcomes: outcomes,
                agendaItems: [],
                article: RenderedMarkdown(markdown: outcomes.strippedMarkdown)
            )
        case .agenda:
            let agenda = MeetingOutputParser.parseAgenda(markdown: markdown)
            return RenderedOutput(
                outcomes: nil,
                agendaItems: agenda.items,
                article: RenderedMarkdown(markdown: agenda.strippedMarkdown)
            )
        case .verbatim:
            return RenderedOutput(outcomes: nil, agendaItems: [], article: RenderedMarkdown(markdown: markdown))
        }
    }
}

/// [Perf Phase 2] Bounded LRU memo of `RenderedOutput`s, shared by every surface that renders a
/// meeting output (document body, brief page, live agenda).
///
/// Keyed by output id + `createdAt` + content length + mode. `MeetingOutput.content` is never mutated
/// in place — regeneration inserts a new row with a new id, and checklist toggles live in
/// `MeetingChecklistStore`, not the markdown — so the id alone pins the content; `createdAt` and the
/// length are a cheap belt-and-braces guard. The key is computed from values, never from the
/// SwiftData object's identity, because objects re-fault after every save + refetch.
///
/// Not observable: it is filled lazily from `body`, so a write must never invalidate a view.
@MainActor
final class RenderedOutputCache {
    static let shared = RenderedOutputCache()

    struct Key: Hashable {
        let outputID: UUID
        let createdAt: Date
        let contentLength: Int
        let mode: RenderedOutput.Mode
    }

    let capacity: Int
    private var entries: [Key: RenderedOutput] = [:]
    /// Recency order, least recent first.
    private var recency: [Key] = []
    /// Number of builds (cache misses) — observability for tests.
    private(set) var buildCount = 0

    init(capacity: Int = 32) {
        self.capacity = max(1, capacity)
    }

    var count: Int { entries.count }

    func rendered(for output: MeetingOutput, mode: RenderedOutput.Mode) -> RenderedOutput {
        rendered(outputID: output.id, createdAt: output.createdAt, content: output.content, mode: mode)
    }

    func rendered(outputID: UUID, createdAt: Date, content: String, mode: RenderedOutput.Mode) -> RenderedOutput {
        let key = Key(outputID: outputID, createdAt: createdAt, contentLength: content.utf8.count, mode: mode)
        if let hit = entries[key] {
            touch(key)
            return hit
        }
        let built = RenderedOutput.build(markdown: content, mode: mode)
        buildCount += 1
        entries[key] = built
        recency.append(key)
        while recency.count > capacity {
            entries[recency.removeFirst()] = nil
        }
        return built
    }

    private func touch(_ key: Key) {
        guard recency.last != key, let index = recency.firstIndex(of: key) else { return }
        recency.remove(at: index)
        recency.append(key)
    }
}
