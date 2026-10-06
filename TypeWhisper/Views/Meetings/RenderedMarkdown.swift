import Foundation

/// [Perf Phase 2] Markdown pre-rendered for `MarkdownDocumentView`: the `MarkdownBlock` split plus
/// every inline `AttributedString(markdown:)`, built once per source string. A body pass only reads
/// these values — the block parse and the per-block inline parse used to rerun on every SwiftUI body
/// evaluation of every view above the document.
///
/// Pure value type; building it touches no actor-isolated state, so callers may build it anywhere.
struct RenderedMarkdown: Equatable, Sendable {
    enum Block: Equatable, Sendable {
        case heading(level: Int, text: AttributedString)
        case paragraph(AttributedString)
        case bullet(items: [AttributedString])
        case ordered(items: [AttributedString])
        case table(header: [AttributedString], rows: [[AttributedString]])
    }

    let blocks: [Block]

    static let empty = RenderedMarkdown(blocks: [])

    init(blocks: [Block]) {
        self.blocks = blocks
    }

    init(markdown: String) {
        self.blocks = MarkdownBlock.parse(markdown).map(Self.render)
    }

    private static func render(_ block: MarkdownBlock) -> Block {
        let inline = MarkdownBlock.inlineAttributed
        switch block {
        case let .heading(level, text):
            return .heading(level: level, text: inline(text))
        case let .paragraph(text):
            return .paragraph(inline(text))
        case let .bullet(items):
            return .bullet(items: items.map(inline))
        case let .ordered(items):
            return .ordered(items: items.map(inline))
        case let .table(header, rows):
            return .table(header: header.map(inline), rows: rows.map { $0.map(inline) })
        }
    }
}
