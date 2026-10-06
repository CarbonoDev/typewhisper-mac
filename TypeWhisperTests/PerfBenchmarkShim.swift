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
