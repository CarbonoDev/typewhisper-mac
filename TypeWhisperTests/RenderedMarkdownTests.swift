import XCTest
@testable import TypeWhisper

/// [Perf Phase 2] `RenderedMarkdown` must render exactly what the per-body path did: the
/// `MarkdownBlock.parse` split with each inline span through `MarkdownBlock.inlineAttributed`.
final class RenderedMarkdownTests: XCTestCase {
    private let sample = """
    # Summary
    Intro with **bold** and *italic*.

    ## Action items
    - Ship the `cache` (Ana)
    - Write tests

    1. First
    2. Second

    | Who | What |
    |-----|------|
    | Ana | **Review** |
    """

    func testBlocksMatchTheUncachedPath() {
        let rendered = RenderedMarkdown(markdown: sample)
        let source = MarkdownBlock.parse(sample)
        XCTAssertEqual(rendered.blocks.count, source.count)

        let inline = MarkdownBlock.inlineAttributed
        for (block, original) in zip(rendered.blocks, source) {
            switch (block, original) {
            case let (.heading(level, text), .heading(sourceLevel, sourceText)):
                XCTAssertEqual(level, sourceLevel)
                XCTAssertEqual(text, inline(sourceText))
            case let (.paragraph(text), .paragraph(sourceText)):
                XCTAssertEqual(text, inline(sourceText))
            case let (.bullet(items), .bullet(sourceItems)):
                XCTAssertEqual(items, sourceItems.map(inline))
            case let (.ordered(items), .ordered(sourceItems)):
                XCTAssertEqual(items, sourceItems.map(inline))
            case let (.table(header, rows), .table(sourceHeader, sourceRows)):
                XCTAssertEqual(header, sourceHeader.map(inline))
                XCTAssertEqual(rows, sourceRows.map { $0.map(inline) })
            default:
                XCTFail("block kind mismatch: \(block) vs \(original)")
            }
        }
    }

    func testInlineEmphasisIsPreRendered() {
        let rendered = RenderedMarkdown(markdown: "Plain **bold** text")
        guard case let .paragraph(text) = rendered.blocks.first else {
            return XCTFail("expected a paragraph")
        }
        XCTAssertEqual(String(text.characters), "Plain bold text")
    }

    func testEmptyMarkdownRendersNothing() {
        XCTAssertEqual(RenderedMarkdown(markdown: ""), .empty)
    }
}
