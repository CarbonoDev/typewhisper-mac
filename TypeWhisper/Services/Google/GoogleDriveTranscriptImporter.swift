import Foundation
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "GoogleDriveTranscriptImporter")

/// The narrow auto-link seam the importer consumes (the `MeetingAudioTranscribing` precedent):
/// `CalendarService` in production, a fake (or `nil`) in tests — the importer only ever needs the
/// single best candidate above the confidence threshold.
@MainActor
protocol MeetingAutoLinking: AnyObject {
    func bestAutoLinkCandidate(
        title: String,
        date: Date,
        window: TimeInterval,
        minimumConfidence: Double
    ) -> (event: CalendarEventDTO, score: Double)?
}

extension CalendarService: MeetingAutoLinking {}

/// The seam the sync engine's job closures call ([Google Phase 2 · M2]) — the importer in
/// production, a fake in `GoogleDriveSyncEngineTests` (which must observe enqueues without real
/// imports running).
@MainActor
protocol GoogleDriveFileProcessing: AnyObject {
    func processFile(_ file: GoogleDriveAPI.GDriveFile, sub: String) async -> GoogleDriveTranscriptImporter.Outcome
}

/// Per-file Drive transcript import ([Google Phase 2 · M2]): export the Gemini notes doc as
/// markdown (`text/plain` fallback, D-D3), resolve the D-D4 disposition, write through
/// `MeetingImportService` into `MeetingService` (which stays the single writer of
/// `meetings.store`), and record the outcome in the ledger — of which this importer is the sole
/// entry/failure writer (D-D5; the engine writes watermarks only).
///
/// **Atomicity (D-D4, normative):** the export completes *before* the candidate snapshot; the
/// snapshot → match → `MeetingService` write then runs in one synchronous main-actor stretch with
/// no `await` between snapshot and write, so two imports can never interleave between "saw no
/// matching meeting" and "created one" — cross-account convergence follows structurally.
///
/// **Write order (D-D5, normative):** the meeting is written first, the ledger second — a crash
/// between the two self-heals (the file re-surfaces, the matcher scores the just-written meeting
/// at ~1.0, and `TranscriptMerger` dedupes the replay to a no-op). The reversed order would
/// record "imported" for a transcript that never landed: a permanent loss.
@MainActor
final class GoogleDriveTranscriptImporter: GoogleDriveFileProcessing {
    enum Outcome: Equatable {
        /// Matched an existing meeting (score ≥ threshold) and merged into it.
        case merged(meetingID: UUID, droppedOverlapped: Int)
        /// No confident match: a new `.importedTranscript` meeting, dated from the filename
        /// (else the doc's `createdTime`), best-effort auto-linked to a calendar event.
        case created(meetingID: UUID)
        /// A ledgered doc edited within the horizon, re-merged into its recorded meeting.
        case remerged(meetingID: UUID)
        /// The re-merge target no longer exists: the edit was acknowledged (`touch`), the entry
        /// marked known-deleted — a deleted meeting stays deleted (D-D5).
        case touched
        /// Export or parse failed; a capped failure was recorded (D-D5 retry policy).
        case failed(message: String)
    }

    /// Surfaced by the engine's job closure so a failed import shows in the activity popover.
    struct ImportFailed: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let tokenProvider: GoogleAccessTokenProviding
    private let transport: GoogleHTTPTransport
    private let importService: MeetingImportService
    private let meetingService: MeetingService
    /// Best-effort calendar auto-link (D-D4 disposition 2); `nil` disables linking (tests).
    private weak var autoLink: (any MeetingAutoLinking)?
    private let ledger: GoogleDriveImportLedger
    private let now: () -> Date

    init(
        tokenProvider: GoogleAccessTokenProviding,
        transport: GoogleHTTPTransport,
        importService: MeetingImportService,
        meetingService: MeetingService,
        autoLink: (any MeetingAutoLinking)?,
        ledger: GoogleDriveImportLedger,
        now: @escaping () -> Date = Date.init
    ) {
        self.tokenProvider = tokenProvider
        self.transport = transport
        self.importService = importService
        self.meetingService = meetingService
        self.autoLink = autoLink
        self.ledger = ledger
        self.now = now
    }

    // MARK: - Per-file pipeline

    func processFile(_ file: GoogleDriveAPI.GDriveFile, sub: String) async -> Outcome {
        let fileID = GoogleDriveAPI.fileID(sub: sub, raw: file.id)
        let docModified = file.modifiedDate ?? now()

        // 1. Export FIRST (D-D4 atomicity): every await happens before the snapshot below.
        let text: String
        do {
            text = try await exportText(rawFileID: file.id, sub: sub)
        } catch {
            logger.warning("Drive export failed for \(file.id, privacy: .private): \(error.localizedDescription)")
            ledger.recordFailure(fileID: fileID, now: now())
            return .failed(message: error.localizedDescription)
        }

        // 2. One synchronous main-actor stretch from here to the ledger record: no awaits.

        // Re-merge: a ledgered doc edited after import (the engine enqueued on `.remerge`; the
        // entry is re-read here so a stale queue entry can never target the wrong meeting).
        if let entry = ledger.entry(for: fileID) {
            guard let meetingID = entry.meetingID,
                  let meeting = meetingService.meetings.first(where: { $0.id == meetingID })
            else {
                // Target vanished (or already known-deleted): acknowledge the edit only —
                // a meeting deleted on purpose stays deleted (D-D5).
                ledger.touch(fileID: fileID, docModifiedTime: docModified, markMeetingDeleted: true)
                return .touched
            }
            do {
                let dropped = try importService.mergeTranscriptText(text, into: meeting)
                ledger.recordImported(
                    fileID: fileID, docModifiedTime: docModified,
                    meetingID: meetingID, disposition: .merged, now: now()
                )
                logger.info("Re-merged Drive doc into meeting \(meetingID) (dropped \(dropped) live rows)")
                return .remerged(meetingID: meetingID)
            } catch {
                ledger.recordFailure(fileID: fileID, now: now())
                return .failed(message: error.localizedDescription)
            }
        }

        // New doc: snapshot candidates, resolve the D-D4 disposition, write, then ledger (F2).
        let candidates = meetingService.meetings.map { meeting in
            DriveTranscriptMatcher.Candidate(
                id: meeting.id,
                title: meeting.title,
                startDate: meeting.startDate,
                calendarEventID: meeting.calendarEventID,
                segmentCount: meeting.segments.count
            )
        }
        let disposition = DriveTranscriptMatcher.disposition(
            fileName: file.name,
            createdTime: file.createdDate,
            sub: sub,
            candidates: candidates
        )

        switch disposition {
        case .merge(let meetingID, let score):
            guard let meeting = meetingService.meetings.first(where: { $0.id == meetingID }) else {
                // Unreachable in the synchronous stretch (the snapshot came from the same array);
                // recorded as a failure rather than trapped, out of caution.
                ledger.recordFailure(fileID: fileID, now: now())
                return .failed(message: "matched meeting disappeared before merge")
            }
            do {
                let dropped = try importService.mergeTranscriptText(text, into: meeting)
                ledger.recordImported(
                    fileID: fileID, docModifiedTime: docModified,
                    meetingID: meetingID, disposition: .merged, now: now()
                )
                logger.info("Merged Drive doc into meeting \(meetingID) (score \(score), dropped \(dropped))")
                return .merged(meetingID: meetingID, droppedOverlapped: dropped)
            } catch {
                ledger.recordFailure(fileID: fileID, now: now())
                return .failed(message: error.localizedDescription)
            }

        case .create(let title, let startDate):
            let meeting: Meeting
            do {
                meeting = try importService.importTranscriptText(text, title: title, startDate: startDate)
            } catch {
                ledger.recordFailure(fileID: fileID, now: now())
                return .failed(message: error.localizedDescription)
            }
            // Best-effort calendar auto-link (D-D4 disposition 2) — still before the ledger
            // record, still synchronous. Historical backfill dates usually fall outside the
            // snapshot window, so old meetings simply stay unlinked.
            if let autoLink, let date = startDate,
               let candidate = autoLink.bestAutoLinkCandidate(
                   title: title,
                   date: date,
                   window: CalendarService.defaultAutoLinkWindow,
                   minimumConfidence: CalendarService.defaultAutoLinkConfidence
               ) {
                let projection = CalendarService.meetingProjection(for: candidate.event)
                meetingService.linkToCalendarEvent(
                    calendarEventID: projection.calendarEventID,
                    seriesID: projection.seriesID,
                    title: projection.title,
                    startDate: projection.startDate,
                    endDate: projection.endDate,
                    attendees: projection.attendees,
                    calendarNotes: projection.calendarNotes,
                    conferencingURL: projection.conferencingURL,
                    for: meeting
                )
            }
            ledger.recordImported(
                fileID: fileID, docModifiedTime: docModified,
                meetingID: meeting.id, disposition: .created, now: now()
            )
            logger.info("Created meeting \(meeting.id) from Drive doc")
            return .created(meetingID: meeting.id)
        }
    }

    // MARK: - Export (D-D3)

    /// Markdown first (load-bearing: it carries the heading/bold markup the Gemini parser rung
    /// keys on); on an unsupported-MIME rejection (HTTP 400/403) retry once with `text/plain` —
    /// degraded timing/speakers, but content lands (fallback rung 2). A zero-segment parse falls
    /// through the parser cascade's generic rungs on its own (rung 1).
    private func exportText(rawFileID: String, sub: String) async throws -> String {
        let token = try await tokenProvider.accessToken(for: sub)
        do {
            return try await export(rawFileID: rawFileID, mimeType: GoogleDriveAPI.markdownExportMIME, token: token)
        } catch let error as GoogleDriveAPI.RequestFailed where error.statusCode == 400 || error.statusCode == 403 {
            logger.warning("Markdown export rejected (HTTP \(error.statusCode)) — retrying as text/plain")
            return try await export(rawFileID: rawFileID, mimeType: GoogleDriveAPI.plainTextExportMIME, token: token)
        }
    }

    private func export(rawFileID: String, mimeType: String, token: String) async throws -> String {
        let request = GoogleDriveAPI.exportRequest(fileID: rawFileID, mimeType: mimeType, token: token)
        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200 else {
            throw GoogleDriveAPI.RequestFailed(statusCode: response.statusCode)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
