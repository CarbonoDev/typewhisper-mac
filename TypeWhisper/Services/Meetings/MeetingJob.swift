import Foundation

/// The kind of long-running, per-meeting background work a `MeetingJob` represents (job-queue plan
/// §0.1). Every kind maps to exactly one execution `lane`.
enum MeetingJobKind: String, Sendable, CaseIterable {
    case summary
    case extendedAnalysis
    case brief
    case finalTranscription
    case audioImport
    case diarization
    case export

    /// The serial-execution lane a kind runs in (plan §0.1 lane table). LLM generation, transcription
    /// work, and I/O each get their own lane so they never contend across categories.
    var lane: MeetingJobLane {
        switch self {
        case .summary, .extendedAnalysis, .brief:
            return .llm
        case .finalTranscription, .audioImport, .diarization:
            return .transcription
        case .export:
            return .io
        }
    }
}

/// The lane a job runs in (plan §0.1). `llm` and `transcription` are cap-1 (serialized); `io` is
/// unbounded. Only `llm` is exercised in J1 (summary / extended analysis).
enum MeetingJobLane: String, Sendable, CaseIterable {
    case llm
    case transcription
    case io
}

/// Queue-ordering hint within a lane (plan §0.5). Within a lane the driver picks `userInitiated`
/// before `background`, ties broken by `createdAt` (FIFO). A running job is never preempted.
enum MeetingJobPriority: Int, Sendable {
    case background = 0
    case userInitiated = 1
}

/// The lifecycle state of a job (plan §0.1). `queued`/`running` are "active"; `succeeded`/`cancelled`/
/// `failed` are settled and no longer block a new enqueue with the same dedupe key.
enum MeetingJobState: Equatable, Sendable {
    case queued
    case running
    case succeeded
    case cancelled
    case failed(message: String)

    /// Whether the job is still occupying the queue (queued or running) — the states that block a
    /// duplicate enqueue and drive the activity indicator counts.
    var isActive: Bool {
        switch self {
        case .queued, .running:
            return true
        case .succeeded, .cancelled, .failed:
            return false
        }
    }
}

/// Dedupe identity for a queued/running job (plan §0.4). A new `enqueue` with an equal key while a
/// job is `queued` or `running` is dropped and returns the existing job's id. A `nil` key is never
/// deduped (new-meeting `audioImport`, which has no `meetingID` yet).
struct MeetingJobDedupeKey: Equatable, Sendable {
    let kind: MeetingJobKind
    let meetingID: UUID
}

/// An immutable value snapshot of a background job, published to the UI (plan §0.1). The execution
/// closure and cancellation handle are held off the value type inside `JobQueueService`.
struct MeetingJob: Identifiable, Sendable {
    let id: UUID
    let kind: MeetingJobKind
    /// `nil` only for a new-meeting `audioImport` (no meeting exists yet). All J1 kinds carry one.
    let meetingID: UUID?
    var state: MeetingJobState
    let priority: MeetingJobPriority
    let createdAt: Date
    var startedAt: Date?
    var finishedAt: Date?
    var progressLabel: String?
    /// `nil` ⇒ never deduped (see §0.4).
    var dedupeKey: MeetingJobDedupeKey?

    var lane: MeetingJobLane { kind.lane }
}
