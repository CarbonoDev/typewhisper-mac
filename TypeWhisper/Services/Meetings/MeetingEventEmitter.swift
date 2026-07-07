import Foundation
import TypeWhisperPluginSDK
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "MeetingEventEmitter")

/// Injectable seam meeting services use to publish `MeetingEvent`s (addendum AD4). Injected as a
/// defaulted no-op so existing call sites and v1 tests compile and run unchanged, and so other
/// tracks can develop against a stub if this track slips.
@MainActor
protocol MeetingEventEmitting: AnyObject {
    func emit(_ event: MeetingEvent)
}

/// Default emitter: does nothing. Used wherever no real bus is injected (v1 tests, previews).
@MainActor
final class NoopMeetingEventEmitter: MeetingEventEmitting {
    init() {}
    func emit(_ event: MeetingEvent) {}
}

/// Real emitter: fans events out on the host `MeetingEventBus` and — when the opt-in AD5 bridge is
/// enabled — mirrors a completed meeting's final transcript onto the classic dictation `EventBus`
/// as a `.transcriptionCompleted` event. The bridge lives here (its one home) and defaults OFF.
@MainActor
final class MeetingEventBusEmitter: MeetingEventEmitting {
    private let bus: MeetingEventBus
    private let defaults: UserDefaults
    /// Injectable bridge sink (testable). Defaults to the classic dictation `EventBus`.
    private let bridge: @MainActor (TranscriptionCompletedPayload) -> Void

    init(
        bus: MeetingEventBus,
        defaults: UserDefaults = .standard,
        bridge: @escaping @MainActor (TranscriptionCompletedPayload) -> Void = { payload in
            EventBus.shared?.emit(.transcriptionCompleted(payload))
        }
    ) {
        self.bus = bus
        self.defaults = defaults
        self.bridge = bridge
    }

    func emit(_ event: MeetingEvent) {
        bus.emit(event)

        // AD5 bridge: default OFF. Fires exactly once per meeting stop, keyed on `.transcriptReady`
        // (the single post-finalize event that carries the full transcript + duration).
        guard defaults.bool(forKey: UserDefaultsKeys.meetingsBridgeToDictationEvents) else { return }
        guard case let .transcriptReady(payload) = event else { return }

        let bridged = TranscriptionCompletedPayload(
            rawText: payload.fullText,
            finalText: payload.fullText,
            language: nil,
            engineUsed: "meeting",
            modelUsed: nil,
            durationSeconds: payload.durationSeconds,
            appName: nil,
            bundleIdentifier: nil,
            url: nil,
            ruleName: nil
        )
        logger.debug("Bridging meeting transcript to classic dictation EventBus")
        bridge(bridged)
    }
}
