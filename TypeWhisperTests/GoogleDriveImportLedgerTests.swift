import XCTest
@testable import TypeWhisper

/// The D-D5 import-identity store ([Google Phase 2 · M1]): persistence round-trip, the pure
/// per-file decision table (unseen / pending / unchanged / edited-within-horizon /
/// edited-beyond-horizon / known-deleted / retry-until-cap), the touch path, per-sub watermarks,
/// the in-memory pending guard (with the D-D6 earliest-pending watermark bound), and failure
/// pruning. All against a temp-directory JSON file — no real Application Support, no network.
@MainActor
final class GoogleDriveImportLedgerTests: XCTestCase {

    // MARK: - Helpers

    // Per-test temp directory + `defer` cleanup (the MeetingImportServiceTests pattern) rather
    // than setUp/tearDown: those overrides are nonisolated on a @MainActor XCTestCase, so they
    // could not build/hold MainActor state anyway.
    private func makeLedger(in directory: URL) -> GoogleDriveImportLedger {
        GoogleDriveImportLedger(fileURL: directory.appendingPathComponent("google-drive-imports.json"))
    }

    /// Wire-decode a fixture file (the fields are `let`s of a Decodable, matching production flow).
    private func makeFile(id: String, modified: Date, created: Date? = nil) throws -> GoogleDriveAPI.GDriveFile {
        let createdField = created.map { "\"createdTime\": \"\(GoogleCalendarAPI.rfc3339String($0))\"," } ?? ""
        let json = """
        {
          "id": "\(id)",
          "name": "Weekly sync - Notas de Gemini",
          "mimeType": "application/vnd.google-apps.document",
          \(createdField)
          "modifiedTime": "\(GoogleCalendarAPI.rfc3339String(modified))"
        }
        """
        return try JSONDecoder().decode(GoogleDriveAPI.GDriveFile.self, from: Data(json.utf8))
    }

    private let now = Date(timeIntervalSince1970: 1_770_000_000)
    private let sub = "sub-1"
    private var fileID: String { GoogleDriveAPI.fileID(sub: sub, raw: "f1") }

    // MARK: - Decision table (D-D5)

    func testUnseenFileImportsNew() throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "DriveLedger")
        defer { TestSupport.remove(dir) }
        let ledger = makeLedger(in: dir)

        let file = try makeFile(id: "f1", modified: now)
        XCTAssertEqual(ledger.action(for: file, sub: sub, now: now), .importNew)
    }

    func testPendingFileSkips() throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "DriveLedger")
        defer { TestSupport.remove(dir) }
        let ledger = makeLedger(in: dir)

        ledger.markPending(fileID: fileID, modifiedTime: now)
        let file = try makeFile(id: "f1", modified: now)

        XCTAssertEqual(ledger.action(for: file, sub: sub, now: now), .skip)
        // …and clearing the guard restores the unseen decision.
        ledger.clearPending(fileID: fileID)
        XCTAssertEqual(ledger.action(for: file, sub: sub, now: now), .importNew)
    }

    func testImportedUnchangedFileSkipsWithinTolerance() throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "DriveLedger")
        defer { TestSupport.remove(dir) }
        let ledger = makeLedger(in: dir)

        ledger.recordImported(
            fileID: fileID, docModifiedTime: now, meetingID: UUID(), disposition: .created, now: now
        )

        // Identical modifiedTime, and sub-tolerance jitter (+0.5 s), both skip.
        XCTAssertEqual(ledger.action(for: try makeFile(id: "f1", modified: now), sub: sub, now: now), .skip)
        let jittered = try makeFile(id: "f1", modified: now.addingTimeInterval(0.5))
        XCTAssertEqual(ledger.action(for: jittered, sub: sub, now: now), .skip)
    }

    func testEditedWithinHorizonRemergesIntoSameMeeting() throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "DriveLedger")
        defer { TestSupport.remove(dir) }
        let ledger = makeLedger(in: dir)

        let meetingID = UUID()
        ledger.recordImported(
            fileID: fileID, docModifiedTime: now, meetingID: meetingID, disposition: .merged, now: now
        )

        let edited = try makeFile(id: "f1", modified: now.addingTimeInterval(600))
        let later = now.addingTimeInterval(2 * 24 * 60 * 60)
        XCTAssertEqual(ledger.action(for: edited, sub: sub, now: later), .remerge(meetingID: meetingID))
    }

    func testEditedBeyondHorizonSkips() throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "DriveLedger")
        defer { TestSupport.remove(dir) }
        let ledger = makeLedger(in: dir)

        ledger.recordImported(
            fileID: fileID, docModifiedTime: now, meetingID: UUID(), disposition: .merged, now: now
        )

        let edited = try makeFile(id: "f1", modified: now.addingTimeInterval(600))
        let beyond = now.addingTimeInterval(GoogleDriveImportLedger.remergeHorizon + 60)
        XCTAssertEqual(ledger.action(for: edited, sub: sub, now: beyond), .skip)
    }

    func testKnownDeletedTargetSkipsEvenWithinHorizon() throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "DriveLedger")
        defer { TestSupport.remove(dir) }
        let ledger = makeLedger(in: dir)

        ledger.recordImported(
            fileID: fileID, docModifiedTime: now, meetingID: UUID(), disposition: .merged, now: now
        )
        // The importer discovered the meeting is gone: touch + mark deleted.
        ledger.touch(fileID: fileID, docModifiedTime: now.addingTimeInterval(300), markMeetingDeleted: true)

        let edited = try makeFile(id: "f1", modified: now.addingTimeInterval(600))
        XCTAssertEqual(ledger.action(for: edited, sub: sub, now: now.addingTimeInterval(700)), .skip)
        XCTAssertNil(ledger.entry(for: fileID)?.meetingID, "deleted meetings stay deleted")
    }

    func testTouchUpdatesDocModifiedTimeOnly() throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "DriveLedger")
        defer { TestSupport.remove(dir) }
        let ledger = makeLedger(in: dir)

        let meetingID = UUID()
        ledger.recordImported(
            fileID: fileID, docModifiedTime: now, meetingID: meetingID, disposition: .merged, now: now
        )

        let editedTime = now.addingTimeInterval(600)
        ledger.touch(fileID: fileID, docModifiedTime: editedTime)

        let entry = try XCTUnwrap(ledger.entry(for: fileID))
        XCTAssertEqual(entry.docModifiedTime, editedTime)
        XCTAssertEqual(entry.meetingID, meetingID, "a plain touch never drops the target")
        XCTAssertEqual(entry.importedAt, now, "touch never moves the horizon anchor")
        // The acknowledged edit no longer triggers anything.
        let file = try makeFile(id: "f1", modified: editedTime)
        XCTAssertEqual(ledger.action(for: file, sub: sub, now: now.addingTimeInterval(700)), .skip)
    }

    func testFailuresRetryUntilCapThenSkip() throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "DriveLedger")
        defer { TestSupport.remove(dir) }
        let ledger = makeLedger(in: dir)

        let file = try makeFile(id: "f1", modified: now)

        ledger.recordFailure(fileID: fileID, now: now)
        XCTAssertEqual(ledger.action(for: file, sub: sub, now: now), .retry)
        ledger.recordFailure(fileID: fileID, now: now)
        XCTAssertEqual(ledger.action(for: file, sub: sub, now: now), .retry)
        ledger.recordFailure(fileID: fileID, now: now)
        // Cap reached (maxRetryAttempts = 3): abandoned to the backfill sheet.
        XCTAssertEqual(ledger.action(for: file, sub: sub, now: now), .skip)
    }

    /// Review fix (D-D5): the re-merge path honors the same retry cap — a ledgered doc whose
    /// re-merges keep failing is abandoned at the cap, UNLESS the doc was edited again *after*
    /// the last failed attempt, which resets the attempt budget (an edit plausibly fixes a
    /// parse failure).
    func testRemergeAtFailureCapSkipsUnlessDocEditedAfterLastAttempt() throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "DriveLedger")
        defer { TestSupport.remove(dir) }
        let ledger = makeLedger(in: dir)

        let meetingID = UUID()
        ledger.recordImported(
            fileID: fileID, docModifiedTime: now, meetingID: meetingID, disposition: .merged, now: now
        )
        // The doc is edited at T+600; three re-merge attempts fail after that edit.
        let editTime = now.addingTimeInterval(600)
        let lastAttempt = now.addingTimeInterval(1_200)
        for _ in 0..<GoogleDriveImportLedger.maxRetryAttempts {
            ledger.recordFailure(fileID: fileID, now: lastAttempt)
        }

        // The edit predates the last failed attempt → abandoned, record kept.
        let staleEdit = try makeFile(id: "f1", modified: editTime)
        XCTAssertEqual(ledger.action(for: staleEdit, sub: sub, now: now.addingTimeInterval(2_000)), .skip)
        XCTAssertNotNil(ledger.failures[fileID], "the abandoned record survives a stale re-discovery")

        // A fresh edit after the last failed attempt → budget reset, re-merge allowed again.
        let freshEdit = try makeFile(id: "f1", modified: lastAttempt.addingTimeInterval(600))
        XCTAssertEqual(
            ledger.action(for: freshEdit, sub: sub, now: now.addingTimeInterval(2_400)),
            .remerge(meetingID: meetingID)
        )
        XCTAssertNil(ledger.failures[fileID], "a fresh edit resets the attempt budget")
    }

    func testRecordImportedClearsFailureAndPendingAndKeepsImportedAt() throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "DriveLedger")
        defer { TestSupport.remove(dir) }
        let ledger = makeLedger(in: dir)

        ledger.recordFailure(fileID: fileID, now: now)
        ledger.markPending(fileID: fileID, modifiedTime: now)

        let meetingID = UUID()
        ledger.recordImported(
            fileID: fileID, docModifiedTime: now, meetingID: meetingID, disposition: .created, now: now
        )
        XCTAssertTrue(ledger.failures.isEmpty)
        XCTAssertTrue(ledger.pendingFileIDs.isEmpty)

        // A later re-merge success updates the doc time but keeps the first-import anchor.
        let later = now.addingTimeInterval(3_600)
        ledger.recordImported(
            fileID: fileID, docModifiedTime: later, meetingID: meetingID, disposition: .merged, now: later
        )
        let entry = try XCTUnwrap(ledger.entry(for: fileID))
        XCTAssertEqual(entry.importedAt, now)
        XCTAssertEqual(entry.docModifiedTime, later)
        XCTAssertEqual(entry.disposition, "merged")
    }

    // MARK: - Persistence

    func testRoundTripPersistsEntriesWatermarksAndFailuresButNotPending() throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "DriveLedger")
        defer { TestSupport.remove(dir) }

        let meetingID = UUID()
        do {
            let ledger = makeLedger(in: dir)
            ledger.recordImported(
                fileID: fileID, docModifiedTime: now, meetingID: meetingID, disposition: .merged, now: now
            )
            ledger.recordFailure(fileID: "google:sub-1:f2", now: now)
            ledger.setWatermark(now, forSub: sub)
            ledger.markPending(fileID: "google:sub-1:f3", modifiedTime: now)
        }

        let reloaded = makeLedger(in: dir)
        let entry = try XCTUnwrap(reloaded.entry(for: fileID))
        XCTAssertEqual(entry.meetingID, meetingID)
        XCTAssertEqual(entry.disposition, "merged")
        // ISO 8601 persistence is second-granular; the 1 s modifiedTime tolerance absorbs that.
        XCTAssertEqual(entry.docModifiedTime.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(entry.importedAt.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(reloaded.failures["google:sub-1:f2"]?.attempts, 1)
        XCTAssertEqual(
            try XCTUnwrap(reloaded.watermark(forSub: sub)).timeIntervalSince1970,
            now.timeIntervalSince1970,
            accuracy: 1
        )
        // The pending guard is deliberately in-memory only (D-D6: a relaunch empties it; the
        // held-back watermark is what re-surfaces the lost jobs).
        XCTAssertTrue(reloaded.pendingFileIDs.isEmpty)
    }

    // MARK: - Watermarks (per sub)

    func testWatermarksAreIndependentPerSub() throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "DriveLedger")
        defer { TestSupport.remove(dir) }
        let ledger = makeLedger(in: dir)

        let other = now.addingTimeInterval(500)
        ledger.setWatermark(now, forSub: "sub-1")
        ledger.setWatermark(other, forSub: "sub-2")

        XCTAssertEqual(ledger.watermark(forSub: "sub-1"), now)
        XCTAssertEqual(ledger.watermark(forSub: "sub-2"), other)
        XCTAssertNil(ledger.watermark(forSub: "sub-3"))
    }

    // MARK: - Pending guard (D-D6 watermark bound)

    func testEarliestPendingModifiedTimeIsTheMinimum() throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "DriveLedger")
        defer { TestSupport.remove(dir) }
        let ledger = makeLedger(in: dir)

        XCTAssertNil(ledger.earliestPendingModifiedTime)

        ledger.markPending(fileID: "google:sub-1:a", modifiedTime: now.addingTimeInterval(100))
        ledger.markPending(fileID: "google:sub-1:b", modifiedTime: now)
        ledger.markPending(fileID: "google:sub-1:c", modifiedTime: now.addingTimeInterval(200))
        XCTAssertEqual(ledger.earliestPendingModifiedTime, now)

        ledger.clearPending(fileID: "google:sub-1:b")
        XCTAssertEqual(ledger.earliestPendingModifiedTime, now.addingTimeInterval(100))
    }

    // MARK: - Failure pruning (D-D5)

    func testPruneDropsOnlyAbandonedFailuresPastThePruneAge() throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "DriveLedger")
        defer { TestSupport.remove(dir) }
        let ledger = makeLedger(in: dir)

        let old = now.addingTimeInterval(-(GoogleDriveImportLedger.failurePruneAge + 60))

        // Abandoned (at cap) and stale → pruned.
        for _ in 0..<GoogleDriveImportLedger.maxRetryAttempts {
            ledger.recordFailure(fileID: "google:sub-1:stale", now: old)
        }
        // Abandoned but recent → kept (still a selectable backfill row).
        for _ in 0..<GoogleDriveImportLedger.maxRetryAttempts {
            ledger.recordFailure(fileID: "google:sub-1:recent", now: now)
        }
        // Under the cap, however old → kept (still retryable).
        ledger.recordFailure(fileID: "google:sub-1:retryable", now: old)

        ledger.pruneStaleFailures(now: now)

        XCTAssertNil(ledger.failures["google:sub-1:stale"])
        XCTAssertNotNil(ledger.failures["google:sub-1:recent"])
        XCTAssertNotNil(ledger.failures["google:sub-1:retryable"])
    }
}
