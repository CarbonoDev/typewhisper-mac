import Foundation
import XCTest
@_spi(Testing) import TypeWhisperPluginSDK
@_spi(Testing) import TypeWhisperPluginSDKTesting
@testable import WebhookPlugin

final class MeetingWebhookTests: XCTestCase {
    override func tearDown() {
        PluginHTTPClientTestHarness.reset()
        super.tearDown()
    }

    private func okResponse() throws -> HTTPURLResponse {
        try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://example.com/hook")!,
            statusCode: 204, httpVersion: nil, headerFields: nil
        ))
    }

    func testConfigDecodesMissingMeetingEventsAsEmpty() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"Legacy","url":"https://example.com/hook",
         "httpMethod":"POST","headers":{},"isEnabled":true,"profileFilter":[]}
        """
        let config = try JSONDecoder().decode(ExampleWebhookConfig.self, from: Data(json.utf8))
        XCTAssertTrue(config.meetingEvents.isEmpty)
    }

    func testFiresOnlyForConfiguredMeetingEvents() async throws {
        let host = try PluginTestHostServices()
        let service = ExampleWebhookService(dataDirectory: host.pluginDataDirectory, host: host)
        var webhook = ExampleWebhookConfig(name: "Meetings", url: "https://example.com/hook")
        webhook.meetingEvents = [MeetingWebhookEvent.transcriptReady]
        service.addWebhook(webhook)

        let sessionStore = PluginHTTPClientSessionStore()
        let response = try okResponse()
        PluginHTTPClientTestHarness.configure { _ in
            sessionStore.makeSession(outcomes: [.success(Data(), response), .success(Data(), response)])
        }

        let meetingID = UUID()
        // Not configured → must NOT fire.
        await service.sendMeetingWebhooks(for: .started(MeetingStartedPayload(
            meetingID: meetingID, title: "T", isCalendarMeeting: false, attendeeCount: 0
        )))
        // Configured → must fire once with the flattened payload + event discriminator.
        await service.sendMeetingWebhooks(for: .transcriptReady(MeetingTranscriptReadyPayload(
            meetingID: meetingID, fullText: "final body", segmentCount: 3, durationSeconds: 60
        )))

        let requests = sessionStore.sessions.flatMap { $0.requestedRequests }
        XCTAssertEqual(requests.count, 1)
        let body = try XCTUnwrap(requests.first?.httpBody)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["event"] as? String, MeetingWebhookEvent.transcriptReady)
        XCTAssertEqual(object["fullText"] as? String, "final body")
        XCTAssertEqual(object["meetingID"] as? String, meetingID.uuidString)
    }

    func testEmptyMeetingEventsNeverFires() async throws {
        let host = try PluginTestHostServices()
        let service = ExampleWebhookService(dataDirectory: host.pluginDataDirectory, host: host)
        service.addWebhook(ExampleWebhookConfig(name: "Silent", url: "https://example.com/hook"))

        let sessionStore = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            sessionStore.makeSession(outcomes: [.success(Data(), try! self.okResponse())])
        }

        for event in [
            MeetingEvent.started(MeetingStartedPayload(meetingID: UUID(), title: "T", isCalendarMeeting: false, attendeeCount: 0)),
            .transcriptReady(MeetingTranscriptReadyPayload(meetingID: UUID(), fullText: "x", segmentCount: 1, durationSeconds: 1)),
            .ended(MeetingEndedPayload(meetingID: UUID(), durationSeconds: 1, stateRaw: "completed", segmentCount: 1)),
        ] {
            await service.sendMeetingWebhooks(for: event)
        }

        let requests = sessionStore.sessions.flatMap { $0.requestedRequests }
        XCTAssertTrue(requests.isEmpty)
    }

    func testDisabledWebhookDoesNotFire() async throws {
        let host = try PluginTestHostServices()
        let service = ExampleWebhookService(dataDirectory: host.pluginDataDirectory, host: host)
        var webhook = ExampleWebhookConfig(name: "Off", url: "https://example.com/hook", isEnabled: false)
        webhook.meetingEvents = MeetingWebhookEvent.all
        service.addWebhook(webhook)

        let sessionStore = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            sessionStore.makeSession(outcomes: [.success(Data(), try! self.okResponse())])
        }

        await service.sendMeetingWebhooks(for: .ended(MeetingEndedPayload(
            meetingID: UUID(), durationSeconds: 1, stateRaw: "completed", segmentCount: 0
        )))

        XCTAssertTrue(sessionStore.sessions.flatMap { $0.requestedRequests }.isEmpty)
    }
}
