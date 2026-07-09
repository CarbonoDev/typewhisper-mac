import Foundation
import Security
import XCTest
@testable import TypeWhisper

final class CLISupportTests: XCTestCase {
    private final class RequestRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var request: URLRequest?

        func record(_ request: URLRequest) {
            lock.withLock {
                self.request = request
            }
        }

        var recordedRequest: URLRequest? {
            lock.withLock { request }
        }
    }

    func testOutputFormatterRendersHumanReadableStatusAndModels() {
        let statusJSON = Data(#"{"status":"ready","engine":"parakeet","model":"tiny"}"#.utf8)
        let modelsJSON = Data(#"{"models":[{"id":"tiny","engine":"parakeet","name":"Tiny","status":"ready","selected":true}]}"#.utf8)

        XCTAssertEqual(OutputFormatter.formatStatus(statusJSON, json: false), "Ready - parakeet (tiny)")
        XCTAssertTrue(OutputFormatter.formatModels(modelsJSON, json: false).contains("tiny"))
        XCTAssertTrue(OutputFormatter.formatModels(modelsJSON, json: false).contains("*"))
    }

    func testPortDiscoveryUsesConfiguredPortFileAndFallback() throws {
        let applicationSupportRoot = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(applicationSupportRoot) }

        let appDirectory = applicationSupportRoot.appendingPathComponent("TypeWhisper", isDirectory: true)
        try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        try "9911".write(to: appDirectory.appendingPathComponent("api-port"), atomically: true, encoding: .utf8)

        XCTAssertEqual(PortDiscovery.discoverPort(dev: false, applicationSupportDirectory: applicationSupportRoot), 9911)
        XCTAssertEqual(PortDiscovery.discoverPort(dev: true, applicationSupportDirectory: applicationSupportRoot), PortDiscovery.defaultPort)
    }

    func testPortDiscoveryUsesTokenizedDiscoveryFileBeforeLegacyPortFile() throws {
        let applicationSupportRoot = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(applicationSupportRoot) }

        let appDirectory = applicationSupportRoot.appendingPathComponent("TypeWhisper", isDirectory: true)
        try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        try "9911".write(to: appDirectory.appendingPathComponent("api-port"), atomically: true, encoding: .utf8)
        try """
        {
          "version": 1,
          "port": 9922,
          "token": "token-from-discovery"
        }
        """.write(to: appDirectory.appendingPathComponent("api-discovery.json"), atomically: true, encoding: .utf8)

        let discovery = PortDiscovery.discover(dev: false, applicationSupportDirectory: applicationSupportRoot)

        XCTAssertEqual(discovery, APIDiscovery(port: 9922, token: "token-from-discovery"))
        XCTAssertEqual(PortDiscovery.discoverPort(dev: false, applicationSupportDirectory: applicationSupportRoot), 9922)
    }

    func testCLITranscribeLanguageOptionsRejectMixedExactAndHintFlags() {
        let options = CLITranscribeLanguageOptions(language: "de", languageHints: ["en", "nl"])
        XCTAssertEqual(
            options.validationError(),
            "Error: --language and --language-hint cannot be used together."
        )
    }

    func testCLIClientTranscribeLocalFileUsesLocalFileEndpointWithoutUploadingBytes() async throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(directory) }
        let fileURL = directory.appendingPathComponent("large.mp4")
        try Data("distinctive-video-bytes".utf8).write(to: fileURL)

        let recorder = RequestRecorder()
        let client = CLIClient(
            port: 9876,
            transport: { request in
                recorder.record(request)
                let body = #"{"text":"ok","language":null,"duration":1,"processing_time":0.1,"engine":"mock","model":"tiny"}"#
                return (Data(body.utf8), Self.httpResponse(url: request.url!, statusCode: 200))
            }
        )

        _ = try await client.transcribe(
            fileURL: fileURL,
            language: nil,
            languageHints: ["de", "en"],
            task: "transcribe",
            targetLanguage: nil,
            engine: "mock",
            model: "tiny"
        )

        let request = try XCTUnwrap(recorder.recordedRequest)
        XCTAssertEqual(request.url?.path, "/v1/transcribe/local-file")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let bodyData = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(body["path"] as? String, fileURL.path)
        XCTAssertEqual(body["language_hints"] as? [String], ["de", "en"])
        XCTAssertEqual(body["task"] as? String, "transcribe")
        XCTAssertEqual(body["engine"] as? String, "mock")
        XCTAssertEqual(body["model"] as? String, "tiny")
        XCTAssertNil(body["apply_corrections"])
        XCTAssertFalse(String(data: bodyData, encoding: .utf8)?.contains("distinctive-video-bytes") == true)
    }

    func testCLIClientTranscribeLocalFileSendsApplyCorrectionsFalseWhenRequested() async throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(directory) }
        let fileURL = directory.appendingPathComponent("raw.wav")
        try Data("audio-bytes".utf8).write(to: fileURL)

        let recorder = RequestRecorder()
        let client = CLIClient(
            port: 9876,
            transport: { request in
                recorder.record(request)
                let body = #"{"text":"ok","language":null,"duration":1,"processing_time":0.1,"engine":"mock","model":"tiny"}"#
                return (Data(body.utf8), Self.httpResponse(url: request.url!, statusCode: 200))
            }
        )

        _ = try await client.transcribe(
            fileURL: fileURL,
            language: nil,
            languageHints: [],
            task: "transcribe",
            targetLanguage: nil,
            applyCorrections: false
        )

        let request = try XCTUnwrap(recorder.recordedRequest)
        XCTAssertEqual(request.url?.path, "/v1/transcribe/local-file")
        let bodyData = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(body["path"] as? String, fileURL.path)
        XCTAssertEqual(body["apply_corrections"] as? Bool, false)
    }

    func testCLIClientSendsBearerTokenWhenConfigured() async throws {
        let recorder = RequestRecorder()
        let client = CLIClient(
            port: 9876,
            apiToken: "cli-token",
            transport: { request in
                recorder.record(request)
                let body = #"{"models":[]}"#
                return (Data(body.utf8), Self.httpResponse(url: request.url!, statusCode: 200))
            }
        )

        _ = try await client.models()

        let request = try XCTUnwrap(recorder.recordedRequest)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer cli-token")
    }

    func testCLIClientTranscribeStdinKeepsMultipartUploadPath() async throws {
        let recorder = RequestRecorder()
        let client = CLIClient(
            port: 9876,
            transport: { request in
                recorder.record(request)
                let body = #"{"text":"ok","language":null,"duration":1,"processing_time":0.1,"engine":"mock","model":"tiny"}"#
                return (Data(body.utf8), Self.httpResponse(url: request.url!, statusCode: 200))
            },
            stdinReader: {
                Data("stdin-audio-bytes".utf8)
            }
        )

        _ = try await client.transcribe(
            fileURL: nil,
            language: "de",
            languageHints: [],
            task: "transcribe",
            targetLanguage: nil,
            engine: nil,
            model: nil
        )

        let request = try XCTUnwrap(recorder.recordedRequest)
        XCTAssertEqual(request.url?.path, "/v1/transcribe")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)

        let bodyText = String(data: try XCTUnwrap(request.httpBody), encoding: .utf8)
        XCTAssertTrue(bodyText?.contains("stdin-audio-bytes") == true)
        XCTAssertTrue(bodyText?.contains("name=\"language\"") == true)
        XCTAssertFalse(bodyText?.contains("name=\"apply_corrections\"") == true)
    }

    func testCLIClientTranscribeStdinSendsApplyCorrectionsFalseWhenRequested() async throws {
        let recorder = RequestRecorder()
        let client = CLIClient(
            port: 9876,
            transport: { request in
                recorder.record(request)
                let body = #"{"text":"ok","language":null,"duration":1,"processing_time":0.1,"engine":"mock","model":"tiny"}"#
                return (Data(body.utf8), Self.httpResponse(url: request.url!, statusCode: 200))
            },
            stdinReader: {
                Data("stdin-audio-bytes".utf8)
            }
        )

        _ = try await client.transcribe(
            fileURL: nil,
            language: nil,
            languageHints: [],
            task: "transcribe",
            targetLanguage: nil,
            applyCorrections: false
        )

        let request = try XCTUnwrap(recorder.recordedRequest)
        XCTAssertEqual(request.url?.path, "/v1/transcribe")
        let bodyText = String(data: try XCTUnwrap(request.httpBody), encoding: .utf8)
        XCTAssertTrue(bodyText?.contains("name=\"apply_corrections\"") == true)
        XCTAssertTrue(bodyText?.contains("\r\nfalse\r\n") == true)
    }

    func testCLIClientImportMeetingTranscriptUsesDirectHandoff() async throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(directory) }
        let fileURL = directory.appendingPathComponent("transcript.txt")
        try "Alice: Hi.".write(to: fileURL, atomically: true, encoding: .utf8)

        let recorder = RequestRecorder()
        let client = CLIClient(
            port: 9876,
            transport: { request in
                recorder.record(request)
                let body = #"{"id":"X","title":"Sync","date":null,"matched_event":null}"#
                return (Data(body.utf8), Self.httpResponse(url: request.url!, statusCode: 200))
            }
        )

        _ = try await client.importMeetingTranscript(
            fileURL: fileURL,
            title: "Sync",
            date: "2026-01-05",
            folder: "Clients/Acme",
            tags: ["sales", "q1"],
            language: "en",
            matchCalendar: true
        )

        let request = try XCTUnwrap(recorder.recordedRequest)
        XCTAssertEqual(request.url?.path, "/v1/meetings/import-transcript")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let bodyData = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(body["path"] as? String, fileURL.path)
        XCTAssertEqual(body["title"] as? String, "Sync")
        XCTAssertEqual(body["date"] as? String, "2026-01-05")
        XCTAssertEqual(body["folder"] as? String, "Clients/Acme")
        XCTAssertEqual(body["tags"] as? [String], ["sales", "q1"])
        XCTAssertEqual(body["language"] as? String, "en")
        XCTAssertEqual(body["match_calendar"] as? Bool, true)
        // Direct handoff: file bytes are not uploaded.
        XCTAssertFalse(String(data: bodyData, encoding: .utf8)?.contains("Alice: Hi.") == true)
    }

    func testCLIClientImportMeetingTranscriptRejectsMissingFile() async throws {
        let client = CLIClient(port: 9876, transport: { request in
            (Data("{}".utf8), Self.httpResponse(url: request.url!, statusCode: 200))
        })
        do {
            _ = try await client.importMeetingTranscript(
                fileURL: URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).txt"),
                title: nil, date: nil, folder: nil, tags: [], language: nil, matchCalendar: false
            )
            XCTFail("Expected fileNotFound")
        } catch let error as CLIError {
            XCTAssertEqual(error.exitCode, 1)
        }
    }

    func testCLIClientListMeetingsBuildsQuery() async throws {
        let recorder = RequestRecorder()
        let client = CLIClient(
            port: 9876,
            transport: { request in
                recorder.record(request)
                let body = #"{"meetings":[],"total":0,"limit":50,"offset":0}"#
                return (Data(body.utf8), Self.httpResponse(url: request.url!, statusCode: 200))
            }
        )

        _ = try await client.listMeetings(folder: "Clients/Acme", tag: "sales", from: "2026-01-01", to: "2026-03-31")

        let request = try XCTUnwrap(recorder.recordedRequest)
        XCTAssertEqual(request.url?.path, "/v1/meetings")
        let query = try XCTUnwrap(request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems })
        XCTAssertTrue(query.contains(URLQueryItem(name: "folder", value: "Clients/Acme")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "tag", value: "sales")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "from", value: "2026-01-01")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "to", value: "2026-03-31")))
    }

    func testOutputFormatterRendersMeetingImportAndList() {
        let importJSON = Data(#"{"id":"abc","title":"Acme Sync","date":null,"matched_event":{"id":"e1","title":"Acme Sync","date":"2026-01-05T10:00:00Z","confidence":0.9}}"#.utf8)
        let importText = OutputFormatter.formatMeetingImport(importJSON, json: false)
        XCTAssertTrue(importText.contains("Acme Sync"))
        XCTAssertTrue(importText.contains("Linked to calendar event"))

        let listJSON = Data(#"{"meetings":[{"id":"abc","title":"Acme Sync","date":"2026-01-05T10:00:00Z","folder":"Clients/Acme","tags":["sales"],"language":"en","has_transcript":true,"has_summary":false,"calendar_linked":true}],"total":1,"limit":50,"offset":0}"#.utf8)
        let listText = OutputFormatter.formatMeetingsList(listJSON, json: false)
        XCTAssertTrue(listText.contains("Acme Sync"))
        XCTAssertTrue(listText.contains("2026-01-05"))
        XCTAssertTrue(listText.contains("[cal]"))
        XCTAssertTrue(OutputFormatter.formatMeetingsList(Data(#"{"meetings":[],"total":0,"limit":50,"offset":0}"#.utf8), json: false).contains("No meetings found."))
    }

    private static func httpResponse(url: URL, statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    }
}
