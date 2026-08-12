import Foundation

/// Pure preview-row planning for the backfill sheet ([Google Phase 2 · M4], D-D7): scan results
/// × ledger state × the D-D4 matcher → one labeled, selectable row per discovered doc. No I/O,
/// no clocks — fully covered by `GoogleDriveBackfillPlannerTests`; the sheet renders rows
/// verbatim and the batch re-checks every disposition at execution time anyway (F4), so a stale
/// preview can never double-import.
@MainActor
enum GoogleDriveBackfillPlanner {
    enum Disposition: Equatable {
        /// Confident match: "Merge into "<meeting>"".
        case merge(meetingID: UUID, meetingTitle: String)
        /// No confident match: "New meeting".
        case create
        /// Ledgered (including known-deleted targets — the §8 respect-deletion rule: no
        /// re-import affordance in v1). Pre-unchecked and disabled.
        case alreadyImported
    }

    struct Row: Equatable, Identifiable {
        /// Namespaced `google:<sub>:<fileID>` — stable selection identity.
        var id: String
        var file: GoogleDriveAPI.GDriveFile
        /// Clean display title (`ImportedMeetingTitle`).
        var title: String
        /// Real date: filename date, else the doc's `createdTime`.
        var date: Date?
        var disposition: Disposition
        /// Retry-abandoned (or still-retryable) failure record exists (D-D7/F7): shown as a
        /// normal selectable row — the backfill sheet doubles as the recovery surface for files
        /// auto-import gave up on.
        var isPreviouslyFailed: Bool

        /// Only un-ledgered docs are importable; "Already imported" rows are disabled (D-D7).
        var isSelectable: Bool {
            disposition != .alreadyImported
        }
    }

    /// Value snapshot of the candidate meetings, taken by the sheet from `MeetingService.meetings`.
    static func candidates(of meetings: [Meeting]) -> [DriveTranscriptMatcher.Candidate] {
        meetings.map { meeting in
            DriveTranscriptMatcher.Candidate(
                id: meeting.id,
                title: meeting.title,
                startDate: meeting.startDate,
                calendarEventID: meeting.calendarEventID,
                segmentCount: meeting.segments.count
            )
        }
    }

    /// Plan the preview rows for one account's scan, newest first (date descending; undated docs
    /// sink to the bottom). Failure-record dispositions are recomputed by the matcher (D-D7/F7)
    /// so an abandoned file previews exactly like a fresh one, just flagged.
    static func rows(
        files: [GoogleDriveAPI.GDriveFile],
        sub: String,
        ledger: GoogleDriveImportLedger,
        candidates: [DriveTranscriptMatcher.Candidate]
    ) -> [Row] {
        files
            .map { file -> Row in
                let fileID = GoogleDriveAPI.fileID(sub: sub, raw: file.id)
                let parsed = ImportedMeetingTitle.parse(file.name)
                let date = parsed.date ?? file.createdDate

                let disposition: Disposition
                if ledger.entry(for: fileID) != nil {
                    // Ledgered — merged, created, or known-deleted alike: "Already imported"
                    // (edits re-merge through the auto engine, never through backfill).
                    disposition = .alreadyImported
                } else {
                    switch DriveTranscriptMatcher.disposition(
                        fileName: file.name,
                        createdTime: file.createdDate,
                        sub: sub,
                        candidates: candidates
                    ) {
                    case .merge(let meetingID, _):
                        let title = candidates.first { $0.id == meetingID }?.title ?? ""
                        disposition = .merge(meetingID: meetingID, meetingTitle: title)
                    case .create:
                        disposition = .create
                    }
                }
                return Row(
                    id: fileID,
                    file: file,
                    title: parsed.cleanTitle,
                    date: date,
                    disposition: disposition,
                    isPreviouslyFailed: ledger.failures[fileID] != nil
                )
            }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }
}
