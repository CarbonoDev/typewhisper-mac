import Foundation

/// [Perf Phase 2] Calendar refresh wiring: the event-driven `CalendarRefreshCoordinator` that replaced
/// the 60 s poll, and the time-gated consumers (start notifications, auto-briefs) it and the
/// Upcoming-list sink drive. Extension-file discipline: no stored state is added here (the coordinator
/// itself is the VM's `calendarRefresh`).
@MainActor
extension MeetingsViewModel {
    /// Start the calendar refresh while the meetings UI is visible (plan D10): arms the store/system
    /// triggers and the wake timer, and refetches.
    func startCalendarPolling() {
        calendarRefresh.start()
    }

    func stopCalendarPolling() {
        calendarRefresh.stop()
    }

    func makeCalendarRefreshCoordinator() -> CalendarRefreshCoordinator {
        CalendarRefreshCoordinator(
            calendarService: calendarService,
            hooks: .init(
                existingCalendarEventIDs: { [weak self] in self?.existingCalendarEventIDs ?? [] },
                consumerWindows: { [weak self] in self?.calendarConsumerWindows ?? [] },
                runConsumers: { [weak self] events, now in self?.runCalendarConsumers(events, now: now) }
            )
        )
    }

    /// The published Upcoming list changed: run the consumers on it and re-plan the wake.
    func calendarUpcomingDidChange(_ events: [CalendarEventDTO]) {
        runCalendarConsumers(events, now: Date())
        calendarRefresh.reschedule()
    }

    /// The consumers' time gates, for the wake planner.
    var calendarConsumerWindows: [CalendarWakePlanner.ConsumerWindow] {
        [MeetingStartNotificationService.consumerWindow] + [briefScheduler.consumerWindow].compactMap { $0 }
    }

    /// Run the time-gated consumers over the Upcoming list.
    func runCalendarConsumers(_ events: [CalendarEventDTO], now: Date) {
        // [Google Phase 1 · M4 / PR #7 review finding 4] Collapse cross-provider CalDAV twins for
        // the *automatic* consumers only: the published list (and the Calendars selection UI) keeps
        // both copies — D-G6 owns the visible half — but auto-created meetings, brief jobs on the
        // cap-1 `llm` lane and start notifications must fire once per real event, not once per
        // provider copy.
        let deduplicated = CalendarEventTwinCollapser.collapse(events)
        // Prompt (never silently record) when a scheduled meeting reaches its start (D10).
        startNotificationService.notifyStartingMeetings(deduplicated, now: now)
        // [Track D] Auto-generate pre-meeting briefs for events entering the lead window (AD9).
        briefScheduler.tick(events: deduplicated, now: now)
    }
}
