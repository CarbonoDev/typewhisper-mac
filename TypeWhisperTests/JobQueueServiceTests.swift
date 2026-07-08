import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

/// Deterministic unit tests for the meeting background-job queue (job-queue plan J1). No real LLM or
/// transcription is touched: operations are inline stubs, the clock is a fake with a monotonically
/// incrementing `now`, and every test settles on `await queue.drain()` — the same discipline as
/// `MeetingBriefSchedulerTests`. Mid-flight ordering (cancel-while-running, cross-lane parallelism,
/// priority preemption) is driven with a `Gate` and a `waitUntil` spin over `Task.yield()`, so no
/// test depends on wall-clock timing.
@MainActor
final class JobQueueServiceTests: XCTestCase {
    // MARK: - Deterministic fake clock

    /// Monotonically incrementing time source so `createdAt`/`startedAt`/`finishedAt` are distinct and
    /// FIFO tie-breaks are stable. Only ever read on the MainActor (from `JobQueueService`).
    private final class FakeJobClock: MeetingJobClock {
        private var current: Date
        private let step: TimeInterval
        init(start: Date = Date(timeIntervalSince1970: 1_700_000_000), step: TimeInterval = 1) {
            self.current = start
            self.step = step
        }
        var now: Date {
            let value = current
            current = current.addingTimeInterval(step)
            return value
        }
    }

    // MARK: - Gate (a resumable barrier so a stub can "hold" its lane deterministically)

    @MainActor
    private final class Gate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var opened = false
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            guard !opened else { return }
            opened = true
            let current = waiters
            waiters = []
            current.forEach { $0.resume() }
        }
    }

    // MARK: - Recorder (reference type: @Sendable closures cannot capture a mutable local var)

    @MainActor
    private final class Recorder {
        private(set) var started: [String] = []
        private(set) var finished: [String] = []
        private(set) var committed: Set<String> = []
        private var active = 0
        private(set) var maxConcurrent = 0

        func begin(_ id: String) {
            started.append(id)
            active += 1
            maxConcurrent = max(maxConcurrent, active)
        }
        /// The "persist" side-effect a job performs only after its awaited work returns — must NOT
        /// happen when the job is cancelled.
        func commit(_ id: String) { committed.insert(id) }
        func end(_ id: String) {
            active -= 1
            finished.append(id)
        }
    }

    // MARK: - Operation builders

    /// A normal stub: records start, optionally blocks on `gate`, yields (so overlapping serial jobs
    /// would be caught by `maxConcurrent`), commits, ends. Optionally throws (before commit).
    private func op(
        _ id: String,
        recorder: Recorder,
        gate: Gate? = nil,
        throwing error: Error? = nil
    ) -> MeetingJobOperation {
        {
            recorder.begin(id)
            if let gate { await gate.wait() }
            await Task.yield()
            if let error {
                recorder.end(id)
                throw error
            }
            recorder.commit(id)
            recorder.end(id)
        }
    }

    /// A cancellation-aware stub: sleeps long enough that the test cancels it first; the sleep throws
    /// `CancellationError`, so `commit` is never reached.
    private func cancellableOp(_ id: String, recorder: Recorder) -> MeetingJobOperation {
        {
            recorder.begin(id)
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            } catch {
                recorder.end(id)
                throw error
            }
            recorder.commit(id)
            recorder.end(id)
        }
    }

    private struct Boom: LocalizedError {
        var errorDescription: String? { "kaboom" }
    }

    // MARK: - Spin helper

    /// Yield until `condition` holds (or a generous iteration cap trips, failing loudly rather than
    /// hanging). Lets the lane workers and child tasks make progress on the MainActor.
    private func waitUntil(
        _ condition: @escaping () -> Bool,
        _ message: String = "condition never met",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        var iterations = 0
        while !condition() {
            if iterations > 100_000 {
                XCTFail(message, file: file, line: line)
                return
            }
            await Task.yield()
            iterations += 1
        }
    }

    private func makeQueue() -> JobQueueService {
        JobQueueService(clock: FakeJobClock())
    }

    // MARK: - Basic execution

    func testEnqueueRunsOperationAndMarksSucceeded() async throws {
        let queue = makeQueue()
        let recorder = Recorder()
        let id = queue.enqueue(kind: .summary, meetingID: UUID(), operation: op("j", recorder: recorder))

        await queue.drain()

        XCTAssertEqual(recorder.started, ["j"])
        XCTAssertEqual(recorder.committed, ["j"])
        let job = try XCTUnwrap(queue.jobs.first { $0.id == id })
        XCTAssertEqual(job.state, .succeeded)
        XCTAssertNotNil(job.startedAt)
        XCTAssertNotNil(job.finishedAt)
    }

    // MARK: - Lane caps & parallelism

    func testLaneCapOneSerializesLLM() async {
        let queue = makeQueue()
        let recorder = Recorder()
        for i in 0..<3 {
            queue.enqueue(kind: .summary, meetingID: UUID(), operation: op("\(i)", recorder: recorder))
        }

        await queue.drain()

        XCTAssertEqual(recorder.maxConcurrent, 1, "llm lane must run one job at a time")
        XCTAssertEqual(recorder.finished, ["0", "1", "2"], "cap-1 lane completes FIFO")
    }

    func testTranscriptionAndLLMRunInParallelAcrossLanes() async {
        let queue = makeQueue()
        let recorder = Recorder()
        let gate = Gate()
        queue.enqueue(kind: .summary, meetingID: UUID(), operation: op("llm", recorder: recorder, gate: gate))
        queue.enqueue(kind: .audioImport, meetingID: UUID(), operation: op("txn", recorder: recorder, gate: gate))

        // Both lanes have independent workers, so both jobs reach `.running` before either is released.
        await waitUntil({ queue.runningCount == 2 }, "both lanes should run concurrently")
        XCTAssertEqual(queue.runningCount, 2)

        gate.open()
        await queue.drain()
        XCTAssertEqual(Set(recorder.committed), ["llm", "txn"])
    }

    // MARK: - Dedupe

    func testDedupeByKindAndMeetingWhileQueuedOrRunning() async {
        let queue = makeQueue()
        let recorder = Recorder()
        let meetingID = UUID()
        // Two synchronous enqueues: the first sits `.queued`; the second collides on the same
        // (summary, meetingID) key and is dropped, returning the first id.
        let id1 = queue.enqueue(kind: .summary, meetingID: meetingID, operation: op("first", recorder: recorder))
        let id2 = queue.enqueue(kind: .summary, meetingID: meetingID, operation: op("second", recorder: recorder))

        XCTAssertEqual(id1, id2)
        XCTAssertEqual(queue.jobs.count, 1)

        await queue.drain()
        XCTAssertEqual(recorder.started, ["first"], "the deduped second operation must never run")
    }

    func testDifferentKindsSameMeetingNotDeduped() async {
        let queue = makeQueue()
        let recorder = Recorder()
        let meetingID = UUID()
        let id1 = queue.enqueue(kind: .summary, meetingID: meetingID, operation: op("summary", recorder: recorder))
        let id2 = queue.enqueue(kind: .extendedAnalysis, meetingID: meetingID, operation: op("extended", recorder: recorder))

        XCTAssertNotEqual(id1, id2)
        XCTAssertEqual(queue.jobs.count, 2)

        await queue.drain()
        XCTAssertEqual(Set(recorder.committed), ["summary", "extended"])
    }

    func testNilMeetingImportNeverDeduped() async {
        let queue = makeQueue()
        let recorder = Recorder()
        // New-meeting audio imports have no meetingID and a nil dedupe key: two different files must
        // both import.
        let id1 = queue.enqueue(kind: .audioImport, meetingID: nil, operation: op("file-a", recorder: recorder))
        let id2 = queue.enqueue(kind: .audioImport, meetingID: nil, operation: op("file-b", recorder: recorder))

        XCTAssertNotEqual(id1, id2)
        XCTAssertEqual(queue.jobs.count, 2)

        await queue.drain()
        XCTAssertEqual(Set(recorder.committed), ["file-a", "file-b"])
    }

    // MARK: - Priority

    func testUserInitiatedPreemptsQueuedBackgroundInLane() async {
        let queue = makeQueue()
        let recorder = Recorder()
        let gate = Gate()
        // A user-initiated job holds the llm lane on the gate.
        queue.enqueue(kind: .summary, meetingID: UUID(), priority: .userInitiated,
                      operation: op("holder", recorder: recorder, gate: gate))
        await waitUntil({ queue.runningCount == 1 }, "holder should be running")

        // While it holds the lane, enqueue a background then a user-initiated job (both llm lane).
        queue.enqueue(kind: .brief, meetingID: UUID(), priority: .background,
                      operation: op("background", recorder: recorder))
        queue.enqueue(kind: .extendedAnalysis, meetingID: UUID(), priority: .userInitiated,
                      operation: op("userInitiated", recorder: recorder))

        gate.open()
        await queue.drain()

        let uiIndex = try? XCTUnwrap(recorder.started.firstIndex(of: "userInitiated"))
        let bgIndex = try? XCTUnwrap(recorder.started.firstIndex(of: "background"))
        XCTAssertNotNil(uiIndex)
        XCTAssertNotNil(bgIndex)
        if let uiIndex, let bgIndex {
            XCTAssertLessThan(uiIndex, bgIndex, "userInitiated must run before a queued background job")
        }
    }

    // MARK: - Cancellation

    func testCancelQueuedNeverRunsOperation() async {
        let queue = makeQueue()
        let recorder = Recorder()
        let gate = Gate()
        // A holder occupies the (cap-1) llm lane so the target stays `.queued`.
        queue.enqueue(kind: .summary, meetingID: UUID(), operation: op("holder", recorder: recorder, gate: gate))
        await waitUntil({ queue.runningCount == 1 }, "holder should be running")

        let target = queue.enqueue(kind: .summary, meetingID: UUID(), operation: op("target", recorder: recorder))
        XCTAssertEqual(queue.jobs.first { $0.id == target }?.state, .queued)

        queue.cancel(target)
        XCTAssertEqual(queue.jobs.first { $0.id == target }?.state, .cancelled)

        gate.open()
        await queue.drain()
        XCTAssertFalse(recorder.started.contains("target"), "a cancelled-while-queued job never runs")
    }

    func testCancelRunningPropagatesTaskCancellation() async {
        let queue = makeQueue()
        let recorder = Recorder()
        let id = queue.enqueue(kind: .summary, meetingID: UUID(), operation: cancellableOp("job", recorder: recorder))

        await waitUntil({ queue.runningCount == 1 }, "job should be running before cancel")
        queue.cancel(id)
        await queue.drain()

        XCTAssertEqual(queue.jobs.first { $0.id == id }?.state, .cancelled)
        XCTAssertFalse(recorder.committed.contains("job"), "the commit side-effect must not happen on cancel")
    }

    // MARK: - Failure & retry

    func testFailedOperationMarksFailedWithMessage() async {
        let queue = makeQueue()
        let recorder = Recorder()
        let id = queue.enqueue(kind: .summary, meetingID: UUID(),
                               operation: op("boom", recorder: recorder, throwing: Boom()))

        await queue.drain()

        XCTAssertEqual(queue.jobs.first { $0.id == id }?.state, .failed(message: "kaboom"))
        XCTAssertFalse(recorder.committed.contains("boom"))
    }

    func testRetryReenqueuesFailedJob() async throws {
        let queue = makeQueue()
        let recorder = Recorder()
        // Fails the first run, succeeds when retried (re-runs the same stored operation closure).
        let id = queue.enqueue(kind: .summary, meetingID: UUID()) {
            recorder.begin("run")
            if recorder.started.count == 1 {
                recorder.end("run")
                throw Boom()
            }
            recorder.commit("run")
            recorder.end("run")
        }

        await queue.drain()
        XCTAssertEqual(queue.jobs.first { $0.id == id }?.state, .failed(message: "kaboom"))

        let retryID = try XCTUnwrap(queue.retry(id))
        XCTAssertNotEqual(retryID, id)

        await queue.drain()
        XCTAssertEqual(recorder.started.count, 2, "retry re-runs the stored operation")
        XCTAssertEqual(queue.jobs.first { $0.id == retryID }?.state, .succeeded)
        XCTAssertTrue(recorder.committed.contains("run"))
    }

    // MARK: - Drain

    func testDrainReturnsWhenAllLanesIdle() async {
        let queue = makeQueue()
        // Draining an empty queue returns immediately.
        await queue.drain()
        XCTAssertEqual(queue.runningCount, 0)
        XCTAssertEqual(queue.queuedCount, 0)

        let recorder = Recorder()
        queue.enqueue(kind: .summary, meetingID: UUID(), operation: op("a", recorder: recorder))
        queue.enqueue(kind: .audioImport, meetingID: UUID(), operation: op("b", recorder: recorder))

        await queue.drain()
        XCTAssertEqual(queue.runningCount, 0)
        XCTAssertEqual(queue.queuedCount, 0)
        XCTAssertTrue(queue.jobs.allSatisfy { !$0.state.isActive })
    }

    // MARK: - Dedupe priority promotion (J2 review finding 2 / plan J3)

    func testUserInitiatedDedupePromotesQueuedBackgroundJob() async throws {
        let queue = makeQueue()
        let recorder = Recorder()
        let gate = Gate()
        let meetingID = UUID()

        // A user-initiated job holds the (cap-1) llm lane so the briefs below stay `.queued`.
        queue.enqueue(kind: .summary, meetingID: UUID(),
                      operation: op("holder", recorder: recorder, gate: gate))
        await waitUntil({ queue.runningCount == 1 }, "holder should be running")

        // The auto-brief scheduler queues a background brief first.
        let bgID = queue.enqueue(kind: .brief, meetingID: meetingID, priority: .background,
                                 operation: op("brief", recorder: recorder))
        XCTAssertEqual(queue.jobs.first { $0.id == bgID }?.priority, .background)

        // The user then picks the brief template: it dedupes on the shared (brief, meetingID) key and
        // must PROMOTE the queued background job to userInitiated (finding 2), returning its id.
        let dupID = queue.enqueue(kind: .brief, meetingID: meetingID, priority: .userInitiated,
                                  operation: op("brief-dup", recorder: recorder))
        XCTAssertEqual(dupID, bgID, "user brief dedupes against the queued auto-brief")
        XCTAssertEqual(queue.jobs.first { $0.id == bgID }?.priority, .userInitiated,
                       "the queued background job is promoted so the user isn't stuck behind it")
        XCTAssertEqual(queue.jobs.count, 2, "no second brief job is created")

        gate.open()
        await queue.drain()
        // Only the original (deduped) operation ever runs — exactly once.
        XCTAssertEqual(recorder.started.filter { $0.hasPrefix("brief") }, ["brief"])
        XCTAssertTrue(recorder.committed.contains("brief"))
        XCTAssertFalse(recorder.started.contains("brief-dup"))
    }

    // MARK: - Settled-job history (plan J3)

    func testDismissRemovesSettledJob() async throws {
        let queue = makeQueue()
        let recorder = Recorder()
        let id = queue.enqueue(kind: .summary, meetingID: UUID(),
                               operation: op("boom", recorder: recorder, throwing: Boom()))
        await queue.drain()
        XCTAssertEqual(queue.jobs.first { $0.id == id }?.state, .failed(message: "kaboom"))

        queue.dismiss(id)
        XCTAssertNil(queue.jobs.first { $0.id == id }, "dismiss removes a settled job from the list")
    }

    func testDismissIsNoOpForAnActiveJob() async {
        let queue = makeQueue()
        let recorder = Recorder()
        let gate = Gate()
        let id = queue.enqueue(kind: .summary, meetingID: UUID(),
                               operation: op("holder", recorder: recorder, gate: gate))
        await waitUntil({ queue.runningCount == 1 }, "holder should be running")

        queue.dismiss(id)
        XCTAssertNotNil(queue.jobs.first { $0.id == id }, "an active job cannot be dismissed")

        gate.open()
        await queue.drain()
    }

    func testSucceededJobsPrunedFromHistory() async {
        let queue = makeQueue()
        let recorder = Recorder()
        // 25 succeeded jobs on the cap-1 llm lane (serial). The retained history is bounded at 20, so
        // the oldest succeeded jobs are evicted while every job still runs.
        for i in 0..<25 {
            queue.enqueue(kind: .summary, meetingID: UUID(), operation: op("\(i)", recorder: recorder))
        }
        await queue.drain()

        XCTAssertEqual(recorder.finished.count, 25, "all 25 jobs still ran")
        let succeeded = queue.jobs.filter { $0.state == .succeeded }
        XCTAssertEqual(succeeded.count, 20, "succeeded history is pruned to the bound")
    }

    func testFailedJobRetainedUntilDismissedOrRetried() async throws {
        let queue = makeQueue()
        let recorder = Recorder()
        // A single failed job, then a burst of succeeded jobs that would exceed the history bound.
        let failID = queue.enqueue(kind: .summary, meetingID: UUID(),
                                   operation: op("boom", recorder: recorder, throwing: Boom()))
        await queue.drain()
        for i in 0..<25 {
            queue.enqueue(kind: .summary, meetingID: UUID(), operation: op("s\(i)", recorder: recorder))
        }
        await queue.drain()

        // Failed jobs are exempt from succeeded/cancelled pruning — the popover needs them for Retry.
        XCTAssertEqual(queue.jobs.first { $0.id == failID }?.state, .failed(message: "kaboom"),
                       "a failed job survives pruning of succeeded jobs")

        // Retrying clears the source failed row (retained only until dismissed or retried).
        let retryID = try XCTUnwrap(queue.retry(failID))
        XCTAssertNotEqual(retryID, failID)
        XCTAssertNil(queue.jobs.first { $0.id == failID }, "retry clears the source failed job")
        await queue.drain()
    }

    // MARK: - Routing (queue → real MeetingLLMService → stub processor; no real LLM)

    /// The `PromptProcessing` seam, blocked on a gate so the test can observe the meeting-scoped
    /// spinner while the LLM call is in flight.
    @MainActor
    private final class BlockingProcessor: PromptProcessing {
        var selectedProviderId = "provider"
        var selectedCloudModel = "model"
        private(set) var callCount = 0
        private let gate: Gate
        init(gate: Gate) { self.gate = gate }

        func process(
            prompt: String,
            text: String,
            providerOverride: String?,
            cloudModelOverride: String?,
            temperatureDirective: PluginLLMTemperatureDirective,
            skipMemoryInjection: Bool
        ) async throws -> String {
            callCount += 1
            await gate.wait()
            return "GENERATED"
        }
    }

    private func makeVault() -> ObsidianVaultService {
        let suite = "JobQueueServiceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return ObsidianVaultService(defaults: defaults)
    }

    private func makeSummaryTemplate() -> PromptAction {
        PromptAction(
            name: "Summary",
            prompt: "Summarize.",
            temperatureModeRaw: PluginLLMTemperatureMode.inheritProviderSetting.rawValue,
            surfaceRaw: PromptSurface.meeting.rawValue,
            meetingKindRaw: MeetingOutputKind.summary.rawValue
        )
    }

    func testRoutingScopesSpinnerAndDedupesToOneOutput() async throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "JobQueueRouting")
        addTeardownBlock { TestSupport.remove(dir) }
        let service = MeetingService(appSupportDirectory: dir)
        let gate = Gate()
        let processor = BlockingProcessor(gate: gate)
        let llm = MeetingLLMService(meetingService: service, vaultService: makeVault(), processor: processor)
        let queue = makeQueue()

        let meeting = service.createMeeting(title: "Sync", source: .adHoc, state: .completed)
        service.appendStableSegments([TranscriptionSegment(text: "Hello team.", start: 0, end: 2)], to: meeting)

        // Route exactly like MeetingsViewModel.generateOutput: a summary job wrapping the service call.
        func enqueueSummary() -> UUID {
            let template = makeSummaryTemplate()
            return queue.enqueue(kind: .summary, meetingID: meeting.id) { [weak llm] in
                _ = try await llm?.generateOutput(for: meeting, using: template)
            }
        }
        let id1 = enqueueSummary()
        // A second click while the first is still active is deduped.
        let id2 = enqueueSummary()
        XCTAssertEqual(id1, id2)

        await waitUntil({ queue.runningCount == 1 }, "generation should be running")
        XCTAssertTrue(queue.hasActiveJob(inLane: .llm, meetingID: meeting.id), "spinner is on while generating")
        XCTAssertFalse(queue.hasActiveJob(inLane: .llm, meetingID: UUID()), "spinner is meeting-scoped")

        gate.open()
        await queue.drain()

        XCTAssertFalse(queue.hasActiveJob(inLane: .llm, meetingID: meeting.id), "spinner clears when idle")
        XCTAssertEqual(processor.callCount, 1, "double-click produces exactly one LLM call")
        XCTAssertNotNil(service.latestOutput(ofKind: .summary, for: meeting), "one output persisted")
    }
}
