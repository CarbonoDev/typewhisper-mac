import Foundation
import Combine
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "JobQueueService")

/// A unit of background work handed to the queue. `@MainActor` because every meeting service it wraps
/// (`MeetingLLMService`, …) is main-actor isolated; the heavy work already hops off-main *inside*
/// those services, so awaiting them here never blocks the main thread (plan Decisions).
typealias MeetingJobOperation = @MainActor @Sendable () async throws -> Void

/// Central in-memory queue that owns long-running, per-meeting background work (job-queue plan J1).
/// Lane-based serial drivers (cap 1 for `llm`/`transcription`, unbounded for `io`) run at most one
/// job per capped lane; dedupe by `(kind, meetingID)` drops a second enqueue while one is in flight;
/// priority orders the queue within a lane. Cancellation propagates through Task cancellation. The
/// published `jobs` value snapshot is the single source the UI reads (meeting-scoped via
/// `jobs(for:)`, so spinners never follow navigation). In-memory only — nothing is persisted.
@MainActor
final class JobQueueService: ObservableObject {
    /// Singleton-adjacent like the view models: assigned by `ServiceContainer` so leaf views can
    /// `@ObservedObject` it directly for reactive updates without threading it through every VM.
    nonisolated(unsafe) static var _shared: JobQueueService?
    static var shared: JobQueueService {
        guard let instance = _shared else {
            fatalError("JobQueueService not initialized")
        }
        return instance
    }

    /// Ordered value snapshot the UI reads. Mutating an element republishes.
    @Published private(set) var jobs: [MeetingJob] = []

    /// The execution closure per job, kept off the published value type. Retained after completion so
    /// a `retry` can re-run it (plan §0.2).
    private var operations: [UUID: MeetingJobOperation] = [:]
    /// The running child `Task` per job — the cancellation handle (plan §0.2 / Decisions).
    private var handles: [UUID: Task<Void, Never>] = [:]
    /// The per-lane serial driver, spawned lazily and self-retiring when the lane's queue empties.
    private var laneWorkers: [MeetingJobLane: Task<Void, Never>] = [:]
    /// Injected time source (fake in tests) so timestamps are deterministic (plan §0.2).
    private let clock: any MeetingJobClock

    init(clock: any MeetingJobClock = SystemJobClock()) {
        self.clock = clock
    }

    // MARK: - Public API

    /// Append a `.queued` job and start its lane worker. If a job with an equal dedupe key is already
    /// `queued`/`running`, the request is dropped and the existing job's id is returned — no second
    /// closure ever runs (plan §0.4). The default dedupe key is derived from `(kind, meetingID)`;
    /// pass `dedupe` to override, or rely on `nil` (never deduped) when there is no `meetingID`.
    @discardableResult
    func enqueue(
        kind: MeetingJobKind,
        meetingID: UUID?,
        priority: MeetingJobPriority = .userInitiated,
        dedupe: MeetingJobDedupeKey? = nil,
        progressLabel: String? = nil,
        operation: @escaping MeetingJobOperation
    ) -> UUID {
        let key = dedupe ?? meetingID.map { MeetingJobDedupeKey(kind: kind, meetingID: $0) }

        if let key, let existing = jobs.first(where: { $0.dedupeKey == key && $0.state.isActive }) {
            logger.debug("Deduped enqueue for \(kind.rawValue, privacy: .public); returning existing job")
            return existing.id
        }

        let id = UUID()
        let job = MeetingJob(
            id: id,
            kind: kind,
            meetingID: meetingID,
            state: .queued,
            priority: priority,
            createdAt: clock.now,
            startedAt: nil,
            finishedAt: nil,
            progressLabel: progressLabel,
            dedupeKey: key
        )
        jobs.append(job)
        operations[id] = operation
        startLaneWorkerIfNeeded(kind.lane)
        return id
    }

    /// Cancel a queued or running job. A queued job never ran its closure, so it is marked
    /// `.cancelled` in place. A running job's child `Task` is cancelled; its own catch classifies the
    /// resulting throw as `.cancelled` (plan §Cancellation semantics). Settled jobs are ignored.
    func cancel(_ jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        switch jobs[index].state {
        case .queued:
            jobs[index].state = .cancelled
            jobs[index].finishedAt = clock.now
        case .running:
            handles[jobID]?.cancel()
        case .succeeded, .cancelled, .failed:
            break
        }
    }

    /// Re-enqueue a settled job's retained operation as a fresh `.queued` job in the same lane with
    /// the same dedupe key (plan §0.2). No-op for an active job or one whose operation is gone.
    @discardableResult
    func retry(_ jobID: UUID) -> UUID? {
        guard let job = jobs.first(where: { $0.id == jobID }), !job.state.isActive,
              let operation = operations[jobID] else { return nil }
        return enqueue(
            kind: job.kind,
            meetingID: job.meetingID,
            priority: job.priority,
            dedupe: job.dedupeKey,
            progressLabel: job.progressLabel,
            operation: operation
        )
    }

    /// Pure, meeting-scoped filter (navigation-proof): the jobs belonging to one meeting.
    func jobs(for meetingID: UUID) -> [MeetingJob] {
        jobs.filter { $0.meetingID == meetingID }
    }

    /// Whether an active (queued/running) job of `kind` exists for `meetingID`.
    func hasActiveJob(kind: MeetingJobKind, meetingID: UUID) -> Bool {
        jobs.contains { $0.kind == kind && $0.meetingID == meetingID && $0.state.isActive }
    }

    /// Whether any active (queued/running) job in `lane` exists for `meetingID`. Lane-level so the
    /// bottom-bar Generate spinner already reflects a brief-in-progress once J2 routes it (plan §CC1).
    func hasActiveJob(inLane lane: MeetingJobLane, meetingID: UUID) -> Bool {
        jobs.contains { $0.lane == lane && $0.meetingID == meetingID && $0.state.isActive }
    }

    var runningCount: Int { jobs.reduce(0) { $0 + ($1.state == .running ? 1 : 0) } }
    var queuedCount: Int { jobs.reduce(0) { $0 + ($1.state == .queued ? 1 : 0) } }

    // MARK: - Testing seam

    /// Await every lane worker (and any in-flight `io` job) to quiescence — the deterministic settle
    /// point tests use (plan §0.3).
    func drain() async {
        while true {
            let workers = Array(laneWorkers.values)
            let running = Array(handles.values)
            if workers.isEmpty && running.isEmpty { break }
            for worker in workers { await worker.value }
            for handle in running { await handle.value }
        }
    }

    // MARK: - Lane drivers

    /// The cap for a lane: 1 for `llm`/`transcription` (serial), `nil` = unbounded for `io`.
    private func capacity(for lane: MeetingJobLane) -> Int? {
        switch lane {
        case .llm, .transcription:
            return 1
        case .io:
            return nil
        }
    }

    private func startLaneWorkerIfNeeded(_ lane: MeetingJobLane) {
        guard laneWorkers[lane] == nil else { return }
        laneWorkers[lane] = Task { [weak self] in
            await self?.runLane(lane)
        }
    }

    /// Serial driver for one lane. A capped lane runs (and awaits) one job at a time; the unbounded
    /// `io` lane launches each queued job immediately without awaiting. Self-retires when no runnable
    /// job remains (plan §0.3).
    private func runLane(_ lane: MeetingJobLane) async {
        defer { laneWorkers[lane] = nil }
        let cap = capacity(for: lane)
        while let next = nextQueuedJob(in: lane) {
            guard let operation = operations[next.id] else {
                // No closure to run (should not happen) — drop it from the queue so we don't spin.
                markSettled(next.id, state: .cancelled)
                continue
            }
            if cap != nil {
                await runJob(next.id, operation: operation)
            } else {
                launchJob(next.id, operation: operation)
            }
        }
    }

    /// The next queued job in a lane: `userInitiated` before `background`, ties broken FIFO by
    /// `createdAt` (plan §0.5).
    private func nextQueuedJob(in lane: MeetingJobLane) -> MeetingJob? {
        jobs
            .filter { $0.lane == lane && $0.state == .queued }
            .min { lhs, rhs in
                if lhs.priority.rawValue != rhs.priority.rawValue {
                    return lhs.priority.rawValue > rhs.priority.rawValue
                }
                return lhs.createdAt < rhs.createdAt
            }
    }

    /// Flip a job `.running`, spawn its child Task, store the handle, and await it (serial lanes).
    private func runJob(_ jobID: UUID, operation: @escaping MeetingJobOperation) async {
        launchJob(jobID, operation: operation)
        await handles[jobID]?.value
    }

    /// Flip a job `.running` and spawn its child Task without awaiting (unbounded lane).
    private func launchJob(_ jobID: UUID, operation: @escaping MeetingJobOperation) {
        updateJob(jobID) { job in
            job.state = .running
            job.startedAt = clock.now
        }
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await operation()
                self.markSettled(jobID, state: Task.isCancelled ? .cancelled : .succeeded)
            } catch is CancellationError {
                self.markSettled(jobID, state: .cancelled)
            } catch {
                // A throw caused by cancellation (e.g. URLError.cancelled) is classified as cancelled,
                // not failed (plan §Cancellation semantics).
                let state: MeetingJobState = Task.isCancelled
                    ? .cancelled
                    : .failed(message: error.localizedDescription)
                self.markSettled(jobID, state: state)
            }
        }
        handles[jobID] = task
    }

    private func markSettled(_ jobID: UUID, state: MeetingJobState) {
        updateJob(jobID) { job in
            job.state = state
            job.finishedAt = clock.now
        }
        handles[jobID] = nil
    }

    private func updateJob(_ jobID: UUID, _ mutate: (inout MeetingJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        mutate(&jobs[index])
    }
}
