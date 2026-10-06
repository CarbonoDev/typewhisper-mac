import Foundation

/// [Perf Phase 2] Everything one meeting row draws, as a plain value. Rows render from this instead
/// of reading a live SwiftData `Meeting` (and observing the singleton view model) on every body
/// evaluation, so an unrelated republish no longer re-runs every visible row: a row whose model is
/// unchanged is skipped by SwiftUI's equality check.
///
/// Two halves with different lifetimes:
/// - **Stored facts** (title, dates, state, organization, attendee count, transcript/brief presence)
///   only change on a `MeetingService` write, which bumps `updatedAt` — so `MeetingRowModelStore`
///   derives them once per `(id, updatedAt)`.
/// - **Volatile facts** (open action items, running long, the working badge, the duplicate flag)
///   depend on state outside the meeting row (the checklist store, the clock, the job queue, the
///   displayed list) and are recomputed on each build — each from an already-memoized source.
struct MeetingRowModel: Equatable, Identifiable {
    let id: UUID

    /// The display title (imported export filenames read as the meetings they are).
    var title: String
    /// The stored start, else the date embedded in an imported export filename.
    var startDate: Date?
    /// The date the archive sorts and shows by: `startDate`, else creation.
    var effectiveDate: Date
    var state: MeetingState
    var isImported: Bool
    /// The trimmed folder path; `nil` when unfiled.
    var folder: String?
    var tags: [String]
    var attendeeCount: Int
    var hasTranscript: Bool
    var hasBrief: Bool

    /// Open/total action items (completed meetings only, as both rows have always shown them).
    var actionFacts: MeetingActionFacts?
    var isRunningLong: Bool
    var workingBadge: MeetingActivityBadge?
    var isDuplicate: Bool

    /// The timeline's state badges after the Sprint 2 "badge diet": running long always, brief
    /// ready only before the meeting happens. Same order as `MeetingsViewModel.homeBadges`.
    var timelineBadges: [MeetingBadge] {
        var badges: [MeetingBadge] = []
        if isRunningLong { badges.append(.runningLong) }
        if hasBrief, state == .scheduled { badges.append(.briefReady) }
        return badges
    }
}

/// [Perf Phase 2] Builds `MeetingRowModel`s for the meeting lists, deriving each row's stored facts
/// once per `(id, updatedAt)` — the invalidation key every meeting-fact cache already uses
/// (`MeetingService` bumps `updatedAt` on each write that changes a row). Main-actor because it reads
/// SwiftData models; not observable, since the lists that call it already observe their inputs.
@MainActor
final class MeetingRowModelStore {
    static let shared = MeetingRowModelStore()

    /// The `updatedAt`-keyed half of a row.
    struct StoredFacts: Equatable {
        var updatedAt: Date
        var title: String
        var startDate: Date?
        var effectiveDate: Date
        var state: MeetingState
        var isImported: Bool
        var folder: String?
        var tags: [String]
        var attendeeCount: Int
        var hasTranscript: Bool
        var hasBrief: Bool
        var endDate: Date?
    }

    private var cache: [UUID: StoredFacts] = [:]
    /// Number of stored-fact derivations (cache misses) — a test probe for the invalidation key.
    private(set) var derivationCount = 0

    /// Volatile inputs the caller supplies (each already memoized or O(1) at its source).
    struct Context {
        var now: Date = Date()
        /// Action items for a completed meeting (`HomeFeedViewModel.actionFacts`).
        var actionFacts: (Meeting) -> MeetingActionFacts?
        /// Kinds of the meeting's running jobs, or nil when the surface shows no working badge.
        var runningJobKinds: ((UUID) -> [MeetingJobKind])?
        var duplicateIDs: Set<UUID> = []
    }

    /// Row models for `meetings`, in order. Meetings already deleted from the store are skipped: their
    /// attributes can no longer be read, and the row is about to disappear anyway.
    func rows(for meetings: [Meeting], context: Context) -> [MeetingRowModel] {
        meetings.compactMap { row(for: $0, context: context) }
    }

    func row(for meeting: Meeting, context: Context) -> MeetingRowModel? {
        guard !meeting.isDeletedFromStore else { return nil }
        let facts = storedFacts(for: meeting)
        let isCompleted = facts.state == .completed
        return MeetingRowModel(
            id: meeting.id,
            title: facts.title,
            startDate: facts.startDate,
            effectiveDate: facts.effectiveDate,
            state: facts.state,
            isImported: facts.isImported,
            folder: facts.folder,
            tags: facts.tags,
            attendeeCount: facts.attendeeCount,
            hasTranscript: facts.hasTranscript,
            hasBrief: facts.hasBrief,
            actionFacts: isCompleted ? context.actionFacts(meeting) : nil,
            // Same predicate as `HomeFeedViewModel.isRunningLong(meeting:now:)`.
            isRunningLong: facts.state == .live && (facts.endDate.map { $0 < context.now } ?? false),
            workingBadge: context.runningJobKinds.flatMap {
                MeetingsViewModel.homeActivityBadge(runningKinds: $0(meeting.id))
            },
            isDuplicate: context.duplicateIDs.contains(meeting.id)
        )
    }

    func storedFacts(for meeting: Meeting) -> StoredFacts {
        if let cached = cache[meeting.id], cached.updatedAt == meeting.updatedAt { return cached }
        derivationCount += 1
        let parsed = ImportedMeetingTitle.parse(meeting.title)
        let source = meeting.source
        let folder = meeting.folderPath?.trimmingCharacters(in: .whitespaces)
        let startDate = meeting.startDate ?? parsed.date
        let facts = StoredFacts(
            updatedAt: meeting.updatedAt,
            title: parsed.cleanTitle,
            startDate: startDate,
            effectiveDate: startDate ?? meeting.createdAt,
            state: meeting.state,
            isImported: source == .importedAudio || source == .importedTranscript || parsed.isImported,
            folder: folder?.isEmpty == false ? folder : nil,
            tags: meeting.tags,
            attendeeCount: meeting.attendees.count,
            hasTranscript: !meeting.segments.isEmpty,
            hasBrief: MeetingsViewModel.homeBadgeFacts(for: meeting, isRunningLong: false).hasBrief,
            endDate: meeting.endDate
        )
        cache[meeting.id] = facts
        return facts
    }
}
