import Foundation
import Combine
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "GoogleCalendarSyncEngine")

/// The token seam the sync engine (and Phase 2/3 services) consume — `GoogleAuthService` in
/// production, a fake in tests (§7). Scope-agnostic: Google access tokens carry the union of
/// granted scopes.
@MainActor
protocol GoogleAccessTokenProviding: AnyObject {
    func accessToken(for accountID: String) async throws -> String
}

extension GoogleAuthService: GoogleAccessTokenProviding {}

extension Notification.Name {
    /// Posted by `GoogleCalendarSyncEngine` when its snapshot *content* changed (D-G7).
    /// `MeetingsViewModel` observes it (M4) and runs the same refresh as its 60 s tick, so new
    /// events appear without waiting for the next poll.
    static let googleCalendarSnapshotDidChange = Notification.Name("googleCalendarSnapshotDidChange")
}

/// Periodic Google Calendar sync into an in-memory snapshot ([Google Phase 1 · M3], D-G7).
/// `CalendarEventProviding.events(from:to:)` is synchronous and called on the main actor, so a
/// network provider cannot answer inline — this engine fetches every connected account's
/// calendars + events on a 5-minute app-lifetime cadence (deliberately *not* the UI-visibility
/// -scoped poll) and `GoogleCalendarProvider` serves the snapshot synchronously.
///
/// Failure semantics (D-G4): a *transient* sync failure (network, 4xx/5xx) keeps the account's
/// last good snapshot — events degrade to stale, never to an empty list — and surfaces through
/// `lastSyncError` for the settings section. A `.needsReauth` from the token seam (terminal auth
/// loss; the auth service already flipped the account's status) is never retried here: the
/// account is skipped with a user-facing `lastSyncError`, and once *every* account has dropped
/// out of `.connected` the provider's authorization status clears its events — intended,
/// mirroring EventKit-denied.
///
/// Failure granularity is *per calendar* inside an account (PR #7 review finding 1): a single
/// calendar whose `events.list` keeps failing (revoked share, stale subscription) is skipped —
/// keeping its own last good events — while every other calendar of that account still syncs, and
/// the failure count is reported through `lastSyncError`. Only a `calendarList` failure fails the
/// whole account slice.
@MainActor
final class GoogleCalendarSyncEngine: ObservableObject {
    /// D-G7 cadence.
    nonisolated static let defaultSyncInterval: TimeInterval = 5 * 60

    /// One calendar with its fetched events — the snapshot element the provider reads.
    struct CalendarEvents: Equatable, Sendable {
        var calendar: CalendarInfo
        var events: [CalendarEventDTO]
    }

    /// Wall clock of the last completed sync cycle that had at least one connected account to
    /// try (settings section, M3).
    @Published private(set) var lastSyncAt: Date?
    /// User-facing description of the last cycle's first failure; `nil` after a clean cycle.
    @Published private(set) var lastSyncError: String?

    /// The current snapshot, flattened across accounts in account-index order. Read synchronously
    /// by `GoogleCalendarProvider`; not `@Published` — consumers react to
    /// `.googleCalendarSnapshotDidChange` instead (the settings UI observes the published sync
    /// metadata above).
    private(set) var snapshot: [CalendarEvents] = []

    private let store: GoogleAccountStore
    private let tokenProvider: GoogleAccessTokenProviding
    private let transport: GoogleHTTPTransport
    /// Injected clock so window math is deterministic under test (§7).
    private let now: () -> Date
    private let syncInterval: TimeInterval

    /// Per-account snapshot slices (`sub` → calendars+events), so one account's failure never
    /// drops another account's data and a transient failure keeps the account's last good slice.
    private var accountSnapshots: [String: [CalendarEvents]] = [:]
    /// Single-flight: a "Refresh now" landing while the timer's sync runs awaits it instead of
    /// racing a second fetch.
    private var inFlightSync: Task<Void, Never>?
    /// Set when `syncNow` coalesces into a running driver (M3 review finding 1): that cycle read
    /// `store.accounts` at its start, so an account connected mid-cycle — or a "Refresh now"
    /// landing during a tick — would otherwise be a no-op until the next 5-min tick. The driver
    /// runs one more full cycle while this is set.
    private var resyncRequested = false
    private var timerTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    /// Pagination hard stop — a defensive bound, far above any real calendar's page count.
    private let maxPages = 20

    init(
        store: GoogleAccountStore,
        tokenProvider: GoogleAccessTokenProviding,
        transport: GoogleHTTPTransport = URLSessionGoogleTransport(),
        now: @escaping () -> Date = Date.init,
        syncInterval: TimeInterval = GoogleCalendarSyncEngine.defaultSyncInterval
    ) {
        self.store = store
        self.tokenProvider = tokenProvider
        self.transport = transport
        self.now = now
        self.syncInterval = syncInterval
    }

    deinit {
        timerTask?.cancel()
    }

    // MARK: - Lifecycle

    /// Starts the 5-minute cadence (immediate first sync) and the connect/disconnect trigger:
    /// any change to the set of accounts or their statuses re-syncs immediately, so a freshly
    /// connected account's events appear without waiting for the next tick (D-G7). Idempotent.
    /// Called from `ServiceContainer.initialize()` — never under tests, which drive `syncNow()`
    /// directly.
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

    /// One full sync cycle across every `.connected` account. Also the "Refresh now" entry point.
    ///
    /// Coalescing (M3 review findings 1+2): a call landing while a driver runs never races a
    /// second fetch — it flags `resyncRequested` and awaits the driver, which loops one more
    /// *full* cycle (re-reading `store.accounts`) before exiting, so an account connected
    /// mid-cycle is fetched immediately rather than on the next tick. The driver's final
    /// flag-check and its clearing of `inFlightSync` happen in one synchronous main-actor
    /// stretch, so there is no window in which a request can land on an already-finished driver
    /// and be lost: a caller either flags a driver that will still check, or finds
    /// `inFlightSync == nil` and starts a fresh one.
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
                // No suspension between this check and the clear below — the exit is atomic
                // with respect to other main-actor code (finding 2).
                if self.resyncRequested { continue }
                self.inFlightSync = nil
                return
            }
        }
        inFlightSync = task
        await task.value
    }

    private func performSync() async {
        let accounts = store.accounts
        // Prune slices of disconnected (removed) accounts so their events leave the snapshot.
        var slices = accountSnapshots.filter { sub, _ in accounts.contains { $0.id == sub } }
        var firstError: String?
        var attemptedAnyAccount = false

        for account in accounts {
            // Accounts already flagged `.needsReauth` are skipped without re-surfacing an error —
            // the settings row's "Needs attention" badge communicates it, and hammering the token
            // endpoint with a known-rejected refresh token helps nobody.
            guard account.status == .connected else { continue }
            attemptedAnyAccount = true
            do {
                let token = try await tokenProvider.accessToken(for: account.id)
                // Per-calendar isolation (PR #7 review finding 1): one permanently failing
                // calendar (revoked share, stale subscription ⇒ persistent 403/404) must never
                // abort the account's whole slice — that would freeze the account's events at the
                // last good snapshot forever. The good calendars land; the failed ones are
                // reported as a per-account note.
                let outcome = try await fetchAccountSlice(
                    account: account,
                    token: token,
                    previous: slices[account.id] ?? []
                )
                slices[account.id] = outcome.slice
                if outcome.failedCalendars > 0 {
                    firstError = firstError ?? calendarFailureMessage(
                        accountEmail: account.email,
                        count: outcome.failedCalendars
                    )
                }
            } catch let error as GoogleAuthError where error == .needsReauth {
                // Terminal auth loss: the auth service already flipped the account's status (M1
                // handoff — do NOT retry). Keep the last good slice; the provider's authorization
                // status clears events once no account is left `.connected`.
                //
                // M3 review finding 4 (documented, accepted): while a sibling account stays
                // connected, this account's stale slice keeps being served indefinitely — only
                // full auth loss clears events via the provider status. An M4+ consideration
                // (e.g. drop or age out the slice) if per-account clearing turns out to matter.
                logger.warning("Sync skipped account \(account.id, privacy: .private): needs reauth")
                firstError = firstError ?? syncErrorMessage(accountEmail: account.email, detail: error.localizedDescription)
            } catch {
                // Transient (network, 4xx/5xx, cancellation — the taxonomy is open, M1 handoff):
                // keep the last good slice so events go stale, never empty (D-G4); retried next tick.
                logger.warning("Sync failed for account \(account.id, privacy: .private): \(error.localizedDescription)")
                firstError = firstError ?? syncErrorMessage(accountEmail: account.email, detail: error.localizedDescription)
            }
        }

        accountSnapshots = slices
        let flattened = accounts.compactMap { slices[$0.id] }.flatMap { $0 }
        if flattened != snapshot {
            snapshot = flattened
            NotificationCenter.default.post(name: .googleCalendarSnapshotDidChange, object: nil)
        }
        lastSyncError = firstError
        // M3 review finding 3 (documented, accepted): `lastSyncAt` deliberately reads "last time
        // a sync had something to try", so it does not bump when no account is `.connected` —
        // in the all-needsReauth state "Refresh now" appears inert, which matches reality (there
        // is nothing to refresh; the rows' "Needs attention" badges point at the remedy).
        if attemptedAnyAccount {
            lastSyncAt = now()
        }
    }

    /// One account's calendars + events: `calendarList`, then per calendar the events in the
    /// D-G7 window, both paginated.
    ///
    /// Failure granularity (D-G4, PR #7 review finding 1): the `calendarList` call still throws —
    /// without the calendar list there is no slice to build, so the account keeps its last good
    /// one. A *per-calendar* `events.list` failure, by contrast, is isolated: that calendar keeps
    /// its previously fetched events (stale, never empty — `previous` is the account's last good
    /// slice) or is skipped when it has none yet, every other calendar still syncs, and the count
    /// of failed calendars comes back for `lastSyncError`.
    private func fetchAccountSlice(
        account: GoogleAccount,
        token: String,
        previous: [CalendarEvents]
    ) async throws -> (slice: [CalendarEvents], failedCalendars: Int) {
        let window = Self.syncWindow(now: now())
        let previousEvents = Dictionary(
            previous.map { ($0.calendar.id, $0.events) },
            uniquingKeysWith: { first, _ in first }
        )
        var slice: [CalendarEvents] = []
        var failedCalendars = 0
        for entry in try await fetchCalendarList(token: token) {
            let info = GoogleCalendarMapper.calendarInfo(
                from: entry,
                sub: account.id,
                accountEmail: account.email
            )
            do {
                let events = try await fetchEvents(
                    calendarRawID: entry.id,
                    info: info,
                    account: account,
                    token: token,
                    window: window
                )
                slice.append(CalendarEvents(calendar: info, events: events))
            } catch {
                failedCalendars += 1
                logger.warning(
                    "Sync failed for calendar \(info.id, privacy: .private): \(error.localizedDescription)"
                )
                guard let stale = previousEvents[info.id] else { continue }
                slice.append(CalendarEvents(calendar: info, events: stale))
            }
        }
        return (slice, failedCalendars)
    }

    private func fetchCalendarList(token: String) async throws -> [GoogleCalendarAPI.GCalCalendarListEntry] {
        var entries: [GoogleCalendarAPI.GCalCalendarListEntry] = []
        var pageToken: String?
        for _ in 0..<maxPages {
            let page: GoogleCalendarAPI.GCalCalendarListPage = try await send(
                GoogleCalendarAPI.calendarListRequest(token: token, pageToken: pageToken)
            )
            entries.append(contentsOf: page.items ?? [])
            guard let next = page.nextPageToken else { return entries }
            pageToken = next
        }
        return entries
    }

    private func fetchEvents(
        calendarRawID: String,
        info: CalendarInfo,
        account: GoogleAccount,
        token: String,
        window: (start: Date, end: Date)
    ) async throws -> [CalendarEventDTO] {
        var events: [CalendarEventDTO] = []
        var pageToken: String?
        for _ in 0..<maxPages {
            let page: GoogleCalendarAPI.GCalEventsPage = try await send(
                GoogleCalendarAPI.eventsRequest(
                    calendarID: calendarRawID,
                    token: token,
                    timeMin: window.start,
                    timeMax: window.end,
                    pageToken: pageToken
                )
            )
            events.append(contentsOf: (page.items ?? []).compactMap { event in
                GoogleCalendarMapper.eventDTO(
                    from: event,
                    calendar: info,
                    sub: account.id,
                    accountEmail: account.email
                )
            })
            guard let next = page.nextPageToken else { return events }
            pageToken = next
        }
        return events
    }

    private func send<Page: Decodable>(_ request: URLRequest) async throws -> Page {
        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200 else {
            throw GoogleCalendarAPI.RequestFailed(statusCode: response.statusCode)
        }
        return try JSONDecoder().decode(Page.self, from: data)
    }

    // MARK: - Window math (pure, D-G7)

    /// `[startOfDay(now) − 1d, now + 48h]` — a superset of `CalendarService`'s lookback + 12 h
    /// look-ahead, with margin for the link picker's near-window queries. `nonisolated` static so
    /// tests assert it without MainActor hops.
    nonisolated static func syncWindow(now: Date, calendar: Calendar = .current) -> (start: Date, end: Date) {
        (
            start: calendar.startOfDay(for: now).addingTimeInterval(-24 * 60 * 60),
            end: now.addingTimeInterval(48 * 60 * 60)
        )
    }

    // MARK: - Error presentation

    /// M2 precedent (review finding 3, documented/accepted): the detail is a debug-facing English
    /// error inside a localized frame — an OAuth/HTTP code is useful verbatim in bug reports.
    private func syncErrorMessage(accountEmail: String, detail: String) -> String {
        String(
            format: String(localized: "google.calendar.syncError"),
            "\(accountEmail): \(detail)"
        )
    }

    /// Partial-failure note (PR #7 review finding 1): the account synced, but N of its calendars
    /// could not be read. Surfaced in the same `lastSyncError` line as a whole-account failure —
    /// the good calendars' events are already published.
    private func calendarFailureMessage(accountEmail: String, count: Int) -> String {
        String(
            format: String(localized: "google.calendar.calendarsFailed"),
            accountEmail,
            count
        )
    }
}
