import Foundation
import SwiftUI
import TypeWhisperPluginSDK

// MARK: - Plugin Entry Point

@objc(ClaudePlugin)
final class ClaudePlugin: NSObject, LLMProviderPlugin, LLMModelSelectable, @unchecked Sendable {
    static let pluginId = "com.typewhisper.claude"
    static let pluginName = "Claude"

    private static let modelsEndpoint = "https://api.anthropic.com/v1/models"
    private static let messagesEndpoint = "https://api.anthropic.com/v1/messages"
    private static let anthropicVersion = "2023-06-01"
    private static let selectedLLMModelKey = "selectedLLMModel"
    private static let cachedModelsKey = "fetchedLLMModels.v1"
    /// Serve a cached model list without re-fetching for 24 hours.
    private static let cacheTTL: TimeInterval = 24 * 60 * 60
    /// Safety bound on pagination so a misbehaving `has_more` never loops forever.
    private static let maxModelPages = 20

    fileprivate var host: HostServices?
    fileprivate var _apiKey: String?
    fileprivate var _selectedLLMModelId: String?
    fileprivate var _llmTemperatureModeRaw: String = PluginLLMTemperatureMode.providerDefault.rawValue
    fileprivate var _llmTemperatureValue: Double = 0.3
    fileprivate var _modelCache: ClaudeModelCache?

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        _apiKey = host.loadSecret(key: "api-key")
        _selectedLLMModelId = host.userDefault(forKey: Self.selectedLLMModelKey) as? String
        if let data = host.userDefault(forKey: Self.cachedModelsKey) as? Data,
           let cache = try? JSONDecoder().decode(ClaudeModelCache.self, from: data) {
            _modelCache = cache
        }
        _llmTemperatureModeRaw = host.userDefault(forKey: "llmTemperatureMode") as? String
            ?? PluginLLMTemperatureMode.providerDefault.rawValue
        _llmTemperatureValue = host.userDefault(forKey: "llmTemperatureValue") as? Double
            ?? 0.3
        // Refresh the model list on activation when the cache is missing or stale.
        refreshModelsIfNeeded()
    }

    func deactivate() {
        host = nil
    }

    // MARK: - LLMProviderPlugin

    var providerName: String { "Claude" }

    var isAvailable: Bool {
        guard let key = _apiKey else { return false }
        return !key.isEmpty
    }

    /// Shown when no cache exists yet (no key configured, or offline). Uses the
    /// current alias ids with no date suffixes — the API returns the same aliases.
    fileprivate static let fallbackLLMModels: [PluginModelInfo] = [
        PluginModelInfo(id: "claude-opus-4-8", displayName: "Claude Opus 4.8"),
        PluginModelInfo(id: "claude-sonnet-5", displayName: "Claude Sonnet 5"),
        PluginModelInfo(id: "claude-opus-4-7", displayName: "Claude Opus 4.7"),
        PluginModelInfo(id: "claude-sonnet-4-6", displayName: "Claude Sonnet 4.6"),
        PluginModelInfo(id: "claude-haiku-4-5", displayName: "Claude Haiku 4.5"),
    ]

    /// The fetched list (newest-first) when a non-empty cache exists, otherwise
    /// the hardcoded fallback.
    private var baseModels: [PluginModelInfo] {
        if let cache = _modelCache, !cache.models.isEmpty {
            return cache.models.map { PluginModelInfo(id: $0.id, displayName: $0.displayName) }
        }
        return Self.fallbackLLMModels
    }

    var supportedModels: [PluginModelInfo] {
        var models = baseModels
        // Selection preservation: if the user's selected model isn't in the
        // current list (e.g. a previously-selected dated id, or a model the
        // account no longer exposes), keep it selectable by appending it rather
        // than silently switching the user to a different model.
        if let selected = _selectedLLMModelId,
           !selected.isEmpty,
           !models.contains(where: { $0.id == selected }) {
            models.append(PluginModelInfo(id: selected, displayName: selected))
        }
        return models
    }

    func process(systemPrompt: String, userText: String, model: String?) async throws -> String {
        try await process(
            systemPrompt: systemPrompt,
            userText: userText,
            model: model,
            temperatureDirective: .inheritProviderSetting
        )
    }

    func process(
        systemPrompt: String,
        userText: String,
        model: String?,
        temperatureDirective: PluginLLMTemperatureDirective
    ) async throws -> String {
        guard let apiKey = _apiKey, !apiKey.isEmpty else {
            throw PluginChatError.notConfigured
        }
        let modelId = model ?? _selectedLLMModelId ?? supportedModels.first!.id
        let resolvedTemperature = providerTemperatureDirective.resolvedTemperature(applying: temperatureDirective)
        return try await callMessagesAPI(
            apiKey: apiKey,
            model: modelId,
            systemPrompt: systemPrompt,
            userText: userText,
            temperature: resolvedTemperature
        )
    }

    func selectLLMModel(_ modelId: String) {
        _selectedLLMModelId = modelId
        host?.setUserDefault(modelId, forKey: Self.selectedLLMModelKey)
    }

    var selectedLLMModelId: String? { _selectedLLMModelId }
    @objc var preferredModelId: String? { _selectedLLMModelId }
    var llmTemperatureMode: PluginLLMTemperatureMode {
        PluginLLMTemperatureMode(rawValue: _llmTemperatureModeRaw) ?? .providerDefault
    }
    var llmTemperatureValue: Double { _llmTemperatureValue }
    fileprivate var providerTemperatureDirective: PluginLLMTemperatureDirective {
        PluginLLMTemperatureDirective(mode: llmTemperatureMode, value: _llmTemperatureValue)
    }

    func setLLMTemperatureMode(_ mode: PluginLLMTemperatureMode) {
        _llmTemperatureModeRaw = mode.rawValue
        host?.setUserDefault(mode.rawValue, forKey: "llmTemperatureMode")
    }

    func setLLMTemperatureValue(_ value: Double) {
        let clamped = min(max(value, 0.0), 2.0)
        _llmTemperatureValue = clamped
        host?.setUserDefault(clamped, forKey: "llmTemperatureValue")
    }

    // MARK: - Settings View

    var settingsView: AnyView? {
        AnyView(ClaudeSettingsView(plugin: self))
    }

    // MARK: - API Key Management

    func setApiKey(_ key: String) {
        _apiKey = key
        if let host {
            do {
                try host.storeSecret(key: "api-key", value: key)
            } catch {
                print("[ClaudePlugin] Failed to store API key: \(error)")
            }
            host.notifyCapabilitiesChanged()
        }
    }

    func removeApiKey() {
        _apiKey = nil
        if let host {
            do {
                try host.storeSecret(key: "api-key", value: "")
            } catch {
                print("[ClaudePlugin] Failed to delete API key: \(error)")
            }
            host.notifyCapabilitiesChanged()
        }
    }

    /// Validates the key by hitting the models endpoint. A successful validation
    /// also seeds/refreshes the model cache from the same response instead of
    /// discarding it.
    func validateApiKey(_ key: String) async -> Bool {
        guard !key.isEmpty else { return false }
        guard let models = await fetchModels(apiKey: key) else { return false }
        if !models.isEmpty {
            await MainActor.run { self.setModelCache(models) }
        }
        return true
    }

    // MARK: - Dynamic Model Discovery

    /// True when a cached list exists and is younger than the TTL.
    var isModelCacheFresh: Bool {
        guard let cache = _modelCache else { return false }
        return Date().timeIntervalSince(cache.fetchedAt) < Self.cacheTTL
    }

    var cacheLastUpdated: Date? { _modelCache?.fetchedAt }

    fileprivate func setModelCache(_ models: [ClaudeFetchedModel]) {
        let cache = ClaudeModelCache(models: models, fetchedAt: Date())
        _modelCache = cache
        if let data = try? JSONEncoder().encode(cache) {
            host?.setUserDefault(data, forKey: Self.cachedModelsKey)
        }
        host?.notifyCapabilitiesChanged()
    }

    /// Fetches the full model list (following pagination), returning nil on any
    /// network/HTTP failure so callers can keep serving the existing cache.
    func fetchModels(apiKey: String) async -> [ClaudeFetchedModel]? {
        guard !apiKey.isEmpty else { return nil }

        var collected: [ClaudeFetchedModel] = []
        var afterId: String?

        for _ in 0..<Self.maxModelPages {
            guard var components = URLComponents(string: Self.modelsEndpoint) else { return nil }
            if let afterId {
                components.queryItems = [URLQueryItem(name: "after_id", value: afterId)]
            }
            guard let url = components.url else { return nil }

            var request = URLRequest(url: url)
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
            request.timeoutInterval = 15

            do {
                let (data, response) = try await PluginHTTPClient.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else { return nil }
                let page = try Self.decodeModelsPage(from: data)
                collected.append(contentsOf: page.models)
                if page.hasMore, let last = page.lastId, !last.isEmpty {
                    afterId = last
                } else {
                    break
                }
            } catch {
                return nil
            }
        }

        return Self.sortedNewestFirst(collected)
    }

    /// Explicit refresh used by the settings UI and the "Refresh models" button.
    /// Returns whether a fresh list was fetched and cached.
    @discardableResult
    func refreshModels() async -> Bool {
        guard let apiKey = _apiKey, !apiKey.isEmpty else { return false }
        guard let models = await fetchModels(apiKey: apiKey), !models.isEmpty else { return false }
        await MainActor.run { self.setModelCache(models) }
        return true
    }

    /// Background refresh: serve the cache immediately, refresh only when missing
    /// or stale, and keep the cache on failure.
    private func refreshModelsIfNeeded() {
        guard let apiKey = _apiKey, !apiKey.isEmpty, !isModelCacheFresh else { return }
        Task { [weak self] in
            guard let self else { return }
            guard let models = await self.fetchModels(apiKey: apiKey), !models.isEmpty else { return }
            await MainActor.run { self.setModelCache(models) }
        }
    }

    nonisolated static func decodeModelsPage(
        from data: Data
    ) throws -> (models: [ClaudeFetchedModel], hasMore: Bool, lastId: String?) {
        let decoded = try JSONDecoder().decode(ClaudeModelsResponse.self, from: data)
        let models = decoded.data.map {
            ClaudeFetchedModel(
                id: $0.id,
                displayName: $0.displayName ?? $0.id,
                createdAt: parseTimestamp($0.createdAt)
            )
        }
        return (models, decoded.hasMore ?? false, decoded.lastId)
    }

    /// Sort newest-first by `created_at`; ties fall back to id for determinism.
    nonisolated static func sortedNewestFirst(_ models: [ClaudeFetchedModel]) -> [ClaudeFetchedModel] {
        models.sorted { lhs, rhs in
            lhs.createdAt != rhs.createdAt ? lhs.createdAt > rhs.createdAt : lhs.id < rhs.id
        }
    }

    nonisolated private static func parseTimestamp(_ raw: String?) -> Double {
        guard let raw, !raw.isEmpty else { return 0 }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) {
            return date.timeIntervalSince1970
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)?.timeIntervalSince1970 ?? 0
    }

    /// Newer Claude models (Opus 4.8, Opus 4.7, Sonnet 5, Fable/Mythos 5, and any
    /// id in those 4.7+/5 families) reject `temperature`/`top_p`/`top_k` with HTTP
    /// 400, so those parameters must be omitted for them. Sonnet 4.6, Opus 4.6,
    /// Haiku 4.5, and older still honor the app's temperature override, so we keep
    /// sending it there. Conservative id-prefix check against the known families.
    nonisolated static func modelRejectsSamplingParams(_ modelId: String) -> Bool {
        let id = modelId.lowercased()
        let rejectingPrefixes = [
            "claude-opus-4-8",
            "claude-opus-4-7",
            "claude-sonnet-5",
            "claude-fable-5",
            "claude-mythos-5",
            "claude-mythos-preview",
        ]
        return rejectingPrefixes.contains { id.hasPrefix($0) }
    }

    // MARK: - Anthropic Messages API

    private func callMessagesAPI(
        apiKey: String,
        model: String,
        systemPrompt: String,
        userText: String,
        temperature: Double?
    ) async throws -> String {
        guard let url = URL(string: Self.messagesEndpoint) else {
            throw PluginChatError.apiError("Invalid URL")
        }

        var requestBody: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": userText]
            ]
        ]
        // Only send the temperature override to models that accept it; newer
        // families 400 on any sampling parameter.
        if let temperature, !Self.modelRejectsSamplingParams(model) {
            requestBody["temperature"] = temperature
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await PluginHTTPClient.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PluginChatError.networkError("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 401:
            throw PluginChatError.invalidApiKey
        case 429:
            throw PluginChatError.rateLimited
        default:
            var displayMessage = "HTTP \(httpResponse.statusCode)"
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                displayMessage = message
            }
            throw PluginChatError.apiError(displayMessage)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let first = content.first,
              let text = first["text"] as? String else {
            throw PluginChatError.apiError("Failed to parse response")
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Models API Decoding

private struct ClaudeModelsResponse: Decodable {
    let data: [ClaudeAPIModel]
    let hasMore: Bool?
    let lastId: String?

    enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case lastId = "last_id"
    }
}

private struct ClaudeAPIModel: Decodable {
    let id: String
    let displayName: String?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case createdAt = "created_at"
    }
}

// MARK: - Cached Model Types

struct ClaudeFetchedModel: Codable, Sendable, Equatable {
    let id: String
    let displayName: String
    /// Epoch seconds parsed from the API `created_at`; used for newest-first sort.
    let createdAt: Double
}

struct ClaudeModelCache: Codable, Sendable {
    let models: [ClaudeFetchedModel]
    let fetchedAt: Date
}

// MARK: - Settings View

private struct ClaudeSettingsView: View {
    let plugin: ClaudePlugin
    @State private var apiKeyInput = ""
    @State private var isValidating = false
    @State private var validationResult: Bool?
    @State private var showApiKey = false
    @State private var selectedModel: String = ""
    @State private var llmTemperatureMode: PluginLLMTemperatureMode = .providerDefault
    @State private var llmTemperatureValue: Double = 0.3
    @State private var isRefreshing = false
    @State private var lastUpdated: Date?
    private let bundle = Bundle(for: ClaudePlugin.self)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // API Key Section
            VStack(alignment: .leading, spacing: 8) {
                Text("API Key", bundle: bundle)
                    .font(.headline)

                HStack(spacing: 8) {
                    if showApiKey {
                        TextField("API Key", text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    } else {
                        SecureField("API Key", text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                    }

                    Button {
                        showApiKey.toggle()
                    } label: {
                        Image(systemName: showApiKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)

                    if plugin.isAvailable {
                        Button(String(localized: "Remove", bundle: bundle)) {
                            apiKeyInput = ""
                            validationResult = nil
                            plugin.removeApiKey()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .foregroundStyle(.red)
                    } else {
                        Button(String(localized: "Save", bundle: bundle)) {
                            saveApiKey()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                if isValidating {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text("Validating...", bundle: bundle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let result = validationResult {
                    HStack(spacing: 4) {
                        Image(systemName: result ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(result ? .green : .red)
                        Text(result ? String(localized: "Valid API Key", bundle: bundle) : String(localized: "Invalid API Key", bundle: bundle))
                            .font(.caption)
                            .foregroundStyle(result ? .green : .red)
                    }
                }
            }

            if plugin.isAvailable {
                Divider()

                // LLM Model Selection
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("LLM Model", bundle: bundle)
                            .font(.headline)

                        Spacer()

                        if isRefreshing {
                            ProgressView().controlSize(.small)
                        }

                        Button {
                            refresh()
                        } label: {
                            Label(String(localized: "Refresh models", bundle: bundle), systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isRefreshing)
                    }

                    Picker("Model", selection: $selectedModel) {
                        ForEach(plugin.supportedModels, id: \.id) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: selectedModel) {
                        plugin.selectLLMModel(selectedModel)
                    }

                    if let lastUpdated {
                        Text("Last updated \(lastUpdated.formatted(date: .abbreviated, time: .shortened))", bundle: bundle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Using default models. Refresh to fetch the full list.", bundle: bundle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Temperature", bundle: bundle)
                        .font(.headline)

                    Picker("Temperature Mode", selection: $llmTemperatureMode) {
                        Text("Provider Default", bundle: bundle).tag(PluginLLMTemperatureMode.providerDefault)
                        Text("Custom", bundle: bundle).tag(PluginLLMTemperatureMode.custom)
                    }
                    .onChange(of: llmTemperatureMode) {
                        plugin.setLLMTemperatureMode(llmTemperatureMode)
                    }

                    if llmTemperatureMode == .custom {
                        HStack {
                            Text("Temperature", bundle: bundle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(llmTemperatureValue, format: .number.precision(.fractionLength(2)))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }

                        Slider(value: $llmTemperatureValue, in: 0...2, step: 0.1)
                            .onChange(of: llmTemperatureValue) {
                                plugin.setLLMTemperatureValue(llmTemperatureValue)
                            }
                    }
                }
            }

            Text("API keys are stored securely in the Keychain", bundle: bundle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .onAppear {
            if let key = plugin._apiKey, !key.isEmpty {
                apiKeyInput = key
            }
            selectedModel = plugin.selectedLLMModelId ?? plugin.supportedModels.first?.id ?? ""
            llmTemperatureMode = plugin.llmTemperatureMode
            llmTemperatureValue = plugin.llmTemperatureValue
            lastUpdated = plugin.cacheLastUpdated
            // Serve the cache immediately; refresh in the background if stale.
            if plugin.isAvailable, !plugin.isModelCacheFresh {
                refresh()
            }
        }
    }

    private func saveApiKey() {
        let trimmedKey = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }

        plugin.setApiKey(trimmedKey)

        isValidating = true
        validationResult = nil
        Task {
            let isValid = await plugin.validateApiKey(trimmedKey)
            await MainActor.run {
                isValidating = false
                validationResult = isValid
                if isValid {
                    lastUpdated = plugin.cacheLastUpdated
                    selectedModel = plugin.selectedLLMModelId ?? plugin.supportedModels.first?.id ?? ""
                }
            }
        }
    }

    private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            let ok = await plugin.refreshModels()
            await MainActor.run {
                isRefreshing = false
                if ok {
                    lastUpdated = plugin.cacheLastUpdated
                    // Keep the current selection working even if the fetched list
                    // dropped it; supportedModels appends it back.
                    selectedModel = plugin.selectedLLMModelId
                        ?? plugin.supportedModels.first?.id
                        ?? selectedModel
                }
            }
        }
    }
}
