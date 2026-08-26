import Foundation
import UserNotifications
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "MeetingEndReminderService")

/// Posts a single local notification when a meeting's scheduled end time passes while its capture is
/// still recording (owner request 2). Mirrors `MeetingStartNotificationService`'s center + clock
/// seams: `UNUserNotificationCenter` is nil under tests (there is no bundle proxy), so the trigger
/// predicate (`shouldRemind`) is exercised directly with an injected clock.
///
/// Design choices:
/// - **Ad-hoc exclusion**: a meeting with no linked calendar event (`calendarEventID == nil`) or no
///   known scheduled end gets no reminder — there is no "meeting time" to have ended.
/// - **Recurring events**: `Meeting.endDate` is the *current occurrence's* end (the provider composes
///   a per-occurrence `calendarEventID` and stamps the occurrence's dates on the created meeting), so
///   using it already scopes the reminder to the current occurrence.
/// - **Once per session / restart semantics**: the codebase models a stop + restart as the *same*
///   meeting continuing (segments appended via `sessionTimeOffset`), not a new session identity, so
///   the once-per-session dedupe is keyed on the meeting id — a restart does not re-remind. The
///   parameter is named `sessionKey` so the pure predicate stays testable with arbitrary keys.
/// - **Notification action**: the codebase has no `UNUserNotificationCenterDelegate` / category /
///   response plumbing, so (per the brief) a plain notification is posted — clicking it opens the
///   app — rather than bolting on a bespoke Stop-action delegate.
@MainActor
final class MeetingEndReminderService: ObservableObject {
    private let center: UNUserNotificationCenter?
    private var remindedSessionKeys = Set<String>()
    private var didRequestAuthorization = false

    init(center: UNUserNotificationCenter? = MeetingEndReminderService.defaultCenter()) {
        self.center = center
    }

    /// `UNUserNotificationCenter.current()` traps when there is no bundle proxy (e.g. unit tests);
    /// return `nil` there so the service is a safe no-op (mirrors `MeetingStartNotificationService`).
    private static func defaultCenter() -> UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil, !AppConstants.isRunningTests else { return nil }
        return UNUserNotificationCenter.current()
    }

    /// Trigger predicate (unit-tested): fire once per session when a *calendar-linked* meeting whose
    /// scheduled end has passed is still recording. Ad-hoc meetings (`calendarEventID == nil`) and
    /// meetings without a known end are excluded; an already-reminded session is excluded.
    func shouldRemind(
        calendarEventID: String?,
        scheduledEnd: Date?,
        isRecording: Bool,
        sessionKey: String,
        now: Date
    ) -> Bool {
        guard isRecording else { return false }
        guard calendarEventID != nil, let end = scheduledEnd else { return false }
        guard !remindedSessionKeys.contains(sessionKey) else { return false }
        return now >= end
    }

    /// Evaluate the reminder for the active capture and, when due, claim the session and post exactly
    /// one notification. Called on the capture elapsed tick (which runs only while recording).
    func evaluate(
        meetingTitle: String,
        calendarEventID: String?,
        scheduledEnd: Date?,
        isRecording: Bool,
        sessionKey: String,
        now: Date = Date()
    ) {
        guard shouldRemind(
            calendarEventID: calendarEventID,
            scheduledEnd: scheduledEnd,
            isRecording: isRecording,
            sessionKey: sessionKey,
            now: now
        ) else { return }
        // Claim synchronously so a burst of once-per-second ticks posts only one notification.
        remindedSessionKeys.insert(sessionKey)
        post(meetingTitle: meetingTitle, sessionKey: sessionKey)
    }

    /// Whether a session has already been reminded (test/inspection helper).
    func hasReminded(sessionKey: String) -> Bool {
        remindedSessionKeys.contains(sessionKey)
    }

    private func post(meetingTitle: String, sessionKey: String) {
        guard let center else { return }

        // The first reminder may fire while authorization is still `.notDetermined`; calling
        // `center.add` before authorization resolves silently drops it, so on the first post we
        // request authorization and add only once its completion fires (mirrors the start service).
        if didRequestAuthorization {
            deliver(meetingTitle: meetingTitle, sessionKey: sessionKey, via: center)
        } else {
            didRequestAuthorization = true
            center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
                if let error {
                    logger.warning("Notification authorization request failed: \(error.localizedDescription)")
                } else {
                    logger.info("Meeting-end reminder authorization granted=\(granted, privacy: .public)")
                }
                Task { @MainActor in
                    guard let self, let center = self.center else { return }
                    self.deliver(meetingTitle: meetingTitle, sessionKey: sessionKey, via: center)
                }
            }
        }
    }

    private func deliver(meetingTitle: String, sessionKey: String, via center: UNUserNotificationCenter) {
        let content = UNMutableNotificationContent()
        content.title = meetingTitle
        content.body = String(localized: "meetings.notification.ended.body")
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "meeting-end-\(sessionKey)",
            content: content,
            trigger: nil
        )
        center.add(request) { [weak self] error in
            if let error {
                logger.warning("Failed to post meeting-end reminder: \(error.localizedDescription)")
                // Delivery failed: un-claim so a subsequent tick retries.
                Task { @MainActor in self?.remindedSessionKeys.remove(sessionKey) }
            }
        }
    }
}
