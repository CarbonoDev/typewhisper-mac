import XCTest
@testable import TypeWhisper

/// Tests for the Meet call controls: which call the floating controls act on, when a call stops
/// being controllable, and how a command reaches the bridge's long-poll.
@MainActor
final class MeetCallControlTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private let muted = MeetCallControlState(micMuted: true, cameraOff: false)
    private let live = MeetCallControlState(micMuted: false, cameraOff: nil)

    private func command(_ action: MeetCallControlCommand.Action, muted: Bool? = nil) -> MeetCallControlCommand {
        MeetCallControlCommand(id: UUID().uuidString, action: action, muted: muted)
    }

    // MARK: - Registry

    func testACallIsControllableOnlyOnceItHasReportedItsState() {
        let id = UUID()
        var registry = MeetCallControlRegistry()
        registry.touch(id, at: t0)
        XCTAssertNil(registry.current(at: t0))

        registry.report(id, state: muted, at: t0)
        XCTAssertEqual(registry.current(at: t0), MeetCallControlSnapshot(meetingID: id, state: muted))
    }

    func testACallTheBridgeStoppedPollingForGoesStaleAndAPollKeepsItAlive() {
        let id = UUID()
        var registry = MeetCallControlRegistry()
        registry.report(id, state: muted, at: t0)

        let edge = t0.addingTimeInterval(MeetCallControlRegistry.freshness)
        XCTAssertNotNil(registry.current(at: edge))
        XCTAssertNil(registry.current(at: edge.addingTimeInterval(1)))
        XCTAssertNil(registry.state(for: id, at: edge.addingTimeInterval(1)))

        // A poll carries no new state, but it proves the bridge is still there.
        registry.touch(id, at: edge)
        XCTAssertEqual(registry.current(at: edge.addingTimeInterval(1))?.state, muted)
    }

    func testTheMostRecentlyJoinedCallWinsAndMutingTheOtherDoesNotStealTheControls() {
        let first = UUID()
        let second = UUID()
        var registry = MeetCallControlRegistry()
        registry.report(first, state: live, at: t0)
        registry.report(second, state: live, at: t0.addingTimeInterval(10))
        XCTAssertEqual(registry.current(at: t0.addingTimeInterval(11))?.meetingID, second)

        registry.report(first, state: muted, at: t0.addingTimeInterval(20))
        XCTAssertEqual(registry.current(at: t0.addingTimeInterval(21))?.meetingID, second)

        registry.remove(second)
        XCTAssertEqual(registry.current(at: t0.addingTimeInterval(21))?.meetingID, first)
    }

    func testQueuedCommandsAreHandedOverOnceAndExpire() {
        let id = UUID()
        var registry = MeetCallControlRegistry()
        registry.report(id, state: live, at: t0)

        let mute = command(.setMic, muted: true)
        registry.enqueue(mute, for: id, at: t0)
        XCTAssertEqual(registry.drain(id, at: t0.addingTimeInterval(1)), [mute])
        XCTAssertEqual(registry.drain(id, at: t0.addingTimeInterval(1)), [])

        registry.enqueue(mute, for: id, at: t0)
        let late = t0.addingTimeInterval(MeetCallControlRegistry.commandTTL + 1)
        XCTAssertEqual(registry.drain(id, at: late), [])
    }

    func testANewerCommandOfTheSameKindReplacesAnUncollectedOne() {
        let id = UUID()
        var registry = MeetCallControlRegistry()
        registry.report(id, state: live, at: t0)

        let mute = command(.setMic, muted: true)
        let unmute = command(.setMic, muted: false)
        let focus = command(.focus)
        registry.enqueue(mute, for: id, at: t0)
        registry.enqueue(focus, for: id, at: t0)
        registry.enqueue(unmute, for: id, at: t0)
        XCTAssertEqual(registry.drain(id, at: t0), [focus, unmute])
    }

    func testCommandsForAnUnknownCallAreDropped() {
        var registry = MeetCallControlRegistry()
        let id = UUID()
        registry.enqueue(command(.focus), for: id, at: t0)
        XCTAssertEqual(registry.drain(id, at: t0), [])
    }

    // MARK: - Service

    func testATogglePressedDuringAnOpenPollAnswersItWithTheTargetState() async {
        let id = UUID()
        let service = MeetCallControlService()
        service.report(meetingID: id, state: live)
        XCTAssertEqual(service.current?.state, live)

        let poll = Task { await service.nextCommands(meetingID: id, wait: 10) }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(20))
        service.toggleMic()

        let commands = await poll.value
        XCTAssertEqual(commands.map(\.action), [.setMic])
        XCTAssertEqual(commands.first?.muted, true)
    }

    func testATogglePressedBetweenPollsIsCollectedByTheNextOne() async {
        let id = UUID()
        let service = MeetCallControlService()
        service.report(meetingID: id, state: muted)
        service.toggleMic()
        service.toggleCamera()

        let commands = await service.nextCommands(meetingID: id, wait: 10)
        XCTAssertEqual(commands.map(\.action), [.setMic, .setCamera])
        XCTAssertEqual(commands.map(\.muted), [false, true])
    }

    func testAnIdlePollTimesOutWithNoCommandsAndCarriesTheBridgesState() async {
        let id = UUID()
        let service = MeetCallControlService()
        let commands = await service.nextCommands(meetingID: id, wait: 0.05, state: muted)
        XCTAssertEqual(commands, [])
        XCTAssertEqual(service.current, MeetCallControlSnapshot(meetingID: id, state: muted))
    }

    func testASecondPollForTheSameCallReleasesTheFirst() async {
        let id = UUID()
        let service = MeetCallControlService()
        service.report(meetingID: id, state: live)

        let first = Task { await service.nextCommands(meetingID: id, wait: 10) }
        try? await Task.sleep(for: .milliseconds(20))
        let second = Task { await service.nextCommands(meetingID: id, wait: 10) }
        let released = await first.value
        XCTAssertEqual(released, [])

        try? await Task.sleep(for: .milliseconds(20))
        service.focusCall()
        let delivered = await second.value
        XCTAssertEqual(delivered.map(\.action), [.focus])
    }

    func testEndingTheCallHidesTheControlsAndReleasesItsPoll() async {
        let id = UUID()
        let service = MeetCallControlService()
        service.report(meetingID: id, state: live)

        let poll = Task { await service.nextCommands(meetingID: id, wait: 10) }
        try? await Task.sleep(for: .milliseconds(20))
        service.end(meetingID: id)

        let commands = await poll.value
        XCTAssertEqual(commands, [])
        XCTAssertNil(service.current)
        // Nothing to act on any more: a late click is a no-op rather than a queued command.
        service.toggleMic()
        XCTAssertNil(service.current)
    }

    func testTheCameraToggleIsANoOpWhenTheCameraStateIsUnknown() async {
        let id = UUID()
        let service = MeetCallControlService()
        service.report(meetingID: id, state: live)
        service.toggleCamera()
        let commands = await service.nextCommands(meetingID: id, wait: 0.05)
        XCTAssertEqual(commands, [])
    }

    func testPresenceStateFallsBackFromTheAskedMeetingToTheCurrentCall() {
        let call = UUID()
        let service = MeetCallControlService()
        XCTAssertNil(service.state(preferring: call))

        service.report(meetingID: call, state: muted)
        XCTAssertEqual(service.state(preferring: call), muted)
        // A local capture of the same call is a different meeting row.
        XCTAssertEqual(service.state(preferring: UUID()), muted)
    }

    func testCommandsEncodeTheWireShapeTheBridgeReads() throws {
        let data = try JSONEncoder().encode(MeetCallControlCommand(id: "c1", action: .setMic, muted: true))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["id"] as? String, "c1")
        XCTAssertEqual(object["action"] as? String, "set_mic")
        XCTAssertEqual(object["muted"] as? Bool, true)

        let focus = try JSONEncoder().encode(MeetCallControlCommand(id: "c2", action: .focus, muted: nil))
        let focusObject = try XCTUnwrap(JSONSerialization.jsonObject(with: focus) as? [String: Any])
        XCTAssertEqual(focusObject["action"] as? String, "focus")
        XCTAssertNil(focusObject["muted"])
    }

    // MARK: - Bridge version

    func testTheShippedBridgeVersionMatchesTheExtensionManifest() throws {
        let manifestURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("chrome-extension/manifest.json")
        let manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        )
        XCTAssertEqual(
            manifest["version"] as? String,
            MeetBridgeVersion.shipped,
            "Bump MeetBridgeVersion.shipped together with chrome-extension/manifest.json"
        )
    }

    func testBridgeVersionsCompareNumericallyNotAlphabetically() {
        XCTAssertTrue(MeetBridgeVersion.isOlder("0.9.1", than: "0.10.0"))
        XCTAssertTrue(MeetBridgeVersion.isOlder("0.2", than: "0.2.1"))
        XCTAssertFalse(MeetBridgeVersion.isOlder("0.3.0", than: "0.3.0"))
        XCTAssertFalse(MeetBridgeVersion.isOlder("1.0.0", than: "0.9.9"))
        XCTAssertFalse(MeetBridgeVersion.isOlder("0.3.0-beta", than: "0.3.0"))
    }

    func testBridgeStatusTellsAnOutdatedBridgeFromASilentOne() {
        XCTAssertEqual(MeetBridgeVersion.status(reported: nil, sawActivity: false, shipped: "0.3.0"), .notSeen)
        XCTAssertEqual(MeetBridgeVersion.status(reported: nil, sawActivity: true, shipped: "0.3.0"), .unversioned)
        XCTAssertEqual(MeetBridgeVersion.status(reported: "0.2.0", sawActivity: true, shipped: "0.3.0"), .outdated("0.2.0"))
        XCTAssertEqual(MeetBridgeVersion.status(reported: "0.3.0", sawActivity: true, shipped: "0.3.0"), .current("0.3.0"))
        // A bridge newer than the app is not the bridge's problem.
        XCTAssertEqual(MeetBridgeVersion.status(reported: "0.4.0", sawActivity: true, shipped: "0.3.0"), .current("0.4.0"))
    }

    func testCaptionActivityWithoutAHelloMeansABridgeThatPredatesVersionReporting() {
        var now = t0
        let service = MeetCallControlService(clock: { now })
        XCTAssertEqual(service.bridgeStatus, .notSeen)

        service.noteBridgeActivity()
        XCTAssertEqual(service.bridgeStatus, .unversioned)

        service.noteBridgeHello(version: MeetBridgeVersion.shipped)
        XCTAssertEqual(service.bridgeStatus, .current(MeetBridgeVersion.shipped))
        // Captions between two hellos belong to the bridge that said hello.
        now = t0.addingTimeInterval(60)
        service.noteBridgeActivity()
        XCTAssertEqual(service.bridgeStatus, .current(MeetBridgeVersion.shipped))

        // Long after the last hello, whatever is feeding captions is a different, silent bridge.
        now = t0.addingTimeInterval(MeetCallControlService.helloFreshness + 61)
        service.noteBridgeActivity()
        XCTAssertEqual(service.bridgeStatus, .unversioned)
    }
}
