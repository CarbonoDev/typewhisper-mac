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

    private var inFlightSync: Task<Void, Never>?
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
        syncInterval: TimeInterval = GoogleDriveSyncEngine.defaultSyncInterval
    ) {
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

        let files = try await listFiles(token: token, since: watermark.addingTimeInterval(-Self.overlapMargin))

        var enqueued = 0
        for file in files {
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

        // Watermark advance (D-D6, normative — crash-safe): on this fully successful list pass,
        // hold the watermark at the earliest enqueued-but-not-yet-ledgered discovery so an
        // in-memory job lost to a quit re-surfaces next cycle (the pending map is in-memory; the
        // ledger is what makes re-discoveries no-ops). `earliestPendingModifiedTime` spans all
        // accounts — conservative across a concurrent sibling account's pending files, which
        // costs at most a few no-op re-discoveries, never a lost file.
        let bound = ledger.earliestPendingModifiedTime
            .map { min(cycleStart, $0.addingTimeInterval(-1)) } ?? cycleStart
        ledger.setWatermark(bound, forSub: sub)
    }

    /// Guard, then enqueue: `markPending` covers the enqueue-to-completion window (cleared by the
    /// importer's ledger record), and its `modifiedTime` feeds the watermark bound above.
    private func enqueueImport(file: GoogleDriveAPI.GDriveFile, sub: String, cycleStart: Date) {
        let fileID = GoogleDriveAPI.fileID(sub: sub, raw: file.id)
        ledger.markPending(fileID: fileID, modifiedTime: file.modifiedDate ?? cycleStart)
        let processor = processor
        jobQueue.enqueue(
            kind: .driveImport,
            meetingID: nil,   // no meeting yet / not known; per-file dedupe is the pending guard
            priority: .background,
            dedupe: nil,
            progressLabel: ImportedMeetingTitle.displayTitle(for: file.name)
        ) {
            let outcome = await processor.processFile(file, sub: sub)
            if case .failed(let message) = outcome {
                throw GoogleDriveTranscriptImporter.ImportFailed(message: message)
            }
        }
    }

    private func listFiles(token: String, since watermark: Date) async throws -> [GoogleDriveAPI.GDriveFile] {
        var files: [GoogleDriveAPI.GDriveFile] = []
        var pageToken: String?
        for _ in 0..<GoogleDriveAPI.maxListPages {
            let request = GoogleDriveAPI.filesListRequest(token: token, watermark: watermark, pageToken: pageToken)
            let (data, response) = try await transport.send(request)
            guard response.statusCode == 200 else {
                throw GoogleDriveAPI.RequestFailed(statusCode: response.statusCode)
            }
            let page = try JSONDecoder().decode(GoogleDriveAPI.GDriveFileListPage.self, from: data)
            files.append(contentsOf: page.files ?? [])
            guard let next = page.nextPageToken else { return files }
            pageToken = next
        }
        return files
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
