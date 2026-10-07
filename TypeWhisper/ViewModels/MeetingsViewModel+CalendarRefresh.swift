import Combine
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

    /// The clock time-driven calendar displays observe (see `CalendarClock`).
    var calendarClock: CalendarClock { calendarRefresh.clock }

    func makeCalendarRefreshCoordinator() -> CalendarRefreshCoordinator {
        // Owned by the hook closure (no VM stored state in an extension).
        let linkedMeetingSync = LinkedMeetingCalendarSync(meetingService: meetingService)
        return CalendarRefreshCoordinator(
            calendarService: calendarService,
            hooks: .init(
                existingCalendarEventIDs: { [weak self] in self?.existingCalendarEventIDs ?? [] },
                consumerWindows: { [weak self] in self?.calendarConsumerWindows ?? [] },
                runConsumers: { [weak self] events, now in self?.runCalendarConsumers(events, now: now) },
                displayLeads: { [MeetingTrayIndicator.trayTitleWindow] },
                // Both hops are load-bearing: the exclusion set is read from `meetingService.meetings`
                // and `Meeting.state`, which `@Published`'s willSet emission precedes (the list), or
                // which capture start writes later in the same turn (`.live`, after `activeMeeting`).
                exclusionsChanged: Publishers.Merge(
                    // Membership: a calendar-linked meeting deleted or merged frees its event.
                    meetingService.meetingsListPublisher.map { _ in () },
                    // An auto-brief placeholder becomes engaged when its capture starts.
                    captureService.$activeMeeting.dropFirst().map { _ in () }
                )
                .receive(on: DispatchQueue.main)
                .eraseToAnyPublisher(),
                reconcileLinkedMeetings: { linkedMeetingSync.reconcile($0) }
            )
        )
    }

    /// `createMeeting(from:)` reusing the meeting already linked to `event` (an auto-brief
    /// placeholder, say): bring an untouched one in line with the event first, so capture started
    /// from a moved occurrence never records into yesterday's dates.
    func syncedLinkedMeeting(_ meeting: Meeting, with event: CalendarEventDTO) -> Meeting {
        meetingService.applyCalendarReconciliation(
            CalendarMeetingReconciler.changes(meetings: [meeting], events: [event])
        )
        return meeting
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
