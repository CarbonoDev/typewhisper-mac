import Foundation
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "MeetingAutoJoinService")

/// Opens a calendar meeting's join link automatically when its start time arrives, in the owning
/// Google account's Chrome profile (`MeetingJoinLauncher`). Time-gated like
/// `MeetingStartNotificationService`: driven by `CalendarRefreshCoordinator` via
/// `MeetingsViewModel.runCalendarConsumers`, with its window registered with the wake planner.
///
/// Each event opens at most once. The opened ids are remembered for the app's lifetime and the most
/// recent few are also persisted, so a relaunch inside the window does not open the call again.
/// While the user is already in a meeting nothing opens and the id is not consumed, so a later tick
/// inside the window retries once the other meeting ends.
@MainActor
final class MeetingAutoJoinService {
    /// Late-wake grace: a tick that lands this long after the start still opens the call.
    static let trailWindow: TimeInterval = 120
    /// The longest lead the settings picker offers; the wake planner window uses it so a wake is
    /// always planned no later than the user's chosen lead.
    static let maxLeadMinutes = 5
    static let leadMinuteChoices = [0, 1, 2, 5]
    static let defaultLeadMinutes = 1
    /// How many opened ids survive a relaunch. Only events inside a few minutes' window matter.
    static let persistedIDLimit = 20

    /// The window `shouldOpen` gates on, for the calendar wake planner. The planner wakes at
    /// `start − lead`; using the user's current lead keeps the wake aligned with the setting (a
    /// wake planned for a shorter lead only opens the call later, never misses it).
    static func consumerWindow(defaults: UserDefaults = .standard) -> CalendarWakePlanner.ConsumerWindow {
        CalendarWakePlanner.ConsumerWindow(lead: leadSeconds(defaults: defaults), trail: trailWindow)
    }

    static func isEnabled(defaults: UserDefaults) -> Bool {
        defaults.object(forKey: UserDefaultsKeys.meetingsAutoJoinEnabled) as? Bool ?? true
    }

    static func leadSeconds(defaults: UserDefaults) -> TimeInterval {
        let minutes = defaults.object(forKey: UserDefaultsKeys.meetingsAutoJoinLeadMinutes) as? Int ?? defaultLeadMinutes
        return TimeInterval(min(max(minutes, 0), maxLeadMinutes) * 60)
    }

    typealias Opener = @MainActor (_ url: URL, _ accountSub: String?) -> Void

    private let defaults: UserDefaults
    private let opener: Opener
    /// Whether the user is already in a meeting (capturing, or a live caption session).
    var isInMeeting: @MainActor () -> Bool
    private var openedEventIDs: Set<String>
    /// Persisted ids, oldest first, capped at `persistedIDLimit`.
    private var recentOpenedIDs: [String]

    init(
        defaults: UserDefaults = .standard,
        isInMeeting: @escaping @MainActor () -> Bool = { false },
        opener: @escaping Opener = MeetingAutoJoinService.defaultOpener
    ) {
        self.defaults = defaults
        self.isInMeeting = isInMeeting
        self.opener = opener
        let persisted = defaults.stringArray(forKey: UserDefaultsKeys.meetingsAutoJoinOpenedEventIDs) ?? []
        self.recentOpenedIDs = persisted
        self.openedEventIDs = Set(persisted)
    }

    /// The real launch, a no-op under tests so a calendar tick there can never open a browser.
    static let defaultOpener: Opener = { url, accountSub in
        guard !AppConstants.isRunningTests else { return }
        MeetingJoinLauncher.open(url: url, accountSub: accountSub)
    }

    /// Open the join link of every event that has just reached its start and has not been opened.
    func openStartingMeetings(_ events: [CalendarEventDTO], now: Date = Date()) {
        guard Self.isEnabled(defaults: defaults) else { return }
        let candidates = events.filter { shouldOpen($0, now: now) }
        guard !candidates.isEmpty else { return }
        // Already in a call: open nothing and keep the ids unconsumed, so a later tick retries.
        guard !isInMeeting() else { return }
        for event in candidates {
            guard let url = Self.joinURL(for: event) else { continue }
            markOpened(event.id)
            logger.info("Auto-opening join link for \(event.title, privacy: .private)")
            opener(url, GoogleCalendarID.accountSub(fromNamespacedID: event.id))
        }
    }

    func shouldOpen(_ event: CalendarEventDTO, now: Date) -> Bool {
        guard !event.isAllDay, !openedEventIDs.contains(event.id) else { return false }
        guard Self.joinURL(for: event) != nil, !Self.userDeclined(event) else { return false }
        let secondsUntilStart = event.startDate.timeIntervalSince(now)
        return secondsUntilStart <= Self.leadSeconds(defaults: defaults) && secondsUntilStart >= -Self.trailWindow
    }

    static func joinURL(for event: CalendarEventDTO) -> URL? {
        guard let raw = event.conferencingURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: raw),
              MeetingJoinLauncher.isLaunchableJoinURL(url) else { return nil }
        return url
    }

    /// The user's own attendee row (`isSelf`) says they declined.
    static func userDeclined(_ event: CalendarEventDTO) -> Bool {
        event.attendees.contains { $0.isSelf == true && $0.responseStatus == .declined }
    }

    private func markOpened(_ id: String) {
        openedEventIDs.insert(id)
        recentOpenedIDs.append(id)
        if recentOpenedIDs.count > Self.persistedIDLimit {
            recentOpenedIDs.removeFirst(recentOpenedIDs.count - Self.persistedIDLimit)
        }
        defaults.set(recentOpenedIDs, forKey: UserDefaultsKeys.meetingsAutoJoinOpenedEventIDs)
    }
}
