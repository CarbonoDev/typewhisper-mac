import Foundation

/// The one place the D-G3 `google:<sub>:<raw>` namespacing is assembled/parsed — never
/// hand-built anywhere else, so the prefix format cannot drift. EventKit IDs stay bare (they are
/// UUIDs that can never carry this prefix, so bare-vs-namespaced cannot collide).
enum GoogleCalendarID {
    static let prefix = "google:"

    /// `CalendarInfo.id` / `CalendarEventDTO.calendarID` for a Google calendar.
    static func calendarID(sub: String, raw: String) -> String {
        "\(prefix)\(sub):\(raw)"
    }

    /// `CalendarEventDTO.id` (→ `Meeting.calendarEventID`) for a Google event instance.
    static func eventID(sub: String, raw: String) -> String {
        "\(prefix)\(sub):\(raw)"
    }

    /// The account `sub` inside a namespaced ID, or `nil` for a bare (EventKit) ID. M4's twin
    /// detector partitions calendar lists with this; §8 notes it as the account-affinity parse.
    static func accountSub(fromNamespacedID id: String) -> String? {
        guard id.hasPrefix(prefix) else { return nil }
        let rest = id.dropFirst(prefix.count)
        guard let colon = rest.firstIndex(of: ":"), colon > rest.startIndex else { return nil }
        return String(rest[..<colon])
    }
}

/// Pure Google-JSON → `CalendarInfo`/`CalendarEventDTO` mapping ([Google Phase 1 · M3]). No I/O,
/// no clocks — fully covered by `GoogleCalendarMapperTests` over fixture JSON. Once events leave
/// this mapper they flow through the exact same `CalendarService` pipeline as EventKit events.
enum GoogleCalendarMapper {
    /// A calendar-list entry as the settings/selection value type. `sourceName` is the account
    /// email — that is what renders the "split by account" grouping, since `CalendarInfo
    /// .sourceName` is already shown per row (`CalendarSelectionSection`); `id` carries the D-G3
    /// namespace so the flat `CalendarSelectionStore` set just works for Google calendars.
    static func calendarInfo(
        from entry: GoogleCalendarAPI.GCalCalendarListEntry,
        sub: String,
        accountEmail: String
    ) -> CalendarInfo {
        CalendarInfo(
            id: GoogleCalendarID.calendarID(sub: sub, raw: entry.id),
            title: entry.summary?.isEmpty == false ? entry.summary! : entry.id,
            sourceName: accountEmail,
            color: color(fromHex: entry.backgroundColor) ?? .fallback
        )
    }

    /// An event instance as a `CalendarEventDTO`, or `nil` for cancelled instances and events
    /// without parseable dates.
    ///
    /// Normative (spec M3): every produced DTO sets `calendarName`, `calendarID` (namespaced),
    /// and `calendarColor` from the owning calendar — `republish()` treats `calendarID == nil` as
    /// always-selected (`CalendarService.swift:124-127`), so leaving it unset would make Google
    /// events un-deselectable, and `calendarName` feeds capture-context rules
    /// (`MeetingContextRule.calendarNamePatterns`).
    ///
    /// `allDayTimeZone` anchors all-day `yyyy-MM-dd` dates (local midnight, matching EventKit's
    /// all-day semantics); injectable so tests are timezone-deterministic.
    static func eventDTO(
        from event: GoogleCalendarAPI.GCalEvent,
        calendar: CalendarInfo,
        sub: String,
        accountEmail: String,
        allDayTimeZone: TimeZone = .current
    ) -> CalendarEventDTO? {
        guard event.status != "cancelled" else { return nil }
        guard
            let startDate = date(from: event.start, timeZone: allDayTimeZone),
            let endDate = date(from: event.end, timeZone: allDayTimeZone)
        else { return nil }

        // D-G8: recurring instances carry the *bare* iCalUID so prior-meeting matching has a real
        // chance of recognizing a series across the EventKit→Google switchover. Non-recurring
        // events get nil, matching the EventKit provider's rule.
        let seriesID = event.recurringEventId != nil ? event.iCalUID : nil

        // Conference-URL precedence: first video entry point, else hangoutLink, else nil.
        let conferencingURL = event.conferenceData?.entryPoints?
            .first(where: { $0.entryPointType == "video" && $0.uri != nil })?.uri
            ?? event.hangoutLink

        let notes = event.description.map(plainText(fromHTML:))

        return CalendarEventDTO(
            id: GoogleCalendarID.eventID(sub: sub, raw: event.id),
            title: event.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            startDate: startDate,
            endDate: endDate,
            isAllDay: event.start?.dateTime == nil && event.start?.date != nil,
            seriesID: seriesID,
            calendarName: calendar.title,
            calendarID: calendar.id,
            calendarColor: calendar.color,
            attendees: attendees(from: event),
            eventNotes: notes?.isEmpty == false ? notes : nil,
            conferencingURL: conferencingURL,
            accountLabel: accountEmail
        )
    }

    // MARK: - Attendees

    private static func attendees(from event: GoogleCalendarAPI.GCalEvent) -> [Attendee] {
        (event.attendees ?? []).map { attendee in
            Attendee(
                name: attendee.displayName ?? attendee.email ?? "",
                email: attendee.email,
                // Same convention as the EventKit provider (D-A8): stored only when *true*, so
                // "indeterminate self" and "known other" both read as `isSelf != true`.
                isSelf: attendee.isSelf == true ? true : nil,
                isOrganizer: attendee.organizer,
                responseStatusRaw: attendee.responseStatus
            )
        }
    }

    // MARK: - Colors

    /// `"#9fe1e7"` (leading `#` optional) → sRGB components; `nil` when absent or malformed
    /// (caller falls back to `CalendarColor.fallback`).
    static func color(fromHex hex: String?) -> CalendarColor? {
        guard var value = hex?.trimmingCharacters(in: .whitespaces), !value.isEmpty else {
            return nil
        }
        if value.hasPrefix("#") {
            value.removeFirst()
        }
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else { return nil }
        return CalendarColor(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }

    // MARK: - Notes (HTML → plain text)

    /// Google event descriptions frequently arrive as HTML. Reduce to plain text: block-level
    /// closers and `<br>` become newlines, remaining tags are stripped, the common entities are
    /// decoded (`&amp;` last, so `&amp;lt;` never double-decodes), and whitespace is tidied.
    /// Plain-text descriptions pass through effectively untouched.
    static func plainText(fromHTML html: String) -> String {
        var text = html
        let fullRange = { NSRange(text.startIndex..., in: text) }
        if let lineBreaks = try? NSRegularExpression(pattern: "(?i)<br\\s*/?>|</p>|</div>|</li>|</tr>") {
            text = lineBreaks.stringByReplacingMatches(in: text, range: fullRange(), withTemplate: "\n")
        }
        if let tags = try? NSRegularExpression(pattern: "<[^>]+>") {
            text = tags.stringByReplacingMatches(in: text, range: fullRange(), withTemplate: "")
        }
        let entities: [(String, String)] = [
            ("&nbsp;", " "),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&apos;", "'"),
            ("&amp;", "&"),
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        if let blankRuns = try? NSRegularExpression(pattern: "\\n{3,}") {
            text = blankRuns.stringByReplacingMatches(in: text, range: fullRange(), withTemplate: "\n\n")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Dates

    private static func date(
        from wire: GoogleCalendarAPI.GCalEventDateTime?,
        timeZone: TimeZone
    ) -> Date? {
        guard let wire else { return nil }
        if let dateTime = wire.dateTime {
            return GoogleCalendarAPI.date(fromRFC3339: dateTime)
        }
        if let day = wire.date {
            return allDayDate(from: day, timeZone: timeZone)
        }
        return nil
    }

    private static func allDayDate(from string: String, timeZone: TimeZone) -> Date? {
        let parts = string.split(separator: "-")
        guard
            parts.count == 3,
            let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }
}
