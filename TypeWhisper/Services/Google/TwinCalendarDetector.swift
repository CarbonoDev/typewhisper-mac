import Foundation

/// One pending "duplicate calendars detected" prompt for a connected Google account (D-G6): the
/// EventKit twins of that account's Google calendars, ready for guided deselection. Rendered
/// inline in `GoogleAccountsSection`; resolved through `MeetingsViewModel.resolveTwinPrompt`.
struct TwinCalendarPrompt: Equatable, Identifiable {
    /// The Google account's `sub` (recorded as handled via `GoogleAccountStore`, D-G5).
    let accountID: String
    /// The account email, interpolated into the prompt message.
    let accountEmail: String
    /// The EventKit calendars detected as CalDAV twins of the account's Google calendars.
    let twins: [CalendarInfo]
    var id: String { accountID }

    /// The twins' titles as one display line ([M4 review fix 2]): the D-G6 heuristic can
    /// cross-match (e.g. account B's CalDAV calendars under a generic "Google" EKSource whose
    /// titles account A also has), so the prompt must name exactly which macOS calendars "Hide
    /// duplicates" would deselect — informed consent, not a blind default. Pure, unit-tested.
    var twinTitlesList: String {
        twins.map(\.title).joined(separator: ", ")
    }
}

/// Pure twin-calendar detection ([Google Phase 1 · M4], D-G6): when the same Google account is
/// also synced into macOS Calendar via CalDAV, the same events arrive from both providers with
/// unrelated IDs. Rather than a silent per-event dedupe (rejected — wrong matches hide real
/// events invisibly), the detector finds the EventKit "twin" *calendars* of a just-connected
/// Google account so the settings UI can offer a coarse, visible, reversible deselection through
/// the existing selection choke point.
///
/// No I/O, no clocks — fully covered by `TwinCalendarDetectorTests`.
enum TwinCalendarDetector {
    /// The EventKit calendars that mirror one of `google`'s calendars (D-G6 heuristics):
    /// an EventKit calendar is a twin when its `sourceName` (`EKSource.title`) case-insensitively
    /// matches "google"/"gmail" or contains the account email, **and** its title case-insensitively
    /// equals a Google calendar's title or the account email (Google primary calendars are titled
    /// with the email).
    static func twins(
        eventKit: [CalendarInfo],
        google: [CalendarInfo],
        accountEmail: String
    ) -> [CalendarInfo] {
        let email = accountEmail.lowercased()
        guard !email.isEmpty else { return [] }
        let googleTitles = Set(google.map { $0.title.lowercased() })
        return eventKit.filter { calendar in
            let source = calendar.sourceName.lowercased()
            let sourceMatches = source == "google" || source == "gmail" || source.contains(email)
            guard sourceMatches else { return false }
            let title = calendar.title.lowercased()
            return googleTitles.contains(title) || title == email
        }
    }

    /// Partition of a fanned-in `availableCalendars()` list by the D-G3 `google:` ID prefix:
    /// non-prefixed entries are the EventKit side; prefixed entries whose ID carries `accountSub`
    /// are that account's Google side (a *different* account's calendars belong to neither).
    /// Equivalent to reading the providers directly; the partition rule keeps the detector pure
    /// over one input list.
    static func partition(
        _ calendars: [CalendarInfo],
        accountSub: String
    ) -> (eventKit: [CalendarInfo], google: [CalendarInfo]) {
        var eventKit: [CalendarInfo] = []
        var google: [CalendarInfo] = []
        for calendar in calendars {
            switch GoogleCalendarID.accountSub(fromNamespacedID: calendar.id) {
            case nil: eventKit.append(calendar)
            case accountSub?: google.append(calendar)
            default: break
            }
        }
        return (eventKit, google)
    }

    /// The pending twin prompts across all accounts (D-G6 trigger semantics): evaluated on every
    /// `.googleCalendarSnapshotDidChange` for each account whose `sub` is not yet handled — and
    /// *re-evaluated while unhandled*, because the first snapshot after connect can race the
    /// calendarList fetch. An account with no twins yields no prompt but stays unhandled, so a
    /// later snapshot (or newly-appearing EventKit twin) can still surface one. Skipped entirely
    /// when EventKit is not authorized: no EventKit calendars ⇒ no twins to hide.
    static func prompts(
        accounts: [GoogleAccount],
        eventKitAuthorized: Bool,
        calendars: [CalendarInfo],
        isHandled: (String) -> Bool
    ) -> [TwinCalendarPrompt] {
        guard eventKitAuthorized else { return [] }
        return accounts.compactMap { account in
            guard !isHandled(account.id) else { return nil }
            let (eventKit, google) = partition(calendars, accountSub: account.id)
            let detected = twins(eventKit: eventKit, google: google, accountEmail: account.email)
            guard !detected.isEmpty else { return nil }
            return TwinCalendarPrompt(
                accountID: account.id,
                accountEmail: account.email,
                twins: detected
            )
        }
    }
}
