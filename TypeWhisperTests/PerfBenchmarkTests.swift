import Combine
import XCTest
@testable import TypeWhisper

/// Before/after benchmarks for the perf refactor's hot paths (plan §3), run without the app over a
/// synthetic on-disk meetings store shaped like the real one and a synthetic 2,000-note vault.
///
/// Skipped unless `TYPEWHISPER_PERF=1` reaches the test runner — pass it as
/// `TEST_RUNNER_TYPEWHISPER_PERF=1` to `xcodebuild`. Each result prints one parseable line:
///
///     PERF|<before|after>|<benchmark>|median_ms|min_ms|max_ms|n|<extra>
///
/// This file must compile unchanged at the pre-refactor commit 772f3535: it uses only API that
/// exists there too, plus `PerfShim` for the four calls whose API changed. See `scripts/perf/README.md`.
@MainActor
final class PerfBenchmarkTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        guard ProcessInfo.processInfo.environment["TYPEWHISPER_PERF"] == "1" else {
            throw XCTSkip("perf benchmarks run only with TYPEWHISPER_PERF=1 (see scripts/perf/README.md)")
        }
    }

    private func report(_ name: String, _ samples: PerfSamples, extra: String = "") {
        let line = String(
            format: "PERF|%@|%@|%.3f|%.3f|%.3f|%d|%@",
            PerfShim.label, name, samples.median, samples.min, samples.max, samples.values.count, extra
        )
        print(line)
    }

    private func report(_ name: String, single milliseconds: Double, extra: String = "") {
        var samples = PerfSamples()
        samples.add(milliseconds)
        report(name, samples, extra: extra)
    }

    /// A short gap between timed iterations so the stall probe's pings are served: `maxMainStall`
    /// then reports the longest single operation's main-thread block, not a whole loop's.
    private static func letMainBreathe() async {
        try? await Task.sleep(nanoseconds: 5_000_000)
    }

    /// A new service (new `ModelContext`, nothing faulted yet) over the prepared store.
    private func freshMeetingService() async throws -> MeetingService {
        MeetingService(appSupportDirectory: try await PerfFixtures.preparedStoreDirectory())
    }

    private func longMeeting(in service: MeetingService) throws -> Meeting {
        // The seeded long meetings are the first `longMeetingCount` rows by creation, which carry
        // the newest start dates; pick by segment count without assuming list order.
        let candidates = service.meetings.filter { $0.source == .importedTranscript }
        return try XCTUnwrap(candidates.first { $0.segments.count >= PerfFixtures.longMeetingSegments })
    }

    // MARK: - Finding 2: one live append into a long meeting, and what it republishes

    func test01LiveAppendIntoLongMeeting() async throws {
        let service = try await freshMeetingService()
        let meeting = try longMeeting(in: service)
        var listPublishes = 0
        var willChanges = 0
        let listSink = service.$meetings.dropFirst().sink { _ in listPublishes += 1 }
        let changeSink = service.objectWillChange.sink { _ in willChanges += 1 }
        defer { listSink.cancel(); changeSink.cancel() }

        var nextStart = Double(meeting.segments.count) * 4
        func batch() -> [TranscriptionSegment] {
            defer { nextStart += 12 }
            return (0..<3).map {
                TranscriptionSegment(text: "Live caption \(nextStart) #\($0)", start: nextStart + Double($0) * 4, end: nextStart + Double($0) * 4 + 3)
            }
        }
        service.appendStableSegments(batch(), source: .liveCapture, to: meeting) // warm-up
        listPublishes = 0
        willChanges = 0

        let probe = MainStallProbe()
        probe.start()
        var samples = PerfSamples()
        let appends = 20
        for _ in 0..<appends {
            let segments = batch()
            samples.add(PerfClock.milliseconds { service.appendStableSegments(segments, source: .liveCapture, to: meeting) })
            await Self.letMainBreathe()
        }
        let stall = await probe.stop()
        report("liveAppend.perAppend", samples, extra: String(
            format: "listPublishes/append=%.2f objectWillChange/append=%.2f maxMainStall=%.1fms",
            Double(listPublishes) / Double(appends), Double(willChanges) / Double(appends), stall
        ))
    }

    // MARK: - Finding 9: imported-title parsing across all rows, repeated as a render would

    func test02ImportedTitleParsingPerRender() async throws {
        let titles = try await freshMeetingService().meetings.map(\.title)
        func render() {
            for title in titles {
                _ = ImportedMeetingTitle.parse(title)
                _ = ImportedMeetingTitle.displayTitle(for: title)
            }
        }
        report("importedTitles.firstRender", single: PerfClock.milliseconds(render), extra: "rows=\(titles.count)")
        var samples = PerfSamples()
        for _ in 0..<20 { samples.add(PerfClock.milliseconds(render)) }
        report("importedTitles.repeatRender", samples, extra: "rows=\(titles.count)")
    }

    // MARK: - Findings 3-5: Home / list per-row facts, first paint and repeat

    func test03HomeRowFactsFirstPaintAndRepeat() async throws {
        let service = try await freshMeetingService()
        let feed = HomeFeedViewModel()
        let now = Date(timeIntervalSince1970: 1_780_100_000)
        func pass() {
            for group in feed.timelineGroups(from: service.meetings) {
                _ = feed.groupTitle(for: group, now: now)
                for meeting in group.meetings {
                    _ = feed.badges(for: meeting, now: now)
                    _ = feed.actionFacts(for: meeting)
                    _ = feed.hasTranscript(for: meeting)
                    _ = ImportedMeetingTitle.displayTitle(for: meeting.title)
                }
            }
        }
        // First paint, split by phase over a fresh context: the scalar work (grouping, headers,
        // titles) versus the relationship reads — badges and action facts fault each row's
        // `outputs`, the transcript fact faults its `segments`. SwiftData exposes no cheap fault
        // counter, so the phases are timed; `relationshipReads` counts the to-many reads made.
        var groups: [MeetingDayGroup] = []
        var relationshipReads = 0
        let scalarMs = PerfClock.milliseconds {
            groups = feed.timelineGroups(from: service.meetings)
            for group in groups {
                _ = feed.groupTitle(for: group, now: now)
                for meeting in group.meetings { _ = ImportedMeetingTitle.displayTitle(for: meeting.title) }
            }
        }
        let outputsMs = PerfClock.milliseconds {
            for group in groups {
                for meeting in group.meetings {
                    _ = feed.badges(for: meeting, now: now)
                    _ = feed.actionFacts(for: meeting)
                    relationshipReads += 1
                }
            }
        }
        let segmentsMs = PerfClock.milliseconds {
            for group in groups {
                for meeting in group.meetings {
                    _ = feed.hasTranscript(for: meeting)
                    relationshipReads += 1
                }
            }
        }
        let rows = service.meetings.count
        report("homeRows.firstPaint", single: scalarMs + outputsMs + segmentsMs, extra: "rows=\(rows)")
        report("homeRows.firstPaint.scalar", single: scalarMs, extra: "groups+headers+titles")
        report("homeRows.firstPaint.outputs", single: outputsMs, extra: "badges+actionFacts relationshipReads=\(rows)")
        report("homeRows.firstPaint.segments", single: segmentsMs, extra: "hasTranscript relationshipReads=\(relationshipReads - rows)")

        var repeats = PerfSamples()
        for _ in 0..<10 { repeats.add(PerfClock.milliseconds(pass)) }
        report("homeRows.repeat", repeats)

        // A write in between (a live append elsewhere): before the refactor every save refetched
        // the list and re-faulted every row's objects.
        let target = try XCTUnwrap(service.meetings.last)
        var afterWrite = PerfSamples()
        for index in 0..<5 {
            service.appendStableSegments(
                [TranscriptionSegment(text: "write \(index)", start: Double(9_000 + index * 5), end: Double(9_003 + index * 5))],
                source: .liveCapture, to: target
            )
            afterWrite.add(PerfClock.milliseconds(pass))
        }
        report("homeRows.afterWrite", afterWrite)
    }

    func test04ListSearchKeystrokes() async throws {
        let meetings = try await freshMeetingService().meetings
        let filter = PerfShim.makeListFilter()
        _ = filter.body(meetings, "") // the list's first paint, before any typing
        var changed = PerfSamples()
        var unchanged = PerfSamples()
        for query in ["a", "ac", "acm", "acme", "acme.ex"] {
            // A keystroke: the query changed, so the filter + sort must run.
            changed.add(PerfClock.milliseconds { _ = filter.body(meetings, query) })
            // Any other re-render of the list with the same query (selection, hover, a republish).
            unchanged.add(PerfClock.milliseconds { _ = filter.body(meetings, query) })
        }
        report("listSearch.changedKeystroke", changed, extra: "rows=\(meetings.count)")
        report("listSearch.unchangedRerender", unchanged, extra: "rows=\(meetings.count)")
    }

    // MARK: - Findings 4-5: archive row models, a visible window vs the whole list

    func test09ArchiveRowsWindowAndWholeList() async throws {
        func measure(_ name: String, rowCount: Int?) async throws {
            // Fresh context, feed and row builder: nothing faulted or memoized yet.
            let service = try await freshMeetingService()
            let builder = PerfShim.makeRowBuilder(feed: HomeFeedViewModel())
            let sorted = service.meetings.sorted { MeetingsListView.effectiveDate($0) > MeetingsListView.effectiveDate($1) }
            let rows = rowCount.map { Array(sorted.prefix($0)) } ?? sorted
            func paint() { for meeting in rows { _ = builder.row(meeting) } }
            report("archiveRows.\(name).firstPaint", single: PerfClock.milliseconds(paint), extra: "rows=\(rows.count)")
            var repeats = PerfSamples()
            for _ in 0..<10 { repeats.add(PerfClock.milliseconds(paint)) }
            report("archiveRows.\(name).repeat", repeats, extra: "rows=\(rows.count)")
        }
        try await measure("window20", rowCount: 20)
        try await measure("wholeList", rowCount: nil)
    }

    // MARK: - Finding 6: a long summary output's markdown, first render and repeat

    func test05SummaryMarkdownRender() async throws {
        let service = try await freshMeetingService()
        let output = try XCTUnwrap(
            service.meetings.flatMap(\.outputs).filter { $0.kind == .summary }.max { $0.content.count < $1.content.count }
        )
        let renderer = PerfShim.makeRenderer()
        report("markdown.firstRender", single: PerfClock.milliseconds { _ = renderer.render(output) },
               extra: "chars=\(output.content.count)")
        var samples = PerfSamples()
        for _ in 0..<20 { samples.add(PerfClock.milliseconds { _ = renderer.render(output) }) }
        report("markdown.repeatRender", samples)
    }

    // MARK: - Finding 10: vault retrieval + Space tree over a 2,000-note vault

    private func makeDefaults(root: String) -> UserDefaults {
        let suite = "PerfBenchmark-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(root, forKey: UserDefaultsKeys.meetingsObsidianRootFolder)
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return defaults
    }

    func test06VaultRetrieval() async throws {
        let vault = try PerfFixtures.makeVault()
        addTeardownBlock { try? FileManager.default.removeItem(at: vault) }
        let service = ObsidianVaultService(defaults: makeDefaults(root: "Meetings"))
        service.connect(to: vault.path)

        let firstProbe = MainStallProbe()
        firstProbe.start()
        var hits = 0
        let first = await PerfClock.millisecondsAsync { hits = await PerfShim.retrieve(service, query: "acme roadmap budget") }
        let firstStall = await firstProbe.stop()
        report("vault.retrieve.first", single: first, extra: String(format: "hits=%d maxMainStall=%.1fms", hits, firstStall))

        let probe = MainStallProbe()
        probe.start()
        var samples = PerfSamples()
        for query in ["hiring plan", "migration estimate", "globex budget", "follow up owner", "initech roadmap"] {
            samples.add(await PerfClock.millisecondsAsync { _ = await PerfShim.retrieve(service, query: query) })
            await Self.letMainBreathe()
        }
        let stall = await probe.stop()
        report("vault.retrieve.repeat", samples, extra: String(format: "maxMainStall=%.1fms", stall))
    }

    func test07SpaceTreeBuildAndFolderVisits() async throws {
        let vault = try PerfFixtures.makeVault()
        addTeardownBlock { try? FileManager.default.removeItem(at: vault) }
        let defaults = makeDefaults(root: "Meetings")
        let service = ObsidianVaultService(defaults: defaults)
        service.connect(to: vault.path)

        // Construction: before the refactor `init` scanned the vault (on the launch path).
        var space: SpaceViewModel?
        let initMs = PerfClock.milliseconds { space = SpaceViewModel(vaultService: service, defaults: defaults) }
        report("space.init", single: initMs)
        let vm = try XCTUnwrap(space)

        let probe = MainStallProbe()
        probe.start()
        var refresh = PerfSamples()
        for _ in 0..<5 {
            refresh.add(await PerfClock.millisecondsAsync { await PerfShim.refresh(vm) })
            await Self.letMainBreathe()
        }
        let stall = await probe.stop()
        report("space.refresh", refresh, extra: String(format: "entries=%d maxMainStall=%.1fms", vm.entries.count, stall))

        // Visiting every folder index once (each visit asks for that folder's children).
        let folders = vm.entries.filter(\.isDirectory).map(\.relativePath)
        var visits = PerfSamples()
        for _ in 0..<5 {
            visits.add(PerfClock.milliseconds { for folder in folders { _ = vm.children(of: folder) } })
        }
        report("space.visitAllFolders", visits, extra: "folders=\(folders.count)")
    }

    // MARK: - Finding 11: calendar refresh with an unchanged event list

    func test08CalendarRefreshUnchanged() async throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let calendar = CalendarService(provider: PerfFixtures.FixedCalendarProvider(now: now))
        var publishes = 0
        let upcoming = calendar.$upcomingEvents.dropFirst().sink { _ in publishes += 1 }
        let earlier = calendar.$earlierEvents.dropFirst().sink { _ in publishes += 1 }
        defer { upcoming.cancel(); earlier.cancel() }

        await PerfShim.calendarRefresh(calendar, now: now)
        publishes = 0

        let probe = MainStallProbe()
        probe.start()
        var samples = PerfSamples()
        let refreshes = 20
        for _ in 0..<refreshes {
            samples.add(await PerfClock.millisecondsAsync { await PerfShim.calendarRefresh(calendar, now: now) })
            await Self.letMainBreathe()
        }
        let stall = await probe.stop()
        report("calendar.refreshUnchanged", samples, extra: String(
            format: "publishes/refresh=%.2f maxMainStall=%.1fms", Double(publishes) / Double(refreshes), stall
        ))
    }
}
