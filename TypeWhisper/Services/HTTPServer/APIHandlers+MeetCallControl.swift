import Foundation

/// The caption bridge's side channel for the user's own microphone and camera in a Meet call: it
/// reports what Meet's toolbar shows, and long-polls for the commands the app's floating controls
/// issue (`MeetCallControlService`). Like the other `/v1/meetings/live` routes these are only ever
/// called by the allowlisted extension.
extension APIHandlers {
    func registerMeetCallControl(on router: APIRouter) {
        router.register("POST", "/v1/meetings/live/{id}/controls", handler: handleLiveControls)
        router.register("POST", "/v1/meetings/live/{id}/commands/poll", handler: handleLiveCommandsPoll)
        router.register("POST", "/v1/bridge/hello", handler: handleBridgeHello)
    }

    // MARK: - POST /v1/bridge/hello

    private struct BridgeHelloRequest: Decodable {
        let version: String?
    }

    private struct BridgeHelloResponse: Encodable {
        let expected_version: String
    }

    /// The bridge says which build it is (on every connect, and from its options page). The answer
    /// names the version this app build ships with, so the extension can say when it is behind.
    private func handleBridgeHello(_ request: HTTPRequest) async -> HTTPResponse {
        guard let callControl = meetingPresence?.callControl else { return Self.callControlUnavailable }
        guard let payload = try? JSONDecoder().decode(BridgeHelloRequest.self, from: request.body),
              let version = payload.version?.trimmingCharacters(in: .whitespacesAndNewlines),
              !version.isEmpty, version.count <= 32,
              version.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) else {
            return .error(status: 400, message: "Missing or invalid 'version'")
        }
        await MainActor.run { callControl.noteBridgeHello(version: version) }
        return .json(BridgeHelloResponse(expected_version: MeetBridgeVersion.shipped))
    }

    private struct LiveControlsRequest: Decodable {
        let micMuted: Bool?
        let cameraOff: Bool?
        let waitSeconds: Double?

        private enum CodingKeys: String, CodingKey {
            case micMuted = "mic_muted"
            case cameraOff = "camera_off"
            case waitSeconds = "wait_seconds"
        }

        /// The toolbar state, when the bridge could read the microphone at all.
        var state: MeetCallControlState? {
            micMuted.map { MeetCallControlState(micMuted: $0, cameraOff: cameraOff) }
        }
    }

    private struct LiveControlsResponse: Encodable {
        let id: String
        let state: String
    }

    private struct LiveCommandsResponse: Encodable {
        let commands: [MeetCallControlCommand]
    }

    private static var callControlUnavailable: HTTPResponse {
        .error(status: 503, message: "Call controls are not available")
    }

    private func decodeControls(_ request: HTTPRequest) -> LiveControlsRequest? {
        if request.body.isEmpty { return LiveControlsRequest(micMuted: nil, cameraOff: nil, waitSeconds: nil) }
        return try? JSONDecoder().decode(LiveControlsRequest.self, from: request.body)
    }

    // MARK: - POST /v1/meetings/live/{id}/controls

    /// The user's mic/camera state changed in Meet (or the bridge is announcing it for the first
    /// time). A body without `mic_muted` withdraws the call: the bridge can no longer read or
    /// click the toggles (the user switched call control off in its options).
    private func handleLiveControls(_ request: HTTPRequest) async -> HTTPResponse {
        guard let callControl = meetingPresence?.callControl else { return Self.callControlUnavailable }
        guard let idString = request.pathParams["id"], let uuid = UUID(uuidString: idString) else {
            return .error(status: 400, message: "Missing or invalid meeting id")
        }
        guard let payload = decodeControls(request) else {
            return .error(status: 400, message: "Invalid JSON body")
        }
        let state = payload.state

        let meetingService = self.meetingService
        return await MainActor.run {
            guard let meeting = meetingService.meetings.first(where: { $0.id == uuid }) else {
                return .error(status: 404, message: "Meeting not found")
            }
            if let state, meeting.state == .live {
                callControl.report(meetingID: meeting.id, state: state)
            } else {
                callControl.end(meetingID: meeting.id)
            }
            return .json(LiveControlsResponse(id: meeting.id.uuidString, state: meeting.state.rawValue))
        }
    }

    // MARK: - POST /v1/meetings/live/{id}/commands/poll

    /// Long-poll: held until the floating controls issue a command or `wait_seconds` runs out.
    /// A meeting that is no longer live answers at once with no commands, so a bridge that missed
    /// its own hang-up does not keep a request open against a finished call.
    private func handleLiveCommandsPoll(_ request: HTTPRequest) async -> HTTPResponse {
        guard let callControl = meetingPresence?.callControl else { return Self.callControlUnavailable }
        guard let idString = request.pathParams["id"], let uuid = UUID(uuidString: idString) else {
            return .error(status: 400, message: "Missing or invalid meeting id")
        }
        guard let payload = decodeControls(request) else {
            return .error(status: 400, message: "Invalid JSON body")
        }
        let wait = payload.waitSeconds ?? 20
        guard wait.isFinite, wait >= 0 else {
            return .error(status: 400, message: "Invalid 'wait_seconds' value")
        }

        let meetingService = self.meetingService
        let isLive: Bool? = await MainActor.run {
            meetingService.meetings.first(where: { $0.id == uuid }).map { $0.state == .live }
        }
        guard let isLive else { return .error(status: 404, message: "Meeting not found") }
        guard isLive else { return .json(LiveCommandsResponse(commands: [])) }

        let commands = await callControl.nextCommands(meetingID: uuid, wait: wait, state: payload.state)
        return .json(LiveCommandsResponse(commands: commands))
    }
}
