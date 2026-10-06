import Combine
import Foundation

/// The app's side of the Meet call controls: holds what the caption bridge last reported about the
/// user's microphone and camera, and hands the bridge the commands the floating controls issue.
///
/// The bridge cannot be pushed to — everything it does is a request *it* makes — so commands travel
/// as the answer to a long-poll it keeps open for the life of the call (`nextCommands`). Nothing is
/// persisted: state is rebuilt from the bridge's next poll after a relaunch. The decisions (which
/// call is current, when a call goes stale, which commands are still worth running) live in
/// `MeetCallControlRegistry`, which is pure.
@MainActor
final class MeetCallControlService: ObservableObject {
    /// The call the floating controls act on, or `nil` when no Meet call can be controlled.
    @Published private(set) var current: MeetCallControlSnapshot?
    /// Which bridge build is talking to the app, for Settings.
    @Published private(set) var bridgeStatus: MeetBridgeVersion.Status = .notSeen

    /// A versioned bridge says hello on every (re)connect, a few minutes apart at most. Caption
    /// activity with no hello for this long comes from a bridge that never says it.
    static let helloFreshness: TimeInterval = 10 * 60

    private struct Waiter {
        let token: UUID
        let continuation: CheckedContinuation<[MeetCallControlCommand], Never>
    }

    private let clock: () -> Date
    private var registry = MeetCallControlRegistry()
    private var waiters: [UUID: Waiter] = [:]
    private var staleCheck: AnyCancellable?
    private var reportedBridgeVersion: String?
    private var lastHelloAt: Date?
    private var sawBridgeActivity = false

    init(clock: @escaping () -> Date = Date.init) {
        self.clock = clock
    }

    // MARK: - Bridge version

    /// The bridge announced its version.
    func noteBridgeHello(version: String) {
        reportedBridgeVersion = version
        lastHelloAt = clock()
        sawBridgeActivity = true
        refreshBridgeStatus()
    }

    /// A caption session showed a sign of life (start, captions, heartbeat).
    func noteBridgeActivity() {
        sawBridgeActivity = true
        if let lastHelloAt, clock().timeIntervalSince(lastHelloAt) > Self.helloFreshness {
            // Whatever is feeding captions now is not the bridge that said hello.
            reportedBridgeVersion = nil
        }
        refreshBridgeStatus()
    }

    private func refreshBridgeStatus() {
        let status = MeetBridgeVersion.status(reported: reportedBridgeVersion, sawActivity: sawBridgeActivity)
        if status != bridgeStatus { bridgeStatus = status }
    }

    // MARK: - From the bridge

    func report(meetingID: UUID, state: MeetCallControlState) {
        registry.report(meetingID, state: state, at: clock())
        refresh()
    }

    /// The call is over: stop offering controls for it and release its open poll.
    func end(meetingID: UUID) {
        registry.remove(meetingID)
        waiters.removeValue(forKey: meetingID)?.continuation.resume(returning: [])
        refresh()
    }

    /// The bridge's long-poll: answers at once when commands are waiting, otherwise holds the
    /// request until one is issued or `wait` runs out (then answers with none, and the bridge asks
    /// again). `state` is what the bridge sees right now, so every poll also re-asserts it.
    func nextCommands(
        meetingID: UUID,
        wait: TimeInterval,
        state: MeetCallControlState? = nil
    ) async -> [MeetCallControlCommand] {
        let now = clock()
        if let state {
            registry.report(meetingID, state: state, at: now)
        } else {
            registry.touch(meetingID, at: now)
        }
        refresh()

        // One open poll per call: a second one means the bridge's worker was recycled and the
        // first request is dead on its side, so answer it and let the new one wait.
        waiters.removeValue(forKey: meetingID)?.continuation.resume(returning: [])

        let pending = registry.drain(meetingID, at: now)
        if !pending.isEmpty { return pending }

        let token = UUID()
        let bounded = min(max(wait, 0), MeetCallControlRegistry.maxPollWait)
        return await withCheckedContinuation { continuation in
            waiters[meetingID] = Waiter(token: token, continuation: continuation)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(bounded))
                guard let self, let waiter = self.waiters[meetingID], waiter.token == token else { return }
                self.waiters[meetingID] = nil
                waiter.continuation.resume(returning: [])
            }
        }
    }

    // MARK: - From the floating controls

    func toggleMic() {
        guard let current else { return }
        send(.setMic, muted: !current.state.micMuted)
    }

    func toggleCamera() {
        guard let current, let cameraOff = current.state.cameraOff else { return }
        send(.setCamera, muted: !cameraOff)
    }

    func focusCall() {
        send(.focus, muted: nil)
    }

    private func send(_ action: MeetCallControlCommand.Action, muted: Bool?) {
        guard let current else { return }
        let command = MeetCallControlCommand(id: UUID().uuidString, action: action, muted: muted)
        if let waiter = waiters.removeValue(forKey: current.meetingID) {
            waiter.continuation.resume(returning: [command])
        } else {
            // Between two polls: the next one collects it, if it comes before the command expires.
            registry.enqueue(command, for: current.meetingID, at: clock())
        }
    }

    // MARK: - Queries

    /// Microphone/camera state for the presence API: the given meeting's when it is the one being
    /// controlled, otherwise the current call's (a local capture and the bridge's caption session
    /// of the same call are two meetings).
    func state(preferring meetingID: UUID) -> MeetCallControlState? {
        let now = clock()
        return registry.state(for: meetingID, at: now) ?? registry.current(at: now)?.state
    }

    private func refresh() {
        let snapshot = registry.current(at: clock())
        if snapshot != current { current = snapshot }

        // While a call is offered, keep checking that the bridge is still there: a closed tab or a
        // quit browser sends no goodbye, it just stops polling.
        if snapshot == nil {
            staleCheck = nil
        } else if staleCheck == nil {
            staleCheck = Timer.publish(every: 5, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in self?.refresh() }
        }
    }
}
