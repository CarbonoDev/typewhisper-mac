import Foundation
import XCTest
import TypeWhisperPluginSDK
@_spi(Testing) import TypeWhisperPluginSDKTesting
@testable import ClaudePlugin

final class ClaudePluginTests: XCTestCase {
    private static let cachedModelsKey = "fetchedLLMModels.v1"
    private static let selectedLLMModelKey = "selectedLLMModel"
    private static let modelsURL = "https://api.anthropic.com/v1/models"
    private static let messagesURL = "https://api.anthropic.com/v1/messages"

    override func tearDown() {
        PluginHTTPClientTestHarness.reset()
        super.tearDown()
    }

    // MARK: - Existing selection behavior

    func testPreferredModelIdReflectsSelectedLLMModel() throws {
        let host = try PluginTestHostServices()
        let plugin = ClaudePlugin()
        plugin.activate(host: host)

        XCTAssertNil(
            (plugin as? LLMModelSelectable)?.preferredModelId ?? nil,
            "preferredModelId must be nil until the user selects a model"
        )

        let target = try XCTUnwrap(plugin.supportedModels.first?.id)
        plugin.selectLLMModel(target)

        let preferred = (plugin as? LLMModelSelectable)?.preferredModelId
        XCTAssertEqual(preferred, target)
    }

    // MARK: - Fallback list

    func testFallbackModelsWhenNoCacheOrKey() throws {
        let host = try PluginTestHostServices()
        let plugin = ClaudePlugin()
        plugin.activate(host: host)

        XCTAssertEqual(
            plugin.supportedModels.map(\.id),
            [
                "claude-opus-4-8",
                "claude-sonnet-5",
                "claude-opus-4-7",
                "claude-sonnet-4-6",
                "claude-haiku-4-5",
            ]
        )
        XCTAssertFalse(
            plugin.supportedModels.contains { $0.id == "claude-haiku-4-5-20251001" },
            "the dated haiku id must be replaced by the alias in the fallback list"
        )
        XCTAssertFalse(plugin.isModelCacheFresh)
    }

    // MARK: - Pagination

    func testPaginationAssemblesAllPagesSortedNewestFirstWithAfterId() async throws {
        let host = try PluginTestHostServices()
        let plugin = ClaudePlugin()
        plugin.activate(host: host)
        plugin.setApiKey("claude-key")

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Self.modelsPage(
                        models: [("a-old-model", "A Old", "2024-01-01T00:00:00Z")],
                        hasMore: true,
                        lastId: "cursor-1"
                    ),
                    Self.httpResponse(url: Self.modelsURL, statusCode: 200)
                ),
                .success(
                    Self.modelsPage(
                        models: [("z-new-model", "Z New", "2026-05-01T00:00:00Z")],
                        hasMore: false,
                        lastId: nil
                    ),
                    Self.httpResponse(url: Self.modelsURL, statusCode: 200)
                ),
            ])
        }

        let ok = await plugin.refreshModels()
        XCTAssertTrue(ok)

        // Both pages assembled and sorted newest-first regardless of page order.
        XCTAssertEqual(plugin.supportedModels.map(\.id), ["z-new-model", "a-old-model"])
        XCTAssertTrue(plugin.isModelCacheFresh)

        let requests = store.sessions[0].requestedRequests
        XCTAssertEqual(requests.count, 2)
        XCTAssertNil(
            URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "after_id" }),
            "first page must not carry an after_id"
        )
        let secondAfterId = URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "after_id" })?.value
        XCTAssertEqual(secondAfterId, "cursor-1")
        // Requests must carry the Anthropic auth headers.
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "x-api-key"), "claude-key")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
    }

    // MARK: - Cache TTL

    func testFreshCacheServedWithoutRefetch() throws {
        let cacheData = try Self.encodeCache(
            models: [ClaudeFetchedModel(id: "cached-fresh", displayName: "Cached Fresh", createdAt: 1_000)],
            fetchedAt: Date()
        )
        let host = try PluginTestHostServices(
            defaults: [Self.cachedModelsKey: cacheData],
            secrets: ["api-key": "claude-key"]
        )
        let plugin = ClaudePlugin()
        plugin.activate(host: host)

        XCTAssertTrue(plugin.isModelCacheFresh)
        XCTAssertEqual(plugin.supportedModels.map(\.id), ["cached-fresh"])
    }

    func testStaleCacheServedImmediatelyThenRefreshes() async throws {
        let cacheData = try Self.encodeCache(
            models: [ClaudeFetchedModel(id: "cached-stale", displayName: "Cached Stale", createdAt: 1_000)],
            fetchedAt: Date(timeIntervalSinceNow: -100_000) // > 24h old
        )
        // Activate without a key so the background refresh does not race the test.
        let host = try PluginTestHostServices(defaults: [Self.cachedModelsKey: cacheData])
        let plugin = ClaudePlugin()
        plugin.activate(host: host)

        XCTAssertFalse(plugin.isModelCacheFresh)
        XCTAssertEqual(
            plugin.supportedModels.map(\.id),
            ["cached-stale"],
            "the stale cache is still served immediately"
        )

        plugin.setApiKey("claude-key")
        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Self.modelsPage(
                        models: [("refreshed-model", "Refreshed", "2026-01-01T00:00:00Z")],
                        hasMore: false,
                        lastId: nil
                    ),
                    Self.httpResponse(url: Self.modelsURL, statusCode: 200)
                ),
            ])
        }

        let ok = await plugin.refreshModels()
        XCTAssertTrue(ok)
        XCTAssertEqual(plugin.supportedModels.map(\.id), ["refreshed-model"])
        XCTAssertTrue(plugin.isModelCacheFresh)
    }

    func testRefreshFailureKeepsExistingCache() async throws {
        let cacheData = try Self.encodeCache(
            models: [ClaudeFetchedModel(id: "cached-kept", displayName: "Cached Kept", createdAt: 1_000)],
            fetchedAt: Date()
        )
        let host = try PluginTestHostServices(defaults: [Self.cachedModelsKey: cacheData])
        let plugin = ClaudePlugin()
        plugin.activate(host: host)
        plugin.setApiKey("claude-key")

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"error":{"message":"boom"}}"#.utf8),
                    Self.httpResponse(url: Self.modelsURL, statusCode: 500)
                ),
            ])
        }

        let ok = await plugin.refreshModels()
        XCTAssertFalse(ok, "a failed fetch must not report success")
        XCTAssertEqual(
            plugin.supportedModels.map(\.id),
            ["cached-kept"],
            "the existing cache must keep being served after a failed fetch"
        )
    }

    // MARK: - Selection preservation

    func testSelectedModelIsPreservedWhenNotInList() throws {
        let host = try PluginTestHostServices(
            defaults: [Self.selectedLLMModelKey: "claude-haiku-4-5-20251001"]
        )
        let plugin = ClaudePlugin()
        plugin.activate(host: host)

        XCTAssertEqual(plugin.preferredModelId, "claude-haiku-4-5-20251001")
        XCTAssertTrue(
            plugin.supportedModels.contains { $0.id == "claude-haiku-4-5-20251001" },
            "a selected model that is not in the list must be appended so it stays selectable"
        )
        // Fallback entries still present.
        XCTAssertTrue(plugin.supportedModels.contains { $0.id == "claude-opus-4-8" })
    }

    func testSelectionPreservedAgainstFetchedListThatDropsIt() async throws {
        let host = try PluginTestHostServices(
            defaults: [Self.selectedLLMModelKey: "claude-legacy-pinned"]
        )
        let plugin = ClaudePlugin()
        plugin.activate(host: host)
        plugin.setApiKey("claude-key")

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Self.modelsPage(
                        models: [("claude-opus-4-8", "Claude Opus 4.8", "2026-01-01T00:00:00Z")],
                        hasMore: false,
                        lastId: nil
                    ),
                    Self.httpResponse(url: Self.modelsURL, statusCode: 200)
                ),
            ])
        }

        _ = await plugin.refreshModels()
        XCTAssertEqual(plugin.preferredModelId, "claude-legacy-pinned")
        XCTAssertTrue(
            plugin.supportedModels.contains { $0.id == "claude-legacy-pinned" },
            "the still-selected model must survive even when the fetched list omits it"
        )
    }

    // MARK: - Unify: validation seeds the cache

    func testValidateApiKeySeedsModelCache() async throws {
        let host = try PluginTestHostServices()
        let plugin = ClaudePlugin()
        plugin.activate(host: host) // no key → no background refresh

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Self.modelsPage(
                        models: [("validated-model", "Validated", "2026-03-01T00:00:00Z")],
                        hasMore: false,
                        lastId: nil
                    ),
                    Self.httpResponse(url: Self.modelsURL, statusCode: 200)
                ),
            ])
        }

        let valid = await plugin.validateApiKey("claude-key")
        XCTAssertTrue(valid)
        XCTAssertEqual(plugin.supportedModels.map(\.id), ["validated-model"])
        XCTAssertTrue(plugin.isModelCacheFresh)
    }

    func testValidateApiKeyFailureReturnsFalse() async throws {
        let host = try PluginTestHostServices()
        let plugin = ClaudePlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(Data("{}".utf8), Self.httpResponse(url: Self.modelsURL, statusCode: 401)),
            ])
        }

        let valid = await plugin.validateApiKey("bad-key")
        XCTAssertFalse(valid)
    }

    // MARK: - Sampling parameter correctness

    func testModelRejectsSamplingParamsByFamily() {
        for id in [
            "claude-opus-4-8",
            "claude-opus-4-7",
            "claude-sonnet-5",
            "claude-fable-5",
            "claude-mythos-5",
        ] {
            XCTAssertTrue(
                ClaudePlugin.modelRejectsSamplingParams(id),
                "\(id) rejects sampling params and must have temperature omitted"
            )
        }

        for id in [
            "claude-sonnet-4-6",
            "claude-opus-4-6",
            "claude-haiku-4-5",
            "claude-haiku-4-5-20251001",
            "claude-3-5-sonnet-20241022",
        ] {
            XCTAssertFalse(
                ClaudePlugin.modelRejectsSamplingParams(id),
                "\(id) honors sampling params and must keep the temperature override"
            )
        }
    }

    func testMessagesRequestOmitsTemperatureForNewerModelAndKeepsForOlder() async throws {
        let host = try PluginTestHostServices(
            defaults: [
                "llmTemperatureMode": PluginLLMTemperatureMode.custom.rawValue,
                "llmTemperatureValue": 0.7,
            ]
        )
        let plugin = ClaudePlugin()
        plugin.activate(host: host) // no key on host → no background model refresh
        plugin.setApiKey("claude-key")

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(Self.messagesResponse(text: "ok"), Self.httpResponse(url: Self.messagesURL, statusCode: 200)),
                .success(Self.messagesResponse(text: "ok"), Self.httpResponse(url: Self.messagesURL, statusCode: 200)),
            ])
        }

        _ = try await plugin.process(systemPrompt: "sys", userText: "hi", model: "claude-opus-4-8")
        _ = try await plugin.process(systemPrompt: "sys", userText: "hi", model: "claude-sonnet-4-6")

        let requests = store.sessions[0].requestedRequests
        XCTAssertEqual(requests.count, 2)

        let opusBody = try Self.jsonBody(from: requests[0])
        XCTAssertNil(opusBody["temperature"], "temperature must be omitted for claude-opus-4-8")

        let sonnetBody = try Self.jsonBody(from: requests[1])
        XCTAssertEqual(sonnetBody["temperature"] as? Double, 0.7, "temperature must be sent for claude-sonnet-4-6")
    }

    // MARK: - Helpers

    private static func modelsPage(
        models: [(id: String, displayName: String, createdAt: String)],
        hasMore: Bool,
        lastId: String?
    ) -> Data {
        var body: [String: Any] = [
            "data": models.map { model in
                [
                    "id": model.id,
                    "display_name": model.displayName,
                    "created_at": model.createdAt,
                    "type": "model",
                ]
            },
            "has_more": hasMore,
        ]
        if let lastId {
            body["last_id"] = lastId
        }
        return try! JSONSerialization.data(withJSONObject: body)
    }

    private static func messagesResponse(text: String) -> Data {
        let body: [String: Any] = [
            "content": [["type": "text", "text": text]],
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    private static func encodeCache(models: [ClaudeFetchedModel], fetchedAt: Date) throws -> Data {
        try JSONEncoder().encode(ClaudeModelCache(models: models, fetchedAt: fetchedAt))
    }

    private static func jsonBody(from request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func httpResponse(url: String, statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: url)!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }
}
