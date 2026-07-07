import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

@MainActor
final class MeetingEventBusTests: XCTestCase {
    private func sampleReady(_ id: UUID = UUID(), text: String = "final text") -> MeetingEvent {
        .transcriptReady(MeetingTranscriptReadyPayload(
            meetingID: id, fullText: text, segmentCount: 3, durationSeconds: 42
        ))
    }

    /// Let the bus's `DispatchQueue.main.async` subscribe hop run before emitting.
    private func drainMainQueue() async {
        try? await Task.sleep(for: .milliseconds(50))
    }

    // MARK: - Bus fan-out + unsubscribe

    func testBusFansOutToAllSubscribers() async throws {
        let bus = MeetingEventBus()
        let first = expectation(description: "first subscriber")
        let second = expectation(description: "second subscriber")
        let meetingID = UUID()

        bus.subscribeMeetingEvents { event in
            if case let .transcriptReady(payload) = event, payload.meetingID == meetingID {
                first.fulfill()
            }
        }
        bus.subscribeMeetingEvents { event in
            if case let .transcriptReady(payload) = event, payload.meetingID == meetingID {
                second.fulfill()
            }
        }
        await drainMainQueue()

        bus.emit(sampleReady(meetingID))
        await fulfillment(of: [first, second], timeout: 2)
    }

    func testUnsubscribeStopsDelivery() async throws {
        let bus = MeetingEventBus()
        let received = expectation(description: "should not be delivered")
        received.isInverted = true

        let id = bus.subscribeMeetingEvents { _ in received.fulfill() }
        await drainMainQueue()
        bus.unsubscribeMeetingEvents(id: id)
        await drainMainQueue()

        bus.emit(sampleReady())
        await fulfillment(of: [received], timeout: 0.5)
    }

    // MARK: - AD5 dictation bridge (default OFF)

    func testBridgeOffDoesNotEmitClassicEvent() {
        let bus = MeetingEventBus()
        let defaults = UserDefaults(suiteName: "MeetingEventBusTests-off-\(UUID().uuidString)")!
        defaults.set(false, forKey: UserDefaultsKeys.meetingsBridgeToDictationEvents)

        var bridged: [TranscriptionCompletedPayload] = []
        let emitter = MeetingEventBusEmitter(bus: bus, defaults: defaults) { bridged.append($0) }

        emitter.emit(sampleReady(UUID(), text: "hello"))
        XCTAssertTrue(bridged.isEmpty)
    }

    func testBridgeOnEmitsExactlyOneClassicEventOnTranscriptReady() {
        let bus = MeetingEventBus()
        let defaults = UserDefaults(suiteName: "MeetingEventBusTests-on-\(UUID().uuidString)")!
        defaults.set(true, forKey: UserDefaultsKeys.meetingsBridgeToDictationEvents)

        var bridged: [TranscriptionCompletedPayload] = []
        let emitter = MeetingEventBusEmitter(bus: bus, defaults: defaults) { bridged.append($0) }

        let id = UUID()
        // Non-transcriptReady events must not bridge.
        emitter.emit(.started(MeetingStartedPayload(
            meetingID: id, title: "T", isCalendarMeeting: false, attendeeCount: 0
        )))
        emitter.emit(.ended(MeetingEndedPayload(
            meetingID: id, durationSeconds: 10, stateRaw: "completed", segmentCount: 1
        )))
        XCTAssertTrue(bridged.isEmpty)

        emitter.emit(.transcriptReady(MeetingTranscriptReadyPayload(
            meetingID: id, fullText: "bridged body", segmentCount: 2, durationSeconds: 99
        )))

        XCTAssertEqual(bridged.count, 1)
        XCTAssertEqual(bridged.first?.finalText, "bridged body")
        XCTAssertEqual(bridged.first?.rawText, "bridged body")
        XCTAssertEqual(bridged.first?.durationSeconds, 99)
    }

    // MARK: - Host capability wiring + dictation isolation

    func testHostServicesExposesMeetingEventsAndDelivers() async throws {
        let bus = MeetingEventBus()
        let host = HostServicesImpl(
            pluginId: "test.meetingevents",
            eventBus: EventBus(),
            meetingEventBus: bus,
            ruleNamesProvider: { [] }
        )

        let observing = (host as HostServices).meetingEvents
        XCTAssertNotNil(observing, "host.meetingEvents must be non-nil on the new host")

        let delivered = expectation(description: "meeting event delivered through host capability")
        let meetingID = UUID()
        observing?.subscribeMeetingEvents { event in
            if case let .started(payload) = event, payload.meetingID == meetingID {
                delivered.fulfill()
            }
        }
        await drainMainQueue()

        bus.emit(.started(MeetingStartedPayload(
            meetingID: meetingID, title: "Kickoff", isCalendarMeeting: false, attendeeCount: 0
        )))
        await fulfillment(of: [delivered], timeout: 2)
    }

    func testClassicDictationSubscriberSeesNoMeetingEvents() async throws {
        // A legacy-style subscriber on the classic EventBus must observe zero meeting activity —
        // the two buses are separate types by construction (dictation-isolation invariant).
        let dictationBus = EventBus()
        let meetingBus = MeetingEventBus()

        let classicSaw = expectation(description: "classic subscriber must not fire")
        classicSaw.isInverted = true
        dictationBus.subscribe { _ in classicSaw.fulfill() }
        await drainMainQueue()

        meetingBus.emit(sampleReady())
        meetingBus.emit(.ended(MeetingEndedPayload(
            meetingID: UUID(), durationSeconds: 1, stateRaw: "completed", segmentCount: 0
        )))

        await fulfillment(of: [classicSaw], timeout: 0.5)
    }
}
