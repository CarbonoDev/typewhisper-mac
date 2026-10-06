import Foundation

// Pure logic behind the Meet call controls: what the caption bridge last said about the user's
// microphone and camera, and the commands the app wants it to run. The bridge reports state over
// `POST /v1/meetings/live/{id}/controls` and collects commands by long-polling
// `POST /v1/meetings/live/{id}/commands/poll` (see `APIHandlers+MeetCallControl.swift`).

/// The user's own microphone and camera in a Meet call, as the bridge reads them off Meet's toolbar.
struct MeetCallControlState: Equatable, Sendable {
    var micMuted: Bool
    /// `nil` when the camera toggle could not be read (no camera, or an unknown Meet build).
    var cameraOff: Bool?
}

/// One instruction for the bridge. Mic and camera commands name a *target* state rather than
/// "toggle", so a command that arrives late or twice can never flip the wrong way.
struct MeetCallControlCommand: Encodable, Equatable, Sendable {
    enum Action: String, Encodable, Sendable {
        case setMic = "set_mic"
        case setCamera = "set_camera"
        /// Bring the Meet tab and its window to the front.
        case focus
    }

    var id: String
    var action: Action
    /// Target for `set_mic` (muted) and `set_camera` (off); absent for `focus`.
    var muted: Bool?
}

/// The call the floating controls act on right now.
struct MeetCallControlSnapshot: Equatable, Sendable {
    var meetingID: UUID
    var state: MeetCallControlState
}

/// What each controllable Meet call last reported, and the commands waiting for it.
///
/// In-memory by design, like `LiveSessionActivityRegistry`: after a relaunch a call that is really
/// still running re-registers on the bridge's next poll, which carries its state.
struct MeetCallControlRegistry: Equatable, Sendable {
    /// A call the bridge has not polled for or reported on for this long can no longer be
    /// controlled. Sized to outlast one full poll wait (`maxPollWait`) plus a slow reconnect.
    static let freshness: TimeInterval = 45
    /// A command nobody collected within this window is dropped: a mute that lands half a minute
    /// after the click is worse than one that never lands.
    static let commandTTL: TimeInterval = 5
    /// Upper bound on how long a poll may be held. Chrome kills an extension worker whose request
    /// takes 30 s to answer, so this stays well under that.
    static let maxPollWait: TimeInterval = 25

    private struct Pending: Equatable, Sendable {
        var command: MeetCallControlCommand
        var expiresAt: Date
    }

    private struct Entry: Equatable, Sendable {
        var state: MeetCallControlState?
        var firstSeenAt: Date
        var lastSeenAt: Date
        var pending: [Pending] = []
    }

    private var entries: [UUID: Entry] = [:]

    /// The bridge reported the toolbar's state.
    mutating func report(_ meetingID: UUID, state: MeetCallControlState, at date: Date) {
        touch(meetingID, at: date)
        entries[meetingID]?.state = state
    }

    /// The bridge showed a sign of life (a poll) without new state.
    mutating func touch(_ meetingID: UUID, at date: Date) {
        var entry = entries[meetingID] ?? Entry(state: nil, firstSeenAt: date, lastSeenAt: date)
        // A call that went stale and came back is a new call for ordering purposes.
        if date.timeIntervalSince(entry.lastSeenAt) > Self.freshness { entry.firstSeenAt = date }
        entry.lastSeenAt = max(entry.lastSeenAt, date)
        entries[meetingID] = entry
    }

    mutating func remove(_ meetingID: UUID) {
        entries[meetingID] = nil
    }

    mutating func enqueue(_ command: MeetCallControlCommand, for meetingID: UUID, at date: Date) {
        guard entries[meetingID] != nil else { return }
        // A newer command of the same kind replaces an uncollected older one: only the last click
        // on the mic button matters.
        entries[meetingID]?.pending.removeAll { $0.command.action == command.action }
        entries[meetingID]?.pending.append(
            Pending(command: command, expiresAt: date.addingTimeInterval(Self.commandTTL))
        )
    }

    /// Hand over the commands still worth running, oldest first, and forget them.
    mutating func drain(_ meetingID: UUID, at date: Date) -> [MeetCallControlCommand] {
        guard let pending = entries[meetingID]?.pending, !pending.isEmpty else { return [] }
        entries[meetingID]?.pending = []
        return pending.filter { $0.expiresAt >= date }.map(\.command)
    }

    func isFresh(_ meetingID: UUID, at now: Date) -> Bool {
        guard let entry = entries[meetingID] else { return false }
        return now.timeIntervalSince(entry.lastSeenAt) <= Self.freshness
    }

    /// The last reported state, while the call can still be controlled.
    func state(for meetingID: UUID, at now: Date) -> MeetCallControlState? {
        isFresh(meetingID, at: now) ? entries[meetingID]?.state : nil
    }

    /// The call the controls act on: the most recently joined one that is fresh and has reported
    /// its state. Joined-order rather than last-changed, so muting in one of two open calls never
    /// makes the controls jump to it.
    func current(at now: Date) -> MeetCallControlSnapshot? {
        entries
            .filter { isFresh($0.key, at: now) && $0.value.state != nil }
            .max { lhs, rhs in
                if lhs.value.firstSeenAt != rhs.value.firstSeenAt {
                    return lhs.value.firstSeenAt < rhs.value.firstSeenAt
                }
                return lhs.key.uuidString < rhs.key.uuidString
            }
            .flatMap { entry in
                entry.value.state.map { MeetCallControlSnapshot(meetingID: entry.key, state: $0) }
            }
    }
}

/// Which build of the Meet Bridge extension is talking to the app. Chrome runs whatever folder the
/// extension was loaded from, so "I reloaded it" and "the new code is running" are not the same
/// thing — the bridge therefore says its version (`POST /v1/bridge/hello`) and Settings shows it.
enum MeetBridgeVersion {
    /// The extension version this app build ships with. Must equal `version` in
    /// `chrome-extension/manifest.json`; `MeetCallControlTests` fails when the two drift, and
    /// `scripts/pr-preflight.sh` fails when the extension changes without a version bump.
    static let shipped = "0.4.0"

    enum Status: Equatable, Sendable {
        /// Nothing has been heard from any bridge since the app started.
        case notSeen
        /// A bridge is feeding captions but never said its version: it predates 0.3.0.
        case unversioned
        /// A bridge older than the one this build ships with.
        case outdated(String)
        case current(String)
    }

    static func status(reported: String?, sawActivity: Bool, shipped: String = shipped) -> Status {
        guard let reported else { return sawActivity ? .unversioned : .notSeen }
        return isOlder(reported, than: shipped) ? .outdated(reported) : .current(reported)
    }

    /// Numeric comparison of dotted versions ("0.10.0" is newer than "0.9.1"); a missing or
    /// non-numeric component counts as 0.
    static func isOlder(_ version: String, than other: String) -> Bool {
        let lhs = components(version)
        let rhs = components(other)
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    private static func components(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }
}
