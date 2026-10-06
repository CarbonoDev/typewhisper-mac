import XCTest
import SwiftData
@testable import TypeWhisper

/// Perf plan Phase 3 — persistent-history pruning over a **real on-disk** meetings store, opened
/// through the production path (`MeetingService` → `SwiftDataStoreFactory`). The prune may only drop
/// history: every meeting, segment and output must survive it and a reopen from disk (which would
/// also expose a factory schema reset as an empty store).
@MainActor
final class PersistentHistoryPrunerTests: XCTestCase {
    @available(macOS 15, *)
    private func historyChangeCount(_ container: ModelContainer) throws -> Int {
        let transactions = try ModelContext(container)
            .fetchHistory(HistoryDescriptor<DefaultHistoryTransaction>())
        return transactions.reduce(0) { $0 + $1.changes.count }
    }

    private func registeredContainer(storeAt url: URL) throws -> ModelContainer {
        let match = PersistentHistoryPruner.registeredContainers().last { entry in
            entry.container.configurations.contains { $0.url.standardizedFileURL == url.standardizedFileURL }
        }
        return try XCTUnwrap(match?.container, "factory did not register the store at \(url.path)")
    }

    private func seed(_ service: MeetingService) -> Meeting {
        let meeting = service.createMeeting(title: "Kept", source: .adHoc, state: .completed)
        service.appendStableSegments(
            (0..<40).map { TranscriptionSegment(text: "line \($0)", start: Double($0), end: Double($0) + 1) },
            to: meeting
        )
        service.appendStableSegments([TranscriptionSegment(text: "tail", start: 40, end: 41)], to: meeting)
        _ = service.addOutput(to: meeting, kind: .summary, content: "SUMMARY")
        return meeting
    }

    func testPruneDropsOldHistoryAndKeepsEveryRowAcrossReopen() async throws {
        guard #available(macOS 15, *) else { throw XCTSkip("SwiftData history API needs macOS 15") }
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "HistoryPrune")
        addTeardownBlock { TestSupport.remove(dir) }

        let service = MeetingService(appSupportDirectory: dir)
        let meeting = seed(service)
        let meetingID = meeting.id
        let container = try registeredContainer(storeAt: dir.appendingPathComponent("meetings.store"))

        let before = try historyChangeCount(container)
        XCTAssertGreaterThan(before, 40, "every save recorded history")

        // The retention window holds: nothing older than an hour ago exists yet, so nothing goes.
        try await PersistentHistoryPruner.prune(container, olderThan: Date().addingTimeInterval(-3_600))
        XCTAssertEqual(try historyChangeCount(container), before)

        // Past the window, the history goes...
        try await PersistentHistoryPruner.prune(container, olderThan: Date().addingTimeInterval(1))
        XCTAssertEqual(try historyChangeCount(container), 0, "history pruned")

        // ...and every row stays, in the live store...
        let live = try XCTUnwrap(service.meetings.first { $0.id == meetingID })
        XCTAssertEqual(live.segments.count, 41)
        XCTAssertEqual(live.outputs.count, 1)

        // ...and on disk: a fresh open (which resets the file on an incompatible schema) sees it all.
        let reopened = MeetingService(appSupportDirectory: dir)
        let fromDisk = try XCTUnwrap(reopened.meetings.first { $0.id == meetingID })
        XCTAssertEqual(reopened.meetings.count, 1)
        XCTAssertEqual(fromDisk.segments.count, 41)
        XCTAssertEqual(fromDisk.segments.map(\.text).sorted().first, "line 0")
        XCTAssertEqual(fromDisk.outputs.first?.content, "SUMMARY")

        // Writes keep working (and recording history) after a prune.
        reopened.appendStableSegments([TranscriptionSegment(text: "after", start: 41, end: 42)], to: fromDisk)
        XCTAssertEqual(fromDisk.segments.count, 42)
        let reopenedContainer = try registeredContainer(storeAt: dir.appendingPathComponent("meetings.store"))
        XCTAssertGreaterThan(try historyChangeCount(reopenedContainer), 0)
    }

    /// The launch entry point reaches the factory's registered stores and leaves their rows intact.
    func testPruneRegisteredStoresKeepsRows() async throws {
        guard #available(macOS 15, *) else { throw XCTSkip("SwiftData history API needs macOS 15") }
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "HistoryPruneAll")
        addTeardownBlock { TestSupport.remove(dir) }
        let service = MeetingService(appSupportDirectory: dir)
        let meetingID = seed(service).id
        let container = try registeredContainer(storeAt: dir.appendingPathComponent("meetings.store"))

        await PersistentHistoryPruner.pruneRegisteredStores(retention: -1)

        XCTAssertEqual(try historyChangeCount(container), 0)
        XCTAssertEqual(service.meetings.first { $0.id == meetingID }?.segments.count, 41)
    }

    func testMainRunLoopIdleResumes() async {
        let resumed = expectation(description: "resumed on the next run-loop idle")
        Task { @MainActor in
            await LaunchMetrics.mainRunLoopIdle()
            resumed.fulfill()
        }
        await fulfillment(of: [resumed], timeout: 5)
    }
}
