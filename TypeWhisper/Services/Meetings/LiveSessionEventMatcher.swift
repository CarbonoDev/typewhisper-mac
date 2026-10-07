import Foundation

/// Calendar matching for a *live* external session (`POST /v1/meetings/live`), pure + unit-testable.
///
/// The import path's `CalendarService.bestAutoLinkCandidate` scores title + date over ±24 h, which is
/// right for a dated transcript file but wrong for a call that is happening now: an exact title match
/// on tomorrow's occurrence of a recurring meeting clears its confidence floor, and linking then moves
/// the recording into the future. A live call can only be an event that is about to start, in
/// progress, or just over — so every candidate here must sit inside that live window first.
///
/// Precedence:
/// 1. **Meet code.** The session key is the Meet call code; an event whose conferencing URL carries
///    that code is the call regardless of title. Recurring occurrences share one code, so the
///    in-window occurrence nearest the session start wins.
/// 2. **Title.** The existing similarity scoring, restricted to in-window events and held to the
///    import path's confidence floor. Anything outside the window is `nil` (`matched_event: null`).
@MainActor
enum LiveSessionEventMatcher {
    /// How early a call may start before its event and still be that event: people join a few
    /// minutes ahead, and a call started a quarter hour early is still that meeting.
    static let earlyJoinAllowance: TimeInterval = 15 * 60

    /// How long after an event's scheduled end a call may start and still be that event: a meeting
    /// that kicked off late, or a reconnect after the slot is over, is still the same meeting while
    /// the event has only just ended. Past this, the slot is someone else's past.
    static let lateStartAllowance: TimeInterval = 30 * 60

    /// Half-window passed to `CalendarService.linkCandidates(around:window:)`. Providers return events
    /// *overlapping* the range, so this only needs to cover the live allowances above; the precise
    /// filter is `isInLiveWindow`. Kept to a few hours so other days are never even fetched.
    static let candidateQueryWindow: TimeInterval = 3 * 60 * 60

    /// Confidence reported for a Meet-code match — the code is an identity, not a guess.
    static let meetCodeMatchConfidence: Double = 1.0

    /// Whether a session starting at `sessionStart` can be `event`: within `earlyJoinAllowance`
    /// before its start through `lateStartAllowance` after its end.
    static func isInLiveWindow(_ event: CalendarEventDTO, sessionStart: Date) -> Bool {
        let opens = event.startDate.addingTimeInterval(-earlyJoinAllowance)
        let closes = max(event.endDate, event.startDate).addingTimeInterval(lateStartAllowance)
        return sessionStart >= opens && sessionStart <= closes
    }

    /// The Meet call code in a conferencing URL (`https://meet.google.com/abc-defg-hij?authuser=1`
    /// → `abc-defg-hij`), lowercased; `nil` for a non-Meet URL.
    static func meetCode(fromConferencingURL url: String) -> String? {
        let lowered = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let host = lowered.range(of: "meet.google.com/") else { return nil }
        let rest = lowered[host.upperBound...]
        let code = rest.prefix { !"/?#&".contains($0) }
        return code.isEmpty ? nil : String(code)
    }

    /// Best live match for a session among `events`, or `nil` when none is confident enough.
    static func bestMatch(
        sessionKey: String?,
        title: String?,
        sessionStart: Date,
        events: [CalendarEventDTO],
        minimumTitleConfidence: Double = CalendarService.defaultAutoLinkConfidence
    ) -> (event: CalendarEventDTO, score: Double)? {
        let live = events.filter { !$0.isAllDay && isInLiveWindow($0, sessionStart: sessionStart) }
        guard !live.isEmpty else { return nil }

        if let code = sessionKey?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !code.isEmpty {
            let byCode = live
                .filter { event in
                    event.conferencingURL.flatMap(meetCode(fromConferencingURL:)) == code
                }
                .min {
                    abs($0.startDate.timeIntervalSince(sessionStart)) < abs($1.startDate.timeIntervalSince(sessionStart))
                }
            if let byCode { return (byCode, meetCodeMatchConfidence) }
        }

        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return nil
        }
        // Same scoring as the import path; inside the live window date proximity is ~1, so the
        // title similarity is what decides.
        let window = CalendarService.defaultAutoLinkWindow
        guard let best = CalendarService.rankedLinkCandidates(
            events: live,
            targetTitle: title,
            targetDate: sessionStart,
            window: window
        ).first else { return nil }
        let score = CalendarService.linkScore(
            eventTitle: best.title,
            eventDate: best.startDate,
            targetTitle: title,
            targetDate: sessionStart,
            window: window
        )
        return score >= minimumTitleConfidence ? (best, score) : nil
    }
}

extension CalendarService {
    /// Live-session counterpart of `bestAutoLinkCandidate`: fetches candidates through
    /// `linkCandidates` (so calendar selection still applies) and matches with
    /// `LiveSessionEventMatcher`.
    func bestLiveSessionCandidate(
        sessionKey: String?,
        title: String?,
        sessionStart: Date
    ) -> (event: CalendarEventDTO, score: Double)? {
        let raw = linkCandidates(around: sessionStart, window: LiveSessionEventMatcher.candidateQueryWindow)
        return LiveSessionEventMatcher.bestMatch(
            sessionKey: sessionKey,
            title: title,
            sessionStart: sessionStart,
            events: raw
        )
    }
}
