import Foundation
import SwiftData
@testable import TypeWhisper

/// Synthetic data + measurement helpers for `PerfBenchmarkTests` (perf plan, before/after numbers).
///
/// Everything here uses only API that exists both at the pre-refactor commit (772f3535) and today,
/// so the same file compiles at both — see `scripts/perf/README.md`.
enum PerfFixtures {
    // MARK: - Meetings store shaped like the real one (plan §2 evidence)

    static let meetingCount = 300
    static let importedTitleCount = 160
    static let longMeetingCount = 4
    static let longMeetingSegments = 1_600
    static let regularMeetingSegments = 150
    static let meetingsWithOutputs = 100

    private static let importedTitlePatterns = [
        "Seguimiento BD - 2026/09/%02d 09:01 CST - Transcripción",
        "Weekly sync - 2026_07_%02d 11_00 UTC - Notas de Gemini",
        "Revisión de arquitectura (%d) - 2026/08/12 16:30 CST - Notas de Gemini",
        "Acme kickoff - 2026_06_%02d 15_00 GMT-06_00 - Transcripción",
    ]

    private static let speakers = ["Nora Ibáñez", "Teo Salas", "Ada Park", "Marco R."]

    /// A realistic long summary: headings, prose, bullets with inline emphasis, action items,
    /// decisions and a table — the shapes `MeetingOutputParser` and `MarkdownBlock` handle.
    static func summaryMarkdown(seed: Int) -> String {
        var lines: [String] = ["# Summary", ""]
        for section in 0..<6 {
            lines.append("## Topic \(section + 1): **migration** of the *ledger* service")
            lines.append("")
            lines.append("The team discussed the incremental migration plan, rollout risks and the `GDA` dashboard. "
                + "Seed \(seed) section \(section) adds enough prose to resemble a real model summary with [links](https://example.com/\(seed)).")
            lines.append("")
            for bullet in 0..<5 {
                lines.append("- Point \(bullet + 1): **owner** follows up on _item_ \(seed)-\(section)-\(bullet)")
            }
            lines.append("")
        }
        lines.append("## Action items")
        lines.append("")
        for item in 0..<8 {
            lines.append("- [ ] \(speakers[item % speakers.count]) to send the revised estimate #\(item) by Friday")
        }
        lines.append("")
        lines.append("## Decisions")
        lines.append("")
        for item in 0..<4 {
            lines.append("- Decided to ship phase \(item + 1) behind a flag")
        }
        lines.append("")
        lines.append("| Owner | Task | Due |")
        lines.append("|---|---|---|")
        for row in 0..<6 {
            lines.append("| \(speakers[row % speakers.count]) | Task \(row) | 2026-10-\(10 + row) |")
        }
        return lines.joined(separator: "\n")
    }

    /// Build the store once per test process (it is read-only to every benchmark except the live
    /// append, which only adds a few rows to one meeting).
    @MainActor
    static func meetingsStoreDirectory() throws -> URL {
        if let cachedStoreDirectory { return cachedStoreDirectory }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PerfBenchmarkStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try seedMeetingsStore(in: dir)
        cachedStoreDirectory = dir
        return dir
    }

    @MainActor private static var cachedStoreDirectory: URL?

    @MainActor
    private static func seedMeetingsStore(in dir: URL) throws {
        let (container, context) = try SwiftDataStoreFactory.create(
            for: [Meeting.self, MeetingSegment.self, MeetingNote.self, MeetingOutput.self,
                  MeetingQATurn.self, MeetingTemplate.self],
            storeName: "meetings",
            in: dir
        )
        _ = container
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        for index in 0..<meetingCount {
            let isImported = index < importedTitleCount
            let title = isImported
                ? String(format: importedTitlePatterns[index % importedTitlePatterns.count], (index % 27) + 1)
                : "Planning session \(index) with Acme"
            let start = base.addingTimeInterval(-Double(index) * 36 * 3_600)
            let meeting = Meeting(
                title: title,
                state: .completed,
                source: isImported ? .importedTranscript : .calendar,
                startDate: index % 140 == 7 ? nil : start,
                endDate: start.addingTimeInterval(3_600)
            )
            meeting.attendees = (0..<(3 + index % 4)).map { attendee in
                Attendee(name: "\(speakers[attendee % speakers.count]) \(attendee)", email: "person\(attendee)@acme.example")
            }
            context.insert(meeting)

            let segmentCount = index < longMeetingCount ? longMeetingSegments : regularMeetingSegments
            for order in 0..<segmentCount {
                let segment = MeetingSegment(
                    order: order,
                    start: Double(order) * 4,
                    end: Double(order) * 4 + 3.5,
                    text: "Turn \(order): we should revisit the migration estimate and the dashboard numbers.",
                    speakerLabel: speakers[order % speakers.count],
                    source: isImported ? .importedTranscript : .liveCapture
                )
                segment.meeting = meeting
                context.insert(segment)
            }
            if index % 3 == 0, index / 3 < meetingsWithOutputs {
                let output = MeetingOutput(kind: .summary, content: summaryMarkdown(seed: index), createdAt: start)
                output.meeting = meeting
                context.insert(output)
            }
            if index % 50 == 0 { try context.save() }
        }
        try context.save()
    }

    // MARK: - Synthetic 2,000-note vault

    static let vaultNoteCount = 2_000

    /// A temp vault: `Meetings/<Client>/<Project>/Note N.md` with frontmatter tags and ~1–2 KB bodies.
    static func makeVault() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PerfBenchmarkVault-\(UUID().uuidString)", isDirectory: true)
        let clients = ["Acme", "Globex", "Initech", "Umbrella", "Hooli"]
        for index in 0..<vaultNoteCount {
            let client = clients[index % clients.count]
            let folder = dir.appendingPathComponent("Meetings/\(client)/Project \(index % 20)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let body = """
            ---
            tags: [meeting, \(client.lowercased()), project-\(index % 20)]
            ---
            # \(client) note \(index)

            \(String(repeating: "Discussion about the roadmap, budget, hiring plan and the migration estimate for \(client). ", count: 12))

            - Follow up on item \(index)
            - Owner: \(speakers[index % speakers.count])
            """
            try body.write(to: folder.appendingPathComponent("Note \(index).md"), atomically: false, encoding: .utf8)
        }
        return dir
    }

    // MARK: - Calendar fake

    final class FixedCalendarProvider: CalendarEventProviding {
        let fixed: [CalendarEventDTO]

        init(now: Date, count: Int = 60) {
            fixed = (0..<count).map { index in
                let start = now.addingTimeInterval(Double(index - 20) * 1_800)
                return CalendarEventDTO(
                    id: "evt-\(index)",
                    title: "Event \(index)",
                    startDate: start,
                    endDate: start.addingTimeInterval(1_800),
                    isAllDay: false,
                    attendees: [Attendee(name: "Ada Park", email: "ada@acme.example")]
                )
            }
        }

        var authorizationStatus: CalendarAuthorizationStatus { .authorized }
        func requestAccess() async -> CalendarAuthorizationStatus { .authorized }
        func events(from start: Date, to end: Date) -> [CalendarEventDTO] {
            fixed.filter { $0.endDate >= start && $0.startDate <= end }
        }
        func calendars() -> [CalendarInfo] { [] }
    }
}

// MARK: - Measurement

/// Timing samples in milliseconds, summarized as median and spread.
struct PerfSamples {
    private(set) var values: [Double] = []

    mutating func add(_ milliseconds: Double) { values.append(milliseconds) }

    var median: Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted.count % 2 == 1
            ? sorted[sorted.count / 2]
            : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }
    var min: Double { values.min() ?? 0 }
    var max: Double { values.max() ?? 0 }
}

enum PerfClock {
    static func milliseconds(_ body: () throws -> Void) rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    @MainActor
    static func milliseconds(_ body: @MainActor () async throws -> Void) async rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try await body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }
}

/// Longest main-thread stall while an operation runs: a background timer pings the main queue every
/// 2 ms and records how late each ping is served. Work done synchronously on the main actor shows up
/// as a stall as long as itself; work moved off the main actor does not.
final class MainStallProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var maxLatencyNanos: UInt64 = 0
    private var timer: DispatchSourceTimer?

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
        timer.schedule(deadline: .now(), repeating: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            let sent = DispatchTime.now().uptimeNanoseconds
            DispatchQueue.main.async {
                let latency = DispatchTime.now().uptimeNanoseconds - sent
                guard let self else { return }
                self.lock.lock()
                if latency > self.maxLatencyNanos { self.maxLatencyNanos = latency }
                self.lock.unlock()
            }
        }
        self.timer = timer
        timer.resume()
    }

    /// Stop and return the longest stall in milliseconds. Lets queued pings drain first.
    @MainActor
    func stop() async -> Double {
        timer?.cancel()
        timer = nil
        try? await Task.sleep(nanoseconds: 20_000_000)
        return Double(readMax()) / 1_000_000
    }

    private func readMax() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return maxLatencyNanos
    }
}
