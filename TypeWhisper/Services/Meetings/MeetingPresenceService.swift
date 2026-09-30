import Combine
import Foundation

/// Answers "is the user in a meeting right now, and which ones were they in?" for other local apps
/// (`GET /v1/meetings/now`, `GET /v1/meetings/sessions`).
///
/// Read-only glue over state other services already own: the capture service's published state, the
/// loaded meeting list, the recorder's level meters and the calendar's event window. It writes
/// nothing to any store; its own state (last caption-session activity, last time the user spoke) is
/// in-memory and rebuilt from live signals after a relaunch. The decisions themselves live in
/// `MeetingPresenceProjector`, which is pure.
@MainActor
final class MeetingPresenceService {
    private let meetingService: MeetingService
    private let captureService: MeetingCaptureService
    private let calendarService: CalendarService?
    private let clock: () -> Date

    private var liveSessions = LiveSessionActivityRegistry()
    private var speakingTracker = SpeakingActivityTracker()
    private var latestSystemLevel: Float = 0
    private var cancellables: Set<AnyCancellable> = []

    init(
        meetingService: MeetingService,
        captureService: MeetingCaptureService,
        audioRecorderService: AudioRecorderService,
        calendarService: CalendarService?,
        clock: @escaping () -> Date = Date.init
    ) {
        self.meetingService = meetingService
        self.captureService = captureService
        self.calendarService = calendarService
        self.clock = clock

        // The recorder is shared with the standalone Recorder, so its levels only mean "the user is
        // talking in a meeting" while a meeting capture is running — hence the gate in `ingest`.
        audioRecorderService.$systemLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in self?.latestSystemLevel = level }
            .store(in: &cancellables)
        audioRecorderService.$micLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in self?.ingest(micLevel: level) }
            .store(in: &cancellables)
        // A new capture starts with a clean slate: "seconds since the user spoke" must never carry
        // over from the previous meeting.
        captureService.$isCapturing
            .removeDuplicates()
            .filter { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.speakingTracker.reset() }
            .store(in: &cancellables)
    }

    private func ingest(micLevel: Float) {
        guard captureService.isCapturing else { return }
        speakingTracker.ingest(micLevel: micLevel, systemLevel: latestSystemLevel, at: clock())
    }

    // MARK: - Caption-session liveness

    /// Record that an external caption session is still running: a caption batch landed, or the
    /// bridge sent a heartbeat. `participants` is the bridge's head count when it could read one.
    func noteLiveSessionActivity(meetingID: UUID, participants: Int? = nil) {
        liveSessions.touch(meetingID, at: clock(), participants: participants)
    }

    func endLiveSession(meetingID: UUID) {
        liveSessions.remove(meetingID)
    }

    // MARK: - Queries

    func now() -> MeetingPresenceNow {
        let date = clock()
        let capturingMeetingID = captureService.isCapturing ? captureService.activeMeeting?.id : nil
        // Only meetings that could be "now" are projected, so a poll every few seconds never walks
        // the whole archive's relationships.
        let candidates = meetingService.meetings
            .filter { $0.state == .live || $0.id == capturingMeetingID }
            .map { Self.facts(for: $0, includeTranscriptFacts: false) }
        let live = MeetingPresenceLiveState(
            capturingMeetingID: capturingMeetingID,
            speaking: capturingMeetingID == nil ? nil : speakingTracker.isSpeaking(at: date),
            secondsSinceSpoke: capturingMeetingID == nil ? nil : speakingTracker.secondsSinceSpoke(at: date)
        )
        return MeetingPresenceProjector.now(
            meetings: candidates,
            live: live,
            calendarEventNow: calendarEventNow(at: date),
            isCaptionSessionActive: { [liveSessions] in liveSessions.isActive($0, at: date) },
            reportedParticipants: { [liveSessions] in liveSessions.participants(for: $0, at: date) }
        )
    }

    func sessions(since: Date, until: Date?, limit: Int) -> [MeetingPresenceSession] {
        let date = clock()
        let capturingMeetingID = captureService.isCapturing ? captureService.activeMeeting?.id : nil
        // Window first on the cheap columns, then read transcripts only for the rows that survive.
        let inWindow = meetingService.meetings.filter { meeting in
            guard let start = meeting.startDate else { return false }
            if let until, start > until { return false }
            if meeting.state != .live, let end = meeting.endDate, end < since { return false }
            return true
        }
        return MeetingPresenceProjector.sessions(
            meetings: inWindow.map { Self.facts(for: $0, includeTranscriptFacts: true) },
            since: since,
            until: until,
            capturingMeetingID: capturingMeetingID,
            isCaptionSessionActive: { [liveSessions] in liveSessions.isActive($0, at: date) },
            limit: limit
        )
    }

    private func calendarEventNow(at date: Date) -> Bool {
        // An event that already backs a meeting is dropped from the calendar's Upcoming list, so the
        // scheduled meetings themselves are the other half of "what is on the calendar right now".
        let events = ((calendarService?.upcomingEvents ?? []) + (calendarService?.earlierEvents ?? []))
            .map { (start: $0.startDate, end: $0.endDate, isAllDay: $0.isAllDay, hasJoinLink: $0.conferencingURL != nil) }
        let scheduledMeetings = meetingService.meetings.compactMap { meeting -> (start: Date, end: Date, isAllDay: Bool, hasJoinLink: Bool)? in
            guard meeting.calendarEventID != nil, let start = meeting.startDate, let end = meeting.endDate else {
                return nil
            }
            return (start: start, end: end, isAllDay: false, hasJoinLink: meeting.conferencingURL != nil)
        }
        return MeetingPresenceProjector.calendarEventNow(events: events + scheduledMeetings, now: date)
    }

    // MARK: - Projection

    /// Reduce a meeting to its presence facts. `includeTranscriptFacts` gates the two fields that
    /// read the segment relationship, which the hot `now()` path never needs.
    static func facts(for meeting: Meeting, includeTranscriptFacts: Bool) -> MeetingPresenceFacts {
        let attendees = meeting.attendees
        var lastCaptionAt: Date?
        var speakingSeconds: Int?
        if includeTranscriptFacts {
            let segments = meeting.segments
            if meeting.externalSessionKey != nil, let start = meeting.startDate,
               let lastEnd = segments.filter({ $0.source == .liveCaptions }).map(\.end).max() {
                lastCaptionAt = start.addingTimeInterval(lastEnd)
            }
            speakingSeconds = MeetingPresenceProjector.speakingSeconds(
                segments: segments.map {
                    (start: $0.start, end: $0.end, speakerLabel: $0.speakerLabel, isCaption: $0.source == .liveCaptions)
                },
                speakerMap: meeting.speakerMap,
                selfNames: attendees.filter { $0.isSelf == true }.map(\.name),
                selfLabel: MeetingDiarizationEnricher.micSpeakerLabel
            )
        }
        return MeetingPresenceFacts(
            id: meeting.id,
            state: meeting.state,
            source: meeting.source,
            startDate: meeting.startDate,
            endDate: meeting.endDate,
            isCalendarLinked: meeting.calendarEventID != nil,
            isRecurring: meeting.seriesID != nil,
            attendeeCount: attendees.count,
            twoPersonCall: meeting.twoPersonCall == true,
            conferencingURL: meeting.conferencingURL,
            isCaptionSession: meeting.externalSessionKey != nil,
            hasAudio: meeting.audioFileName != nil,
            lastCaptionAt: lastCaptionAt,
            speakingSeconds: speakingSeconds
        )
    }
}
