import Combine
import Foundation

/// [Perf Phase 2 · VM split] The calendar slice of `MeetingsViewModel`: the calendar service's lists
/// and status mirrored for views, plus the derived source-availability flags and the twin-calendar
/// prompts, on their own `ObservableObject` so a calendar refetch re-renders only the calendar
/// surfaces (Coming Up, Upcoming/Earlier, the Calendars settings, the tray) instead of every
/// observer of the singleton view model.
///
/// Owned by `MeetingsViewModel` as `calendar` (a plain `let`); the VM forwards the old property
/// names as computed properties and keeps the actions (selection writes, twin-prompt resolution,
/// focus requests). Writes still go through `CalendarService` and `GoogleAccountStore`.
/// See `docs/specs/2026-10-06-meetings-vm-split.md`.
@MainActor
final class MeetingsCalendarModel: ObservableObject {
    @Published private(set) var calendarAuthorizationStatus: CalendarAuthorizationStatus
    /// [Google Phase 1 · M4] Whether *any* calendar source can feed the meetings UI (D-G4):
    /// the primary (EventKit) provider is authorized **or** ≥ 1 Google account is connected.
    /// The calendar-UI availability gate (`HomeNextSection`, `UpcomingMeetingsSection`,
    /// `MeetingLinkEventView`) — without it a Google-only user (EventKit denied) would get fan-in
    /// events that never render. Fed from the status mirror plus `GoogleAccountStore.$accounts`.
    @Published private(set) var hasAnyCalendarSource = false
    /// [PR #7 review finding 5] Whether to surface the "one source is broken" row: macOS Calendar
    /// access is denied/restricted **while another source still works**, so the D-G4 suppression of
    /// `calendarErrorMessage` (a working configuration is not an error) would otherwise hide the
    /// missing iCloud/Exchange/local calendars everywhere outside Settings. Session-dismissible.
    @Published private(set) var showsSystemCalendarProblem = false
    /// [PR #7 review finding 7] Bumped whenever calendar *selection* changes through the view
    /// model (per-calendar toggle, group toggle, twin-prompt resolution). `CalendarSelectionSection`
    /// keeps a local `@State` row snapshot — selection is read from the service, not a `@Published`
    /// — so it needs an explicit signal to reload after a selection write it did not make itself.
    @Published private(set) var calendarSelectionRevision = 0
    /// [Google Phase 1 · M4] Pending "duplicate calendars detected" prompts (D-G6), one per
    /// connected Google account whose EventKit CalDAV twins were found and whose prompt has not
    /// been handled yet. Rendered inline by `GoogleAccountsSection`; re-evaluated on every Google
    /// snapshot change while unhandled.
    @Published private(set) var twinCalendarPrompts: [TwinCalendarPrompt] = []
    @Published private(set) var upcomingEvents: [CalendarEventDTO]
    /// [M10] Already-ended events from the lookback window (since start of day) — the collapsible
    /// "Earlier" section. Mirrored from `CalendarService.earlierEvents`.
    @Published private(set) var earlierEvents: [CalendarEventDTO]
    @Published private(set) var calendarErrorMessage: String?

    /// In-memory (per launch) dismissal of the per-source problem row — the same "hide it now"
    /// semantics as `CalendarService.dismiss(eventID:)`, deliberately not persisted: the remedy
    /// lives in System Settings and the row must come back if the user never applies it.
    private var systemCalendarProblemDismissed = false
    private let calendarService: CalendarService
    /// Read-only consumer (the store stays the single writer of all `google.*` state). Optional so
    /// unit tests constructing the VM without the Google stack keep compiling.
    private let googleAccountStore: GoogleAccountStore?
    private var cancellables = Set<AnyCancellable>()

    init(calendarService: CalendarService, googleAccountStore: GoogleAccountStore?) {
        self.calendarService = calendarService
        self.googleAccountStore = googleAccountStore
        calendarAuthorizationStatus = calendarService.authorizationStatus
        upcomingEvents = calendarService.upcomingEvents
        earlierEvents = calendarService.earlierEvents
        calendarErrorMessage = calendarService.errorMessage
        // [Google Phase 1 · M4] Seed the availability flag from both sources (D-G4), and the
        // per-source problem flag, which is *not* the same question (PR #7 review finding 5).
        let accounts = googleAccountStore?.accounts ?? []
        hasAnyCalendarSource = MeetingsViewModel.hasAnyCalendarSource(
            authorization: calendarService.authorizationStatus,
            accounts: accounts
        )
        showsSystemCalendarProblem = MeetingsViewModel.showsSystemCalendarProblem(
            authorization: calendarService.authorizationStatus,
            accounts: accounts,
            dismissed: false
        )

        // Synchronous: the follow-ups read the mirror just set, the account store, and EventKit's
        // live status (`availableCalendars`) — none of them the service's not-yet-set property.
        calendarService.$authorizationStatus
            .sink { [weak self] status in
                guard let self else { return }
                if self.calendarAuthorizationStatus != status { self.calendarAuthorizationStatus = status }
                // [Google Phase 1 · M4] Both inputs of the availability flag flow through here
                // or the `$accounts` sink below, so it can never go stale (D-G4). EventKit
                // authorization also gates twin detection (no EventKit calendars ⇒ no twins).
                self.recomputeHasAnyCalendarSource()
                self.evaluateTwinPrompts()
            }
            .store(in: &cancellables)
        // [Google Phase 1 · M4] Google connect state is the second leg of `hasAnyCalendarSource`
        // (D-G4) — the store publishes every index change (connect, disconnect, status flip).
        // Hop load-bearing: both follow-ups re-read `googleAccountStore.accounts` (directly and via
        // the Google provider's `calendars()`), which `$accounts`' willSet emission precedes.
        googleAccountStore?.$accounts
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.recomputeHasAnyCalendarSource()
                // [M4 review fix 3] Symmetry with the status/snapshot sinks: a disconnect (or an
                // account change riding an index write) retracts or surfaces a pending twin
                // prompt immediately instead of waiting for the next snapshot change.
                self.evaluateTwinPrompts()
            }
            .store(in: &cancellables)
        calendarService.$upcomingEvents.mirror(to: self, \.upcomingEvents).store(in: &cancellables)
        calendarService.$earlierEvents.mirror(to: self, \.earlierEvents).store(in: &cancellables)
        calendarService.$errorMessage.mirror(to: self, \.calendarErrorMessage).store(in: &cancellables)
    }

    var isCalendarAuthorized: Bool { calendarAuthorizationStatus == .authorized }

    func recomputeHasAnyCalendarSource() {
        let accounts = googleAccountStore?.accounts ?? []
        let hasSource = MeetingsViewModel.hasAnyCalendarSource(
            authorization: calendarAuthorizationStatus,
            accounts: accounts
        )
        let showsProblem = MeetingsViewModel.showsSystemCalendarProblem(
            authorization: calendarAuthorizationStatus,
            accounts: accounts,
            dismissed: systemCalendarProblemDismissed
        )
        if hasAnyCalendarSource != hasSource { hasAnyCalendarSource = hasSource }
        if showsSystemCalendarProblem != showsProblem { showsSystemCalendarProblem = showsProblem }
    }

    /// [PR #7 review finding 5] Hide the per-source problem row for this launch.
    func dismissSystemCalendarProblem() {
        systemCalendarProblemDismissed = true
        recomputeHasAnyCalendarSource()
    }

    /// Re-run twin detection (D-G6) over the fanned-in calendar list for every not-yet-handled
    /// Google account. Called on every snapshot change and on EventKit status changes; pure logic
    /// lives in `TwinCalendarDetector.prompts`.
    func evaluateTwinPrompts() {
        let prompts = googleAccountStore.map { store in
            TwinCalendarDetector.prompts(
                accounts: store.accounts,
                eventKitAuthorized: calendarAuthorizationStatus == .authorized,
                calendars: calendarService.availableCalendars(),
                isHandled: store.isTwinPromptHandled
            )
        } ?? []
        if twinCalendarPrompts != prompts { twinCalendarPrompts = prompts }
    }

    /// Drop a resolved twin prompt (the VM records it as handled through the store first).
    func removeTwinPrompt(accountID: TwinCalendarPrompt.ID) {
        twinCalendarPrompts.removeAll { $0.accountID == accountID }
    }

    /// Signal `CalendarSelectionSection` to reload its row snapshot after a selection write.
    func noteSelectionChanged() {
        calendarSelectionRevision += 1
    }
}
