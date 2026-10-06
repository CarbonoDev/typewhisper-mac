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

    /// Nothing to prepare: the fact columns did not exist.
    static func prepareStore(_ service: MeetingService) async {}

    /// The archive body evaluated `filteredMeetings` + the effective-date sort once per body pass
    /// (772f3535 already threaded one `displayedMeetings` through the body; the plan's "7x" predates
    /// that), with no memo: every re-render repeated it, and the sort parsed both titles per
    /// comparison (`MeetingsListView.effectiveDate`).
    static func makeListFilter() -> PerfListFilter {
        PerfListFilter { meetings, searchText in
            MeetingsViewModel.filteredMeetings(meetings, folder: nil, tag: nil, searchText: searchText)
                .sorted { MeetingsListView.effectiveDate($0) > MeetingsListView.effectiveDate($1) }
                .count
        }
    }

    /// `ArchiveRow`'s body read the live `Meeting` directly on every evaluation: the title parse (via
    /// `parsed`, `isImported` and the gutter's effective date), folder, tags, attendees (twice), the
    /// memoized transcript fact and, for completed meetings, the memoized action facts.
    static func makeRowBuilder(feed: HomeFeedViewModel) -> PerfRowBuilder {
        PerfRowBuilder { meeting in
            let parsed = ImportedMeetingTitle.parse(meeting.title)
            let isImported = meeting.source == .importedAudio || meeting.source == .importedTranscript
                || ImportedMeetingTitle.parse(meeting.title).isImported
            let gutter = PerfRowBuilder.gutterText(MeetingsListView.effectiveDate(meeting))
            let folder = meeting.folderPath?.trimmingCharacters(in: .whitespaces)
            let tags = meeting.tags
            let attendees = meeting.attendees.count > 1 ? meeting.attendees.count : 0
            let hasTranscript = feed.hasTranscript(for: meeting)
            let actions = meeting.state == .completed ? feed.actionFacts(for: meeting)?.totalCount ?? 0 : 0
            return parsed.cleanTitle.count + gutter.count + (folder?.count ?? 0) + tags.count + attendees
                + (isImported ? 1 : 0) + (hasTranscript ? 1 : 0) + actions
        }
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

@MainActor
struct PerfListFilter {
    let body: @MainActor ([Meeting], String) -> Int
}

@MainActor
struct PerfRowBuilder {
    let row: @MainActor (Meeting) -> Int

    static func gutterText(_ date: Date) -> String {
        let sameYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
        return date.formatted(
            sameYear
                ? .dateTime.day(.twoDigits).month(.abbreviated)
                : .dateTime.day(.twoDigits).month(.abbreviated).year(.twoDigits)
        )
    }
}
