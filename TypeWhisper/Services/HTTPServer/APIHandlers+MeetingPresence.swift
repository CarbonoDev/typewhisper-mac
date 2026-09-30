import Foundation

/// Meeting presence for other local apps: is the user in a meeting right now, and which meetings
/// were they in. Content-free by construction — no title, transcript, or attendee name leaves
/// through these routes (spec: docs/specs/2026-09-30-meeting-presence-api-proposal.md).
extension APIHandlers {
    func registerMeetingPresence(on router: APIRouter) {
        // Literal paths, so neither is shadowed by `/v1/meetings/{id}`. Both demand the token even
        // when loopback callers are otherwise exempt: they are built to be polled by another app.
        router.register("GET", "/v1/meetings/now", requiresToken: true, handler: handleMeetingNow)
        router.register("GET", "/v1/meetings/sessions", requiresToken: true, handler: handleMeetingSessions)
        router.register("POST", "/v1/meetings/live/{id}/heartbeat", handler: handleLiveHeartbeat)
    }

    private static var presenceUnavailable: HTTPResponse {
        .error(status: 503, message: "Meeting presence is not available")
    }

    // MARK: - GET /v1/meetings/now

    /// Polled every few seconds by its client, so it reads in-memory state only.
    private func handleMeetingNow(_ request: HTTPRequest) async -> HTTPResponse {
        guard let presence = meetingPresence else { return Self.presenceUnavailable }
        return await MainActor.run { .json(presence.now()) }
    }

    // MARK: - GET /v1/meetings/sessions

    private struct SessionsResponse: Encodable {
        let schema: Int
        let sessions: [MeetingPresenceSession]
    }

    private func handleMeetingSessions(_ request: HTTPRequest) async -> HTTPResponse {
        guard let presence = meetingPresence else { return Self.presenceUnavailable }
        guard let sinceString = request.queryParams["since"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sinceString.isEmpty else {
            return .error(status: 400, message: "Missing 'since'")
        }
        guard let since = Self.parseISO8601Date(sinceString) else {
            return .error(status: 400, message: "Invalid 'since' value")
        }
        var until: Date?
        if let untilString = request.queryParams["until"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !untilString.isEmpty {
            guard let parsed = Self.parseISO8601Date(untilString) else {
                return .error(status: 400, message: "Invalid 'until' value")
            }
            until = parsed
        }
        let limit = min(max(Int(request.queryParams["limit"] ?? "") ?? 100, 1), 200)

        return await MainActor.run {
            .json(SessionsResponse(
                schema: MeetingPresenceProjector.schemaVersion,
                sessions: presence.sessions(since: since, until: until, limit: limit)
            ))
        }
    }

    // MARK: - POST /v1/meetings/live/{id}/heartbeat

    private struct LiveHeartbeatRequest: Decodable {
        let participants: Int?
    }

    private struct LiveHeartbeatResponse: Encodable {
        let id: String
        let state: String
    }

    /// Keep-alive from the caption bridge: the call is still open even though nobody has said
    /// anything lately. Without it a quiet stretch would read as "the meeting is over" once the last
    /// caption ages out; with it, a meeting whose end message was lost still stops counting as in
    /// progress as soon as the heartbeats stop.
    ///
    /// The bridge only sends this while someone else is in the call. A reported head count of one
    /// is honored the same way here — the user alone in an open room is not in a meeting.
    private func handleLiveHeartbeat(_ request: HTTPRequest) async -> HTTPResponse {
        guard let idString = request.pathParams["id"], let uuid = UUID(uuidString: idString) else {
            return .error(status: 400, message: "Missing or invalid meeting id")
        }
        var participants: Int?
        if !request.body.isEmpty {
            guard let payload = try? JSONDecoder().decode(LiveHeartbeatRequest.self, from: request.body) else {
                return .error(status: 400, message: "Invalid JSON body")
            }
            participants = payload.participants
        }
        if let count = participants, count < 0 || count > 10_000 {
            return .error(status: 400, message: "Invalid 'participants' value")
        }

        let meetingService = self.meetingService
        let presence = self.meetingPresence
        return await MainActor.run {
            guard let meeting = meetingService.meetings.first(where: { $0.id == uuid }) else {
                return .error(status: 404, message: "Meeting not found")
            }
            if meeting.state == .live, participants.map({ $0 > 1 }) ?? true {
                presence?.noteLiveSessionActivity(meetingID: meeting.id, participants: participants)
            }
            return .json(LiveHeartbeatResponse(id: meeting.id.uuidString, state: meeting.state.rawValue))
        }
    }
}
