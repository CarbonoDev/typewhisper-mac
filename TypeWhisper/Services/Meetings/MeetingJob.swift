import Foundation

/// The kind of long-running, per-meeting background work a `MeetingJob` represents (job-queue plan
/// §0.1). Every kind maps to exactly one execution `lane`.
enum MeetingJobKind: String, Sendable, CaseIterable {
    case summary
    case extendedAnalysis
    case brief
    case languageDetection
    /// Agentic related-vault-document discovery (Amendment 2, DB1): one single-turn LLM judge call.
    case relatedDiscovery
    case finalTranscription
    case audioImport
    case diarization
    case export

    /// The serial-execution lane a kind runs in (plan §0.1 lane table). LLM generation, transcription
    /// work, and I/O each get their own lane so they never contend across categories.
    var lane: MeetingJobLane {
        switch self {
        case .summary, .extendedAnalysis, .brief, .languageDetection, .relatedDiscovery:
            // Language detection and related-docs discovery are single-turn LLM calls (plan D5;
            // Amendment 2, DB1) — they share the cap-1 `llm` lane so they are never concurrent with a
            // user generation, and a discovery enqueued ahead of an auto-brief runs first (DB6).
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
    /// `var` (not `let`) so the queue can promote a queued `.background` job to `.userInitiated` when
    /// a user-initiated enqueue dedupes against it (J2 review finding 2 / plan §0.4-0.5): the user
    /// must not wait behind background work that produces the same output.
    var priority: MeetingJobPriority
    let createdAt: Date
    var startedAt: Date?
    var finishedAt: Date?
    var progressLabel: String?
    /// `nil` ⇒ never deduped (see §0.4).
    var dedupeKey: MeetingJobDedupeKey?

    var lane: MeetingJobLane { kind.lane }
}

// MARK: - Presentation (job-queue plan J3)

extension MeetingJobKind {
    /// The localized, user-facing label for this kind of work, shown in the activity popover and on
    /// the Home timeline "working" badge (plan J3 §EN+DE key table).
    var displayName: String {
        switch self {
        case .summary: return String(localized: "meetings.jobs.kind.summary")
        case .extendedAnalysis: return String(localized: "meetings.jobs.kind.extendedAnalysis")
        case .brief: return String(localized: "meetings.jobs.kind.brief")
        case .languageDetection: return String(localized: "meetings.jobs.kind.languageDetection")
        case .relatedDiscovery: return String(localized: "meetings.jobs.kind.relatedDiscovery")
        case .finalTranscription: return String(localized: "meetings.jobs.kind.finalTranscription")
        case .audioImport: return String(localized: "meetings.jobs.kind.audioImport")
        case .diarization: return String(localized: "meetings.jobs.kind.diarization")
        case .export: return String(localized: "meetings.jobs.kind.export")
        }
    }
}

/// The activity popover's grouped view of the queue: running first, then queued, then recently-failed
/// (plan J3). A pure value derived from a `[MeetingJob]` snapshot so the sectioning and ordering are
/// unit-testable without SwiftUI.
struct MeetingJobSections {
    var running: [MeetingJob]
    var queued: [MeetingJob]
    var failed: [MeetingJob]

    var isEmpty: Bool { running.isEmpty && queued.isEmpty && failed.isEmpty }
}

/// Pure presentation logic for background jobs (plan J3). Lives off the view so the popover sectioning,
/// kind labels, and cancellability rules are deterministic and testable.
enum MeetingJobPresentation {
    /// Section a job snapshot into running / queued / recently-failed groups. Running is ordered by
    /// start time (oldest first); queued mirrors the driver's own order (`userInitiated` before
    /// `background`, then FIFO by `createdAt`); failed is newest-first so the most recent failure is
    /// on top.
    static func sections(from jobs: [MeetingJob]) -> MeetingJobSections {
        let running = jobs
            .filter { $0.state == .running }
            .sorted { ($0.startedAt ?? $0.createdAt) < ($1.startedAt ?? $1.createdAt) }
        let queued = jobs
            .filter { $0.state == .queued }
            .sorted { lhs, rhs in
                if lhs.priority.rawValue != rhs.priority.rawValue {
                    return lhs.priority.rawValue > rhs.priority.rawValue
                }
                return lhs.createdAt < rhs.createdAt
            }
        let failed = jobs
            .filter { if case .failed = $0.state { return true } else { return false } }
            .sorted { ($0.finishedAt ?? $0.createdAt) > ($1.finishedAt ?? $1.createdAt) }
        return MeetingJobSections(running: running, queued: queued, failed: failed)
    }

    /// Whether the activity popover may offer a Cancel button for an active job.
    ///
    /// Two kinds are non-cancellable from the popover:
    /// - `.export` runs inline on the `io` lane and completes instantly — there is nothing to cancel.
    /// - a **queued** `.finalTranscription` (J2 review finding 1): cancelling a queued final pass would
    ///   mark the job `.cancelled` *without ever running `runFinalization`*, stranding the meeting in
    ///   `.processing` forever. A *running* final pass is cancellable (its `runFinalization` keeps the
    ///   live segments and still completes the meeting). While queued the button is withheld with a
    ///   localized hint; the transcription lane is cap-1 so the queued window is short.
    static func canCancel(_ job: MeetingJob) -> Bool {
        guard job.state.isActive else { return false }
        if job.kind == .export { return false }
        if job.kind == .finalTranscription && job.state == .queued { return false }
        return true
    }
}
