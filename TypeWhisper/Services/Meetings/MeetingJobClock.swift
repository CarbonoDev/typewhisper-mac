import Foundation

/// Injectable time source for `JobQueueService` (job-queue plan §0.2) so `createdAt`/`startedAt`/
/// `finishedAt` are deterministic under test. Production uses `SystemJobClock`; tests inject a fake
/// clock with a monotonically incrementing `now`.
protocol MeetingJobClock {
    var now: Date { get }
}

/// Wall-clock time source used in production.
struct SystemJobClock: MeetingJobClock {
    var now: Date { Date() }
}
