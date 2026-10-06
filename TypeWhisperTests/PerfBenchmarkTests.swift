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

    private func freshMeetingService() throws -> MeetingService {
        MeetingService(appSupportDirectory: try PerfFixtures.meetingsStoreDirectory())
    }

    private func longMeeting(in service: MeetingService) throws -> Meeting {
        // The seeded long meetings are the first `longMeetingCount` rows by creation, which carry
        // the newest start dates; pick by segment count without assuming list order.
        let candidates = service.meetings.filter { $0.source == .importedTranscript }
        return try XCTUnwrap(candidates.first { $0.segments.count >= PerfFixtures.longMeetingSegments })
    }

    // MARK: - Finding 2: one live append into a long meeting, and what it republishes

    func test01LiveAppendIntoLongMeeting() async throws {
        let service = try freshMeetingService()
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

    func test02ImportedTitleParsingPerRender() throws {
        let titles = try freshMeetingService().meetings.map(\.title)
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

    func test03HomeRowFactsFirstPaintAndRepeat() throws {
        let service = try freshMeetingService()
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
        report("homeRows.firstPaint", single: PerfClock.milliseconds(pass), extra: "rows=\(service.meetings.count)")

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

    func test04ListSearchKeystrokes() throws {
        let meetings = try freshMeetingService().meetings
        var samples = PerfSamples()
        for query in ["a", "ac", "acm", "acme", "acme.ex"] {
            // The list body evaluated its filter + sort several times per pass (finding 5: 7×).
            samples.add(PerfClock.milliseconds {
                for _ in 0..<7 {
                    _ = MeetingsViewModel.filteredMeetings(meetings, folder: nil, tag: nil, searchText: query)
                        .sorted { ($0.startDate ?? $0.createdAt) > ($1.startDate ?? $1.createdAt) }
                }
            })
        }
        report("listSearch.perKeystroke", samples, extra: "rows=\(meetings.count) passes/keystroke=7")
    }

    // MARK: - Finding 6: a long summary output's markdown, first render and repeat

    func test05SummaryMarkdownRender() throws {
        let service = try freshMeetingService()
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
        let first = await PerfClock.milliseconds { hits = await PerfShim.retrieve(service, query: "acme roadmap budget") }
        let firstStall = await firstProbe.stop()
        report("vault.retrieve.first", single: first, extra: String(format: "hits=%d maxMainStall=%.1fms", hits, firstStall))

        let probe = MainStallProbe()
        probe.start()
        var samples = PerfSamples()
        for query in ["hiring plan", "migration estimate", "globex budget", "follow up owner", "initech roadmap"] {
            samples.add(await PerfClock.milliseconds { _ = await PerfShim.retrieve(service, query: query) })
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
            refresh.add(await PerfClock.milliseconds { await PerfShim.refresh(vm) })
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
            samples.add(await PerfClock.milliseconds { await PerfShim.calendarRefresh(calendar, now: now) })
            await Self.letMainBreathe()
        }
        let stall = await probe.stop()
        report("calendar.refreshUnchanged", samples, extra: String(
            format: "publishes/refresh=%.2f maxMainStall=%.1fms", Double(publishes) / Double(refreshes), stall
        ))
    }
}
