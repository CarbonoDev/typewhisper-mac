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
    struct Candidate: Equatable, Sendable {
        var id: UUID
        var title: String
        var startDate: Date?
        var calendarEventID: String?
        var segmentCount: Int

        init(
            id: UUID = UUID(),
            title: String,
            startDate: Date? = nil,
            calendarEventID: String? = nil,
            segmentCount: Int = 0
        ) {
            self.id = id
            self.title = title
            self.startDate = startDate
            self.calendarEventID = calendarEventID
            self.segmentCount = segmentCount
        }
    }

    enum Disposition: Equatable {
        /// A confident match (score ≥ threshold): merge into the existing meeting
        /// (`MeetingImportService.mergeTranscriptText`, overlap policy applies).
        case merge(meetingID: UUID, score: Double)
        /// No candidate cleared the threshold (or none in window): create a new
        /// `.importedTranscript` meeting with the clean title, dated from the filename (falling
        /// back to the doc's `createdTime`) — then best-effort calendar auto-link (importer, M2).
        case create(title: String, startDate: Date?)
    }

    /// Resolve the disposition for one Drive doc.
    ///
    /// Scoring reuses the Phase-1-proven pure statics unchanged — `CalendarService.titleSimilarity`
    /// (token Jaccard) / `dateProximity` / the 0.65/0.35 `linkScore` blend — over candidates whose
    /// `startDate` lies within ±`window` of the doc's date (`defaultAutoLinkWindow`, ±24 h:
    /// deliberately narrow so a weekly recurring title can never hit the wrong occurrence).
    /// Disposition (D-D4): merge whenever **any** candidate clears `minimumConfidence` (0.6);
    /// choosing among the qualifying candidates prefers one whose `calendarEventID` is namespaced
    /// to the **same account** (the transcript and the calendar event came from the same Google
    /// account), then higher score, then more segments (the `ranksBefore` spirit,
    /// `MeetingMergePlan`). Below threshold is a near-miss and creates, never auto-merges: a wrong
    /// merge silently corrupts a meeting, a duplicate is visible and foldable via the manual merge
    /// flow (spec §1 non-goal).
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
                if lhs.sameAccount != rhs.sameAccount { return lhs.sameAccount }
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.candidate.segmentCount > rhs.candidate.segmentCount
            }

        if let best = qualifying.first {
            return .merge(meetingID: best.candidate.id, score: best.score)
        }
        return .create(title: title, startDate: parsed.date ?? createdTime)
    }
}
