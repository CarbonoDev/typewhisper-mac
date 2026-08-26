import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

/// [M4] Per-purpose model routing (plan D9). Verifies the precedence ladder `template > purpose > app
/// default` resolved per call — the call-time override (`nil` = "Use app default" passthrough) and the
/// effective value used for provenance — plus that each meeting AI service actually threads the ladder:
/// output/brief provenance equals the effective value, Q&A and the related-docs judge honor the purpose
/// setting, and language detection stays back-compatible with its legacy keys.
@MainActor
final class MeetingModelRouterTests: XCTestCase {
    // MARK: - Stub processor (records the resolved overrides each call receives)

    @MainActor
    private final class StubProcessor: PromptProcessing {
        struct Call {
            let prompt: String
            let providerOverride: String?
            let cloudModelOverride: String?
        }
        var selectedProviderId: String
        var selectedCloudModel: String
        private(set) var calls: [Call] = []
        /// Per-call-index responder; defaults to a valid language code so the detection catalog resolves.
        var responder: (Int) -> String = { _ in "de" }

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
            calls.append(Call(prompt: prompt, providerOverride: providerOverride, cloudModelOverride: cloudModelOverride))
            return responder(calls.count)
        }
    }

    // MARK: - Fixtures

    private func makeDefaults() -> UserDefaults {
        let suite = "MeetingModelRouterTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return defaults
    }

    private func makeVault() -> ObsidianVaultService {
        ObsidianVaultService(defaults: makeDefaults())
    }

    private func makeStore(prefix: String = "ModelRouter") throws -> MeetingService {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: prefix)
        addTeardownBlock { TestSupport.remove(dir) }
        return MeetingService(appSupportDirectory: dir)
    }

    private func makeMeeting(on service: MeetingService, texts: [String] = ["Short transcript."]) -> Meeting {
        let meeting = service.createMeeting(title: "Analysis", source: .adHoc, state: .completed)
        var start = 0.0
        service.appendStableSegments(
            texts.map { text in
                defer { start += 2 }
                return TranscriptionSegment(text: text, start: start, end: start + 2)
            },
            to: meeting
        )
        return meeting
    }

    private func makeTemplate(providerType: String? = nil, cloudModel: String? = nil) -> PromptAction {
        PromptAction(
            name: "T",
            prompt: "Summarize this.",
            providerType: providerType,
            cloudModel: cloudModel,
            surfaceRaw: PromptSurface.meeting.rawValue,
            meetingKindRaw: MeetingOutputKind.summary.rawValue
        )
    }

    // MARK: - Router: precedence ladder (template > purpose > app default)

    func testTemplateWinsOverPurposeAndGlobal() {
        let defaults = makeDefaults()
        defaults.set("purpose-p", forKey: UserDefaultsKeys.meetingsModelSummariesProviderId)
        defaults.set("purpose-m", forKey: UserDefaultsKeys.meetingsModelSummariesModel)
        let router = MeetingModelRouter(processor: StubProcessor(), defaults: defaults)

        XCTAssertEqual(
            router.overrideProvider(for: .summariesAnalysis, templateProvider: "tmpl-p"), "tmpl-p"
        )
        XCTAssertEqual(
            router.effectiveProvider(for: .summariesAnalysis, templateProvider: "tmpl-p"), "tmpl-p"
        )
        XCTAssertEqual(
            router.effectiveModel(for: .summariesAnalysis, templateModel: "tmpl-m"), "tmpl-m"
        )
    }

    func testPurposeWinsOverGlobal() {
        let defaults = makeDefaults()
        defaults.set("purpose-p", forKey: UserDefaultsKeys.meetingsModelSummariesProviderId)
        let router = MeetingModelRouter(processor: StubProcessor(), defaults: defaults)

        // No template ⇒ the purpose rung wins over the app default, for both the call override and the
        // effective (provenance) value.
        XCTAssertEqual(router.overrideProvider(for: .summariesAnalysis), "purpose-p")
        XCTAssertEqual(router.effectiveProvider(for: .summariesAnalysis), "purpose-p")
    }

    func testEmptyPurposeTracksAppDefaultLive() {
        let defaults = makeDefaults()
        let processor = StubProcessor(provider: "global-provider", model: "global-model")
        let router = MeetingModelRouter(processor: processor, defaults: defaults)

        // "Use app default": the override is nil (passthrough — the processor inherits its own
        // selection), while the effective value resolves to the live app default.
        XCTAssertNil(router.overrideProvider(for: .summariesAnalysis))
        XCTAssertNil(router.overrideModel(for: .summariesAnalysis))
        XCTAssertEqual(router.effectiveProvider(for: .summariesAnalysis), "global-provider")
        XCTAssertEqual(router.effectiveModel(for: .summariesAnalysis), "global-model")

        // Changing the app default is reflected live (nothing is snapshotted).
        processor.selectedProviderId = "changed-provider"
        XCTAssertEqual(router.effectiveProvider(for: .summariesAnalysis), "changed-provider")
    }

    func testProviderAndModelDimensionsResolveIndependently() {
        let defaults = makeDefaults()
        defaults.set("purpose-m", forKey: UserDefaultsKeys.meetingsModelSummariesModel)
        let router = MeetingModelRouter(processor: StubProcessor(), defaults: defaults)

        // Only the model rung is set at the purpose level; the provider falls through to the app default.
        XCTAssertNil(router.overrideProvider(for: .summariesAnalysis))
        XCTAssertEqual(router.overrideModel(for: .summariesAnalysis), "purpose-m")
        XCTAssertEqual(router.effectiveProvider(for: .summariesAnalysis), "global-provider")
        XCTAssertEqual(router.effectiveModel(for: .summariesAnalysis), "purpose-m")
    }

    func testGlobalFallbackEngagesOnlyAtAppDefaultRung() {
        // [B6/#859] The global LLM fallback priority list lives inside PromptProcessingService and is
        // consulted *only* when it receives `process(providerOverride: nil)` — an explicit override pins a
        // single candidate and bypasses the fallback list entirely (verified against the real service in
        // PromptProcessingModelResolutionTests). The router's job is therefore to emit a nil override at,
        // and only at, the app-default rung. This test locks that contract across every higher rung.
        let defaults = makeDefaults()
        let router = MeetingModelRouter(processor: StubProcessor(), defaults: defaults)

        // App-default rung (no purpose/template/one-shot): nil override ⇒ fallback list engages.
        XCTAssertNil(router.overrideProvider(for: .summariesAnalysis))
        XCTAssertNil(router.overrideModel(for: .summariesAnalysis))

        // One-shot rung: concrete override ⇒ fallback bypassed.
        XCTAssertEqual(
            router.overrideProvider(for: .summariesAnalysis, oneShotProvider: "oneshot-p"), "oneshot-p"
        )

        // Template rung: concrete override ⇒ fallback bypassed.
        XCTAssertEqual(
            router.overrideProvider(for: .summariesAnalysis, templateProvider: "tmpl-p"), "tmpl-p"
        )

        // Purpose rung: concrete override ⇒ fallback bypassed.
        defaults.set("purpose-p", forKey: UserDefaultsKeys.meetingsModelSummariesProviderId)
        XCTAssertEqual(router.overrideProvider(for: .summariesAnalysis), "purpose-p")

        // With the purpose set, the app-default rung no longer applies, so a nil override is never emitted
        // for this purpose ⇒ the fallback list can never engage over an explicit purpose selection.
        XCTAssertNotNil(router.overrideProvider(for: .summariesAnalysis))
    }

    func testWhitespaceOnlyPurposeIsTreatedAsUnset() {
        let defaults = makeDefaults()
        defaults.set("   ", forKey: UserDefaultsKeys.meetingsModelSummariesProviderId)
        let router = MeetingModelRouter(processor: StubProcessor(), defaults: defaults)

        XCTAssertNil(router.overrideProvider(for: .summariesAnalysis))
        XCTAssertEqual(router.effectiveProvider(for: .summariesAnalysis), "global-provider")
    }

    func testEffectiveIsNilWhenEvenAppDefaultEmpty() {
        let defaults = makeDefaults()
        let router = MeetingModelRouter(processor: StubProcessor(provider: "", model: ""), defaults: defaults)

        XCTAssertNil(router.effectiveProvider(for: .qa))
        XCTAssertNil(router.effectiveModel(for: .qa))
    }

    func testLanguageDetectionReusesLegacyKeys() {
        // The languageDetection purpose maps to the pre-existing detection keys (back-compat, plan D9).
        XCTAssertEqual(
            MeetingModelPurpose.languageDetection.providerDefaultsKey,
            UserDefaultsKeys.meetingsLanguageDetectionProviderId
        )
        XCTAssertEqual(
            MeetingModelPurpose.languageDetection.modelDefaultsKey,
            UserDefaultsKeys.meetingsLanguageDetectionModel
        )

        let defaults = makeDefaults()
        defaults.set("det-p", forKey: UserDefaultsKeys.meetingsLanguageDetectionProviderId)
        let router = MeetingModelRouter(processor: StubProcessor(), defaults: defaults)
        XCTAssertEqual(router.overrideProvider(for: .languageDetection), "det-p")
    }

    func testEveryPurposeHasDistinctKeys() {
        var seen = Set<String>()
        for purpose in MeetingModelPurpose.allCases {
            XCTAssertTrue(seen.insert(purpose.providerDefaultsKey).inserted, "duplicate provider key for \(purpose)")
            XCTAssertTrue(seen.insert(purpose.modelDefaultsKey).inserted, "duplicate model key for \(purpose)")
        }
    }

    // MARK: - Service integration: provenance equals the effective value

    func testGeneratedOutputRecordsPurposeAsProvenance() async throws {
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

        let output = try await llm.generateOutput(for: meeting, using: makeTemplate())

        // The call used the purpose override, and provenance records the same effective value.
        XCTAssertEqual(stub.calls.first?.providerOverride, "purpose-p")
        XCTAssertEqual(stub.calls.first?.cloudModelOverride, "purpose-m")
        XCTAssertEqual(output.providerUsed, "purpose-p")
        XCTAssertEqual(output.modelUsed, "purpose-m")
    }

    func testTemplateBeatsPurposeInCallAndProvenance() async throws {
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
            for: meeting, using: makeTemplate(providerType: "tmpl-p", cloudModel: "tmpl-m")
        )

        XCTAssertEqual(stub.calls.first?.providerOverride, "tmpl-p")
        XCTAssertEqual(stub.calls.first?.cloudModelOverride, "tmpl-m")
        XCTAssertEqual(output.providerUsed, "tmpl-p")
        XCTAssertEqual(output.modelUsed, "tmpl-m")
    }

    func testEmptyPurposeAndNoTemplateRecordsAppDefault() async throws {
        let defaults = makeDefaults() // no purpose keys
        let service = try makeStore()
        let stub = StubProcessor(provider: "global-provider", model: "global-model")
        let router = MeetingModelRouter(processor: stub, defaults: defaults)
        let llm = MeetingLLMService(
            meetingService: service, vaultService: makeVault(), processor: stub, modelRouter: router
        )
        let meeting = makeMeeting(on: service)

        let output = try await llm.generateOutput(for: meeting, using: makeTemplate())

        // Passthrough: the call inherits the app default (nil override), and provenance records the
        // effective app-default value.
        XCTAssertNil(stub.calls.first?.providerOverride)
        XCTAssertNil(stub.calls.first?.cloudModelOverride)
        XCTAssertEqual(output.providerUsed, "global-provider")
        XCTAssertEqual(output.modelUsed, "global-model")
    }

    // MARK: - Q&A honors the purpose setting

    func testQuestionAnswerHonorsQAPurpose() async throws {
        let defaults = makeDefaults()
        defaults.set("qa-p", forKey: UserDefaultsKeys.meetingsModelQAProviderId)
        defaults.set("qa-m", forKey: UserDefaultsKeys.meetingsModelQAModel)
        let service = try makeStore()
        let stub = StubProcessor()
        let router = MeetingModelRouter(processor: stub, defaults: defaults)
        let llm = MeetingLLMService(
            meetingService: service, vaultService: makeVault(), processor: stub, modelRouter: router
        )
        let meeting = makeMeeting(on: service, texts: ["We shipped the release."])

        _ = try await llm.answerQuestion(for: meeting, question: "What happened?")

        XCTAssertEqual(stub.calls.first?.providerOverride, "qa-p")
        XCTAssertEqual(stub.calls.first?.cloudModelOverride, "qa-m")
    }

    // MARK: - Related-docs judge honors the purpose setting

    func testRelatedDocsJudgeHonorsPurpose() async throws {
        let defaults = makeDefaults()
        defaults.set("judge-p", forKey: UserDefaultsKeys.meetingsModelRelatedDocsProviderId)
        defaults.set("judge-m", forKey: UserDefaultsKeys.meetingsModelRelatedDocsModel)
        let service = try makeStore(prefix: "ModelRouterJudge")

        // A minimal connected vault with one candidate note matching the meeting query.
        let vaultDir = try TestSupport.makeTemporaryDirectory(prefix: "ModelRouterJudgeVault")
        addTeardownBlock { TestSupport.remove(vaultDir) }
        let noteURL = vaultDir.appendingPathComponent("Notes/Acme.md")
        try FileManager.default.createDirectory(at: noteURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# Acme\nacme roadmap notes".write(to: noteURL, atomically: true, encoding: .utf8)
        let vault = ObsidianVaultService(defaults: defaults)
        vault.connect(to: vaultDir.path)

        let store = MeetingFolderMetadataStore(defaults: defaults)
        let stub = StubProcessor()
        stub.responder = { _ in "NONE" } // valid judge reply — success, keep zero
        let router = MeetingModelRouter(processor: stub, defaults: defaults)
        let docs = MeetingRelatedDocsService(
            meetingService: service,
            vaultService: vault,
            folderMetadataStore: store,
            processor: stub,
            modelRouter: router
        )
        let meeting = service.createMeeting(title: "Acme", source: .calendar, state: .scheduled)

        try await docs.discoverRelated(for: meeting)

        XCTAssertEqual(stub.calls.count, 1, "the judge ran once over the uncovered candidate")
        XCTAssertEqual(stub.calls.first?.providerOverride, "judge-p")
        XCTAssertEqual(stub.calls.first?.cloudModelOverride, "judge-m")
    }

    // MARK: - Detection honors the purpose (legacy keys) — back-compat

    func testDetectionHonorsLegacyDetectionKeys() async throws {
        let defaults = makeDefaults()
        defaults.set("det-p", forKey: UserDefaultsKeys.meetingsLanguageDetectionProviderId)
        defaults.set("det-m", forKey: UserDefaultsKeys.meetingsLanguageDetectionModel)
        let service = try makeStore(prefix: "ModelRouterDetect")
        let stub = StubProcessor()
        stub.responder = { _ in "de" } // a recognized language code so detection persists
        // No router injected: MeetingLanguageService builds one over the same `defaults`.
        let detector = MeetingLanguageService(
            meetingService: service,
            processor: stub,
            jobQueue: JobQueueService(),
            defaults: defaults
        )
        let meeting = makeMeeting(on: service, texts: ["Guten Tag, wie geht es Ihnen heute?"])

        try await detector.detectLanguage(for: meeting)

        XCTAssertEqual(stub.calls.first?.providerOverride, "det-p")
        XCTAssertEqual(stub.calls.first?.cloudModelOverride, "det-m")
        XCTAssertEqual(meeting.languageCode, "de")
    }
}
