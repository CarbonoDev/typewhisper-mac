import Foundation

// Pure logic behind the meeting-presence endpoints (`GET /v1/meetings/now`,
// `GET /v1/meetings/sessions`; spec: docs/specs/2026-09-30-meeting-presence-api-proposal.md).
// Everything here is content-free by construction: a `Meeting` is reduced to `MeetingPresenceFacts`
// before any response is built, so a title, a transcript line, or an attendee name cannot leak into
// a presence response by accident.

/// How the app learned a meeting was in progress.
enum MeetingPresenceDetection: String, Sendable {
    /// The user recorded it with the app's own capture (mic + system audio).
    case capture
    /// The Google Meet caption bridge reported it; no audio of ours is involved.
    case captions
}

/// A meeting reduced to the facts the presence endpoints may expose.
struct MeetingPresenceFacts: Equatable, Sendable {
    var id: UUID
    var state: MeetingState
    var source: MeetingSource
    var startDate: Date?
    var endDate: Date?
    var isCalendarLinked: Bool
    var isRecurring: Bool
    var attendeeCount: Int
    var twoPersonCall: Bool
    var conferencingURL: String?
    /// Fed by an external caption session (`Meeting.externalSessionKey`).
    var isCaptionSession: Bool
    /// The app holds a recording of it (`Meeting.audioFileName`).
    var hasAudio: Bool
    /// When the last caption landed (meeting start + the latest caption segment's end). Only
    /// populated for a caption session still marked `.live`, where it stands in for a missing end.
    var lastCaptionAt: Date?
    /// Seconds of transcript attributed to the user; `nil` when the app cannot tell which speaker
    /// the user is.
    var speakingSeconds: Int?
}

/// `GET /v1/meetings/now`. Optional fields are omitted from the JSON when unknown.
struct MeetingPresenceNow: Encodable, Equatable, Sendable {
    var schema = MeetingPresenceProjector.schemaVersion
    var in_meeting: Bool
    var meeting_id: String?
    var started_at: Date?
    var detected_by: String?
    var platform: String?
    var participants: Int?
    var scheduled: Bool?
    var recurring: Bool?
    var speaking: Bool?
    var seconds_since_spoke: Int?
    /// A calendar event with a join link is running right now. A weak hint that stands apart from
    /// `in_meeting`: it says a meeting is *scheduled*, not that the user is in it.
    var calendar_event_now: Bool
}

/// One row of `GET /v1/meetings/sessions`.
struct MeetingPresenceSession: Encodable, Equatable, Sendable {
    var meeting_id: String
    var started_at: Date
    /// `nil` (encoded as an explicit `null`) while the meeting is in progress.
    var ended_at: Date?
    var detected_by: String
    var platform: String?
    var participants: Int?
    var scheduled: Bool
    var recurring: Bool?
    var speaking_seconds: Int?

    private enum CodingKeys: String, CodingKey {
        case meeting_id, started_at, ended_at, detected_by, platform, participants, scheduled
        case recurring, speaking_seconds
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(meeting_id, forKey: .meeting_id)
        try container.encode(started_at, forKey: .started_at)
        // Explicit `null`, not an omitted key: "still running" is a statement, "unknown" is not.
        try container.encode(ended_at, forKey: .ended_at)
        try container.encode(detected_by, forKey: .detected_by)
        try container.encodeIfPresent(platform, forKey: .platform)
        try container.encodeIfPresent(participants, forKey: .participants)
        try container.encode(scheduled, forKey: .scheduled)
        try container.encodeIfPresent(recurring, forKey: .recurring)
        try container.encodeIfPresent(speaking_seconds, forKey: .speaking_seconds)
    }
}

/// Live, in-memory signals about the meeting the user is in right now.
struct MeetingPresenceLiveState: Equatable, Sendable {
    /// The meeting the app's own capture is recording, if any.
    var capturingMeetingID: UUID?
    var speaking: Bool?
    var secondsSinceSpoke: Int?
}

enum MeetingPresenceProjector {
    static let schemaVersion = 1

    /// `meet`, `zoom`, `teams` or `webex`, from the join link's host. A caption session is Meet by
    /// definition — the bridge only exists there.
    static func platform(conferencingURL: String?, isCaptionSession: Bool) -> String? {
        if isCaptionSession { return "meet" }
        guard let conferencingURL, let host = URL(string: conferencingURL)?.host?.lowercased() else {
            return nil
        }
        let known: [(suffix: String, name: String)] = [
            ("meet.google.com", "meet"),
            ("zoom.us", "zoom"),
            ("teams.microsoft.com", "teams"),
            ("teams.live.com", "teams"),
            ("webex.com", "webex")
        ]
        return known.first { host == $0.suffix || host.hasSuffix("." + $0.suffix) }?.name
    }

    /// People actually in the call when the bridge reported a count; otherwise the invited roster;
    /// otherwise 2 for a meeting flagged as a two-person call.
    static func participants(_ facts: MeetingPresenceFacts, reported: Int?) -> Int? {
        if let reported, reported > 0 { return reported }
        if facts.attendeeCount > 0 { return facts.attendeeCount }
        return facts.twoPersonCall ? 2 : nil
    }

    /// How a meeting counts as something the user was in, or `nil` when it does not (a scheduled
    /// meeting that never started, an imported file, a transcript merged in from Drive).
    static func detection(_ facts: MeetingPresenceFacts, capturingMeetingID: UUID?) -> MeetingPresenceDetection? {
        guard facts.source == .adHoc || facts.source == .calendar, facts.state != .scheduled else {
            return nil
        }
        if facts.id == capturingMeetingID || facts.hasAudio { return .capture }
        return facts.isCaptionSession ? .captions : nil
    }

    /// The meeting the user is in right now. A local capture wins over a caption session: it is the
    /// one the user started by hand, and it carries the speaking signal.
    static func current(
        meetings: [MeetingPresenceFacts],
        capturingMeetingID: UUID?,
        isCaptionSessionActive: (UUID) -> Bool
    ) -> (facts: MeetingPresenceFacts, detection: MeetingPresenceDetection)? {
        if let capturingMeetingID, let capturing = meetings.first(where: { $0.id == capturingMeetingID }) {
            return (capturing, .capture)
        }
        let liveCaptionSessions = meetings
            .filter { $0.state == .live && $0.isCaptionSession && isCaptionSessionActive($0.id) }
            .sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
        return liveCaptionSessions.last.map { ($0, .captions) }
    }

    static func now(
        meetings: [MeetingPresenceFacts],
        live: MeetingPresenceLiveState,
        calendarEventNow: Bool,
        isCaptionSessionActive: (UUID) -> Bool,
        reportedParticipants: (UUID) -> Int?
    ) -> MeetingPresenceNow {
        guard let (facts, detection) = current(
            meetings: meetings,
            capturingMeetingID: live.capturingMeetingID,
            isCaptionSessionActive: isCaptionSessionActive
        ) else {
            return MeetingPresenceNow(in_meeting: false, calendar_event_now: calendarEventNow)
        }
        let isCapture = detection == .capture
        return MeetingPresenceNow(
            in_meeting: true,
            meeting_id: facts.id.uuidString,
            started_at: facts.startDate,
            detected_by: detection.rawValue,
            platform: platform(conferencingURL: facts.conferencingURL, isCaptionSession: facts.isCaptionSession),
            participants: participants(facts, reported: reportedParticipants(facts.id)),
            scheduled: facts.isCalendarLinked,
            recurring: facts.isCalendarLinked ? facts.isRecurring : nil,
            // The microphone signal only exists while our own capture runs; a caption session has
            // no live notion of who is talking.
            speaking: isCapture ? live.speaking : nil,
            seconds_since_spoke: isCapture ? live.secondsSinceSpoke : nil,
            calendar_event_now: calendarEventNow
        )
    }

    /// Meetings the user was in, overlapping `[since, until]`, oldest first.
    static func sessions(
        meetings: [MeetingPresenceFacts],
        since: Date,
        until: Date?,
        capturingMeetingID: UUID?,
        isCaptionSessionActive: (UUID) -> Bool,
        limit: Int
    ) -> [MeetingPresenceSession] {
        let rows: [MeetingPresenceSession] = meetings.compactMap { facts in
            guard let start = facts.startDate,
                  let detection = detection(facts, capturingMeetingID: capturingMeetingID) else {
                return nil
            }
            let inProgress = facts.id == capturingMeetingID
                || (facts.state == .live && detection == .captions && isCaptionSessionActive(facts.id))
            let end: Date?
            if inProgress {
                end = nil
            } else if facts.state == .live {
                // Still marked live but nothing is feeding it: a caption session whose end never
                // arrived, or a capture cut short. Its last caption is the best end we have.
                end = facts.endDate ?? facts.lastCaptionAt ?? start
            } else {
                end = facts.endDate ?? start
            }
            if let until, start > until { return nil }
            if let end, end < since { return nil }
            return MeetingPresenceSession(
                meeting_id: facts.id.uuidString,
                started_at: start,
                ended_at: end,
                detected_by: detection.rawValue,
                platform: platform(conferencingURL: facts.conferencingURL, isCaptionSession: facts.isCaptionSession),
                participants: participants(facts, reported: nil),
                scheduled: facts.isCalendarLinked,
                recurring: facts.isCalendarLinked ? facts.isRecurring : nil,
                speaking_seconds: facts.speakingSeconds
            )
        }
        return Array(rows.sorted { $0.started_at < $1.started_at }.prefix(max(0, limit)))
    }

    /// Whether a timed calendar event with a join link spans `now`.
    static func calendarEventNow(
        events: [(start: Date, end: Date, isAllDay: Bool, hasJoinLink: Bool)],
        now: Date
    ) -> Bool {
        events.contains { !$0.isAllDay && $0.hasJoinLink && $0.start <= now && now < $0.end }
    }

    /// Seconds of transcript attributed to the user, or `nil` when no segment can be pinned on them.
    ///
    /// The user is identifiable on two paths: the two-person channel split, which labels the mic
    /// track `selfLabel`, and any labeled transcript whose speaker resolves (through `speakerMap`)
    /// to the attendee marked as self.
    static func speakingSeconds(
        segments: [(start: Double, end: Double, speakerLabel: String?)],
        speakerMap: [String: String],
        selfNames: [String],
        selfLabel: String
    ) -> Int? {
        let names = Set(selfNames.map(normalize).filter { !$0.isEmpty })
        var labeled = false
        var total: Double = 0
        for segment in segments {
            guard let label = segment.speakerLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !label.isEmpty else { continue }
            labeled = true
            let resolved = normalize(speakerMap[label] ?? label)
            if label == selfLabel || names.contains(resolved) {
                total += max(0, segment.end - segment.start)
            }
        }
        // An unlabeled transcript says nothing about who spoke; a labeled one with no way to name
        // the user says nothing either. Only then is a zero a real zero.
        guard labeled else { return nil }
        let usedChannelSplit = segments.contains { $0.speakerLabel == selfLabel }
        guard usedChannelSplit || !names.isEmpty || total > 0 else { return nil }
        return Int(total.rounded())
    }

    private static func normalize(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// Decides "the user is talking" from the recorder's microphone and system-audio levels.
///
/// Both levels are `min(1, rms * 5)` as published by `AudioRecorderService`. The microphone also
/// hears the other participants when the user is on speakers, so a loud mic alone is not speech:
/// it has to hold its own against what the system is playing.
struct SpeakingActivityTracker: Equatable, Sendable {
    /// Below this the microphone is room noise.
    static let micThreshold: Float = 0.06
    /// The mic must reach at least this share of the system level to count as the user rather than
    /// speaker bleed.
    static let systemDominanceShare: Float = 0.5
    /// How long after the last voiced sample the user still counts as speaking. Sized for a client
    /// that polls every few seconds, so a breath between sentences does not read as "listening".
    static let hangover: TimeInterval = 3

    private(set) var lastSpokeAt: Date?

    mutating func ingest(micLevel: Float, systemLevel: Float, at date: Date) {
        guard micLevel >= Self.micThreshold, micLevel >= systemLevel * Self.systemDominanceShare else {
            return
        }
        lastSpokeAt = date
    }

    func isSpeaking(at now: Date) -> Bool {
        guard let lastSpokeAt else { return false }
        return now.timeIntervalSince(lastSpokeAt) <= Self.hangover
    }

    /// Whole seconds since the user last spoke; `nil` until they have spoken once.
    func secondsSinceSpoke(at now: Date) -> Int? {
        guard let lastSpokeAt else { return nil }
        return max(0, Int(now.timeIntervalSince(lastSpokeAt)))
    }

    mutating func reset() {
        lastSpokeAt = nil
    }
}

/// When each external caption session was last heard from — a caption batch or a bridge heartbeat.
///
/// A caption session is only marked over when the bridge says so, and that message can be lost (the
/// app closed at hang-up, the tab killed). Presence therefore never trusts `.live` alone: a caption
/// session counts as in progress only while it keeps showing signs of life. In-memory by design —
/// after a relaunch a call that is really still running re-registers on its next heartbeat.
struct LiveSessionActivityRegistry: Equatable, Sendable {
    /// A caption session silent for longer than this is no longer "in a meeting".
    static let freshness: TimeInterval = 5 * 60

    private struct Entry: Equatable, Sendable {
        var lastActivityAt: Date
        var participants: Int?
    }

    private var entries: [UUID: Entry] = [:]

    /// Record a sign of life. `participants` is the bridge's count of people in the call, when it
    /// could read one; a `nil` keeps whatever was last reported.
    mutating func touch(_ meetingID: UUID, at date: Date, participants: Int? = nil) {
        var entry = entries[meetingID] ?? Entry(lastActivityAt: date, participants: nil)
        entry.lastActivityAt = max(entry.lastActivityAt, date)
        if let participants { entry.participants = participants }
        entries[meetingID] = entry
    }

    mutating func remove(_ meetingID: UUID) {
        entries[meetingID] = nil
    }

    func isActive(_ meetingID: UUID, at now: Date) -> Bool {
        guard let entry = entries[meetingID] else { return false }
        return now.timeIntervalSince(entry.lastActivityAt) <= Self.freshness
    }

    /// The last reported head count, while the session is still fresh.
    func participants(for meetingID: UUID, at now: Date) -> Int? {
        isActive(meetingID, at: now) ? entries[meetingID]?.participants : nil
    }
}
