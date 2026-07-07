import Foundation
import TypeWhisperPluginSDK
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "MeetingEventBus")

/// Host-side publish/subscribe bus for `MeetingEvent`s (addendum AD4). A structural mirror of
/// `EventBus` — deliberately a *separate* bus from the dictation `EventBus` so meeting events can
/// never reach a classic `TypeWhisperEvent` subscriber (dictation-isolation invariant). Plugins
/// reach it through `HostServices.meetingEvents` (the `MeetingEventObserving` capability).
@MainActor
final class MeetingEventBus: MeetingEventObserving, @unchecked Sendable {
    nonisolated(unsafe) static var shared: MeetingEventBus!

    private struct Subscription: Sendable {
        let id: UUID
        let handler: @Sendable (MeetingEvent) async -> Void
    }

    private var subscriptions: [Subscription] = []

    @discardableResult
    nonisolated func subscribeMeetingEvents(
        _ handler: @escaping @Sendable (MeetingEvent) async -> Void
    ) -> UUID {
        let id = UUID()
        let subscription = Subscription(id: id, handler: handler)
        DispatchQueue.main.async {
            self.subscriptions.append(subscription)
        }
        return id
    }

    nonisolated func unsubscribeMeetingEvents(id: UUID) {
        DispatchQueue.main.async {
            self.subscriptions.removeAll { $0.id == id }
        }
    }

    func emit(_ event: MeetingEvent) {
        let handlers = subscriptions.map { $0.handler }
        for handler in handlers {
            Task.detached {
                await handler(event)
            }
        }
        logger.debug("Emitted meeting event to \(handlers.count) subscriber(s)")
    }
}
