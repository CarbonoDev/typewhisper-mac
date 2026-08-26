import Foundation

/// The D-D4 attach-to-meeting resolver ([Google Phase 2 · M1]): given a Gemini notes doc's
/// identity (filename + Drive `createdTime`) and a value snapshot of candidate meetings, decide
/// merge-into-existing vs create-new. Pure logic over plain values (the `SpeakerSourcePlan` /
/// `MeetingMergePlan` pattern) — no store access, no clocks — so the whole decision table is
/// unit-testable (`DriveTranscriptMatcherTests`). `@MainActor` only because it reuses
/// `CalendarService`'s scoring statics; the importer runs it inside its synchronous main-actor
/// snapshot→match→write stretch anyway (D-D4 atomicity).
@MainActor
enum DriveTranscriptMatcher {
    /// Value snapshot of one existing meeting, taken from `MeetingService.meetings` in the same
    /// main-actor stretch as the write (D-D4 atomicity: no `await` between snapshot and write).
    /// Deliberately **no segment count** (review fix, 2026-08-12): it was only ever the last
    /// tie-break rung, and reading `Meeting.segments.count` faults the entire cascade relationship
    /// of every meeting for every imported file (a 500-meeting archive materialized ~150 k
    /// segment objects on the main actor per file). Remaining ties are broken by `id` instead —
    /// arbitrary but stable, which is all a tie between two equally-scored, equally-affine
    /// candidates needs.
    struct Candidate: Equatable, Sendable {
        var id: UUID
        var title: String
        var startDate: Date?
        var calendarEventID: String?

        init(
            id: UUID = UUID(),
            title: String,
            startDate: Date? = nil,
            calendarEventID: String? = nil
        ) {
            self.id = id
            self.title = title
            self.startDate = startDate
            self.calendarEventID = calendarEventID
        }
    }

    /// Meeting states an import must never write into (review fix, 2026-08-12): `mergeImport`
    /// deletes and re-inserts the target's segment rows, so merging a Gemini doc published
    /// mid-call into the `.live` meeting that is still capturing would delete live rows the user
    /// is watching — and repeat on every 15-minute poll. Callers snapshot only meetings whose
    /// state is outside this set, and defer (rather than duplicate) a doc whose best match is in
    /// it, so the import lands after the meeting completes.
    static let unwritableStates: Set<MeetingState> = [.live, .processing]

    enum Disposition: Equatable {
        /// A confident match (score ≥ threshold): merge into the existing meeting
        /// (`MeetingImportService.mergeTranscriptText`, overlap policy applies).
        case merge(meetingID: UUID, score: Double)
        /// No candidate cleared the threshold (or none in window): create a new
        /// `.importedTranscript` meeting with the clean title, dated from the filename (falling
        /// back to the doc's `createdTime`) — then best-effort calendar auto-link (importer, M2).
        case create(title: String, startDate: Date?)
    }

    /// Scores within this band of each other count as a near-tie, where account affinity (then
    /// segment count) may break the order; a wider gap is decided by score alone (D-D4, review
    /// ruling on the tie-break ordering).
    static let affinityTieBand: Double = 0.05

    /// Resolve the disposition for one Drive doc.
    ///
    /// Scoring reuses the Phase-1-proven pure statics unchanged — `CalendarService.titleSimilarity`
    /// (token Jaccard) / `dateProximity` / the 0.65/0.35 `linkScore` blend — over candidates whose
    /// `startDate` lies within ±`window` of the doc's date (`defaultAutoLinkWindow`, ±24 h:
    /// deliberately narrow so a weekly recurring title can never hit the wrong occurrence).
    /// Disposition (D-D4): merge whenever **any** candidate clears `minimumConfidence` (0.6).
    /// Ranking among the qualifiers is **score-dominant**: a score gap wider than
    /// `affinityTieBand` (0.05) wins outright — account affinity must never redirect a transcript
    /// away from a clearly better match (back-to-back recurring occurrences: yesterday's
    /// same-account meeting at ~0.66 must lose to today's unlinked meeting at ~1.0, or the merge
    /// silently corrupts the wrong occurrence and breaks cross-account convergence). Within the
    /// near-tie band, prefer a candidate whose `calendarEventID` is namespaced to the **same
    /// account** (the transcript and the calendar event came from the same Google account), then
    /// higher score, then a stable `id` order (see `Candidate` on the dropped rung). Below
    /// threshold is a near-miss and creates, never auto-merges: a wrong merge silently corrupts a
    /// meeting, a duplicate is visible and foldable via the manual merge flow (spec §1 non-goal).
    static func disposition(
        fileName: String,
        createdTime: Date?,
        sub: String,
        candidates: [Candidate],
        window: TimeInterval = CalendarService.defaultAutoLinkWindow,
        minimumConfidence: Double = CalendarService.defaultAutoLinkConfidence
    ) -> Disposition {
        let parsed = ImportedMeetingTitle.parse(fileName)
        let title = parsed.cleanTitle
        // Filename date first (matches Drive names verbatim); doc createdTime as fallback.
        guard let targetDate = parsed.date ?? createdTime else {
            // No usable date at all: nothing to window against — create, undated.
            return .create(title: title, startDate: nil)
        }

        let qualifying = candidates
            .compactMap { candidate -> (candidate: Candidate, score: Double, sameAccount: Bool)? in
                guard let startDate = candidate.startDate,
                      abs(startDate.timeIntervalSince(targetDate)) <= window
                else { return nil }
                let score = CalendarService.linkScore(
                    eventTitle: candidate.title,
                    eventDate: startDate,
                    targetTitle: title,
                    targetDate: targetDate,
                    window: window
                )
                guard score >= minimumConfidence else { return nil }
                let sameAccount = candidate.calendarEventID
                    .flatMap(GoogleCalendarID.accountSub(fromNamespacedID:)) == sub
                return (candidate, score, sameAccount)
            }
            .sorted { lhs, rhs in
                // Score-dominant: affinity only ever breaks near-ties (see affinityTieBand).
                if abs(lhs.score - rhs.score) > Self.affinityTieBand { return lhs.score > rhs.score }
                if lhs.sameAccount != rhs.sameAccount { return lhs.sameAccount }
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.candidate.id.uuidString < rhs.candidate.id.uuidString
            }

        if let best = qualifying.first {
            return .merge(meetingID: best.candidate.id, score: best.score)
        }
        return .create(title: title, startDate: parsed.date ?? createdTime)
    }
}
