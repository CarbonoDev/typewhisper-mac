import Foundation
import os

private let apiLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "typewhisper-mac", category: "APIHandlers")

final class APIHandlers: @unchecked Sendable {
    private let modelManager: ModelManagerService
    private let audioFileService: AudioFileService
    private let translationService: AnyObject? // TranslationService (macOS 15+)
    private let historyService: HistoryService
    private let workflowService: WorkflowService
    private let dictionaryService: DictionaryService
    private let dictationViewModel: DictationViewModel
    private let audioRecorderViewModel: AudioRecorderViewModel
    private let meetingService: MeetingService
    private let meetingImportService: MeetingImportService
    /// Used for the optional `match_calendar` auto-link on import. Optional so tests (and any
    /// host without a calendar) can omit it; when nil, `match_calendar` reports `matched_event: null`.
    private let calendarService: CalendarService?

    init(
        modelManager: ModelManagerService,
        audioFileService: AudioFileService,
        translationService: AnyObject?,
        historyService: HistoryService,
        workflowService: WorkflowService,
        dictionaryService: DictionaryService,
        dictationViewModel: DictationViewModel,
        audioRecorderViewModel: AudioRecorderViewModel,
        meetingService: MeetingService,
        meetingImportService: MeetingImportService,
        calendarService: CalendarService?
    ) {
        self.modelManager = modelManager
        self.audioFileService = audioFileService
        self.translationService = translationService
        self.historyService = historyService
        self.workflowService = workflowService
        self.dictionaryService = dictionaryService
        self.dictationViewModel = dictationViewModel
        self.audioRecorderViewModel = audioRecorderViewModel
        self.meetingService = meetingService
        self.meetingImportService = meetingImportService
        self.calendarService = calendarService
    }

    func register(on router: APIRouter) {
        router.register("POST", "/v1/transcribe", handler: handleTranscribe)
        router.register("POST", "/v1/transcribe/local-file", handler: handleTranscribeLocalFile)
        router.register("GET", "/v1/status", handler: handleStatus)
        router.register("GET", "/v1/models", handler: handleModels)
        router.register("GET", "/v1/history", handler: handleGetHistory)
        router.register("DELETE", "/v1/history", handler: handleDeleteHistory)
        router.register("GET", "/v1/rules", handler: handleGetRules)
        router.register("PUT", "/v1/rules/toggle", handler: handleToggleRule)
        router.register("GET", "/v1/profiles", handler: handleGetRules)
        router.register("PUT", "/v1/profiles/toggle", handler: handleToggleRule)
        router.register("POST", "/v1/dictation/start", handler: handleStartDictation)
        router.register("POST", "/v1/dictation/stop", handler: handleStopDictation)
        router.register("GET", "/v1/dictation/status", handler: handleDictationStatus)
        router.register("GET", "/v1/dictation/transcription", handler: handleDictationTranscription)
        router.register("POST", "/v1/recorder/start", handler: handleStartRecorder)
        router.register("POST", "/v1/recorder/stop", handler: handleStopRecorder)
        router.register("GET", "/v1/recorder/status", handler: handleRecorderStatus)
        router.register("GET", "/v1/recorder/session", handler: handleRecorderSession)
        router.register("GET", "/v1/dictionary/terms", handler: handleGetDictionaryTerms)
        router.register("PUT", "/v1/dictionary/terms", handler: handlePutDictionaryTerms)
        router.register("DELETE", "/v1/dictionary/terms", handler: handleDeleteDictionaryTerms)
        router.register("GET", "/v1/dictionary/corrections", handler: handleGetDictionaryCorrections)
        router.register("PUT", "/v1/dictionary/corrections", handler: handlePutDictionaryCorrections)
        router.register("DELETE", "/v1/dictionary/corrections", handler: handleDeleteDictionaryCorrections)
        router.register("POST", "/v1/meetings/import-transcript", handler: handleImportMeetingTranscript)
        router.register("POST", "/v1/meetings/live", handler: handleStartLiveMeeting)
        router.register("POST", "/v1/meetings/live/{id}/segments", handler: handleAppendLiveSegments)
        router.register("POST", "/v1/meetings/live/{id}/end", handler: handleEndLiveMeeting)
        router.register("GET", "/v1/meetings", handler: handleListMeetings)
        router.register("GET", "/v1/meetings/{id}", handler: handleGetMeeting)
    }

    // MARK: - POST /v1/transcribe

    private struct TranscribeOptions {
        var language: String? = nil
        var languageHints: [String] = []
        var task: TranscriptionTask = .transcribe
        var targetLanguage: String? = nil
        var responseFormat = "json"
        var requestPrompt: String? = nil
        var engineOverride: String? = nil
        var modelOverride: String? = nil
        var awaitDownload = false
        var normalizeNumbers: Bool? = nil
        var applyCorrections = true
    }

    private struct LocalFileTranscribeRequest: Decodable {
        let path: String
        let language: String?
        let languageHints: [String]?
        let task: String?
        let targetLanguage: String?
        let responseFormat: String?
        let prompt: String?
        let engine: String?
        let model: String?
        let normalizeNumbers: Bool?
        let applyCorrections: Bool?

        enum CodingKeys: String, CodingKey {
            case path
            case language
            case languageHints = "language_hints"
            case task
            case targetLanguage = "target_language"
            case responseFormat = "response_format"
            case prompt
            case engine
            case model
            case normalizeNumbers = "normalize_numbers"
            case applyCorrections = "apply_corrections"
        }
    }

    private func handleTranscribe(_ request: HTTPRequest) async -> HTTPResponse {
        let audioData: Data
        var fileExtension = "wav"
        var options = TranscribeOptions(awaitDownload: request.queryParams["await_download"] == "1")

        let contentType = request.headers["content-type"] ?? ""

        if contentType.contains("multipart/form-data"),
           let boundary = extractBoundary(from: contentType) {
            let parts = HTTPRequestParser.parseMultipart(body: request.body, boundary: boundary)

            guard let filePart = parts.first(where: { $0.name == "file" }) else {
                return .error(status: 400, message: "Missing 'file' part in multipart form data")
            }

            audioData = filePart.data

            if let fn = filePart.filename, let ext = fn.split(separator: ".").last {
                fileExtension = String(ext).lowercased()
            } else if let ct = filePart.contentType {
                fileExtension = extensionFromMIME(ct)
            }

            if let langPart = parts.first(where: { $0.name == "language" }),
               let val = String(data: langPart.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !val.isEmpty {
                options.language = val
            }

            options.languageHints = parts
                .filter { $0.name == "language_hint" }
                .compactMap { String(data: $0.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            if let taskPart = parts.first(where: { $0.name == "task" }),
               let val = String(data: taskPart.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               let parsed = TranscriptionTask(rawValue: val) {
                options.task = parsed
            }

            if let targetPart = parts.first(where: { $0.name == "target_language" }),
               let val = String(data: targetPart.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !val.isEmpty {
                options.targetLanguage = val
            }

            if let formatPart = parts.first(where: { $0.name == "response_format" }),
               let val = String(data: formatPart.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !val.isEmpty {
                options.responseFormat = val
            }

            if let promptPart = parts.first(where: { $0.name == "prompt" }),
               let val = String(data: promptPart.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !val.isEmpty {
                options.requestPrompt = val
            }

            if let enginePart = parts.first(where: { $0.name == "engine" }),
               let val = String(data: enginePart.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !val.isEmpty {
                options.engineOverride = val
            }

            if let modelPart = parts.first(where: { $0.name == "model" }),
               let val = String(data: modelPart.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !val.isEmpty {
                options.modelOverride = val
            }

            if let normalizePart = parts.first(where: { $0.name == "normalize_numbers" }),
               let val = String(data: normalizePart.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !val.isEmpty {
                guard let parsed = Self.parseBoolean(val) else {
                    return .error(status: 400, message: "Invalid 'normalize_numbers' value")
                }
                options.normalizeNumbers = parsed
            }

            if let correctionsPart = parts.first(where: { $0.name == "apply_corrections" }),
               let val = String(data: correctionsPart.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !val.isEmpty {
                guard let parsed = Self.parseBoolean(val) else {
                    return .error(status: 400, message: "Invalid 'apply_corrections' value")
                }
                options.applyCorrections = parsed
            }
        } else if !request.body.isEmpty {
            audioData = request.body
            fileExtension = extensionFromMIME(contentType)
            options.language = request.headers["x-language"]
            options.languageHints = request.headers["x-language-hints"]?
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty } ?? []
            if let taskStr = request.headers["x-task"], let parsed = TranscriptionTask(rawValue: taskStr) {
                options.task = parsed
            }
            options.targetLanguage = request.headers["x-target-language"]
            if let format = request.headers["x-response-format"], !format.isEmpty {
                options.responseFormat = format
            }
            if let prompt = request.headers["x-prompt"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !prompt.isEmpty {
                options.requestPrompt = prompt
            }
            if let engine = request.headers["x-engine"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !engine.isEmpty {
                options.engineOverride = engine
            }
            if let model = request.headers["x-model"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !model.isEmpty {
                options.modelOverride = model
            }
            if let normalizeNumbers = request.headers["x-normalize-numbers"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !normalizeNumbers.isEmpty {
                guard let parsed = Self.parseBoolean(normalizeNumbers) else {
                    return .error(status: 400, message: "Invalid 'x-normalize-numbers' value")
                }
                options.normalizeNumbers = parsed
            }
            if let applyCorrections = request.headers["x-apply-corrections"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !applyCorrections.isEmpty {
                guard let parsed = Self.parseBoolean(applyCorrections) else {
                    return .error(status: 400, message: "Invalid 'x-apply-corrections' value")
                }
                options.applyCorrections = parsed
            }
        } else {
            return .error(status: 400, message: "No audio data provided")
        }

        guard !audioData.isEmpty else {
            return .error(status: 400, message: "Empty audio data")
        }

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".\(fileExtension)")

        do {
            try audioData.write(to: tempURL)
            defer { try? FileManager.default.removeItem(at: tempURL) }
            let samples = try await audioFileService.loadAudioSamples(from: tempURL)
            return await transcribeLoadedSamples(samples, options: options)
        } catch {
            return .error(status: 500, message: "Transcription failed: \(error.localizedDescription)")
        }
    }

    private func handleTranscribeLocalFile(_ request: HTTPRequest) async -> HTTPResponse {
        guard !request.body.isEmpty else {
            return .error(status: 400, message: "Missing JSON body")
        }

        let payload: LocalFileTranscribeRequest
        do {
            payload = try JSONDecoder().decode(LocalFileTranscribeRequest.self, from: request.body)
        } catch {
            if Self.hasInvalidJSONBooleanField("apply_corrections", in: request.body) {
                return .error(status: 400, message: "Invalid 'apply_corrections' value")
            }
            return .error(status: 400, message: "Invalid JSON body")
        }

        let fileURL = URL(fileURLWithPath: payload.path)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .error(status: 400, message: "File not found")
        }

        guard AudioFileService.supportedExtensions.contains(fileURL.pathExtension.lowercased()) else {
            return .error(status: 400, message: "Unsupported audio format")
        }

        var options = TranscribeOptions(awaitDownload: request.queryParams["await_download"] == "1")
        options.language = payload.language?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        options.languageHints = payload.languageHints?.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } ?? []
        if let task = payload.task.flatMap(TranscriptionTask.init(rawValue:)) {
            options.task = task
        }
        options.targetLanguage = payload.targetLanguage?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if let responseFormat = payload.responseFormat?.trimmingCharacters(in: .whitespacesAndNewlines), !responseFormat.isEmpty {
            options.responseFormat = responseFormat
        }
        options.requestPrompt = payload.prompt?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        options.engineOverride = payload.engine?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        options.modelOverride = payload.model?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        options.normalizeNumbers = payload.normalizeNumbers
        options.applyCorrections = payload.applyCorrections ?? true

        do {
            let samples = try await audioFileService.loadAudioSamples(from: fileURL)
            return await transcribeLoadedSamples(samples, options: options)
        } catch {
            return .error(status: 500, message: "Transcription failed: \(error.localizedDescription)")
        }
    }

    private func transcribeLoadedSamples(_ samples: [Float], options: TranscribeOptions) async -> HTTPResponse {
        if options.language != nil, !options.languageHints.isEmpty {
            return .error(status: 400, message: "Use either 'language' or 'language_hint', not both")
        }

        let resolvedOverride: ResolvedOverride
        switch await resolveEngineModelOverride(
            engine: options.engineOverride,
            model: options.modelOverride,
            awaitDownload: options.awaitDownload
        ) {
        case .use(let value):
            resolvedOverride = value
        case .reject(let response):
            return response
        }

        if resolvedOverride.engineId == nil {
            let hasEngine = await modelManager.selectedProviderId != nil
            guard hasEngine else {
                return .error(status: 503, message: "No engine selected. Select an engine in TypeWhisper first.")
            }
        }

        do {
            let effectiveProviderId: String?
            if let engineId = resolvedOverride.engineId {
                effectiveProviderId = engineId
            } else {
                effectiveProviderId = await modelManager.selectedProviderId
            }
            let dictionaryPrompt = await MainActor.run {
                dictionaryService.getTermsForPrompt(providerId: effectiveProviderId)
            }
            let dictionaryTermHints = await MainActor.run {
                dictionaryService.getTermHints(providerId: effectiveProviderId)
            }
            let prompt = mergedPrompt(requestPrompt: options.requestPrompt, dictionaryPrompt: dictionaryPrompt)
            let languageSelection: LanguageSelection
            if !options.languageHints.isEmpty {
                languageSelection = LanguageSelection.auto.withSelectedCodes(options.languageHints, nilBehavior: .auto)
            } else if let language = options.language {
                languageSelection = .exact(language)
            } else {
                languageSelection = .auto
            }
            let result = try await modelManager.transcribe(
                audioSamples: samples,
                languageSelection: languageSelection,
                task: options.task,
                engineOverrideId: resolvedOverride.engineId,
                cloudModelOverride: resolvedOverride.modelId,
                prompt: prompt,
                dictionaryTermHints: dictionaryTermHints,
                normalizeNumbers: options.normalizeNumbers
            )

            var finalText = result.text
            if let targetCode = options.targetLanguage {
                #if canImport(Translation)
                if #available(macOS 15, *), let ts = translationService as? TranslationService {
                    if let targetNormalized = TranslationService.normalizedLanguageIdentifier(from: targetCode) {
                        if targetCode.caseInsensitiveCompare(targetNormalized) != .orderedSame {
                            apiLogger.info("API translation target normalized \(targetCode, privacy: .public) -> \(targetNormalized, privacy: .public)")
                        }
                        let target = Locale.Language(identifier: targetNormalized)
                        let sourceRaw = result.detectedLanguage
                        let sourceNormalized = TranslationService.normalizedLanguageIdentifier(from: sourceRaw)
                        if let sourceRaw {
                            if let sourceNormalized {
                                if sourceRaw.caseInsensitiveCompare(sourceNormalized) != .orderedSame {
                                    apiLogger.info("API translation source normalized \(sourceRaw, privacy: .public) -> \(sourceNormalized, privacy: .public)")
                                }
                            } else {
                                apiLogger.warning("API translation source language \(sourceRaw, privacy: .public) invalid, using auto source")
                            }
                        }
                        let sourceLanguage = sourceNormalized.map { Locale.Language(identifier: $0) }
                        finalText = try await ts.translate(
                            text: finalText,
                            to: target,
                            source: sourceLanguage
                        )
                    } else {
                        apiLogger.error("API translation target language invalid: \(targetCode, privacy: .public)")
                    }
                } else {
                    return .error(status: 501, message: "Translation requires macOS 15 or later")
                }
                #else
                return .error(status: 501, message: "Translation requires macOS 15 or later")
                #endif
            }

            if options.applyCorrections {
                finalText = await MainActor.run {
                    dictionaryService.applyCorrections(to: finalText)
                }
            }

            let modelId = await resolveResponseModelId(
                override: resolvedOverride,
                engineUsed: result.engineUsed
            )

            if options.responseFormat == "verbose_json" {
                struct SegmentEntry: Encodable {
                    let start: Double
                    let end: Double
                    let text: String
                    let speaker: String?
                    let speakerConfidence: Double?

                    enum CodingKeys: String, CodingKey {
                        case start
                        case end
                        case text
                        case speaker
                        case speakerConfidence = "speaker_confidence"
                    }

                    func encode(to encoder: Encoder) throws {
                        var container = encoder.container(keyedBy: CodingKeys.self)
                        try container.encode(start, forKey: .start)
                        try container.encode(end, forKey: .end)
                        try container.encode(text, forKey: .text)
                        try container.encodeIfPresent(speaker, forKey: .speaker)
                        try container.encodeIfPresent(speakerConfidence, forKey: .speakerConfidence)
                    }
                }

                struct VerboseResponse: Encodable {
                    let text: String
                    let language: String?
                    let duration: Double
                    let processing_time: Double
                    let engine: String
                    let model: String?
                    let segments: [SegmentEntry]
                }

                let segments = result.segments.map {
                    SegmentEntry(
                        start: $0.start,
                        end: $0.end,
                        text: $0.text,
                        speaker: $0.speakerLabel,
                        speakerConfidence: $0.speakerConfidence
                    )
                }

                return .json(VerboseResponse(
                    text: finalText,
                    language: result.detectedLanguage,
                    duration: result.duration,
                    processing_time: result.processingTime,
                    engine: result.engineUsed,
                    model: modelId,
                    segments: segments
                ))
            } else {
                struct TranscribeResponse: Encodable {
                    let text: String
                    let language: String?
                    let duration: Double
                    let processing_time: Double
                    let engine: String
                    let model: String?
                }

                return .json(TranscribeResponse(
                    text: finalText,
                    language: result.detectedLanguage,
                    duration: result.duration,
                    processing_time: result.processingTime,
                    engine: result.engineUsed,
                    model: modelId
                ))
            }
        } catch {
            return .error(status: 500, message: "Transcription failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Engine/Model Override Resolution

    private struct ResolvedOverride {
        let engineId: String?
        let modelId: String?
    }

    private enum OverrideResolution {
        case use(ResolvedOverride)
        case reject(HTTPResponse)
    }

    /// Resolve per-request `engine` / `model` overrides against the full set of loaded
    /// transcription plugins. Implements the matrix from issue #317:
    ///
    /// - both nil -> use GUI selection
    /// - engine only -> use that engine's default model
    /// - model only -> infer engine by scanning the model catalog across all engines
    /// - both set   -> use as-is
    ///
    /// Also enforces configuration: an unconfigured engine returns 409 by default (to
    /// distinguish "typo" from "needs setup") unless the caller passed `?await_download=1`,
    /// in which case the usual `triggerRestoreModel` retry path is allowed to run.
    @MainActor
    private func resolveEngineModelOverride(
        engine: String?,
        model: String?,
        awaitDownload: Bool
    ) -> OverrideResolution {
        if engine == nil, model == nil {
            return .use(ResolvedOverride(engineId: nil, modelId: nil))
        }

        let engines = PluginManager.shared.transcriptionEngines

        let resolvedEngineId: String?
        if let engine {
            guard let match = engines.first(where: { $0.providerId == engine }) else {
                return .reject(.error(status: 400, message: "Unknown engine '\(engine)'"))
            }
            resolvedEngineId = match.providerId
        } else if let model {
            let matches = engines.filter { engine in
                engine.modelCatalog.contains(where: { $0.id == model })
            }
            if matches.isEmpty {
                return .reject(.error(status: 400, message: "Unknown model '\(model)'"))
            }
            if matches.count > 1 {
                let engineIds = matches.map { $0.providerId }.joined(separator: ", ")
                return .reject(.error(
                    status: 400,
                    message: "Ambiguous model id '\(model)' -- matches engines: \(engineIds). Specify 'engine' too."
                ))
            }
            resolvedEngineId = matches[0].providerId
        } else {
            resolvedEngineId = nil
        }

        if let engineId = resolvedEngineId,
           let model,
           let plugin = engines.first(where: { $0.providerId == engineId }) {
            let ids = Set(plugin.modelCatalog.map { $0.id })
            if !ids.isEmpty, !ids.contains(model) {
                return .reject(.error(
                    status: 400,
                    message: "Model '\(model)' is not offered by engine '\(engineId)'"
                ))
            }
        }

        if let engineId = resolvedEngineId,
           let plugin = engines.first(where: { $0.providerId == engineId }),
           !plugin.isConfigured,
           !awaitDownload {
            return .reject(.error(
                status: 409,
                message: "Engine '\(engineId)' is not configured (missing API key or downloaded weights). Pass ?await_download=1 to wait for restore."
            ))
        }

        return .use(ResolvedOverride(engineId: resolvedEngineId, modelId: model))
    }

    @MainActor
    private func resolveResponseModelId(override: ResolvedOverride, engineUsed: String) -> String? {
        if let modelId = override.modelId { return modelId }
        if let engineId = override.engineId,
           let plugin = PluginManager.shared.transcriptionEngine(for: engineId) {
            return plugin.selectedModelId
        }
        if let plugin = PluginManager.shared.transcriptionEngine(for: engineUsed) {
            return plugin.selectedModelId
        }
        return nil
    }

    private func mergedPrompt(requestPrompt: String?, dictionaryPrompt: String?) -> String? {
        let components = [requestPrompt, dictionaryPrompt]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !components.isEmpty else { return nil }
        return components.joined(separator: "\n")
    }

    private static func parseBoolean(_ value: String) -> Bool? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            true
        case "0", "false", "no", "off":
            false
        default:
            nil
        }
    }

    private static func hasInvalidJSONBooleanField(_ field: String, in body: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let value = object[field] else {
            return false
        }

        return !(value is Bool) && !(value is NSNull)
    }

    // MARK: - GET /v1/status

    private func handleStatus(_ request: HTTPRequest) async -> HTTPResponse {
        let providerId = await modelManager.selectedProviderId
        let modelId = await modelManager.selectedModelId
        let isReady = await modelManager.isModelReady
        let supportsStreaming = await modelManager.supportsStreaming
        let supportsTranslation = await modelManager.supportsTranslation

        struct StatusResponse: Encodable {
            let status: String
            let engine: String?
            let model: String?
            let supports_streaming: Bool
            let supports_translation: Bool
        }

        let response = StatusResponse(
            status: isReady ? "ready" : "no_model",
            engine: providerId,
            model: modelId,
            supports_streaming: supportsStreaming,
            supports_translation: supportsTranslation
        )
        return .json(response)
    }

    // MARK: - GET /v1/models

    @MainActor
    private func handleModels(_ request: HTTPRequest) async -> HTTPResponse {
        struct ModelEntry: Encodable {
            let id: String
            let engine: String
            let name: String
            let size_description: String
            let language_count: Int
            let status: String
            let selected: Bool
            let downloaded: Bool?
            let loaded: Bool?
        }

        let selectedProviderId = modelManager.selectedProviderId
        var models: [ModelEntry] = []

        for engine in PluginManager.shared.transcriptionEngines {
            let isSelected = engine.providerId == selectedProviderId
            for model in engine.modelCatalog {
                models.append(ModelEntry(
                    id: model.id,
                    engine: engine.providerId,
                    name: model.displayName,
                    size_description: model.sizeDescription,
                    language_count: model.languageCount,
                    status: engine.isConfigured ? "ready" : "not_configured",
                    selected: isSelected && engine.selectedModelId == model.id,
                    downloaded: model.downloaded,
                    loaded: model.loaded
                ))
            }
        }

        struct ModelsResponse: Encodable { let models: [ModelEntry] }
        return .json(ModelsResponse(models: models))
    }

    // MARK: - GET /v1/history

    private func handleGetHistory(_ request: HTTPRequest) async -> HTTPResponse {
        let query = request.queryParams["q"]
        let limit = min(Int(request.queryParams["limit"] ?? "") ?? 50, 200)
        let offset = max(Int(request.queryParams["offset"] ?? "") ?? 0, 0)

        let historyService = self.historyService
        return await MainActor.run {
            let allRecords: [TranscriptionRecord]
            if let query, !query.isEmpty {
                allRecords = historyService.searchRecords(query: query)
            } else {
                allRecords = historyService.records
            }

            let total = allRecords.count
            let sliceEnd = min(offset + limit, total)
            let sliceStart = min(offset, total)
            let page = Array(allRecords[sliceStart..<sliceEnd])

            struct HistoryEntry: Encodable {
                let id: String
                let text: String
                let raw_text: String
                let timestamp: Date
                let app_name: String?
                let app_bundle_id: String?
                let app_url: String?
                let duration: Double
                let language: String?
                let engine: String
                let model: String?
                let words_count: Int
            }

            struct HistoryResponse: Encodable {
                let entries: [HistoryEntry]
                let total: Int
                let limit: Int
                let offset: Int
            }

            let entries = page.map { record in
                HistoryEntry(
                    id: record.id.uuidString,
                    text: record.finalText,
                    raw_text: record.rawText,
                    timestamp: record.timestamp,
                    app_name: record.appName,
                    app_bundle_id: record.appBundleIdentifier,
                    app_url: record.appURL,
                    duration: record.durationSeconds,
                    language: record.language,
                    engine: record.engineUsed,
                    model: record.modelUsed,
                    words_count: record.wordsCount
                )
            }

            return .json(HistoryResponse(entries: entries, total: total, limit: limit, offset: offset))
        }
    }

    // MARK: - DELETE /v1/history

    private func handleDeleteHistory(_ request: HTTPRequest) async -> HTTPResponse {
        guard let idString = request.queryParams["id"],
              let uuid = UUID(uuidString: idString) else {
            return .error(status: 400, message: "Missing or invalid 'id' query parameter")
        }

        let historyService = self.historyService
        return await MainActor.run {
            guard let record = historyService.records.first(where: { $0.id == uuid }) else {
                return .error(status: 404, message: "History entry not found")
            }

            historyService.deleteRecord(record)
            return .json(["deleted": true])
        }
    }

    // MARK: - /v1/dictionary/terms

    private func handleGetDictionaryTerms(_ request: HTTPRequest) async -> HTTPResponse {
        struct DictionaryTermEntryResponse: Encodable {
            let term: String
            let ctc_min_similarity: Float?
        }

        struct DictionaryTermsResponse: Encodable {
            let terms: [String]
            let term_entries: [DictionaryTermEntryResponse]
            let count: Int
        }

        return await MainActor.run {
            let termHints = dictionaryService.enabledTermHints()
            let terms = termHints.map(\.text)
            let entries = termHints.map {
                DictionaryTermEntryResponse(term: $0.text, ctc_min_similarity: $0.ctcMinSimilarity)
            }
            return .json(DictionaryTermsResponse(terms: terms, term_entries: entries, count: terms.count))
        }
    }

    private func handlePutDictionaryTerms(_ request: HTTPRequest) async -> HTTPResponse {
        struct DictionaryTermEntryRequest: Decodable {
            let term: String
            let ctcMinSimilarity: Float?

            enum CodingKeys: String, CodingKey {
                case term
                case ctcMinSimilarity
                case ctc_min_similarity
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                term = try container.decode(String.self, forKey: .term)
                ctcMinSimilarity = try container.decodeIfPresent(Float.self, forKey: .ctc_min_similarity)
                    ?? container.decodeIfPresent(Float.self, forKey: .ctcMinSimilarity)
            }
        }

        struct DictionaryTermsRequest: Decodable {
            let terms: [String]?
            let termEntries: [DictionaryTermEntryRequest]?
            let replace: Bool?

            enum CodingKeys: String, CodingKey {
                case terms
                case termEntries = "term_entries"
                case replace
            }
        }

        struct DictionaryTermEntryResponse: Encodable {
            let term: String
            let ctc_min_similarity: Float?
        }

        guard !request.body.isEmpty else {
            return .error(status: 400, message: "Missing JSON body")
        }

        let payload: DictionaryTermsRequest
        do {
            payload = try JSONDecoder().decode(DictionaryTermsRequest.self, from: request.body)
        } catch {
            return .error(status: 400, message: "Invalid JSON body")
        }

        struct DictionaryTermsResponse: Encodable {
            let terms: [String]
            let term_entries: [DictionaryTermEntryResponse]
            let count: Int
        }

        guard payload.terms != nil || payload.termEntries != nil else {
            return .error(status: 400, message: "Missing 'terms' or 'term_entries'")
        }
        guard payload.terms == nil || payload.termEntries == nil else {
            return .error(status: 400, message: "Use either 'terms' or 'term_entries', not both")
        }

        do {
            return try await MainActor.run {
                if let termEntries = payload.termEntries {
                    try dictionaryService.setAPITermEntries(
                        termEntries.map { (term: $0.term, ctcMinSimilarity: $0.ctcMinSimilarity) },
                        replaceExisting: payload.replace ?? false
                    )
                } else if let terms = payload.terms {
                    try dictionaryService.setAPITerms(terms, replaceExisting: payload.replace ?? false)
                }

                let termHints = dictionaryService.enabledTermHints()
                let terms = termHints.map(\.text)
                let entries = termHints.map {
                    DictionaryTermEntryResponse(term: $0.text, ctc_min_similarity: $0.ctcMinSimilarity)
                }
                return .json(DictionaryTermsResponse(terms: terms, term_entries: entries, count: terms.count))
            }
        } catch {
            return .error(status: 500, message: "Failed to save dictionary: \(error.localizedDescription)")
        }
    }

    private func handleDeleteDictionaryTerms(_ request: HTTPRequest) async -> HTTPResponse {
        struct DeleteDictionaryTermRequest: Decodable {
            let term: String
        }

        struct DeleteResponse: Encodable {
            let deleted: Bool
            let count: Int
        }

        guard !request.body.isEmpty else {
            return .error(status: 400, message: "Missing JSON body")
        }

        let payload: DeleteDictionaryTermRequest
        do {
            payload = try JSONDecoder().decode(DeleteDictionaryTermRequest.self, from: request.body)
        } catch {
            return .error(status: 400, message: "Invalid JSON body")
        }

        let term = payload.term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else {
            return .error(status: 400, message: "Missing or empty 'term'")
        }

        do {
            return try await MainActor.run {
                let deleted = try dictionaryService.deleteAPITerm(term)
                let terms = dictionaryService.enabledTerms()
                return .json(DeleteResponse(deleted: deleted, count: terms.count))
            }
        } catch {
            return .error(status: 500, message: "Failed to save dictionary: \(error.localizedDescription)")
        }
    }

    // MARK: - /v1/dictionary/corrections

    private struct DictionaryCorrectionEntry: Encodable {
        let original: String
        let replacement: String
        let caseSensitive: Bool
    }

    private struct DictionaryCorrectionsResponse: Encodable {
        let corrections: [DictionaryCorrectionEntry]
        let count: Int
    }

    private func handleGetDictionaryCorrections(_ request: HTTPRequest) async -> HTTPResponse {
        await MainActor.run {
            dictionaryCorrectionsResponse()
        }
    }

    private func handlePutDictionaryCorrections(_ request: HTTPRequest) async -> HTTPResponse {
        struct DictionaryCorrectionRequest: Decodable {
            let original: String
            let replacement: String
            let caseSensitive: Bool?
        }

        guard !request.body.isEmpty else {
            return .error(status: 400, message: "Missing JSON body")
        }

        let payload: DictionaryCorrectionRequest
        do {
            payload = try JSONDecoder().decode(DictionaryCorrectionRequest.self, from: request.body)
        } catch {
            return .error(status: 400, message: "Invalid JSON body")
        }

        let original = payload.original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else {
            return .error(status: 400, message: "Missing or empty 'original'")
        }

        do {
            return try await MainActor.run {
                try dictionaryService.upsertAPICorrection(
                    original: original,
                    replacement: payload.replacement,
                    caseSensitive: payload.caseSensitive ?? false
                )
                return dictionaryCorrectionsResponse()
            }
        } catch {
            return .error(status: 500, message: "Failed to save dictionary: \(error.localizedDescription)")
        }
    }

    private func handleDeleteDictionaryCorrections(_ request: HTTPRequest) async -> HTTPResponse {
        struct DeleteDictionaryCorrectionRequest: Decodable {
            let original: String
        }

        struct DeleteResponse: Encodable {
            let deleted: Bool
            let count: Int
        }

        guard !request.body.isEmpty else {
            return .error(status: 400, message: "Missing JSON body")
        }

        let payload: DeleteDictionaryCorrectionRequest
        do {
            payload = try JSONDecoder().decode(DeleteDictionaryCorrectionRequest.self, from: request.body)
        } catch {
            return .error(status: 400, message: "Invalid JSON body")
        }

        let original = payload.original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else {
            return .error(status: 400, message: "Missing or empty 'original'")
        }

        do {
            return try await MainActor.run {
                let deleted = try dictionaryService.deleteAPICorrection(original: original)
                let count = dictionaryService.corrections.count
                return .json(DeleteResponse(deleted: deleted, count: count))
            }
        } catch {
            return .error(status: 500, message: "Failed to save dictionary: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func dictionaryCorrectionsResponse() -> HTTPResponse {
        let corrections = dictionaryService.corrections.map {
            DictionaryCorrectionEntry(
                original: $0.original,
                replacement: $0.replacement ?? "",
                caseSensitive: $0.caseSensitive
            )
        }
        return .json(DictionaryCorrectionsResponse(corrections: corrections, count: corrections.count))
    }

    // MARK: - GET /v1/rules

    private func handleGetRules(_ request: HTTPRequest) async -> HTTPResponse {
        let workflowService = self.workflowService
        return await MainActor.run {
            struct RuleEntry: Encodable {
                let id: String
                let name: String
                let is_enabled: Bool
                let priority: Int
                let bundle_identifiers: [String]
                let url_patterns: [String]
                let input_language: String?
                let language_mode: String
                let language_hints: [String]
                let translation_target_language: String?
            }

            struct RulesResponse: Encodable {
                let rules: [RuleEntry]
                let profiles: [RuleEntry]
            }

            let entries = workflowService.workflows.map { workflow in
                let selection = workflow.inputLanguageSelection
                let legacyInputLanguage: String?
                switch selection {
                case .auto:
                    legacyInputLanguage = "auto"
                case .exact(let code):
                    legacyInputLanguage = code
                case .inheritGlobal, .hints:
                    legacyInputLanguage = nil
                }

                return RuleEntry(
                    id: workflow.id.uuidString,
                    name: workflow.name,
                    is_enabled: workflow.isEnabled,
                    priority: workflow.sortOrder,
                    bundle_identifiers: workflow.trigger?.appBundleIdentifiers ?? [],
                    url_patterns: workflow.trigger?.websitePatterns ?? [],
                    input_language: legacyInputLanguage,
                    language_mode: selection.mode.rawValue,
                    language_hints: selection.selectedCodes,
                    translation_target_language: workflow.translationTargetLanguage
                )
            }

            return .json(RulesResponse(rules: entries, profiles: entries))
        }
    }

    // MARK: - PUT /v1/rules/toggle

    private func handleToggleRule(_ request: HTTPRequest) async -> HTTPResponse {
        guard let idString = request.queryParams["id"],
              let uuid = UUID(uuidString: idString) else {
            return .error(status: 400, message: "Missing or invalid 'id' query parameter")
        }

        let workflowService = self.workflowService
        return await MainActor.run {
            guard let workflow = workflowService.workflows.first(where: { $0.id == uuid }) else {
                return .error(status: 404, message: "Rule not found")
            }

            workflowService.toggleWorkflow(workflow)

            struct ToggleResponse: Encodable {
                let id: String
                let name: String
                let rule_name: String
                let profile_name: String
                let is_enabled: Bool
            }

            return .json(ToggleResponse(
                id: workflow.id.uuidString,
                name: workflow.name,
                rule_name: workflow.name,
                profile_name: workflow.name,
                is_enabled: workflow.isEnabled
            ))
        }
    }

    // MARK: - POST /v1/dictation/start

    private func handleStartDictation(_ request: HTTPRequest) async -> HTTPResponse {
        let dictationViewModel = self.dictationViewModel
        return await MainActor.run {
            guard !dictationViewModel.isRecording else {
                return .error(status: 409, message: "Already recording")
            }

            let id = dictationViewModel.apiStartRecording()
            if let session = dictationViewModel.apiDictationSession(id: id), session.status == .failed {
                return .error(status: 409, message: session.error ?? "Failed to start dictation")
            }

            struct StartResponse: Encodable {
                let id: String
                let status: String
            }
            return .json(StartResponse(id: id.uuidString, status: "recording"))
        }
    }

    // MARK: - POST /v1/dictation/stop

    private func handleStopDictation(_ request: HTTPRequest) async -> HTTPResponse {
        let dictationViewModel = self.dictationViewModel
        return await MainActor.run {
            guard dictationViewModel.isRecording else {
                return .error(status: 409, message: "Not recording")
            }
            guard let id = dictationViewModel.apiStopRecording() else {
                return .error(status: 500, message: "Missing active dictation session")
            }

            struct StopResponse: Encodable {
                let id: String
                let status: String
            }
            return .json(StopResponse(id: id.uuidString, status: "stopped"))
        }
    }

    // MARK: - GET /v1/dictation/status

    private func handleDictationStatus(_ request: HTTPRequest) async -> HTTPResponse {
        let dictationViewModel = self.dictationViewModel
        return await MainActor.run {
            struct DictationStatusResponse: Encodable { let is_recording: Bool }
            return .json(DictationStatusResponse(is_recording: dictationViewModel.isRecording))
        }
    }

    // MARK: - GET /v1/dictation/transcription

    private func handleDictationTranscription(_ request: HTTPRequest) async -> HTTPResponse {
        guard let idString = request.queryParams["id"],
              let uuid = UUID(uuidString: idString) else {
            return .error(status: 400, message: "Missing or invalid 'id' query parameter")
        }

        let dictationViewModel = self.dictationViewModel
        return await MainActor.run {
            guard let session = dictationViewModel.apiDictationSession(id: uuid) else {
                return .error(status: 404, message: "Dictation session not found")
            }

            struct DictationTranscriptionPayload: Encodable {
                let text: String
                let raw_text: String
                let timestamp: Date
                let app_name: String?
                let app_bundle_id: String?
                let app_url: String?
                let duration: Double
                let language: String?
                let engine: String
                let model: String?
                let words_count: Int
            }

            struct DictationTranscriptionResponse: Encodable {
                let id: String
                let status: String
                let transcription: DictationTranscriptionPayload?
                let error: String?
            }

            let transcription = session.transcription.map {
                DictationTranscriptionPayload(
                    text: $0.text,
                    raw_text: $0.rawText,
                    timestamp: $0.timestamp,
                    app_name: $0.appName,
                    app_bundle_id: $0.appBundleIdentifier,
                    app_url: $0.appURL,
                    duration: $0.duration,
                    language: $0.language,
                    engine: $0.engine,
                    model: $0.model,
                    words_count: $0.wordsCount
                )
            }

            return .json(DictationTranscriptionResponse(
                id: session.id.uuidString,
                status: session.status.rawValue,
                transcription: transcription,
                error: session.error
            ))
        }
    }

    // MARK: - POST /v1/recorder/start

    private func handleStartRecorder(_ request: HTTPRequest) async -> HTTPResponse {
        let micEnabled: Bool?
        let systemAudioEnabled: Bool?
        do {
            micEnabled = try parseOptionalBooleanQuery(request, name: "mic")
            systemAudioEnabled = try parseOptionalBooleanQuery(request, name: "system_audio")
        } catch {
            return .error(status: 400, message: error.localizedDescription)
        }

        do {
            let id = try await audioRecorderViewModel.apiStartRecording(
                micEnabled: micEnabled,
                systemAudioEnabled: systemAudioEnabled
            )

            struct StartResponse: Encodable {
                let id: String
                let status: String
            }
            return .json(StartResponse(id: id.uuidString, status: "recording"))
        } catch AudioRecorderViewModel.RecorderAPIError.noSourceEnabled {
            return .error(status: 400, message: AudioRecorderViewModel.RecorderAPIError.noSourceEnabled.localizedDescription)
        } catch AudioRecorderViewModel.RecorderAPIError.alreadyRecording {
            return .error(status: 409, message: AudioRecorderViewModel.RecorderAPIError.alreadyRecording.localizedDescription)
        } catch AudioRecorderViewModel.RecorderAPIError.finalizing {
            return .error(status: 409, message: AudioRecorderViewModel.RecorderAPIError.finalizing.localizedDescription)
        } catch {
            return .error(status: 409, message: error.localizedDescription)
        }
    }

    // MARK: - POST /v1/recorder/stop

    private func handleStopRecorder(_ request: HTTPRequest) async -> HTTPResponse {
        do {
            let id = try await audioRecorderViewModel.apiStopRecording()

            struct StopResponse: Encodable {
                let id: String
                let status: String
            }
            return .json(StopResponse(id: id.uuidString, status: "finalizing"))
        } catch {
            return .error(status: 409, message: error.localizedDescription)
        }
    }

    // MARK: - GET /v1/recorder/status

    private func handleRecorderStatus(_ request: HTTPRequest) async -> HTTPResponse {
        let recording = await audioRecorderViewModel.apiRecorderIsRecording

        struct RecorderStatusResponse: Encodable {
            let recording: Bool
        }
        return .json(RecorderStatusResponse(recording: recording))
    }

    // MARK: - GET /v1/recorder/session

    private func handleRecorderSession(_ request: HTTPRequest) async -> HTTPResponse {
        guard let idString = request.queryParams["id"],
              let uuid = UUID(uuidString: idString) else {
            return .error(status: 400, message: "Missing or invalid 'id' query parameter")
        }
        guard let session = await audioRecorderViewModel.apiRecorderSession(id: uuid) else {
            return .error(status: 404, message: "Recorder session not found")
        }

        struct RecorderSessionResponse: Encodable {
            let id: String
            let status: String
            let text: String?
            let output_file: String?
            let error: String?
        }
        return .json(RecorderSessionResponse(
            id: session.id.uuidString,
            status: session.status.rawValue,
            text: session.text,
            output_file: session.outputFile,
            error: session.error
        ))
    }

    // MARK: - POST /v1/meetings/import-transcript

    private struct MeetingImportRequest: Decodable {
        let path: String?
        let text: String?
        let title: String?
        let date: String?
        let folder: String?
        let tags: [String]?
        let language: String?
        let matchCalendar: Bool?

        enum CodingKeys: String, CodingKey {
            case path, text, title, date, folder, tags, language
            case matchCalendar = "match_calendar"
        }
    }

    /// Resolved, mode-agnostic import inputs (JSON body or raw-text body).
    private struct MeetingImportInputs {
        var path: String?
        var text: String?
        var title: String?
        var date: Date?
        var folder: String?
        var tags: [String]?
        var language: String?
        var matchCalendar: Bool
    }

    private struct MatchedEventResponse: Encodable {
        let id: String
        let title: String
        let date: Date
        let confidence: Double
    }

    private struct MeetingImportResponse: Encodable {
        let id: String
        let title: String
        let date: Date?
        let matched_event: MatchedEventResponse?
    }

    private func handleImportMeetingTranscript(_ request: HTTPRequest) async -> HTTPResponse {
        let inputs: MeetingImportInputs
        switch parseImportInputs(request) {
        case .use(let value): inputs = value
        case .reject(let response): return response
        }

        let meetingService = self.meetingService
        let importService = self.meetingImportService
        let calendarService = self.calendarService

        return await MainActor.run {
            // 1) Create the meeting from a file (direct handoff) or raw text.
            let meeting: Meeting
            do {
                if let path = inputs.path {
                    let fileURL = URL(fileURLWithPath: path)
                    guard FileManager.default.fileExists(atPath: fileURL.path) else {
                        return .error(status: 400, message: "File not found")
                    }
                    meeting = try importService.importTranscriptFile(at: fileURL, title: inputs.title)
                } else {
                    meeting = try importService.importTranscriptText(inputs.text ?? "", title: inputs.title)
                }
            } catch let error as MeetingImportService.ImportError {
                switch error {
                case .unsupportedTranscriptFile, .unreadableTranscriptFile, .emptyTranscript:
                    return .error(status: 400, message: error.localizedDescription)
                default:
                    return .error(status: 500, message: error.localizedDescription)
                }
            } catch {
                return .error(status: 500, message: "Import failed: \(error.localizedDescription)")
            }

            // 2) Apply optional metadata. Date is set before matching so the calendar query can use it.
            if let date = inputs.date {
                meetingService.setMeetingDate(date, for: meeting)
            }
            if let folder = inputs.folder {
                meetingService.setFolder(folder, for: meeting)
            }
            if let tags = inputs.tags {
                meetingService.setObsidianTags(tags, for: meeting)
            }
            if let language = inputs.language?.trimmingCharacters(in: .whitespacesAndNewlines), !language.isEmpty {
                meetingService.setLanguage(language, for: meeting)
            }

            // 3) Optional calendar matching: auto-link the best historical event above the confidence
            //    threshold, so the imported meeting feeds prior-meeting briefs.
            var matched: MatchedEventResponse?
            if inputs.matchCalendar, let date = inputs.date, let calendarService,
               let candidate = calendarService.bestAutoLinkCandidate(title: meeting.title, date: date) {
                let projection = CalendarService.meetingProjection(for: candidate.event)
                meetingService.linkToCalendarEvent(
                    calendarEventID: projection.calendarEventID,
                    seriesID: projection.seriesID,
                    title: projection.title,
                    startDate: projection.startDate,
                    endDate: projection.endDate,
                    attendees: projection.attendees,
                    for: meeting
                )
                matched = MatchedEventResponse(
                    id: candidate.event.id,
                    title: projection.title,
                    date: candidate.event.startDate,
                    confidence: candidate.score
                )
            }

            return .json(MeetingImportResponse(
                id: meeting.id.uuidString,
                title: meeting.title,
                date: meeting.startDate,
                matched_event: matched
            ))
        }
    }

    private func parseImportInputs(_ request: HTTPRequest) -> MeetingImportInputsResolution {
        let contentType = request.headers["content-type"] ?? ""
        var inputs = MeetingImportInputs(matchCalendar: false)

        if contentType.contains("application/json") {
            guard !request.body.isEmpty else {
                return .reject(.error(status: 400, message: "Missing JSON body"))
            }
            let payload: MeetingImportRequest
            do {
                payload = try JSONDecoder().decode(MeetingImportRequest.self, from: request.body)
            } catch {
                if Self.hasInvalidJSONBooleanField("match_calendar", in: request.body) {
                    return .reject(.error(status: 400, message: "Invalid 'match_calendar' value"))
                }
                return .reject(.error(status: 400, message: "Invalid JSON body"))
            }

            let path = payload.path?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let text = (payload.text?.isEmpty == false) ? payload.text : nil
            guard path != nil || text != nil else {
                return .reject(.error(status: 400, message: "Provide 'path' or 'text'"))
            }
            guard path == nil || text == nil else {
                return .reject(.error(status: 400, message: "Use either 'path' or 'text', not both"))
            }
            inputs.path = path
            inputs.text = text
            inputs.title = payload.title
            inputs.folder = payload.folder
            inputs.tags = payload.tags
            inputs.language = payload.language
            inputs.matchCalendar = payload.matchCalendar ?? false

            if let dateString = payload.date?.trimmingCharacters(in: .whitespacesAndNewlines), !dateString.isEmpty {
                guard let date = Self.parseISO8601Date(dateString) else {
                    return .reject(.error(status: 400, message: "Invalid 'date' value"))
                }
                inputs.date = date
            }
        } else {
            guard !request.body.isEmpty, let text = String(data: request.body, encoding: .utf8), !text.isEmpty else {
                return .reject(.error(status: 400, message: "Missing transcript text body"))
            }
            inputs.text = text
            inputs.title = request.queryParams["title"]
            inputs.folder = request.queryParams["folder"]
            inputs.language = request.queryParams["language"]
            inputs.tags = request.queryParams["tags"]?
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            if let matchValue = request.queryParams["match_calendar"] {
                guard let parsed = Self.parseBoolean(matchValue) else {
                    return .reject(.error(status: 400, message: "Invalid 'match_calendar' value"))
                }
                inputs.matchCalendar = parsed
            }

            if let dateString = request.queryParams["date"]?.trimmingCharacters(in: .whitespacesAndNewlines), !dateString.isEmpty {
                guard let date = Self.parseISO8601Date(dateString) else {
                    return .reject(.error(status: 400, message: "Invalid 'date' value"))
                }
                inputs.date = date
            }
        }

        return .use(inputs)
    }

    private enum MeetingImportInputsResolution {
        case use(MeetingImportInputs)
        case reject(HTTPResponse)
    }

    // MARK: - Live meeting sessions (browser caption bridge)

    /// Ceiling on one `POST .../segments` batch. The Meet extension flushes every few seconds, so a
    /// healthy batch is single digits; anything near this bound is a malfunctioning or hostile client
    /// and is rejected outright rather than silently truncated.
    private static let maxLiveSegmentsPerBatch = 500

    /// Ceiling on a single caption line. Meet caption lines are a sentence or two; this only exists so
    /// a runaway client cannot write unbounded rows into the store.
    private static let maxLiveSegmentTextLength = 8_000

    private struct LiveSessionAttendee: Decodable {
        let name: String
        let email: String?
        let isSelf: Bool?

        enum CodingKeys: String, CodingKey {
            case name, email
            case isSelf = "is_self"
        }
    }

    private struct LiveSessionStartRequest: Decodable {
        let sessionKey: String?
        let title: String?
        let startedAt: String?
        let attendees: [LiveSessionAttendee]?

        enum CodingKeys: String, CodingKey {
            case title, attendees
            case sessionKey = "session_key"
            case startedAt = "started_at"
        }
    }

    private struct LiveSegmentPayload: Decodable {
        let text: String
        let speaker: String?
        let start: Double
        let end: Double
        let confidence: Double?
    }

    private struct LiveSegmentsRequest: Decodable {
        let segments: [LiveSegmentPayload]
    }

    private struct LiveSessionEndRequest: Decodable {
        let endedAt: String?

        enum CodingKeys: String, CodingKey {
            case endedAt = "ended_at"
        }
    }

    /// `POST /v1/meetings/live` — create or resume the meeting backing an external live session.
    ///
    /// Idempotent on `session_key` (the Meet call code): an MV3 service worker that Chrome evicts
    /// mid-call, a page reload, or a second tab joined to the same call all resume the same meeting
    /// instead of forking duplicates. Only a *non-completed* meeting is resumed, so rejoining a call
    /// that was already ended starts a fresh one rather than reopening yesterday's.
    private func handleStartLiveMeeting(_ request: HTTPRequest) async -> HTTPResponse {
        guard !request.body.isEmpty,
              let payload = try? JSONDecoder().decode(LiveSessionStartRequest.self, from: request.body) else {
            return .error(status: 400, message: "Invalid JSON body")
        }
        guard let sessionKey = payload.sessionKey?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            return .error(status: 400, message: "Missing 'session_key'")
        }
        guard sessionKey.count <= 256 else {
            return .error(status: 400, message: "'session_key' is too long")
        }

        var startDate: Date?
        if let startedAt = payload.startedAt?.trimmingCharacters(in: .whitespacesAndNewlines), !startedAt.isEmpty {
            guard let parsed = Self.parseISO8601Date(startedAt) else {
                return .error(status: 400, message: "Invalid 'started_at' value")
            }
            startDate = parsed
        }

        let title = payload.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? String(localized: "meetings.calendar.untitledEvent")
        let attendees: [Attendee] = (payload.attendees ?? []).compactMap { entry in
            let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return Attendee(
                name: name,
                email: entry.email?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                isSelf: entry.isSelf
            )
        }

        let meetingService = self.meetingService
        return await MainActor.run {
            if let existing = meetingService.meetings.first(where: {
                $0.externalSessionKey == sessionKey && $0.state != .completed
            }) {
                return .json(LiveSessionResponse(
                    id: existing.id.uuidString,
                    created: false,
                    title: existing.title,
                    state: existing.state.rawValue,
                    segment_count: existing.segments.count
                ))
            }

            let meeting = meetingService.createMeeting(
                title: title,
                source: .adHoc,
                state: .live,
                startDate: startDate ?? Date(),
                attendees: attendees
            )
            meetingService.setExternalSessionKey(sessionKey, for: meeting)
            apiLogger.info("Started live meeting session for key \(sessionKey, privacy: .public)")
            return .json(LiveSessionResponse(
                id: meeting.id.uuidString,
                created: true,
                title: meeting.title,
                state: meeting.state.rawValue,
                segment_count: 0
            ))
        }
    }

    /// `POST /v1/meetings/live/{id}/segments` — append a batch of speaker-attributed caption lines.
    ///
    /// Segments land with source `.liveCaptions` so a later re-transcription of our own audio (which
    /// replaces `.liveCapture` rows) can never destroy the caption-derived speaker timeline.
    /// `start`/`end` are seconds relative to the meeting start, as measured by the caller.
    private func handleAppendLiveSegments(_ request: HTTPRequest) async -> HTTPResponse {
        guard let idString = request.pathParams["id"], let uuid = UUID(uuidString: idString) else {
            return .error(status: 400, message: "Missing or invalid meeting id")
        }
        guard !request.body.isEmpty,
              let payload = try? JSONDecoder().decode(LiveSegmentsRequest.self, from: request.body) else {
            return .error(status: 400, message: "Invalid JSON body")
        }
        guard !payload.segments.isEmpty else {
            return .error(status: 400, message: "Missing 'segments'")
        }
        guard payload.segments.count <= Self.maxLiveSegmentsPerBatch else {
            return .error(
                status: 413,
                message: "Too many segments in one batch (max \(Self.maxLiveSegmentsPerBatch))"
            )
        }

        // Drop blank lines rather than failing the batch: the caption stabilizer can legitimately
        // emit an empty tail when a speaker's turn is revised away mid-flush.
        let segments: [TranscriptionSegment] = payload.segments.compactMap { entry in
            let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= Self.maxLiveSegmentTextLength else { return nil }
            guard entry.start.isFinite, entry.end.isFinite else { return nil }
            let start = max(0, entry.start)
            return TranscriptionSegment(
                text: text,
                start: start,
                end: max(start, entry.end),
                speakerLabel: entry.speaker?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                speakerConfidence: entry.confidence
            )
        }

        let meetingService = self.meetingService
        return await MainActor.run {
            guard let meeting = meetingService.meetings.first(where: { $0.id == uuid }) else {
                return .error(status: 404, message: "Meeting not found")
            }
            if !segments.isEmpty {
                meetingService.appendStableSegments(segments, source: .liveCaptions, to: meeting)
            }
            return .json(LiveAppendResponse(
                id: meeting.id.uuidString,
                appended: segments.count,
                segment_count: meeting.segments.count
            ))
        }
    }

    /// `POST /v1/meetings/live/{id}/end` — close out an external live session.
    ///
    /// Deliberately inert beyond the state transition: it does not kick off summarization, so leaving
    /// a call never spends tokens without the user asking. The meeting simply becomes a normal
    /// completed meeting the user can summarize, export, or identify speakers on.
    private func handleEndLiveMeeting(_ request: HTTPRequest) async -> HTTPResponse {
        guard let idString = request.pathParams["id"], let uuid = UUID(uuidString: idString) else {
            return .error(status: 400, message: "Missing or invalid meeting id")
        }

        var endDate: Date?
        if !request.body.isEmpty {
            guard let payload = try? JSONDecoder().decode(LiveSessionEndRequest.self, from: request.body) else {
                return .error(status: 400, message: "Invalid JSON body")
            }
            if let endedAt = payload.endedAt?.trimmingCharacters(in: .whitespacesAndNewlines), !endedAt.isEmpty {
                guard let parsed = Self.parseISO8601Date(endedAt) else {
                    return .error(status: 400, message: "Invalid 'ended_at' value")
                }
                endDate = parsed
            }
        }

        let meetingService = self.meetingService
        let resolvedEnd = endDate ?? Date()
        return await MainActor.run {
            guard let meeting = meetingService.meetings.first(where: { $0.id == uuid }) else {
                return .error(status: 404, message: "Meeting not found")
            }
            meeting.endDate = resolvedEnd
            meeting.state = .completed
            meetingService.update(meeting)
            return .json(LiveSessionResponse(
                id: meeting.id.uuidString,
                created: false,
                title: meeting.title,
                state: meeting.state.rawValue,
                segment_count: meeting.segments.count
            ))
        }
    }

    private struct LiveSessionResponse: Encodable {
        let id: String
        let created: Bool
        let title: String
        let state: String
        let segment_count: Int
    }

    private struct LiveAppendResponse: Encodable {
        let id: String
        let appended: Int
        let segment_count: Int
    }

    // MARK: - GET /v1/meetings

    private struct MeetingRow: Encodable {
        let id: String
        let title: String
        let date: Date?
        let folder: String?
        let tags: [String]
        let language: String?
        let has_transcript: Bool
        let has_summary: Bool
        let calendar_linked: Bool
    }

    private func handleListMeetings(_ request: HTTPRequest) async -> HTTPResponse {
        let folder = request.queryParams["folder"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let tag = request.queryParams["tag"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let limit = min(Int(request.queryParams["limit"] ?? "") ?? 50, 200)
        let offset = max(Int(request.queryParams["offset"] ?? "") ?? 0, 0)

        var fromDate: Date?
        if let fromString = request.queryParams["from"]?.trimmingCharacters(in: .whitespacesAndNewlines), !fromString.isEmpty {
            guard let parsed = Self.parseISO8601Date(fromString) else {
                return .error(status: 400, message: "Invalid 'from' value")
            }
            fromDate = parsed
        }
        var toDate: Date?
        if let toString = request.queryParams["to"]?.trimmingCharacters(in: .whitespacesAndNewlines), !toString.isEmpty {
            guard let parsed = Self.parseISO8601Date(toString) else {
                return .error(status: 400, message: "Invalid 'to' value")
            }
            toDate = parsed
        }

        let tagKey = tag?.lowercased()

        let meetingService = self.meetingService
        return await MainActor.run {
            let folderComponents = folder.map { MeetingService.folderComponents($0) }
            let filtered = meetingService.meetings.filter { meeting in
                if let folderComponents, !folderComponents.isEmpty {
                    let meetingComponents = MeetingService.folderComponents(meeting.folderPath)
                    guard meetingComponents.count >= folderComponents.count,
                          Array(meetingComponents.prefix(folderComponents.count)) == folderComponents else {
                        return false
                    }
                }
                if let tagKey {
                    guard meeting.tags.contains(where: { $0.lowercased() == tagKey }) else { return false }
                }
                if let fromDate {
                    guard let start = meeting.startDate, start >= fromDate else { return false }
                }
                if let toDate {
                    guard let start = meeting.startDate, start <= toDate else { return false }
                }
                return true
            }

            let total = filtered.count
            let sliceStart = min(offset, total)
            let sliceEnd = min(offset + limit, total)
            let page = Array(filtered[sliceStart..<sliceEnd])

            struct MeetingsResponse: Encodable {
                let meetings: [MeetingRow]
                let total: Int
                let limit: Int
                let offset: Int
            }

            return .json(MeetingsResponse(
                meetings: page.map { Self.meetingRow($0) },
                total: total,
                limit: limit,
                offset: offset
            ))
        }
    }

    // MARK: - GET /v1/meetings/{id}

    private func handleGetMeeting(_ request: HTTPRequest) async -> HTTPResponse {
        guard let idString = request.pathParams["id"], let uuid = UUID(uuidString: idString) else {
            return .error(status: 400, message: "Missing or invalid meeting id")
        }
        let includeTranscript = request.queryParams["include"]?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .contains("transcript") ?? false

        let meetingService = self.meetingService
        return await MainActor.run {
            guard let meeting = meetingService.meetings.first(where: { $0.id == uuid }) else {
                return .error(status: 404, message: "Meeting not found")
            }

            struct MeetingDetailResponse: Encodable {
                let id: String
                let title: String
                let date: Date?
                let end_date: Date?
                let state: String
                let source: String
                let folder: String?
                let tags: [String]
                let language: String?
                let calendar_linked: Bool
                let calendar_event_id: String?
                let has_transcript: Bool
                let has_summary: Bool
                let segment_count: Int
                let attendees: [AttendeeRow]
                let transcript: String?
            }
            struct AttendeeRow: Encodable {
                let name: String
                let email: String?
            }

            let row = Self.meetingRow(meeting)
            let transcript: String? = includeTranscript ? Self.renderTranscript(meeting) : nil

            return .json(MeetingDetailResponse(
                id: row.id,
                title: row.title,
                date: row.date,
                end_date: meeting.endDate,
                state: meeting.state.rawValue,
                source: meeting.source.rawValue,
                folder: row.folder,
                tags: row.tags,
                language: row.language,
                calendar_linked: row.calendar_linked,
                calendar_event_id: meeting.calendarEventID,
                has_transcript: row.has_transcript,
                has_summary: row.has_summary,
                segment_count: meeting.segments.count,
                attendees: meeting.attendees.map { AttendeeRow(name: $0.name, email: $0.email) },
                transcript: transcript
            ))
        }
    }

    // MARK: - Meeting helpers

    @MainActor
    private static func meetingRow(_ meeting: Meeting) -> MeetingRow {
        let hasSummary = meeting.outputs.contains { $0.kind == .summary || $0.kind == .extended }
        return MeetingRow(
            id: meeting.id.uuidString,
            title: meeting.title,
            date: meeting.startDate,
            folder: meeting.folderPath,
            tags: meeting.tags,
            language: meeting.languageCode,
            has_transcript: !meeting.segments.isEmpty,
            has_summary: hasSummary,
            calendar_linked: meeting.calendarEventID != nil
        )
    }

    /// Render a meeting's segments chronologically into newline-separated `Speaker: text` lines,
    /// resolving `SPEAKER_xx` labels through the meeting's speaker map when present.
    @MainActor
    private static func renderTranscript(_ meeting: Meeting) -> String {
        let speakerMap = meeting.speakerMap
        return meeting.segments
            .sorted { $0.order < $1.order }
            .map { segment -> String in
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let label = segment.speakerLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
                    let name = speakerMap[label] ?? label
                    return "\(name): \(text)"
                }
                return text
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func parseISO8601Date(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: trimmed) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: trimmed) { return date }
        let dateOnly = ISO8601DateFormatter()
        dateOnly.formatOptions = [.withFullDate]
        return dateOnly.date(from: trimmed)
    }

    // MARK: - Helpers

    private enum BooleanQueryError: LocalizedError {
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .invalid(let name):
                "Invalid '\(name)' query parameter"
            }
        }
    }

    private func parseOptionalBooleanQuery(_ request: HTTPRequest, name: String) throws -> Bool? {
        guard let value = request.queryParams[name] else { return nil }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "1":
            return true
        case "false", "0":
            return false
        default:
            throw BooleanQueryError.invalid(name)
        }
    }

    private func extractBoundary(from contentType: String) -> String? {
        for part in contentType.components(separatedBy: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("boundary=") {
                var boundary = String(trimmed.dropFirst("boundary=".count))
                if boundary.hasPrefix("\"") && boundary.hasSuffix("\"") {
                    boundary = String(boundary.dropFirst().dropLast())
                }
                return boundary
            }
        }
        return nil
    }

    private func extensionFromMIME(_ mime: String) -> String {
        let lower = mime.lowercased().trimmingCharacters(in: .whitespaces)
        if lower.contains("wav") || lower.contains("wave") { return "wav" }
        if lower.contains("mp3") || lower.contains("mpeg") { return "mp3" }
        if lower.contains("m4a") || lower.contains("mp4") { return "m4a" }
        if lower.contains("flac") { return "flac" }
        if lower.contains("ogg") { return "ogg" }
        if lower.contains("aac") { return "aac" }
        return "wav"
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
