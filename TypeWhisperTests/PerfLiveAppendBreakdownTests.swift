import SwiftData
import XCTest
@testable import TypeWhisper

/// Where the remaining live-append time goes (current code only — this file is not part of the
/// before/after graft; `scripts/perf/run-before-after.sh` copies `PerfBenchmarkTests` alone).
///
/// `MeetingService.appendStableSegments` is timed as a whole, then its steps are replayed on a
/// second `ModelContext` over the same on-disk store — segment mapping, relationship assignment,
/// insert, the `updatedAt` bump, and the SwiftData `save()` — because the service's own context is
/// private and its save path is not to be changed here. `isInFetchOrder` (the in-place write's
/// "did a sort key move" scan over the published list) is a static and is timed directly.
/// Skipped unless `TYPEWHISPER_PERF=1`, like `PerfBenchmarkTests`.
@MainActor
final class PerfLiveAppendBreakdownTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        guard ProcessInfo.processInfo.environment["TYPEWHISPER_PERF"] == "1" else {
            throw XCTSkip("perf benchmarks run only with TYPEWHISPER_PERF=1 (see scripts/perf/README.md)")
        }
    }

    private func report(_ name: String, _ samples: PerfSamples, extra: String = "") {
        print(String(
            format: "PERF|%@|%@|%.3f|%.3f|%.3f|%d|%@",
            PerfShim.label, name, samples.median, samples.min, samples.max, samples.values.count, extra
        ))
    }

    private func batch(startingAt start: Double) -> [TranscriptionSegment] {
        (0..<3).map {
            TranscriptionSegment(text: "Live caption \(start) #\($0)", start: start + Double($0) * 4, end: start + Double($0) * 4 + 3)
        }
    }

    func testLiveAppendBreakdown() async throws {
        let dir = try await PerfFixtures.preparedStoreDirectory()
        let iterations = 20

        // 1. The real thing, through the service.
        let service = MeetingService(appSupportDirectory: dir)
        let serviceMeeting = try XCTUnwrap(
            service.meetings.first { $0.segments.count >= PerfFixtures.longMeetingSegments }
        )
        var next = 100_000.0
        service.appendStableSegments(batch(startingAt: next), source: .liveCapture, to: serviceMeeting)
        next += 12
        var total = PerfSamples()
        for _ in 0..<iterations {
            let segments = batch(startingAt: next)
            next += 12
            total.add(PerfClock.milliseconds { service.appendStableSegments(segments, source: .liveCapture, to: serviceMeeting) })
        }
        report("liveAppend.breakdown.total", total, extra: "appendStableSegments, 3 segments into 1,600+")

        // 2. The published-order scan the in-place commit runs after its save.
        var scan = PerfSamples()
        for _ in 0..<iterations {
            scan.add(PerfClock.milliseconds { _ = MeetingService.isInFetchOrder(service.meetings) })
        }
        report("liveAppend.breakdown.isInFetchOrder", scan, extra: "meetings=\(service.meetings.count)")

        // 3. The same SwiftData work on a second context over the same store, step by step.
        let (container, context) = try SwiftDataStoreFactory.create(
            for: [Meeting.self, MeetingSegment.self, MeetingNote.self, MeetingOutput.self,
                  MeetingQATurn.self, MeetingTemplate.self],
            storeName: "meetings",
            in: dir
        )
        _ = container
        let regular = try XCTUnwrap(service.meetings.first { $0.segments.count == PerfFixtures.regularMeetingSegments })
        try replaySteps(context: context, meetingID: serviceMeeting.id, label: "", next: &next, iterations: iterations)
        // The same steps into a 150-segment meeting: shows which steps scale with the meeting's size.
        try replaySteps(context: context, meetingID: regular.id, label: ".short", next: &next, iterations: iterations)
    }

    private func replaySteps(
        context: ModelContext, meetingID: UUID, label: String, next: inout Double, iterations: Int
    ) throws {
        let meeting = try XCTUnwrap(
            try context.fetch(FetchDescriptor<Meeting>(predicate: #Predicate { $0.id == meetingID })).first
        )
        let segmentCount = meeting.segments.count
        var nextOrder = (meeting.segments.map(\.order).max() ?? -1) + 1 // once, as the order cache does

        var mapping = PerfSamples()
        var relate = PerfSamples()
        var insert = PerfSamples()
        var touch = PerfSamples()
        var save = PerfSamples()
        var replay = PerfSamples()
        for iteration in 0...iterations {
            let segments = batch(startingAt: next)
            next += 12
            var models: [MeetingSegment] = []
            let mapMs = PerfClock.milliseconds {
                models = segments.enumerated().map { offset, segment in
                    MeetingSegmentMapper.makeSegment(from: segment, order: nextOrder + offset, source: .liveCapture, isStable: true)
                }
            }
            nextOrder += segments.count
            let relateMs = PerfClock.milliseconds { for model in models { model.meeting = meeting } }
            let insertMs = PerfClock.milliseconds { for model in models { context.insert(model) } }
            let touchMs = PerfClock.milliseconds { meeting.updatedAt = Date() }
            let saveMs = try PerfClock.milliseconds { try context.save() }
            guard iteration > 0 else { continue } // the first round is warm-up
            mapping.add(mapMs)
            relate.add(relateMs)
            insert.add(insertMs)
            touch.add(touchMs)
            save.add(saveMs)
            replay.add(mapMs + relateMs + insertMs + touchMs + saveMs)
        }
        report("liveAppend.breakdown\(label).replay", replay, extra: "sum of the steps below; segments=\(segmentCount)")
        report("liveAppend.breakdown\(label).segmentMapping", mapping)
        report("liveAppend.breakdown\(label).relationshipAssign", relate, extra: "segment.meeting = meeting")
        report("liveAppend.breakdown\(label).insert", insert)
        report("liveAppend.breakdown\(label).updatedAt", touch)
        report("liveAppend.breakdown\(label).save", save, extra: "ModelContext.save()")
    }
}
