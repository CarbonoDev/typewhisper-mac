import Foundation
@testable import TypeWhisper

/// The **before** variant of `TypeWhisperTests/PerfBenchmarkShim.swift`, for the pre-refactor commit
/// (772f3535). `scripts/perf/run-before-after.sh` copies it over the after variant in the exported
/// old tree. Each call does what that commit's code did for the same user action.
@MainActor
enum PerfShim {
    static let label = "before"

    /// Vault retrieval was synchronous on the main actor: walk + read + parse + rank every call.
    static func retrieve(_ service: ObsidianVaultService, query: String) async -> Int {
        service.retrieve(query: query, limit: 3).count
    }

    /// Space refresh was synchronous on the main actor (walk + recursive tree build).
    static func refresh(_ space: SpaceViewModel) async {
        space.refresh()
    }

    /// The 60 s poll called the synchronous `refresh` (query on main, unconditional republish).
    static func calendarRefresh(_ calendar: CalendarService, now: Date) async {
        calendar.refresh(now: now)
    }

    /// The document body re-ran the outcome extraction, the block split and every inline
    /// `AttributedString(markdown:)` on each body pass (`MeetingDocumentBody` +
    /// `MarkdownDocumentView.blocks`); there was no memo, so first and repeat cost the same.
    static func makeRenderer() -> PerfOutputRenderer {
        PerfOutputRenderer { output in
            let outcomes = MeetingOutputParser.parse(markdown: output.content)
            let blocks = MarkdownBlock.parse(outcomes.strippedMarkdown)
            for block in blocks {
                switch block {
                case let .heading(_, text), let .paragraph(text):
                    _ = MarkdownBlock.inlineAttributed(text)
                case let .bullet(items), let .ordered(items):
                    items.forEach { _ = MarkdownBlock.inlineAttributed($0) }
                case let .table(header, rows):
                    header.forEach { _ = MarkdownBlock.inlineAttributed($0) }
                    rows.forEach { $0.forEach { _ = MarkdownBlock.inlineAttributed($0) } }
                }
            }
            return blocks.count
        }
    }
}

@MainActor
struct PerfOutputRenderer {
    let render: @MainActor (MeetingOutput) -> Int
}
