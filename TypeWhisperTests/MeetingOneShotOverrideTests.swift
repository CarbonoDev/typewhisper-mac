import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

/// [M5/D10] On-the-spot (one-shot) model overrides. Verifies the prepended rung of the routing ladder
/// `one-shot > template > purpose > app default`: a one-shot pick wins for that run only, reaches the
/// processor, is recorded on the output's provenance, and persists **nothing** (a subsequent default run
/// falls back to the template/purpose/global ladder). Also covers the target-aware "Save as default…" —
/// a templated run saves to the template row, a template-less purpose saves to the purpose setting.
@MainActor
final class MeetingOneShotOverrideTests: XCTestCase {
    // MARK: - Stub processor (records the resolved overrides each call receives)

    @MainActor
    private final class StubProcessor: PromptProcessing {
        struct Call {
            let providerOverride: String?
            let cloudModelOverride: String?
        }
        var selectedProviderId: String
        var selectedCloudModel: String
        private(set) var calls: [Call] = []

        init(provider: String = "global-provider", model: String = "global-model") {
            selectedProviderId = provider
            selectedCloudModel = model
        }

        func process(
            prompt: String,
            text: String,
            providerOverride: String?,
            cloudModelOverride: String?,
            temperatureDirective: PluginLLMTemperatureDirective,
            skipMemoryInjection: Bool
        ) async throws -> String {
            calls.append(Call(providerOverride: providerOverride, cloudModelOverride: cloudModelOverride))
            return "RESULT"
        }
    }

    // MARK: - Fixtures

    private func makeDefaults() -> UserDefaults {
        let suite = "MeetingOneShotOverrideTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return defaults
    }

    private func makeVault() -> ObsidianVaultService {
        ObsidianVaultService(defaults: makeDefaults())
    }

    private func makeStore(prefix: String = "OneShot") throws -> MeetingService {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: prefix)
        addTeardownBlock { TestSupport.remove(dir) }
        return MeetingService(appSupportDirectory: dir)
    }

    private func makePromptActionService() throws -> PromptActionService {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "OneShotPrompts")
        addTeardownBlock { TestSupport.remove(dir) }
        return PromptActionService(appSupportDirectory: dir, defaults: makeDefaults())
    }

    private func makeMeeting(on service: MeetingService) -> Meeting {
        let meeting = service.createMeeting(title: "Analysis", source: .adHoc, state: .completed)
        service.appendStableSegments([TranscriptionSegment(text: "Short transcript.", start: 0, end: 2)], to: meeting)
        return meeting
    }

    private func makeTemplate(provider: String? = nil, model: String? = nil) -> PromptAction {
        PromptAction(
            name: "T",
            prompt: "Summarize this.",
            providerType: provider,
            cloudModel: model,
            surfaceRaw: PromptSurface.meeting.rawValue,
            meetingKindRaw: MeetingOutputKind.summary.rawValue
        )
    }

    // MARK: - Router: one-shot is the top rung

    func testRouterOneShotWinsOverTemplatePurposeAndGlobal() {
        let defaults = makeDefaults()
        defaults.set("purpose-p", forKey: UserDefaultsKeys.meetingsModelSummariesProviderId)
        defaults.set("purpose-m", forKey: UserDefaultsKeys.meetingsModelSummariesModel)
        let router = MeetingModelRouter(processor: StubProcessor(), defaults: defaults)

        // Even with a template AND a purpose set, the one-shot pick wins for both the call override and
        // the effective (provenance) value.
        XCTAssertEqual(
            router.overrideProvider(for: .summariesAnalysis, templateProvider: "tmpl-p", oneShotProvider: "one-p"),
            "one-p"
        )
        XCTAssertEqual(
            router.overrideModel(for: .summariesAnalysis, templateModel: "tmpl-m", oneShotModel: "one-m"),
            "one-m"
        )
        XCTAssertEqual(
            router.effectiveProvider(for: .summariesAnalysis, templateProvider: "tmpl-p", oneShotProvider: "one-p"),
            "one-p"
        )
        XCTAssertEqual(
            router.effectiveModel(for: .summariesAnalysis, templateModel: "tmpl-m", oneShotModel: "one-m"),
            "one-m"
        )
    }

    func testRouterOneShotProviderWithoutModelDoesNotBleedForeignModel() {
        // A one-shot provider picked with NO model (the menus emit `action(provider.id, nil)` for a
        // provider with an empty model list) must pin the model dimension to that provider: a nil one-shot
        // model means "that provider's own default", NOT the template/purpose model of a *different*
        // provider. The ladder stops at the one-shot rung so neither the call override nor provenance
        // names a foreign model (M5 review finding; D10 "provenance always records what actually ran").
        let defaults = makeDefaults()
        defaults.set("purpose-m", forKey: UserDefaultsKeys.meetingsModelSummariesModel)
        let router = MeetingModelRouter(processor: StubProcessor(), defaults: defaults)

        // Both a template model and a purpose model are set, yet the one-shot provider (no model) blocks
        // them from bleeding through.
        XCTAssertNil(router.overrideModel(
            for: .summariesAnalysis, templateModel: "tmpl-m", oneShotModel: nil, oneShotProvider: "one-p"
        ))
        XCTAssertNil(router.effectiveModel(
            for: .summariesAnalysis, templateModel: "tmpl-m", oneShotModel: nil, oneShotProvider: "one-p"
        ))
        // Sanity: a one-shot provider WITH a model still records that model; and no one-shot provider
        // leaves the legacy ladder intact (template model wins).
        XCTAssertEqual(router.effectiveModel(
            for: .summariesAnalysis, templateModel: "tmpl-m", oneShotModel: "one-m", oneShotProvider: "one-p"
        ), "one-m")
        XCTAssertEqual(router.effectiveModel(
            for: .summariesAnalysis, templateModel: "tmpl-m", oneShotModel: nil, oneShotProvider: nil
        ), "tmpl-m")
    }

    func testRouterNilOneShotPreservesLegacyLadder() {
        let defaults = makeDefaults()
        defaults.set("purpose-p", forKey: UserDefaultsKeys.meetingsModelSummariesProviderId)
        let router = MeetingModelRouter(processor: StubProcessor(), defaults: defaults)

        // A nil/blank one-shot inherits the existing `template ?? purpose ?? global` behavior.
        XCTAssertEqual(router.overrideProvider(for: .summariesAnalysis, oneShotProvider: nil), "purpose-p")
        XCTAssertEqual(router.overrideProvider(for: .summariesAnalysis, oneShotProvider: "  "), "purpose-p")
    }

    // MARK: - generateOutput threads and records the one-shot, persisting nothing

    func testGeneratedOutputOneShotReachesProcessorAndIsRecorded() async throws {
        let defaults = makeDefaults()
        defaults.set("purpose-p", forKey: UserDefaultsKeys.meetingsModelSummariesProviderId)
        defaults.set("purpose-m", forKey: UserDefaultsKeys.meetingsModelSummariesModel)
        let service = try makeStore()
        let stub = StubProcessor()
        let router = MeetingModelRouter(processor: stub, defaults: defaults)
        let llm = MeetingLLMService(
            meetingService: service, vaultService: makeVault(), processor: stub, modelRouter: router
        )
        let meeting = makeMeeting(on: service)

        let output = try await llm.generateOutput(
            for: meeting, using: makeTemplate(provider: "tmpl-p", model: "tmpl-m"),
            providerOverride: "one-p", modelOverride: "one-m"
        )

        // The one-shot reached the processor and is recorded on the output — beating even the template.
        XCTAssertEqual(stub.calls.first?.providerOverride, "one-p")
        XCTAssertEqual(stub.calls.first?.cloudModelOverride, "one-m")
        XCTAssertEqual(output.providerUsed, "one-p")
        XCTAssertEqual(output.modelUsed, "one-m")
    }

    func testOneShotPersistsNothing() async throws {
        let defaults = makeDefaults()
        defaults.set("purpose-p", forKey: UserDefaultsKeys.meetingsModelSummariesProviderId)
        defaults.set("purpose-m", forKey: UserDefaultsKeys.meetingsModelSummariesModel)
        let service = try makeStore()
        let stub = StubProcessor()
        let router = MeetingModelRouter(processor: stub, defaults: defaults)
        let llm = MeetingLLMService(
            meetingService: service, vaultService: makeVault(), processor: stub, modelRouter: router
        )
        let template = makeTemplate()
        let meeting = makeMeeting(on: service)

        _ = try await llm.generateOutput(for: meeting, using: template, providerOverride: "one-p", modelOverride: "one-m")
        // The one-shot must not mutate the template or the purpose keys.
        XCTAssertNil(template.providerType)
        XCTAssertNil(template.cloudModel)
        XCTAssertEqual(defaults.string(forKey: UserDefaultsKeys.meetingsModelSummariesProviderId), "purpose-p")

        // A subsequent DEFAULT run (no one-shot) falls back to the persisted purpose rung — proving the
        // prior override left nothing behind.
        _ = try await llm.generateOutput(for: meeting, using: template)
        XCTAssertEqual(stub.calls.last?.providerOverride, "purpose-p")
        XCTAssertEqual(stub.calls.last?.cloudModelOverride, "purpose-m")
    }

    func testBriefOneShotReachesProcessorAndIsRecorded() async throws {
        let defaults = makeDefaults()
        let service = try makeStore(prefix: "OneShotBrief")
        let stub = StubProcessor(provider: "global-provider", model: "global-model")
        let router = MeetingModelRouter(processor: stub, defaults: defaults)
        let brief = MeetingBriefService(
            meetingService: service, vaultService: makeVault(), processor: stub, modelRouter: router
        )

        // A prior related meeting so the brief has context (avoids insufficientContext).
        let target = service.createMeeting(
            title: "Acme", source: .calendar, state: .scheduled, seriesID: "s1"
        )
        let prior = service.createMeeting(
            title: "Acme (prior)", source: .calendar, state: .completed, seriesID: "s1"
        )
        service.addOutput(to: prior, kind: .summary, content: "Prior summary.")

        let output = try await brief.generateBrief(for: target, providerOverride: "one-p", modelOverride: "one-m")

        XCTAssertEqual(stub.calls.first?.providerOverride, "one-p")
        XCTAssertEqual(stub.calls.first?.cloudModelOverride, "one-m")
        XCTAssertEqual(output.providerUsed, "one-p")
        XCTAssertEqual(output.modelUsed, "one-m")
    }

    // MARK: - Save as default is target-aware (template vs purpose)

    func testSaveAsDefaultWritesTemplateForTemplatedRuns() throws {
        // A summary/brief run is driven by a PromptAction, so "Save as default…" writes the template's
        // own provider/model (adjudication Part A #6) — a purpose-level save would be masked by it.
        let prompts = try makePromptActionService()
        let template = try XCTUnwrap(prompts.addMeetingTemplate(
            PromptTemplateSpec(surface: .meeting, name: "Summary", prompt: "Summarize.", meetingKind: .summary)
        ))
        XCTAssertNil(template.providerType)

        prompts.setModelDefault(provider: "anthropic", model: "claude-3", for: template)

        XCTAssertEqual(template.providerType, "anthropic")
        XCTAssertEqual(template.cloudModel, "claude-3")

        // A blank pick clears back to "Use app default".
        prompts.setModelDefault(provider: "", model: "", for: template)
        XCTAssertNil(template.providerType)
        XCTAssertNil(template.cloudModel)
    }

    func testSaveAsDefaultWritesPurposeSettingForTemplateLessPurposes() {
        // A template-less purpose (Q&A) has no PromptAction to save onto, so its default is the purpose
        // setting — the keys the router reads for that purpose.
        let defaults = makeDefaults()
        defaults.set("qa-p", forKey: MeetingModelPurpose.qa.providerDefaultsKey)
        defaults.set("qa-m", forKey: MeetingModelPurpose.qa.modelDefaultsKey)
        let router = MeetingModelRouter(processor: StubProcessor(), defaults: defaults)

        XCTAssertEqual(router.purposeProvider(for: .qa), "qa-p")
        XCTAssertEqual(router.purposeModel(for: .qa), "qa-m")
        // The purpose keys are the Q&A ones, not the summaries ones (per-target isolation).
        XCTAssertNil(router.purposeProvider(for: .summariesAnalysis))
    }
}
