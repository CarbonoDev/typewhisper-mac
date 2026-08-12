import XCTest
@testable import TypeWhisper

/// The pure backfill preview planner ([Google Phase 2 · M4], D-D7): the disposition matrix
/// (merge-with-title / create / already-imported disabled — including known-deleted targets per
/// the §8 respect-deletion rule), previously-failed rows surfacing as selectable with
/// matcher-recomputed dispositions (F7), clean title/date extraction, and date-descending
/// ordering. Temp-dir ledger; no network.
@MainActor
final class GoogleDriveBackfillPlannerTests: XCTestCase {

    private let fixedNow = Date(timeIntervalSince1970: 1_770_000_000)

    /// 2026-07-07 11:00:00 UTC — embedded in the dated fixture names.
    private let embeddedDate: Date = {
        var components = DateComponents()
        components.year = 2026; components.month = 7; components.day = 7
        components.hour = 11; components.minute = 0
        components.timeZone = TimeZone(identifier: "UTC")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)!
    }()

    private func makeLedger(in directory: URL) -> GoogleDriveImportLedger {
        GoogleDriveImportLedger(fileURL: directory.appendingPathComponent("google-drive-imports.json"))
    }

    private func makeFile(id: String, name: String, created: Date? = nil, modified: Date? = nil) throws -> GoogleDriveAPI.GDriveFile {
        let createdField = created.map { #""createdTime": "\#(GoogleCalendarAPI.rfc3339String($0))", "# } ?? ""
        let json = #"{"id": "\#(id)", "name": "\#(name)", "mimeType": "application/vnd.google-apps.document", \#(createdField)"modifiedTime": "\#(GoogleCalendarAPI.rfc3339String(modified ?? fixedNow))"}"#
        return try JSONDecoder().decode(GoogleDriveAPI.GDriveFile.self, from: Data(json.utf8))
    }

    // MARK: - Disposition matrix

    func testConfidentMatchRowsCarryTheMeetingTitle() throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "DrivePlanner")
        defer { TestSupport.remove(dir) }
        let meetingID = UUID()
        let candidates = [
            DriveTranscriptMatcher.Candidate(id: meetingID, title: "Weekly sync", startDate: embeddedDate)
        ]

        let rows = GoogleDriveBackfillPlanner.rows(
            files: [try makeFile(id: "f1", name: "Weekly sync - 2026_07_07 11_00 UTC - Notas de Gemini")],
            sub: "sub-1",
            ledger: makeLedger(in: dir),
            candidates: candidates
        )

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].title, "Weekly sync")
        XCTAssertEqual(rows[0].date, embeddedDate)
        XCTAssertEqual(rows[0].disposition, .merge(meetingID: meetingID, meetingTitle: "Weekly sync"))
        XCTAssertTrue(rows[0].isSelectable)
        XCTAssertFalse(rows[0].isPreviouslyFailed)
    }

    func testNoMatchRowsAreNewMeetingsDatedFromCreatedTimeWhenFilenameHasNoDate() throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "DrivePlanner")
        defer { TestSupport.remove(dir) }
        let created = embeddedDate

        let rows = GoogleDriveBackfillPlanner.rows(
            files: [try makeFile(id: "f1", name: "Ad-hoc call - Notas de Gemini", created: created)],
            sub: "sub-1",
            ledger: makeLedger(in: dir),
            candidates: []
        )

        XCTAssertEqual(rows[0].disposition, .create)
        XCTAssertEqual(rows[0].title, "Ad-hoc call")
        XCTAssertEqual(rows[0].date, created, "createdTime fallback when the filename carries no date")
        XCTAssertTrue(rows[0].isSelectable)
    }

    func testAlreadyImportedRowsAreDisabledIncludingKnownDeletedTargets() throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "DrivePlanner")
        defer { TestSupport.remove(dir) }
        let ledger = makeLedger(in: dir)
        // A normal import, and one whose meeting was deleted (touch + markMeetingDeleted): both
        // read "Already imported" with no re-import affordance (§8 respect-deletion rule).
        ledger.recordImported(
            fileID: "google:sub-1:imported", docModifiedTime: fixedNow,
            meetingID: UUID(), disposition: .created, now: fixedNow
        )
        ledger.recordImported(
            fileID: "google:sub-1:deleted", docModifiedTime: fixedNow,
            meetingID: UUID(), disposition: .merged, now: fixedNow
        )
        ledger.touch(fileID: "google:sub-1:deleted", docModifiedTime: fixedNow, markMeetingDeleted: true)

        let rows = GoogleDriveBackfillPlanner.rows(
            files: [
                try makeFile(id: "imported", name: "Done call - Notas de Gemini"),
                try makeFile(id: "deleted", name: "Deleted call - Notas de Gemini"),
            ],
            sub: "sub-1",
            ledger: ledger,
            candidates: []
        )

        XCTAssertEqual(rows.count, 2)
        for row in rows {
            XCTAssertEqual(row.disposition, .alreadyImported)
            XCTAssertFalse(row.isSelectable, "pre-unchecked and disabled (D-D7)")
        }
    }

    /// D-D7/F7: retry-abandoned failures surface as normal selectable rows with their
    /// disposition recomputed by the matcher — the sheet doubles as the recovery surface.
    func testPreviouslyFailedRowsAreSelectableWithRecomputedDisposition() throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "DrivePlanner")
        defer { TestSupport.remove(dir) }
        let ledger = makeLedger(in: dir)
        for _ in 0..<GoogleDriveImportLedger.maxRetryAttempts {
            ledger.recordFailure(fileID: "google:sub-1:f1", now: fixedNow)
        }
        let meetingID = UUID()
        let candidates = [
            DriveTranscriptMatcher.Candidate(id: meetingID, title: "Weekly sync", startDate: embeddedDate)
        ]

        let rows = GoogleDriveBackfillPlanner.rows(
            files: [try makeFile(id: "f1", name: "Weekly sync - 2026_07_07 11_00 UTC - Notas de Gemini")],
            sub: "sub-1",
            ledger: ledger,
            candidates: candidates
        )

        XCTAssertTrue(rows[0].isPreviouslyFailed)
        XCTAssertTrue(rows[0].isSelectable, "abandoned files remain recoverable here")
        XCTAssertEqual(rows[0].disposition, .merge(meetingID: meetingID, meetingTitle: "Weekly sync"))
    }

    // MARK: - Ordering

    func testRowsAreOrderedByDateDescendingWithUndatedLast() throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "DrivePlanner")
        defer { TestSupport.remove(dir) }

        let rows = GoogleDriveBackfillPlanner.rows(
            files: [
                try makeFile(id: "old", name: "Old call - 2026_06_01 09_00 UTC - Notas de Gemini"),
                try makeFile(id: "new", name: "New call - 2026_07_07 11_00 UTC - Notas de Gemini"),
                // No filename date and no createdTime → undated, sinks to the bottom.
                try makeFile(id: "undated", name: "Undated call - Notas de Gemini"),
            ],
            sub: "sub-1",
            ledger: makeLedger(in: dir),
            candidates: []
        )

        XCTAssertEqual(rows.map(\.file.id), ["new", "old", "undated"])
    }
}
