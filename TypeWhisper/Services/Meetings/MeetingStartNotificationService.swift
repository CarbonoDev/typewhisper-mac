import Foundation
import UserNotifications
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "MeetingStartNotificationService")

/// Posts a local user notification when a scheduled calendar meeting is about to start, prompting
/// the user to open Meetings and start capture (plan D10: the app never silently records — at
/// event start it prompts). Detection is driven by the calendar poll in `MeetingsViewModel`.
@MainActor
final class MeetingStartNotificationService: ObservableObject {
    /// Fire once per event when `now` is within [start − lead, start + grace].
    private static let leadWindow: TimeInterval = 60
    private static let graceWindow: TimeInterval = 120

    private let center: UNUserNotificationCenter?
    private var notifiedEventIDs = Set<String>()
    private var didRequestAuthorization = false

    /// [Track D] Optional lookup (calendarEventID → has a fresh auto-brief). When set and it returns
    /// true, the notification body gains a "brief ready" line (plan AD9). Injected by
    /// `ServiceContainer` after the brief scheduler is constructed; nil in tests keeps behavior v1.
    var freshBriefLookup: ((_ calendarEventID: String, _ now: Date) -> Bool)?

    init(center: UNUserNotificationCenter? = MeetingStartNotificationService.defaultCenter()) {
        self.center = center
    }

    /// `UNUserNotificationCenter.current()` traps when there is no bundle proxy (e.g. unit tests);
    /// return `nil` there so the service is a safe no-op.
    private static func defaultCenter() -> UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil, !AppConstants.isRunningTests else { return nil }
        return UNUserNotificationCenter.current()
    }

    /// Given the current upcoming/current events, post a notification for any that have just
    /// reached their start time and have not been notified yet.
    func notifyStartingMeetings(_ events: [CalendarEventDTO], now: Date = Date()) {
        for event in events where shouldNotify(event, now: now) {
            // Claim the id so concurrent poll cycles do not double-post while the async add is in
            // flight. If the add ultimately fails, `deliverNotification` un-claims it so a later
            // poll retries (finding 5).
            notifiedEventIDs.insert(event.id)
            post(for: event)
        }
    }

    func shouldNotify(_ event: CalendarEventDTO, now: Date) -> Bool {
        guard !event.isAllDay, !notifiedEventIDs.contains(event.id) else { return false }
        let secondsUntilStart = event.startDate.timeIntervalSince(now)
        return secondsUntilStart <= Self.leadWindow && secondsUntilStart >= -Self.graceWindow
    }

    private func post(for event: CalendarEventDTO) {
        guard let center else { return }

        // The very first event fires while authorization is still `.notDetermined`. Calling
        // `center.add` before authorization resolves silently drops the notification (finding 5),
        // so on the first post we request authorization and only add once its completion fires.
        if didRequestAuthorization {
            deliverNotification(for: event, via: center)
        } else {
            didRequestAuthorization = true
            center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
                if let error {
                    logger.warning("Notification authorization request failed: \(error.localizedDescription)")
                } else {
                    logger.info("Meeting-start notification authorization granted=\(granted, privacy: .public)")
                }
                Task { @MainActor in
                    guard let self, let center = self.center else { return }
                    self.deliverNotification(for: event, via: center)
                }
            }
        }
    }

    private func deliverNotification(for event: CalendarEventDTO, via center: UNUserNotificationCenter) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "meetings.notification.starting.title")
        var body = String(
            format: String(localized: "meetings.notification.starting.body"),
            event.title
        )
        // [Track D] Mention a ready pre-meeting brief so the user knows to open it (plan AD9).
        if freshBriefLookup?(event.id, Date()) == true {
            body += "\n" + String(localized: "meetings.brief.auto.notification.briefReady")
        }
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "meeting-start-\(event.id)",
            content: content,
            trigger: nil
        )
        center.add(request) { [weak self] error in
            if let error {
                logger.warning("Failed to post meeting-start notification: \(error.localizedDescription)")
                // Delivery failed: un-claim the id so a subsequent poll retries within the window.
                Task { @MainActor in self?.notifiedEventIDs.remove(event.id) }
            }
        }
    }
}
