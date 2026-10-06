import Foundation
@testable import TypeWhisper

/// The four calls whose API the perf refactor changed, behind one seam so `PerfBenchmarkTests`
/// compiles unchanged at both commits. This is the **after** variant (current code); the
/// pre-refactor variant lives at `scripts/perf/PerfBenchmarkShim.before.swift` and replaces this
/// file when the suite runs at 772f3535 (see `scripts/perf/README.md`).
@MainActor
enum PerfShim {
    static let label = "after"

    /// Vault retrieval (finding 10): now async, enumeration + parse + rank off the main actor.
    static func retrieve(_ service: ObsidianVaultService, query: String) async -> Int {
        await service.retrieve(query: query, limit: 3).count
    }

    /// Space snapshot refresh (finding 10): now async, enumeration + tree index off the main actor.
    static func refresh(_ space: SpaceViewModel) async {
        await space.refresh()
    }

    /// One calendar refresh as the app's refresh path runs it (finding 11). Today: the event-driven
    /// coordinator calls `refreshInBackground` (provider query off main, equality-gated publish).
    static func calendarRefresh(_ calendar: CalendarService, now: Date) async {
        await calendar.refreshInBackground(now: now)
    }

    /// Bring a freshly seeded store to the state a real launch leaves it in. Today: the launch
    /// backfill of the denormalised fact columns (`reconcileFacts`, run by `runDeferredStartup`).
    static func prepareStore(_ service: MeetingService) async {
        await service.reconcileFacts()
    }

    /// One archive-list body's filter + sort (findings 5). Today: one memoized
    /// `MeetingListPipeline` call per body, as `MeetingsListView.displayedMeetings` makes it.
    static func makeListFilter() -> PerfListFilter {
        let pipeline = MeetingListPipeline()
        return PerfListFilter { meetings, searchText in
            pipeline.meetings(meetings, query: MeetingListQuery(searchText: searchText, sortNewestFirst: true)).count
        }
    }

    /// One archive row's body (finding 4/5). Today: `MeetingRowModelStore` builds the row's value
    /// model once per `(id, updatedAt)` (as `MeetingRowCell` does); the view formats the gutter date.
    static func makeRowBuilder(feed: HomeFeedViewModel) -> PerfRowBuilder {
        let store = MeetingRowModelStore()
        let context = MeetingRowModelStore.Context(actionFacts: feed.actionFacts(for:))
        return PerfRowBuilder { meeting in
            guard let row = store.row(for: meeting, context: context) else { return 0 }
            return row.title.count + PerfRowBuilder.gutterText(row.effectiveDate).count
        }
    }

    /// A renderer for one output's document article (finding 6). Today: the shared memo builds the
    /// parse + inline attributes once per output; repeats are lookups.
    static func makeRenderer() -> PerfOutputRenderer {
        let cache = RenderedOutputCache()
        return PerfOutputRenderer { output in
            cache.rendered(for: output, mode: .outcomes).article.blocks.count
        }
    }
}

/// One body pass's worth of rendering for an output; returns the block count (keeps the work live).
@MainActor
struct PerfOutputRenderer {
    let render: @MainActor (MeetingOutput) -> Int
}

/// One archive body's filter + sort; returns the displayed count.
@MainActor
struct PerfListFilter {
    let body: @MainActor ([Meeting], String) -> Int
}

/// One archive row's body work; returns a value derived from what it drew (keeps the work live).
@MainActor
struct PerfRowBuilder {
    let row: @MainActor (Meeting) -> Int

    /// The archive row's gutter date (same format at both commits).
    static func gutterText(_ date: Date) -> String {
        let sameYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
        return date.formatted(
            sameYear
                ? .dateTime.day(.twoDigits).month(.abbreviated)
                : .dateTime.day(.twoDigits).month(.abbreviated).year(.twoDigits)
        )
    }
}
