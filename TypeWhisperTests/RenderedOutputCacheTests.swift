import XCTest
@testable import TypeWhisper

/// [Perf Phase 2] `RenderedOutputCache`: same result as the uncached parse, built once per output
/// content, invalidated only by a content change (a regenerated output is a new row), bounded LRU.
@MainActor
final class RenderedOutputCacheTests: XCTestCase {
    private let summary = """
    ## Overview
    We met about the launch.

    ## Action items
    - Ship the build (Ana)
    - Update the docs

    ## Decisions
    - Launch on Monday
    """

    private let brief = """
    ## Context
    Prior meetings covered pricing.

    ## Suggested talking points
    - Pricing tiers
    - Launch date
    """

    // MARK: - Same result as the uncached path

    func testOutcomesModeMatchesInlineParse() {
        let rendered = RenderedOutput.build(markdown: summary, mode: .outcomes)
        let parsed = MeetingOutputParser.parse(markdown: summary)
        XCTAssertEqual(rendered.outcomes, parsed)
        XCTAssertFalse(parsed.actions.isEmpty, "fixture must exercise extraction")
        XCTAssertEqual(rendered.article, RenderedMarkdown(markdown: parsed.strippedMarkdown))
        XCTAssertTrue(rendered.agendaItems.isEmpty)
    }

    func testAgendaModeMatchesInlineParse() {
        let rendered = RenderedOutput.build(markdown: brief, mode: .agenda)
        let parsed = MeetingOutputParser.parseAgenda(markdown: brief)
        XCTAssertFalse(parsed.items.isEmpty, "fixture must exercise extraction")
        XCTAssertEqual(rendered.agendaItems, parsed.items)
        XCTAssertEqual(rendered.article, RenderedMarkdown(markdown: parsed.strippedMarkdown))
        XCTAssertNil(rendered.outcomes)
    }

    func testVerbatimModeRendersTheSourceUntouched() {
        let rendered = RenderedOutput.build(markdown: brief, mode: .verbatim)
        XCTAssertEqual(rendered.article, RenderedMarkdown(markdown: brief))
        XCTAssertNil(rendered.outcomes)
        XCTAssertTrue(rendered.agendaItems.isEmpty)
    }

    // MARK: - Memoization

    func testRepeatedReadsBuildOnce() {
        let cache = RenderedOutputCache()
        let output = MeetingOutput(kind: .summary, content: summary)
        let first = cache.rendered(for: output, mode: .outcomes)
        for _ in 0..<5 {
            XCTAssertEqual(cache.rendered(for: output, mode: .outcomes), first)
        }
        XCTAssertEqual(cache.buildCount, 1)
    }

    func testModesAreCachedSeparately() {
        let cache = RenderedOutputCache()
        let output = MeetingOutput(kind: .brief, content: brief)
        let agenda = cache.rendered(for: output, mode: .agenda)
        let verbatim = cache.rendered(for: output, mode: .verbatim)
        XCTAssertNotEqual(agenda.article, verbatim.article)
        XCTAssertEqual(cache.buildCount, 2)
    }

    func testRegeneratedOutputInvalidates() {
        let cache = RenderedOutputCache()
        let meeting = Meeting(title: "Launch")
        let old = MeetingOutput(kind: .summary, content: summary, meeting: meeting)
        _ = cache.rendered(for: old, mode: .outcomes)

        // Regeneration inserts a new row (new id) with new content.
        let regenerated = MeetingOutput(kind: .summary, content: "## Overview\nShorter.", meeting: meeting)
        let rendered = cache.rendered(for: regenerated, mode: .outcomes)
        XCTAssertEqual(cache.buildCount, 2)
        XCTAssertEqual(rendered.article, RenderedMarkdown(markdown: "## Overview\nShorter."))
    }

    func testContentChangeUnderTheSameIDInvalidates() {
        // Outputs are not edited in place today; the length guard still refuses a stale render.
        let cache = RenderedOutputCache()
        let id = UUID()
        let date = Date()
        _ = cache.rendered(outputID: id, createdAt: date, content: summary, mode: .outcomes)
        let edited = summary + "\n\nAddendum."
        let rendered = cache.rendered(outputID: id, createdAt: date, content: edited, mode: .outcomes)
        XCTAssertEqual(cache.buildCount, 2)
        XCTAssertEqual(rendered, RenderedOutput.build(markdown: edited, mode: .outcomes))
    }

    func testUnrelatedMeetingChangeDoesNotInvalidate() {
        let cache = RenderedOutputCache()
        let meeting = Meeting(title: "Launch")
        let output = MeetingOutput(kind: .summary, content: summary, meeting: meeting)
        _ = cache.rendered(for: output, mode: .outcomes)

        // A transcript append / rename / note bumps the meeting, never the output's content.
        meeting.title = "Launch (renamed)"
        meeting.updatedAt = Date().addingTimeInterval(60)
        _ = cache.rendered(for: output, mode: .outcomes)
        XCTAssertEqual(cache.buildCount, 1)
    }

    // MARK: - Bound

    func testCacheIsBoundedAndEvictsLeastRecentlyUsed() {
        let cache = RenderedOutputCache(capacity: 2)
        let a = MeetingOutput(kind: .summary, content: "A")
        let b = MeetingOutput(kind: .summary, content: "B")
        let c = MeetingOutput(kind: .summary, content: "C")
        _ = cache.rendered(for: a, mode: .verbatim)
        _ = cache.rendered(for: b, mode: .verbatim)
        _ = cache.rendered(for: a, mode: .verbatim)   // a is now most recent
        _ = cache.rendered(for: c, mode: .verbatim)   // evicts b
        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(cache.buildCount, 3)

        _ = cache.rendered(for: a, mode: .verbatim)
        XCTAssertEqual(cache.buildCount, 3, "a survived eviction")
        _ = cache.rendered(for: b, mode: .verbatim)
        XCTAssertEqual(cache.buildCount, 4, "b was evicted and rebuilt")
        XCTAssertEqual(cache.count, 2)
    }
}
