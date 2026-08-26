import Foundation
import Combine
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "GoogleDriveSyncEngine")

/// Periodic Drive discovery of Gemini notes docs ([Google Phase 2 · M2], D-D6) — deliberately the
/// `GoogleCalendarSyncEngine` shape: app-lifetime task loop started from
/// `ServiceContainer.initialize()`, coalescing `syncNow()` with a `resyncRequested` re-loop,
/// per-account failure isolation with the Phase 1 error taxonomy (`.needsReauth` skipped, never
/// retried; everything else transient), and published `lastSyncAt`/`lastSyncError` for the
/// settings row. Differences: **15-minute** cadence (transcripts are not time-critical), and only
/// accounts that are `.connected` **and Drive-enabled** (D-D7/D-D8 toggle — default off, so this
/// engine issues zero Drive requests until a toggle is turned on in M3) are polled.
///
/// Per cycle, per account: token → `files.list` bounded by `watermark − 5 min` (first-ever cycle:
/// seed the watermark to now and import **nothing** — history is backfill's job, user-controlled)
/// → per file the ledger's D-D5 decision → cap 25 enqueues per cycle (the remainder lands next
/// cycle via the held/overlapped watermark). Job closures call the injected
/// `GoogleDriveFileProcessing` seam (the importer); this engine writes **watermarks +
/// housekeeping** (the per-cycle `pruneStaleFailures` sweep) — the importer stays the sole
/// entry/failure writer (D-D5).
@MainActor
final class GoogleDriveSyncEngine: ObservableObject {
    /// D-D6 cadence.
    nonisolated static let defaultSyncInterval: TimeInterval = 15 * 60
    /// Watermark overlap margin: re-list a little history each cycle so sub-margin clock skew /
    /// list-vs-modify races can never skip a file (re-discoveries are ledger no-ops).
    nonisolated static let overlapMargin: TimeInterval = 5 * 60
    /// Burst bound per cycle (D-D6); the remainder re-surfaces next cycle via the watermark.
    nonisolated static let maxEnqueuesPerCycle = 25
    /// Pause between two serialized auto-imports — the backfill's rate-limit pacing, reused
    /// (review fix): the `io` lane is unbounded, so without this the cycle's 25 jobs would fire
    /// their `files/{id}/export` calls simultaneously and earn a burst of 403/429s that spend the
    /// ledger's retry budget on self-inflicted failures.
    nonisolated static let defaultInterImportPause = GoogleDriveTranscriptImporter.backfillInterFilePause

    /// Wall clock of the last completed cycle that had at least one Drive-enabled account to try.
    @Published private(set) var lastSyncAt: Date?
    /// User-facing description of the last cycle's first failure; `nil` after a clean cycle.
    @Published private(set) var lastSyncError: String?

    private let store: GoogleAccountStore
    private let tokenProvider: GoogleAccessTokenProviding
    private let transport: GoogleHTTPTransport
    private let ledger: GoogleDriveImportLedger
    private let jobQueue: JobQueueService
    private let processor: GoogleDriveFileProcessing
    /// Injected clock so watermark math is deterministic under test.
    private let now: () -> Date
    private let syncInterval: TimeInterval
    /// Inter-import pacing (0 under test).
    private let interImportPause: UInt64

    private var inFlightSync: Task<Void, Never>?
    /// Tail of the serial auto-import chain — see `serialized(_:)`.
    private var importChainTail: Task<Void, Never>?
    /// fileID → the job that owns its pending guard, so a job that never ran (cancelled while
    /// queued) cannot strand that guard forever (review fix; swept at the top of every cycle).
    private var pendingJobs: [String: UUID] = [:]
    /// The Phase 1 coalescing contract: a `syncNow()` landing mid-cycle flags this and awaits the
    /// driver, which runs one more full cycle before exiting (no lost requests, no racing fetches).
    private var resyncRequested = false
    private var timerTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init(
        store: GoogleAccountStore,
        tokenProvider: GoogleAccessTokenProviding,
        transport: GoogleHTTPTransport = URLSessionGoogleTransport(),
        ledger: GoogleDriveImportLedger,
        jobQueue: JobQueueService,
        processor: GoogleDriveFileProcessing,
        now: @escaping () -> Date = Date.init,
        syncInterval: TimeInterval = GoogleDriveSyncEngine.defaultSyncInterval,
        interImportPause: UInt64 = GoogleDriveSyncEngine.defaultInterImportPause
    ) {
        self.interImportPause = interImportPause
        self.store = store
        self.tokenProvider = tokenProvider
        self.transport = transport
        self.ledger = ledger
        self.jobQueue = jobQueue
        self.processor = processor
        self.now = now
        self.syncInterval = syncInterval
    }

    deinit {
        timerTask?.cancel()
    }

    // MARK: - Lifecycle

    /// Starts the 15-minute cadence (immediate first cycle) and the account-change trigger
    /// (connect/disconnect/status flip re-syncs immediately). The remaining D-D6 triggers —
    /// Drive-toggle flip and manual "Check now" — call `syncNow()` directly from the M3 UI.
    /// Idempotent; called from `ServiceContainer.initialize()` — never under tests, which drive
    /// `syncNow()` directly.
    func start() {
        guard timerTask == nil else { return }
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncNow()
                guard let interval = self?.syncInterval else { return }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
        store.$accounts
            .map { accounts in accounts.map { "\($0.id):\($0.statusRaw)" } }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                Task { await self?.syncNow() }
            }
            .store(in: &cancellables)
    }

    // MARK: - Sync

    /// One full discovery cycle across every `.connected` + Drive-enabled account. Also the
    /// "Check now" / toggle-flip entry point. Coalescing semantics are the Phase 1 contract
    /// (see `GoogleCalendarSyncEngine.syncNow` — findings 1+2): the driver's final flag-check and
    /// `inFlightSync` clear happen in one synchronous main-actor stretch.
    func syncNow() async {
        if let inFlightSync {
            resyncRequested = true
            await inFlightSync.value
            return
        }
        let task = Task { [weak self] in
            while true {
                guard let self else { return }
                self.resyncRequested = false
                await self.performSync()
                if self.resyncRequested { continue }
                self.inFlightSync = nil
                return
            }
        }
        inFlightSync = task
        await task.value
    }

    private func performSync() async {
        // Housekeeping (D-D5): drop abandoned failure records past the prune age.
        ledger.pruneStaleFailures(now: now())
        // Housekeeping (D-D6 review fixes): release pending guards whose job never ran, and
        // forget the cycle state of accounts that are no longer polled.
        releaseStrandedPendingGuards()
        forgetUnpolledAccounts()

        var firstError: String?
        var attemptedAnyAccount = false

        for account in store.accounts {
            // Only `.connected` AND Drive-enabled accounts are polled (D-D7/D-D8). With every
            // toggle off — the default — this loop issues zero Drive requests (QA step 1).
            guard account.status == .connected,
                  store.isDriveImportEnabled(for: account.id) else { continue }
            attemptedAnyAccount = true
            do {
                let token = try await tokenProvider.accessToken(for: account.id)
                try await syncAccount(sub: account.id, token: token)
            } catch let error as GoogleAuthError where error == .needsReauth {
                // Terminal auth loss (Phase 1 taxonomy): never retried here; the message carries
                // the reconnect remedy (D-D8 — "needs to be reconnected").
                logger.warning("Drive sync skipped account \(account.id, privacy: .private): needs reauth")
                firstError = firstError ?? syncErrorMessage(accountEmail: account.email, detail: error.localizedDescription)
            } catch {
                // Transient (network, 4xx/5xx, cancellation): watermark untouched (only a fully
                // successful list pass advances it), retried next tick.
                logger.warning("Drive sync failed for account \(account.id, privacy: .private): \(error.localizedDescription)")
                firstError = firstError ?? syncErrorMessage(accountEmail: account.email, detail: error.localizedDescription)
            }
        }

        lastSyncError = firstError
        if attemptedAnyAccount {
            lastSyncAt = now()
        }
    }

    // MARK: - Per-cycle housekeeping (review fixes)

    /// A `.driveImport` job cancelled while still `.queued` never runs its closure
    /// (`JobQueueService.cancel` settles it in place), and the importer is the only thing that
    /// clears a pending guard — so the file would read `.skip` for the rest of the session while
    /// pinning every account's watermark to its `modifiedTime − 1 s`. Reconcile here: any tracked
    /// job that has settled releases its guard (a no-op when the importer already cleared it).
    private func releaseStrandedPendingGuards() {
        for (fileID, jobID) in pendingJobs {
            let job = jobQueue.jobs.first { $0.id == jobID }
            // Gone from the queue (pruned history) or settled ⇒ it will never clear the guard.
            guard job?.state.isActive != true else { continue }
            ledger.clearPending(fileID: fileID)
            pendingJobs.removeValue(forKey: fileID)
        }
    }

    /// D-D6 seeding is only honest if a *stopped* account forgets its watermark: otherwise
    /// toggling Drive off for two months and back on resumes from the stale watermark and
    /// mass-imports everything published meanwhile. The toggle-OFF path clears it eagerly
    /// (`GoogleDriveToggleFlow`); this sweep is the durable backstop that also covers a removed
    /// account and a toggle flipped off while the app was quit. Ledger *entries* survive — import
    /// identity outlives the account (D-D5), so a re-add can never re-import what already landed.
    private func forgetUnpolledAccounts() {
        // Keyed on the toggle and on account existence only — deliberately NOT on `.needsReauth`:
        // under Testing-mode weekly expiry (D-D1) that state is routine, and dropping the
        // watermark there would skip every transcript published during the reauth gap.
        let polled = Set(
            store.accounts
                .filter { store.isDriveImportEnabled(for: $0.id) }
                .map(\.id)
        )
        for sub in ledger.forgetCycleState(exceptSubs: polled) {
            pendingJobs = pendingJobs.filter { GoogleCalendarID.accountSub(fromNamespacedID: $0.key) != sub }
        }
    }

    /// One account's discovery pass: watermark-bounded `files.list`, the per-file D-D5 decision,
    /// capped enqueues, then the crash-safe watermark advance (D-D6).
    private func syncAccount(sub: String, token: String) async throws {
        let cycleStart = now()

        // First-ever cycle for this account: seed the watermark to now and import NOTHING —
        // history is backfill's job, user-controlled (D-D6).
        guard let watermark = ledger.watermark(forSub: sub) else {
            ledger.setWatermark(cycleStart, forSub: sub)
            logger.info("Seeded Drive watermark for account \(sub, privacy: .private)")
            return
        }

        let listing = try await listFiles(token: token, since: watermark.addingTimeInterval(-Self.overlapMargin))

        var enqueued = 0
        for file in listing.files {
            guard enqueued < Self.maxEnqueuesPerCycle else { break }
            let action = ledger.action(for: file, sub: sub, now: now())
            switch action {
            case .skip:
                continue
            case .importNew, .retry, .remerge:
                enqueueImport(file: file, sub: sub, cycleStart: cycleStart)
                enqueued += 1
            }
        }

        // Watermark advance (D-D6, normative — crash-safe): hold the watermark at the earliest
        // **unresolved** discovery so nothing can end up silently below the bound. Unresolved =
        // enqueued-but-not-yet-ledgered (an in-memory job lost to a quit re-surfaces next cycle)
        // **plus failed-but-never-imported** (review fix: the retry cap used to abandon a file
        // that the watermark had already passed — a permanent, invisible drop).
        // `earliestUnresolvedModifiedTime` spans all accounts — conservative across a concurrent
        // sibling account's files, which costs at most a few no-op re-discoveries, never a loss.
        var bound = ledger.earliestUnresolvedModifiedTime
            .map { min(cycleStart, $0.addingTimeInterval(-1)) } ?? cycleStart
        // Truncated pass (review fix): the page walk stopped at `maxListPages`, so everything
        // after the last page is UNSEEN — and since `orderBy: modifiedTime` is ascending, that is
        // the newest end. Advancing to `cycleStart` here would push those files below the next
        // cycle's bound forever, reporting success all the while. Cap the advance at the last
        // file actually seen (− 1 s so it is re-listed) and let the next cycle continue the walk.
        if listing.isTruncated, let lastSeen = listing.lastSeenModifiedTime {
            bound = min(bound, lastSeen.addingTimeInterval(-1))
            logger.warning("Drive list pass truncated at \(GoogleDriveAPI.maxListPages) pages — watermark held at the last page seen")
        }
        ledger.setWatermark(bound, forSub: sub)
    }

    /// Guard, then enqueue: `markPending` covers the enqueue-to-completion window (cleared by the
    /// importer's ledger record), and its `modifiedTime` feeds the watermark bound above.
    private func enqueueImport(file: GoogleDriveAPI.GDriveFile, sub: String, cycleStart: Date) {
        let fileID = GoogleDriveAPI.fileID(sub: sub, raw: file.id)
        ledger.markPending(fileID: fileID, modifiedTime: file.modifiedDate ?? cycleStart)
        let processor = processor
        let jobID = jobQueue.enqueue(
            kind: .driveImport,
            meetingID: nil,   // no meeting yet / not known; per-file dedupe is the pending guard
            priority: .background,
            dedupe: nil,
            progressLabel: ImportedMeetingTitle.displayTitle(for: file.name)
        ) { [weak self] in
            // Serialized + paced (review fix): the `io` lane is unbounded, so all 25 of a cycle's
            // jobs are launched at once; without this gate their exports would hit Drive
            // simultaneously and the resulting rate-limit rejections would spend the ledger's
            // retry budget on failures we caused ourselves.
            let outcome = await self?.serialized {
                // `ownsPendingEntry: true` (F4): this job's file carries the pending entry marked
                // at enqueue above — the re-check must not self-block on it. `.skipped` reads as
                // success.
                await processor.processFile(file, sub: sub, ownsPendingEntry: true)
            }
            if case .failed(let message) = outcome {
                throw GoogleDriveTranscriptImporter.ImportFailed(message: message)
            }
        }
        pendingJobs[fileID] = jobID
    }

    /// Run `work` after every previously enqueued auto-import has finished, then pace the next one.
    /// A plain task chain rather than the job queue's lane cap: `.io` is unbounded by design (and
    /// shared with exports/backfills that must not be blocked), so the bound belongs to this
    /// engine's own traffic.
    private func serialized<T: Sendable>(_ work: @escaping @MainActor () async -> T) async -> T {
        let previous = importChainTail
        let pause = interImportPause
        let workTask = Task { @MainActor () -> T in
            if let previous {
                await previous.value
                if pause > 0 {
                    try? await Task.sleep(nanoseconds: pause)
                }
            }
            return await work()
        }
        // The tail the *next* caller waits on: the same link, result-erased.
        importChainTail = Task { @MainActor in _ = await workTask.value }
        return await workTask.value
    }

    // MARK: - Discovery listing (shared by the cycle and the M4 backfill scan)

    /// One list pass. `files` are the Gemini notes docs (already filtered by the canonical marker
    /// rule); `isTruncated` says the `maxListPages` guard cut the walk short — never a silent
    /// partial success (review fix): the cycle refuses to advance the watermark past what it saw,
    /// and the backfill sheet tells the user the preview is incomplete.
    struct Listing {
        var files: [GoogleDriveAPI.GDriveFile] = []
        var isTruncated = false
        /// Newest `modifiedTime` across **every** raw item walked (matching or not) — the ceiling
        /// a truncated pass may advance the watermark to.
        var lastSeenModifiedTime: Date?
    }

    /// The backfill scan (D-D7): the same discovery rule with **no watermark bound**, paged to
    /// completion (or to the page guard). Never touches watermarks — the scan is read-only
    /// discovery. Uses the `fullText` narrowing because an unbounded pass would otherwise have to
    /// walk every Google Doc in the corpus; the name filter below still decides.
    func scanAllFiles(sub: String) async throws -> Listing {
        let token = try await tokenProvider.accessToken(for: sub)
        return try await listFiles(token: token, since: nil, narrowing: .fullTextMarkers)
    }

    /// Walks the pages, keeping only names that carry the trailing Gemini marker.
    ///
    /// The name predicate cannot live in the query: Drive's `contains` operator prefix-matches
    /// `name`, so a trailing "- Notas de Gemini" never matches server-side (D-D3 review fix,
    /// 2026-08-12). Client-side filtering is the correction, and it is cheap here because the
    /// auto-import pass is bounded to one cycle's `modifiedTime` window.
    private func listFiles(
        token: String,
        since watermark: Date?,
        narrowing: GoogleDriveAPI.Narrowing = .timeWindow
    ) async throws -> Listing {
        var listing = Listing()
        var pageToken: String?
        for _ in 0..<GoogleDriveAPI.maxListPages {
            let request = GoogleDriveAPI.filesListRequest(
                token: token, watermark: watermark, pageToken: pageToken, narrowing: narrowing
            )
            let (data, response) = try await transport.send(request)
            guard response.statusCode == 200 else {
                throw GoogleDriveAPI.RequestFailed(statusCode: response.statusCode)
            }
            let page = try JSONDecoder().decode(GoogleDriveAPI.GDriveFileListPage.self, from: data)
            for file in page.files ?? [] {
                if let modified = file.modifiedDate,
                   modified > (listing.lastSeenModifiedTime ?? .distantPast) {
                    listing.lastSeenModifiedTime = modified
                }
                if ImportedMeetingTitle.hasNotesSuffix(file.name) {
                    listing.files.append(file)
                }
            }
            guard let next = page.nextPageToken else { return listing }
            pageToken = next
        }
        listing.isTruncated = true
        return listing
    }

    // MARK: - Error presentation

    /// The Phase 1 message discipline: a localized frame around a debug-facing detail.
    private func syncErrorMessage(accountEmail: String, detail: String) -> String {
        String(
            format: String(localized: "google.drive.syncError"),
            "\(accountEmail): \(detail)"
        )
    }
}
