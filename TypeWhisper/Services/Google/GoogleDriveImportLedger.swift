import Foundation
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "GoogleDriveImportLedger")

/// The D-D5 import-identity side store ([Google Phase 2 · M1]): which Drive files have been
/// imported (and into which meeting), per-account discovery watermarks (D-D3/D-D6), and capped
/// failure counts — persisted as atomic JSON at
/// `AppConstants.appSupportDirectory/google-drive-imports.json` (the `WatchFolderService`
/// fingerprint precedent, per-build-flavor). Deliberately **not** a `Meeting` column: import
/// identity must outlive the meeting row (a merged import has no meeting of its own; a deleted
/// meeting must not resurrect its doc on the next poll).
///
/// Single writer: `GoogleDriveTranscriptImporter` (entries + failures) and the sync engine
/// (watermarks only). The in-memory `pending` map guards the enqueue-to-completion window so one
/// file is never enqueued twice concurrently; its `modifiedTime` values feed the engine's
/// crash-safe watermark rule (D-D6 — hold the watermark below the earliest
/// enqueued-but-not-yet-ledgered file).
@MainActor
final class GoogleDriveImportLedger {
    /// One successfully imported Drive file (D-D5).
    struct Entry: Codable, Equatable {
        /// Namespaced `google:<sub>:<driveFileID>` (Phase 1 §9 convention, `GoogleDriveAPI.fileID`).
        var fileID: String
        /// Drive `modifiedTime` at the last successful import/re-merge.
        var docModifiedTime: Date
        /// First successful import — fixes the D-D5 re-merge horizon; never moved by re-merges.
        var importedAt: Date
        /// Merge/create target; `nil` once known-deleted (the importer marks it on a failed
        /// re-merge resolve, so a meeting deleted on purpose stays deleted).
        var meetingID: UUID?
        /// `"merged"` | `"created"` — backfill preview + debugging.
        var disposition: String
    }

    enum Disposition: String {
        case merged
        case created
    }

    /// A file whose import job ran and failed (D-D5): retried while `attempts < maxRetryAttempts`,
    /// then abandoned (the record stays — surfaced as a selectable backfill row) until pruned.
    struct FailureRecord: Codable, Equatable {
        var attempts: Int
        var lastAttemptAt: Date
    }

    /// The engine's per-file branch, made pure and testable (D-D5/D-D6).
    enum LedgerAction: Equatable {
        /// Never seen, not pending, no failure history → enqueue an import.
        case importNew
        /// Ledgered, edited after import, within the re-merge horizon → re-merge into the same meeting.
        case remerge(meetingID: UUID)
        /// A prior import attempt failed and the retry cap is not exhausted → try again.
        case retry
        /// Already imported and unchanged, in flight, edited beyond the horizon, known-deleted
        /// target, or retries exhausted.
        case skip
    }

    // MARK: - Tuning constants (D-D5)

    /// A doc edit within this window after first import re-merges; beyond it, the entry is only
    /// touched so an ancient doc edit never churns meetings.
    static let remergeHorizon: TimeInterval = 14 * 24 * 60 * 60
    /// Drive `modifiedTime` jitter tolerance before an edit counts as an edit.
    static let modifiedTimeTolerance: TimeInterval = 1
    /// Import attempts before a failing file is abandoned to the backfill sheet.
    static let maxRetryAttempts = 3
    /// Failure records past the retry cap are pruned this long after their last attempt.
    static let failurePruneAge: TimeInterval = 30 * 24 * 60 * 60

    static var defaultFileURL: URL {
        AppConstants.appSupportDirectory.appendingPathComponent("google-drive-imports.json")
    }

    // MARK: - State

    private(set) var entries: [String: Entry] = [:]
    /// Account `sub` → last successful sync-cycle watermark (D-D3/D-D6).
    private(set) var watermarks: [String: Date] = [:]
    /// Namespaced fileID → failure record (D-D5).
    private(set) var failures: [String: FailureRecord] = [:]
    /// In-memory only (never persisted — a relaunch legitimately empties it; the D-D6 watermark
    /// rule is what makes the lost jobs re-surface): fileID → `modifiedTime` at enqueue.
    private var pending: [String: Date] = [:]

    private let fileURL: URL

    init(fileURL: URL = GoogleDriveImportLedger.defaultFileURL) {
        self.fileURL = fileURL
        load()
    }

    // MARK: - Decisions (D-D5)

    func entry(for fileID: String) -> Entry? {
        entries[fileID]
    }

    /// The per-file branch of the engine's cycle (and the backfill's execution-time re-check),
    /// pure over ledger state — no writes, no clocks (`now` injected).
    func action(for file: GoogleDriveAPI.GDriveFile, sub: String, now: Date) -> LedgerAction {
        let fileID = GoogleDriveAPI.fileID(sub: sub, raw: file.id)
        // In flight: enqueued but not yet ledgered — the concurrent-enqueue guard.
        if pending[fileID] != nil { return .skip }

        if let entry = entries[fileID] {
            // Edited only when Drive's modifiedTime moved past the recorded one (+ tolerance).
            guard let modified = file.modifiedDate,
                  modified.timeIntervalSince(entry.docModifiedTime) > Self.modifiedTimeTolerance
            else { return .skip }
            // Within the re-merge horizon and the target still known → re-merge into the same
            // meeting. Beyond it, or known-deleted (`meetingID == nil`) → skip; the importer's
            // `touch` is what quiets the record when a re-merge resolve fails.
            if now.timeIntervalSince(entry.importedAt) <= Self.remergeHorizon,
               let meetingID = entry.meetingID {
                return .remerge(meetingID: meetingID)
            }
            return .skip
        }

        if let failure = failures[fileID] {
            return failure.attempts < Self.maxRetryAttempts ? .retry : .skip
        }
        return .importNew
    }

    // MARK: - Success / failure records (importer-owned, D-D5)

    /// Record a successful import (write order is normative: the **meeting is already written**
    /// when this runs — meeting first, ledger second, so a crash between the two self-heals as a
    /// re-discovered no-op merge, never a permanently lost transcript). First success fixes
    /// `importedAt`; re-merges keep it (the horizon anchor) and update `docModifiedTime`.
    func recordImported(
        fileID: String,
        docModifiedTime: Date,
        meetingID: UUID?,
        disposition: Disposition,
        now: Date
    ) {
        if var existing = entries[fileID] {
            existing.docModifiedTime = docModifiedTime
            existing.meetingID = meetingID
            existing.disposition = disposition.rawValue
            entries[fileID] = existing
        } else {
            entries[fileID] = Entry(
                fileID: fileID,
                docModifiedTime: docModifiedTime,
                importedAt: now,
                meetingID: meetingID,
                disposition: disposition.rawValue
            )
        }
        failures.removeValue(forKey: fileID)
        pending.removeValue(forKey: fileID)
        save()
    }

    /// Update `docModifiedTime` only (D-D5 "touch"): an edit beyond the horizon, or whose target
    /// meeting no longer exists, is acknowledged without touching any meeting.
    /// `markMeetingDeleted` nils the target so a deleted meeting stays deleted.
    func touch(fileID: String, docModifiedTime: Date, markMeetingDeleted: Bool = false) {
        guard var entry = entries[fileID] else { return }
        entry.docModifiedTime = docModifiedTime
        if markMeetingDeleted {
            entry.meetingID = nil
        }
        entries[fileID] = entry
        pending.removeValue(forKey: fileID)
        save()
    }

    /// An import job ran and failed: bump the capped attempt count (D-D5). The file leaves the
    /// pending set, so the failure record — not the watermark — is what brings it back.
    func recordFailure(fileID: String, now: Date) {
        var record = failures[fileID] ?? FailureRecord(attempts: 0, lastAttemptAt: now)
        record.attempts += 1
        record.lastAttemptAt = now
        failures[fileID] = record
        pending.removeValue(forKey: fileID)
        save()
    }

    /// A later success outside the auto path (backfill) clears the failure history.
    func clearFailure(fileID: String) {
        guard failures.removeValue(forKey: fileID) != nil else { return }
        save()
    }

    /// Drop abandoned failure records (past the retry cap) older than `failurePruneAge` — the
    /// backfill sheet remains the recovery. Imported entries are kept indefinitely (bounded by
    /// the number of real docs, declared acceptable — spec §8).
    func pruneStaleFailures(now: Date) {
        let stale = failures.filter {
            $0.value.attempts >= Self.maxRetryAttempts
                && now.timeIntervalSince($0.value.lastAttemptAt) > Self.failurePruneAge
        }
        guard !stale.isEmpty else { return }
        for key in stale.keys {
            failures.removeValue(forKey: key)
        }
        save()
    }

    // MARK: - Watermarks (engine-owned, D-D3/D-D6)

    func watermark(forSub sub: String) -> Date? {
        watermarks[sub]
    }

    func setWatermark(_ date: Date, forSub sub: String) {
        watermarks[sub] = date
        save()
    }

    // MARK: - Pending guard (in-memory, D-D5/D-D6)

    var pendingFileIDs: Set<String> {
        Set(pending.keys)
    }

    /// The earliest `modifiedTime` of any enqueued-but-not-yet-ledgered file — the D-D6 crash-safe
    /// watermark bound (`watermark := min(cycleStart, earliestPending − 1 s)`).
    var earliestPendingModifiedTime: Date? {
        pending.values.min()
    }

    func markPending(fileID: String, modifiedTime: Date) {
        pending[fileID] = modifiedTime
    }

    func clearPending(fileID: String) {
        pending.removeValue(forKey: fileID)
    }

    // MARK: - Persistence (atomic JSON, the WatchFolderService discipline)

    private struct Snapshot: Codable {
        var entries: [Entry]
        var watermarks: [String: Date]
        var failures: [String: FailureRecord]
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(Snapshot.self, from: data) else {
            logger.error("Unreadable ledger at \(self.fileURL.lastPathComponent) — starting empty")
            return
        }
        entries = Dictionary(uniqueKeysWithValues: snapshot.entries.map { ($0.fileID, $0) })
        watermarks = snapshot.watermarks
        failures = snapshot.failures
    }

    private func save() {
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let snapshot = Snapshot(
            entries: entries.values.sorted { $0.fileID < $1.fileID },
            watermarks: watermarks,
            failures: failures
        )
        do {
            let data = try encoder.encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Failed to save ledger: \(error.localizedDescription)")
        }
    }
}
