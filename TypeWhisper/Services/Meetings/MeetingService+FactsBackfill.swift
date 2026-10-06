import Foundation
import SwiftData
import os.log

private let backfillLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "MeetingFacts")

/// How much one main-actor turn of the facts pass may do before it yields. Whichever limit is hit
/// first ends the turn; the defaults keep a turn in the low milliseconds on the largest meetings.
struct MeetingFactsBackfillBudget: Sendable {
    /// Segment rows read (plus one per verification query) per turn.
    var rowsPerTurn = 400
    var timePerTurn: Duration = .milliseconds(4)
}

/// What a pass did, for logging and tests.
struct MeetingFactsBackfillReport: Equatable, Sendable {
    var turns = 0
    var maxRowsInATurn = 0
    /// Meetings whose columns were written (backfilled or healed).
    var written = 0
    /// Computations restarted because the store changed under them (an interleaved write).
    var retries = 0
    var completed = false
}

/// The launch pass over the denormalised facts (perf plan Phase 2): fills unset columns on rows
/// written before they existed and heals drift, without a hitch after the first frame.
///
/// - **Budgeted by work, not meetings.** An unset row is computed from paged store fetches of
///   only `end` and `speakerLabel` (never by faulting the `segments` relationship), so a
///   1,700-segment meeting spans several turns and every turn stays within the budget.
/// - **Never races a write.** The result is written in the same turn as a final store `COUNT`; if
///   the count disagrees (a live append landed between pages), the meeting is recomputed. If any
///   column changed while the pass was reading, a choke point already wrote authoritative values
///   and the pass leaves them alone. A live append on an unset row leaves it unset (see
///   `factsDidAppend`), so the two cannot double-count.
/// - **Idempotent and interruptible.** It only fills or corrects columns; cancellation stops it
///   between turns and the next launch resumes with whatever is still unset.
extension MeetingService {
    @discardableResult
    func reconcileFacts(
        budget: MeetingFactsBackfillBudget = MeetingFactsBackfillBudget(),
        pause: @MainActor () async -> Void = { try? await Task.sleep(nanoseconds: 2_000_000) }
    ) async -> MeetingFactsBackfillReport {
        var report = MeetingFactsBackfillReport()
        var turnStart = ContinuousClock.now
        var turnRows = 0
        var unsaved = false

        /// Ends the turn when it is over budget. Returns false when the pass was cancelled.
        func yieldIfOverBudget() async -> Bool {
            guard turnRows >= budget.rowsPerTurn || ContinuousClock.now - turnStart >= budget.timePerTurn else {
                return true
            }
            if unsaved { save(); unsaved = false }
            report.turns += 1
            report.maxRowsInATurn = max(report.maxRowsInATurn, turnRows)
            await pause()
            turnStart = ContinuousClock.now
            turnRows = 0
            return !Task.isCancelled
        }

        for meeting in meetings {
            guard isLive(meeting) else { continue }

            if meeting.hasStoredFacts,
               let count = storeSegmentCount(of: meeting.id),
               let kinds = storeOutputKinds(of: meeting.id) {
                turnRows += 1 + kinds.count
                let consistent = count == meeting.factSegmentCount && kinds == meeting.storedOutputKinds
                if consistent {
                    guard await yieldIfOverBudget() else { return finish(report, unsaved: unsaved) }
                    continue
                }
            }

            attempts: for _ in 0..<3 {
                let columnsBefore = factColumns(of: meeting)
                var facts = MeetingTranscriptFacts.empty
                var offset = 0
                while true {
                    let limit = max(1, budget.rowsPerTurn - turnRows)
                    guard let page = segmentPage(of: meeting.id, offset: offset, limit: limit) else { break attempts }
                    turnRows += page.count
                    for row in page { facts.add(end: row.end, speakerLabel: row.speakerLabel) }
                    offset += page.count
                    if page.count < limit { break }
                    guard await yieldIfOverBudget() else { return finish(report, unsaved: unsaved) }
                    guard isLive(meeting) else { break attempts }
                }

                // Same turn as the write: nothing can land between this check and the store.
                guard factColumns(of: meeting) == columnsBefore else { break attempts }
                guard let count = storeSegmentCount(of: meeting.id),
                      let kinds = storeOutputKinds(of: meeting.id) else { break attempts }
                guard count == facts.segmentCount else {
                    report.retries += 1
                    continue attempts
                }
                meeting.storeTranscriptFacts(facts)
                meeting.storeOutputKinds(kinds)
                unsaved = true
                report.written += 1
                break attempts
            }
            guard await yieldIfOverBudget() else { return finish(report, unsaved: unsaved) }
        }

        report.turns += 1
        report.maxRowsInATurn = max(report.maxRowsInATurn, turnRows)
        report.completed = true
        return finish(report, unsaved: unsaved)
    }

    private func finish(_ report: MeetingFactsBackfillReport, unsaved: Bool) -> MeetingFactsBackfillReport {
        if unsaved { save() }
        if report.written > 0 {
            backfillLogger.info("Reconciled denormalised facts on \(report.written) meeting(s) in \(report.turns) turn(s)")
        }
        return report
    }

    private func isLive(_ meeting: Meeting) -> Bool {
        meeting.modelContext != nil && !meeting.isDeleted
    }

    private func factColumns(of meeting: Meeting) -> [String?] {
        [
            meeting.factSegmentCount.map(String.init),
            meeting.factTranscriptEnd.map { String($0) },
            meeting.factSpeakerLabelsRaw,
            meeting.factOutputKindsRaw,
        ]
    }

    /// One page of a meeting's segment rows, `end` and `speakerLabel` only, in `order`.
    private func segmentPage(of meetingID: UUID, offset: Int, limit: Int) -> [(end: Double, speakerLabel: String?)]? {
        var descriptor = FetchDescriptor<MeetingSegment>(
            predicate: #Predicate { $0.meeting?.id == meetingID },
            sortBy: [SortDescriptor(\.order)]
        )
        descriptor.fetchOffset = offset
        descriptor.fetchLimit = limit
        descriptor.propertiesToFetch = [\.end, \.speakerLabel]
        guard let rows = try? modelContext.fetch(descriptor) else { return nil }
        return rows.map { ($0.end, $0.speakerLabel) }
    }
}
