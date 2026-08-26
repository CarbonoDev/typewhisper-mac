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
/// (watermarks + housekeeping — the per-cycle `pruneStaleFailures` sweep). The in-memory
/// `pending` map guards the enqueue-to-completion window so one
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

    /// Why an import attempt failed (D-D5, review fix): the retry budget is **error-class aware**.
    /// A permanent error (a 4xx that will fail identically next time, an empty/unparseable doc)
    /// burns the small `maxRetryAttempts` budget; a transient one (429, 5xx, network) gets the
    /// much larger `maxTransientAttempts` budget, so 45 minutes of Drive flakiness can never
    /// abandon a transcript. Cancellation records nothing at all (the importer just clears the
    /// pending guard) — a user's Cancel is not a failure.
    enum FailureKind: Equatable {
        case permanent
        case transient
    }

    /// A file whose import job ran and failed (D-D5): retried while its budget lasts, then
    /// abandoned (the record stays — surfaced as a selectable backfill row, and it keeps holding
    /// the watermark behind itself) until pruned.
    ///
    /// `transientAttempts` and `docModifiedTime` are decoded leniently (`decodeIfPresent`): a
    /// ledger written before the review fix must keep loading, never wipe itself.
    struct FailureRecord: Codable, Equatable {
        /// Permanent-error attempts — the small budget (`maxRetryAttempts`).
        var attempts: Int
        var lastAttemptAt: Date
        /// Transient-error attempts — the large budget (`maxTransientAttempts`).
        var transientAttempts: Int = 0
        /// The Drive `modifiedTime` of the file at the last attempt: the D-D6 watermark bound
        /// holds behind unresolved failures exactly as it does behind pending entries, so an
        /// abandoned file is never silently below the bound.
        var docModifiedTime: Date?

        /// Both budgets spent (or the permanent one, which is the harder stop) → abandoned.
        @MainActor
        var isExhausted: Bool {
            attempts >= GoogleDriveImportLedger.maxRetryAttempts
                || transientAttempts >= GoogleDriveImportLedger.maxTransientAttempts
        }

        init(attempts: Int, lastAttemptAt: Date, transientAttempts: Int = 0, docModifiedTime: Date? = nil) {
            self.attempts = attempts
            self.lastAttemptAt = lastAttemptAt
            self.transientAttempts = transientAttempts
            self.docModifiedTime = docModifiedTime
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            attempts = try container.decode(Int.self, forKey: .attempts)
            lastAttemptAt = try container.decode(Date.self, forKey: .lastAttemptAt)
            transientAttempts = try container.decodeIfPresent(Int.self, forKey: .transientAttempts) ?? 0
            docModifiedTime = try container.decodeIfPresent(Date.self, forKey: .docModifiedTime)
        }
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
    /// Permanent-error import attempts before a failing file is abandoned to the backfill sheet.
    static let maxRetryAttempts = 3
    /// Transient-error (429/5xx/network) attempts before the same abandonment (D-D5 review fix).
    /// Deliberately generous — at the 15-minute cadence this is ~2.5 h of continuous flakiness,
    /// and an abandoned file still holds the watermark behind itself, so it stays re-discoverable.
    static let maxTransientAttempts = 10
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

    /// The per-file branch of the engine's cycle (and the F4 execution-time re-check at the top
    /// of `processFile`), pure over ledger state — no clocks (`now` injected), and no writes
    /// except the one documented self-heal: a fresh doc edit resetting an exhausted re-merge
    /// attempt budget (review fix, D-D5).
    ///
    /// `exemptingPendingFileID` (D-D7/F4): an auto-import job re-checking its **own** file must
    /// not be blocked by the very pending entry the engine marked for it at enqueue — the owner
    /// passes its fileID to bypass the pending gate for that one file. Every other caller (the
    /// backfill batch, discovery) leaves it `nil`, so in-flight files still read `.skip`.
    func action(
        for file: GoogleDriveAPI.GDriveFile,
        sub: String,
        now: Date,
        exemptingPendingFileID: String? = nil
    ) -> LedgerAction {
        let fileID = GoogleDriveAPI.fileID(sub: sub, raw: file.id)
        // In flight: enqueued but not yet ledgered — the concurrent-enqueue guard.
        if pending[fileID] != nil, fileID != exemptingPendingFileID { return .skip }

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
                // Re-merges are gated by the same retry cap (review fix, D-D5): a doc whose
                // re-merge keeps failing is abandoned once attempts reach the cap — UNLESS the
                // doc was edited again *after* the last failed attempt (an edit plausibly fixes
                // a parse failure), which resets the attempt budget before re-merging.
                if let failure = failures[fileID], failure.isExhausted {
                    guard modified > failure.lastAttemptAt else { return .skip }
                    failures.removeValue(forKey: fileID)
                    save()
                }
                return .remerge(meetingID: meetingID)
            }
            return .skip
        }

        if let failure = failures[fileID] {
            // Never-imported and still within budget → retry. Once abandoned the file keeps its
            // record (and with it the watermark hold, D-D6) so it is never silently below the
            // bound: it re-surfaces every cycle as a `.skip`, remains a selectable backfill row,
            // and becomes `.importNew` again once `pruneStaleFailures` drops the record.
            return failure.isExhausted ? .skip : .retry
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

    /// An import job ran and failed: bump the attempt count of the **matching error class**
    /// (D-D5 review fix — a 45-minute run of 5xx must not spend the permanent budget). The file
    /// leaves the pending set; the record carries its `modifiedTime` so the engine's watermark
    /// bound keeps holding behind it (D-D6) until it succeeds or the record is pruned.
    func recordFailure(fileID: String, docModifiedTime: Date?, kind: FailureKind, now: Date) {
        var record = failures[fileID] ?? FailureRecord(attempts: 0, lastAttemptAt: now)
        switch kind {
        case .permanent: record.attempts += 1
        case .transient: record.transientAttempts += 1
        }
        record.lastAttemptAt = now
        record.docModifiedTime = docModifiedTime ?? record.docModifiedTime
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
            $0.value.isExhausted
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

    /// Drop every **cycle-scoped** trace of the given accounts — watermarks and in-flight pending
    /// guards — so the next enable re-seeds per D-D6 ("seed the watermark to now, import nothing;
    /// history is backfill's job"). Called when the Drive toggle goes OFF and, via the engine's
    /// per-cycle sweep, when an account is removed or its toggle was flipped off while quit.
    ///
    /// Import **entries are deliberately kept**: import identity must outlive the account row
    /// (D-D5), so a disconnect → re-add can never re-import (and thus re-duplicate) a doc that
    /// already landed. Failure records are kept for the same reason (they are the backfill
    /// sheet's recovery flag) and age out through `pruneStaleFailures`.
    func forgetCycleState(forSub sub: String) {
        var changed = watermarks.removeValue(forKey: sub) != nil
        let prefix = GoogleDriveAPI.fileID(sub: sub, raw: "")
        for key in pending.keys where key.hasPrefix(prefix) {
            pending.removeValue(forKey: key)
            changed = true
        }
        guard changed else { return }
        logger.info("Cleared Drive cycle state for account \(sub, privacy: .private)")
        save()
    }

    /// The sweep the engine runs each cycle: forget every account that is no longer polled
    /// (removed, disconnected, or Drive-disabled). Returns the subs it cleared.
    @discardableResult
    func forgetCycleState(exceptSubs keep: Set<String>) -> [String] {
        let known = Set(watermarks.keys)
            .union(pending.keys.compactMap(GoogleCalendarID.accountSub(fromNamespacedID:)))
        let stale = known.subtracting(keep).sorted()
        for sub in stale {
            forgetCycleState(forSub: sub)
        }
        return stale
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

    /// The D-D6 bound the engine actually uses: the earliest `modifiedTime` among **unresolved**
    /// files — enqueued-but-not-yet-ledgered (pending) *and* failed-but-not-yet-imported (review
    /// fix). Holding the watermark behind a failed file is what keeps an abandoned transcript
    /// re-discoverable instead of silently dropping below the bound forever.
    var earliestUnresolvedModifiedTime: Date? {
        let failed = failures.compactMap { fileID, record in
            entries[fileID] == nil ? record.docModifiedTime : nil
        }
        return (Array(pending.values) + failed).min()
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
        // Last-wins, never `uniqueKeysWithValues` (review fix): the ledger is external data — a
        // torn `save()`, a restored backup or a hand-edited file can carry duplicate `fileID`s,
        // and this runs inside `ServiceContainer` init, so a trap here is an app that cannot
        // launch. Degrade exactly like the unreadable-JSON branch above: keep going, log once.
        var loaded: [String: Entry] = [:]
        var duplicates = 0
        for entry in snapshot.entries {
            if loaded.updateValue(entry, forKey: entry.fileID) != nil { duplicates += 1 }
        }
        if duplicates > 0 {
            logger.error("Ledger carried \(duplicates) duplicate fileID(s) — kept the last of each")
        }
        entries = loaded
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
