import Foundation
import AppKit
import Combine
import EventKit

/// [Perf Phase 2] The one calendar refresh coordinator: replaces the 60 s poll that re-queried
/// EventKit on the main actor and re-ran every downstream consumer each minute.
///
/// - **Refetch** (provider query, EventKit off the main actor via `CalendarService.refreshInBackground`)
///   on `EKEventStoreChanged`, system wake, day rollover and clock / time-zone changes — while
///   `start`ed — and on demand (`refetch()`: Google snapshot changes, access grants). Bursts of
///   triggers coalesce into one in-flight query plus at most one follow-up.
/// - **Wake** — one one-shot timer armed for `CalendarWakePlanner.nextWake`: a re-window of the
///   retained query (no provider hit) or, when the retained query stops covering the window, a
///   refetch. Time-gated consumers (start notifications, auto-briefs) run on every wake, so they see
///   their windows open at the same moments the poll gave them.
/// - **Equality gate** — `CalendarService` publishes a section only when it changed; consumers run
///   from that publish (the VM sink) or from a wake, never from an unchanged re-query.
///
/// Like the poll it replaces, the store/system triggers and the wake timer are live only between
/// `start` and `stop` (the main window / meetings settings lifetime).
@MainActor
final class CalendarRefreshCoordinator {
    typealias WakeScheduler = @MainActor (
        _ delay: TimeInterval,
        _ action: @escaping @MainActor @Sendable () -> Void
    ) -> AnyCancellable

    struct Hooks {
        /// The VM's exclusion set (events already backing an engaged meeting).
        var existingCalendarEventIDs: @MainActor () -> Set<String>
        /// The time-gated consumers' windows, re-read on every plan (settings may change).
        var consumerWindows: @MainActor () -> [CalendarWakePlanner.ConsumerWindow]
        /// Run the time-gated consumers over the published Upcoming list.
        var runConsumers: @MainActor (_ events: [CalendarEventDTO], _ now: Date) -> Void
        /// Leads before an event's start at which a time-driven display changes (`CalendarClock`).
        var displayLeads: @MainActor () -> [TimeInterval] = { [] }
        /// Emits when the exclusion set may have changed without a VM call to `loadUpcoming` — a
        /// meeting deleted or merged away, an auto-brief placeholder engaged by capture start. The
        /// coordinator re-windows the retained query (no provider hit), started or not.
        var exclusionsChanged: AnyPublisher<Void, Never> = Empty().eraseToAnyPublisher()
    }

    private let calendarService: CalendarService
    private let now: @MainActor () -> Date
    private let scheduleWake: WakeScheduler
    private let notificationCenter: NotificationCenter
    private let workspaceNotificationCenter: NotificationCenter
    private let hooks: Hooks

    private var isStarted = false
    private var triggerObservers: [AnyCancellable] = []
    private var exclusionObserver: AnyCancellable?
    private var wakeTimer: AnyCancellable?
    private var refetchTask: Task<Void, Never>?
    /// A trigger arrived while a query was in flight: run one more when it lands.
    private var refetchPending = false
    /// A pending refetch owes the consumers a run even if nothing changed (it came from a wake).
    private var pendingRunsConsumers = false

    /// The armed wake, for tests and diagnostics.
    private(set) var nextWake: CalendarWakePlanner.Wake?

    /// Ticked after every wake and every refetch, so time-driven displays re-render at the instants
    /// they can change (see `CalendarClock`).
    let clock = CalendarClock()

    init(
        calendarService: CalendarService,
        hooks: Hooks,
        now: @escaping @MainActor () -> Date = { Date() },
        notificationCenter: NotificationCenter = .default,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        scheduleWake: @escaping WakeScheduler = CalendarRefreshCoordinator.timerWake
    ) {
        self.calendarService = calendarService
        self.hooks = hooks
        self.now = now
        self.notificationCenter = notificationCenter
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.scheduleWake = scheduleWake
        exclusionObserver = hooks.exclusionsChanged.sink { [weak self] in self?.exclusionsDidChange() }
    }

    /// Re-apply the exclusion set to the retained query (`Hooks.exclusionsChanged`). A change in
    /// the Upcoming list reaches the consumers through the VM sink, which also re-plans.
    private func exclusionsDidChange() {
        calendarService.rewindow(now: now(), existingCalendarEventIDs: hooks.existingCalendarEventIDs())
    }

    // MARK: - Lifecycle

    /// Arm the triggers (once) and refetch — each call refetches, as each `startCalendarPolling`
    /// call used to re-query.
    func start() {
        if !isStarted {
            isStarted = true
            observeTriggers()
        }
        refetch()
    }

    func stop() {
        isStarted = false
        triggerObservers.removeAll()
        wakeTimer = nil
        nextWake = nil
    }

    // MARK: - Refetch

    /// Query every provider (off the main actor for EventKit) and publish what changed. Allowed while
    /// stopped too (Google snapshot changes refreshed the lists before the poll started, too).
    func refetch() {
        refetch(runsConsumers: false)
    }

    /// Await the in-flight query (and its follow-up), for tests.
    func settle() async {
        while let task = refetchTask {
            await task.value
        }
    }

    private func refetch(runsConsumers: Bool) {
        guard refetchTask == nil else {
            refetchPending = true
            pendingRunsConsumers = pendingRunsConsumers || runsConsumers
            return
        }
        refetchTask = Task { [weak self] in
            guard let self else { return }
            let at = self.now()
            let changed = await self.calendarService.refreshInBackground(
                now: at,
                existingCalendarEventIDs: self.hooks.existingCalendarEventIDs()
            )
            // A change reaches the consumers through the published-list sink; a wake-driven
            // refetch owes them a run regardless (their windows are time-gated).
            if runsConsumers && !changed {
                self.hooks.runConsumers(self.calendarService.upcomingEvents, at)
            }
            self.refetchTask = nil
            self.clock.tick(at)
            self.reschedule()
            if self.refetchPending {
                let followUpRunsConsumers = self.pendingRunsConsumers
                self.refetchPending = false
                self.pendingRunsConsumers = false
                self.refetch(runsConsumers: followUpRunsConsumers)
            }
        }
    }

    // MARK: - Wake

    /// Re-plan the single wake timer from the current calendar state. Called after every refetch
    /// and wake, and by the VM whenever the published Upcoming list changes.
    func reschedule() {
        guard isStarted else { return }
        let at = now()
        let wake = CalendarWakePlanner.nextWake(
            sourceEvents: calendarService.selectedSourceEvents,
            consumerEvents: CalendarEventTwinCollapser.collapse(calendarService.upcomingEvents),
            now: at,
            lookAhead: calendarService.lookAhead,
            grace: calendarService.grace,
            consumerWindows: hooks.consumerWindows(),
            displayLeads: hooks.displayLeads(),
            refetchAt: calendarService.nextRefetchDate()
        )
        guard wake != nextWake || wakeTimer == nil else { return }
        nextWake = wake
        wakeTimer = nil
        if let wake {
            wakeTimer = scheduleWake(max(0, wake.date.timeIntervalSince(at))) { [weak self] in
                self?.fire(wake)
            }
        }
    }

    private func fire(_ wake: CalendarWakePlanner.Wake) {
        wakeTimer = nil
        nextWake = nil
        guard isStarted else { return }
        if wake.isRefetch {
            refetch(runsConsumers: true)
            return
        }
        let at = now()
        let changed = calendarService.rewindow(now: at, existingCalendarEventIDs: hooks.existingCalendarEventIDs())
        if !changed {
            hooks.runConsumers(calendarService.upcomingEvents, at)
        }
        clock.tick(at)
        reschedule()
    }

    // MARK: - Triggers

    private func refetchOn(_ center: NotificationCenter, _ name: Notification.Name) -> AnyCancellable {
        center.publisher(for: name)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refetch() }
    }

    private func observeTriggers() {
        triggerObservers = [
            // Any calendar database change (EventKit posts it for every store in the process).
            refetchOn(notificationCenter, .EKEventStoreChanged),
            // The rolling window must advance across midnight, clock jumps and time-zone changes.
            refetchOn(notificationCenter, .NSCalendarDayChanged),
            refetchOn(notificationCenter, .NSSystemClockDidChange),
            refetchOn(notificationCenter, .NSSystemTimeZoneDidChange),
            // Timers do not advance during sleep: re-query and re-plan on wake.
            refetchOn(workspaceNotificationCenter, NSWorkspace.didWakeNotification),
        ]
    }

    /// Production wake: a one-shot main-run-loop timer in common modes (fires during tracking).
    static func timerWake(
        _ delay: TimeInterval,
        _ action: @escaping @MainActor @Sendable () -> Void
    ) -> AnyCancellable {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated { action() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        return AnyCancellable { timer.invalidate() }
    }
}
