import Foundation

/// Pure assembly of the two Gmail search queries and the D-M2 date window ([Google Phase 3 · M1],
/// D-M1/D-M2). No clocks, no I/O — fully covered by `GmailQueryBuilderTests`.
enum GmailQueryBuilder {
    /// D-M1 flooding guard: per-clause caps so a generic title can never displace attendee mail.
    static let attendeeAddressCap = 8
    static let titleTermCap = 4
    /// Per-clause `maxResults` for the two-call merge (D-M1 step 2).
    static let attendeeMaxResults = 25
    static let subjectMaxResults = 10
    /// D-M2: `[reference − 14 days, reference + 1 day]`.
    static let lookbackDays = 14
    static let lookaheadDays = 1

    /// The serialized date-granular window (D-M1 rule). Stored as strings — the cache fingerprint
    /// covers exactly these, so same-day fetches are fingerprint-stable while a raw `Date` instant
    /// would make every live fetch a miss.
    struct Window: Equatable, Sendable {
        let afterDay: String   // yyyy/MM/dd of the window-start instant
        let beforeDay: String  // yyyy/MM/dd of the calendar day AFTER the window-end instant
    }

    /// The two independent `q` strings of the D-M1 two-call merge; either may be `nil`.
    struct Queries: Equatable, Sendable {
        let attendee: String?
        let subject: String?

        var isEmpty: Bool { attendee == nil && subject == nil }
    }

    // MARK: - Window (D-M2)

    /// `[reference − 14d, reference + 1d]` serialized at date granularity. Gmail's `before:` is
    /// *exclusive* of the named day, so `beforeDay` names the calendar day AFTER the window-end
    /// instant — the window-end day itself (including a meeting day's mid-meeting arrivals) is
    /// always covered (D-M1 normative rule).
    static func window(reference: Date, calendar: Calendar = .current) -> Window {
        let start = reference.addingTimeInterval(-TimeInterval(lookbackDays) * 86_400)
        let end = reference.addingTimeInterval(TimeInterval(lookaheadDays) * 86_400)
        let dayAfterEnd = calendar.date(byAdding: .day, value: 1, to: end) ?? end.addingTimeInterval(86_400)
        return Window(afterDay: dayString(start, calendar: calendar), beforeDay: dayString(dayAfterEnd, calendar: calendar))
    }

    // MARK: - Queries (D-M1)

    /// The attendee-email list after self-exclusion: `excludedEmails` (self attendees ∪ all
    /// connected account emails, D-M2) subtracted case-insensitively, case-insensitive dedupe,
    /// input order preserved. Exposed so `GmailContextService` computes the same list for its
    /// scope fingerprint.
    static func includedAddresses(attendeeEmails: [String], excludedEmails: [String]) -> [String] {
        let excluded = Set(excludedEmails.map { normalize($0) })
        var seen = Set<String>()
        var included: [String] = []
        for email in attendeeEmails {
            let key = normalize(email)
            guard !key.isEmpty, !excluded.contains(key), seen.insert(key).inserted else { continue }
            included.append(email.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return included
    }

    /// The two `q` strings (D-M1 step 1). Attendee clause: `(from:a OR to:a OR …)` over the first
    /// 8 post-exclusion addresses, `nil` when none remain. Subject clause: `subject:(t1 t2 …)`
    /// over the first 4 title content terms (`LexicalRetriever.tokenize` — lowercased,
    /// stop-worded), AND-scoped inside the parens, `nil` when no content terms. Both carry the
    /// date window and the noise filters.
    static func queries(
        attendeeEmails: [String],
        excludedEmails: [String],
        titleTerms: String,
        window: Window
    ) -> Queries {
        let suffix = commonSuffix(window: window)

        let addresses = includedAddresses(attendeeEmails: attendeeEmails, excludedEmails: excludedEmails)
            .prefix(attendeeAddressCap)
        let attendee: String?
        if addresses.isEmpty {
            attendee = nil
        } else {
            let clause = addresses.map { "from:\($0) OR to:\($0)" }.joined(separator: " OR ")
            attendee = "(\(clause)) \(suffix)"
        }

        let terms = LexicalRetriever.tokenize(titleTerms).prefix(titleTermCap)
        let subject: String? = terms.isEmpty ? nil : "subject:(\(terms.joined(separator: " "))) \(suffix)"

        return Queries(attendee: attendee, subject: subject)
    }

    // MARK: - Private

    private static func normalize(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func commonSuffix(window: Window) -> String {
        "after:\(window.afterDay) before:\(window.beforeDay) "
            + "-in:chats -in:drafts -category:promotions -category:social"
    }

    /// `yyyy/MM/dd` from calendar components — no `DateFormatter`, so the rendering is
    /// locale-independent and cheap.
    private static func dayString(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d/%02d/%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
