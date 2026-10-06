import XCTest
import SwiftData
@testable import TypeWhisper

/// The launch pass over the denormalised meeting facts: turns stay within their row budget even on
/// a huge meeting, a write that lands mid-pass is never lost or double-counted, and the pass is
/// interruptible and idempotent.
@MainActor
final class MeetingFactsBackfillTests: XCTestCase {
    private var dir: URL!
    /// No wall-clock limit in tests, so turn boundaries depend only on the row budget.
    private let rowsOnly = { (rows: Int) in MeetingFactsBackfillBudget(rowsPerTurn: rows, timePerTurn: .seconds(60)) }

    override func setUpWithError() throws {
        dir = try TestSupport.makeTemporaryDirectory()
    }

    override func tearDown() {
        TestSupport.remove(dir)
        super.tearDown()
    }

    /// Write a pre-facts store (all columns unset) with one meeting per entry of `segmentCounts`.
    private func makeV1Store(segmentCounts: [Int]) throws -> [UUID] {
        let ids = segmentCounts.map { _ in UUID() }
        try autoreleasepool {
            let config = ModelConfiguration(url: dir.appendingPathComponent("meetings.store"))
            let container = try ModelContainer(for: Schema(MeetingsSchemaV1.models), configurations: [config])
            let context = ModelContext(container)
            for (id, count) in zip(ids, segmentCounts) {
                let meeting = MeetingsSchemaV1.Meeting(id: id, title: "Old \(count)", startDate: Date())
                context.insert(meeting)
                for index in 0..<count {
                    context.insert(MeetingsSchemaV1.MeetingSegment(
                        order: index, start: Double(index), end: Double(index) + 1, text: "l\(index)",
                        speakerLabel: "SPEAKER_0\(index % 3)", meeting: meeting
                    ))
                }
            }
            try context.save()
        }
        return ids
    }

    private func assertFactsMatch(_ meeting: Meeting, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(meeting.hasStoredFacts, "columns unset", file: file, line: line)
        XCTAssertEqual(meeting.storedTranscriptFacts, meeting.computedTranscriptFacts(), file: file, line: line)
        XCTAssertEqual(meeting.storedOutputKinds, meeting.computedOutputKinds(), file: file, line: line)
    }

    func testALargeMeetingIsSplitAcrossTurnsWithinTheRowBudget() async throws {
        let ids = try makeV1Store(segmentCounts: [1_000, 3, 0])
        let service = MeetingService(appSupportDirectory: dir)
        var pauses = 0

        let report = await service.reconcileFacts(budget: rowsOnly(100)) { pauses += 1 }

        XCTAssertTrue(report.completed)
        XCTAssertEqual(report.written, 3)
        XCTAssertGreaterThanOrEqual(report.turns, 10, "1,000 rows at 100 per turn")
        XCTAssertLessThanOrEqual(report.maxRowsInATurn, 100)
        XCTAssertEqual(pauses, report.turns - 1)
        for id in ids {
            assertFactsMatch(try XCTUnwrap(service.meetings.first { $0.id == id }))
        }
        let big = try XCTUnwrap(service.meetings.first { $0.id == ids[0] })
        XCTAssertEqual(big.factSegmentCount, 1_000)
        XCTAssertEqual(big.storedTranscriptFacts?.speakerCount, 3)
    }

    func testALiveAppendLandingMidBackfillIsCountedExactlyOnce() async throws {
        let ids = try makeV1Store(segmentCounts: [300])
        let service = MeetingService(appSupportDirectory: dir)
        let meeting = try XCTUnwrap(service.meetings.first { $0.id == ids[0] })
        var appended = false

        let report = await service.reconcileFacts(budget: rowsOnly(50)) {
            // A caption flush between two pages of this meeting's backfill.
            guard !appended else { return }
            appended = true
            service.appendStableSegments(
                [TranscriptionSegment(text: "live", start: 900, end: 905, speakerLabel: "SPEAKER_09")],
                source: .liveCaptions,
                to: meeting
            )
            XCTAssertNil(meeting.factSegmentCount, "an append on an unfilled row leaves it to the pass")
        }

        XCTAssertTrue(appended)
        XCTAssertTrue(report.completed)
        assertFactsMatch(meeting)
        XCTAssertEqual(meeting.factSegmentCount, 301)
        XCTAssertEqual(meeting.factTranscriptEnd, 905)

        // Once filled, the next live append keeps the columns incrementally.
        service.appendStableSegments([TranscriptionSegment(text: "next", start: 905, end: 910)], to: meeting)
        assertFactsMatch(meeting)
        XCTAssertEqual(meeting.factSegmentCount, 302)
    }

    func testAChokePointWriteMidBackfillWinsOverThePass() async throws {
        let ids = try makeV1Store(segmentCounts: [200])
        let service = MeetingService(appSupportDirectory: dir)
        let meeting = try XCTUnwrap(service.meetings.first { $0.id == ids[0] })
        var replaced = false

        let report = await service.reconcileFacts(budget: rowsOnly(50)) {
            guard !replaced else { return }
            replaced = true
            // The final pass replaces the transcript; its choke point recomputes the columns.
            service.replaceSegments(
                of: meeting, source: .liveCapture,
                with: [TranscriptionSegment(text: "final", start: 0, end: 12)]
            )
        }

        XCTAssertTrue(report.completed)
        assertFactsMatch(meeting)
        XCTAssertEqual(meeting.factSegmentCount, 1)
        XCTAssertEqual(meeting.factTranscriptEnd, 12)
    }

    func testAnInterruptedPassResumesAndARerunIsANoOp() async throws {
        let ids = try makeV1Store(segmentCounts: [120, 120, 120])
        let service = MeetingService(appSupportDirectory: dir)

        let task = Task { @MainActor in
            await service.reconcileFacts(budget: rowsOnly(100)) { withUnsafeCurrentTask { $0?.cancel() } }
        }
        let interrupted = await task.value
        XCTAssertFalse(interrupted.completed)
        let unfilled = service.meetings.filter { !$0.hasStoredFacts }
        XCTAssertFalse(unfilled.isEmpty, "stopped part-way")

        let resumed = await service.reconcileFacts(budget: rowsOnly(100), pause: {})
        XCTAssertTrue(resumed.completed)
        for id in ids {
            assertFactsMatch(try XCTUnwrap(service.meetings.first { $0.id == id }))
        }

        let rerun = await service.reconcileFacts(budget: rowsOnly(100), pause: {})
        XCTAssertTrue(rerun.completed)
        XCTAssertEqual(rerun.written, 0, "nothing left to fill or heal")
    }
}
