import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

/// Unit tests for the pre-meeting brief service (plan M5): prior-meeting + knowledge-base context
/// assembly, single-turn LLM call, `.brief` persistence, and graceful degradation. The LLM is
/// stubbed via the `PromptProcessing` seam; the vault is a temp directory.
@MainActor
final class MeetingBriefServiceTests: XCTestCase {
    // MARK: - Stub processor

    @MainActor
    private final class StubProcessor: PromptProcessing {
        struct Call {
            let prompt: String
            let text: String
            let providerOverride: String?
            let cloudModelOverride: String?
            let temperatureDirective: PluginLLMTemperatureDirective
            let skipMemoryInjection: Bool
        }

        var selectedProviderId = "brief-provider"
        var selectedCloudModel = "brief-model"
        private(set) var calls: [Call] = []
        var errorToThrow: Error?
        var response = "BRIEF_RESULT"

        func process(
            prompt: String,
            text: String,
            providerOverride: String?,
            cloudModelOverride: String?,
            temperatureDirective: PluginLLMTemperatureDirective,
            skipMemoryInjection: Bool
        ) async throws -> String {
            calls.append(Call(
                prompt: prompt,
                text: text,
                providerOverride: providerOverride,
                cloudModelOverride: cloudModelOverride,
                temperatureDirective: temperatureDirective,
                skipMemoryInjection: skipMemoryInjection
            ))
            if let errorToThrow { throw errorToThrow }
            return response
        }
    }

    // MARK: - Fixtures

    private func makeDefaults() -> UserDefaults {
        let suite = "MeetingBriefServiceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return defaults
    }

    private func makeService() throws -> MeetingService {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "MeetingBrief")
        addTeardownBlock { TestSupport.remove(dir) }
        return MeetingService(appSupportDirectory: dir)
    }

    /// An empty prompt store (no meeting templates) into which brief templates can be added.
    private func makePromptActionService(defaults: UserDefaults) throws -> PromptActionService {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "MeetingBriefPrompts")
        addTeardownBlock { TestSupport.remove(dir) }
        return PromptActionService(appSupportDirectory: dir, defaults: defaults)
    }

    /// Add a single `.brief` meeting template with the given prompt and optional overrides.
    @discardableResult
    private func addBriefTemplate(
        to prompts: PromptActionService,
        prompt: String,
        provider: String? = nil,
        model: String? = nil,
        temperatureMode: PluginLLMTemperatureMode = .inheritProviderSetting,
        temperatureValue: Double? = nil
    ) throws -> PromptAction {
        let spec = PromptTemplateSpec(
            surface: .meeting,
            name: "Brief Template",
            prompt: prompt,
            meetingKind: .brief,
            providerType: provider,
            cloudModel: model,
            temperatureMode: temperatureMode,
            temperatureValue: temperatureValue
        )
        return try XCTUnwrap(prompts.addMeetingTemplate(spec))
    }

    /// A temp vault with a single note that matches an "Acme Sync" query.
    private func makeConnectedVault(defaults: UserDefaults) throws -> ObsidianVaultService {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "MeetingBriefVault")
        addTeardownBlock { TestSupport.remove(dir) }
        let note = dir.appendingPathComponent("Acme Overview.md")
        try """
        ---
        tags: [acme]
        ---
        # Acme Overview
        Background on the acme sync roadmap. VAULT_MARKER_XYZ
        """.write(to: note, atomically: true, encoding: .utf8)

        let service = ObsidianVaultService(defaults: defaults)
        service.connect(to: dir.path)
        return service
    }

    /// Target meeting plus two prior meetings that match it (one by shared attendee email, one by
    /// series id), each carrying a summary output with a unique marker.
    private func seedMeetings(on service: MeetingService) -> Meeting {
        let target = service.createMeeting(
            title: "Acme Sync",
            source: .calendar,
            state: .scheduled,
            startDate: Date(),
            seriesID: "series-1",
            attendees: [Attendee(name: "Marco", email: "marco@x.com")]
        )

        let byEmail = service.createMeeting(
            title: "Acme Sync (last week)",
            source: .calendar,
            state: .completed,
            startDate: Date().addingTimeInterval(-7 * 86_400),
            attendees: [Attendee(name: "Marco", email: "marco@x.com")]
        )
        service.addOutput(to: byEmail, kind: .summary, content: "PRIOR_MARKER_B: agreed to ship.")

        let bySeries = service.createMeeting(
            title: "Acme Sync (two weeks ago)",
            source: .calendar,
            state: .completed,
            startDate: Date().addingTimeInterval(-14 * 86_400),
            seriesID: "series-1"
        )
        service.addOutput(to: bySeries, kind: .summary, content: "PRIOR_MARKER_C: open questions.")

        return target
    }

    // MARK: - Tests

    func testBriefMergesPriorMeetingsAndVaultPassage() async throws {
        let defaults = makeDefaults()
        let service = try makeService()
        let vault = try makeConnectedVault(defaults: defaults)
        let stub = StubProcessor()
        let brief = MeetingBriefService(meetingService: service, vaultService: vault, processor: stub)

        let target = seedMeetings(on: service)
        let output = try await brief.generateBrief(for: target)

        // Exactly one single-turn call, no template overrides, memory injection skipped.
        XCTAssertEqual(stub.calls.count, 1)
        let call = try XCTUnwrap(stub.calls.first)
        XCTAssertNil(call.providerOverride)
        XCTAssertNil(call.cloudModelOverride)
        XCTAssertTrue(call.skipMemoryInjection)

        // The context merges both prior-meeting summaries and the vault passage.
        XCTAssertTrue(call.text.contains("PRIOR_MARKER_B"))
        XCTAssertTrue(call.text.contains("PRIOR_MARKER_C"))
        XCTAssertTrue(call.text.contains("VAULT_MARKER_XYZ"))

        // Persisted as a `.brief` output with global-selection provenance.
        XCTAssertEqual(output.kind, .brief)
        XCTAssertEqual(output.content, "BRIEF_RESULT")
        XCTAssertNil(output.templateID)
        XCTAssertEqual(output.providerUsed, "brief-provider")
        XCTAssertEqual(output.modelUsed, "brief-model")
        XCTAssertEqual(target.outputs.filter { $0.kind == .brief }.count, 1)
        XCTAssertEqual(service.latestOutput(ofKind: .brief, for: target)?.id, output.id)
    }

    func testBriefWithoutVaultFallsBackToPriorMeetingsOnly() async throws {
        let service = try makeService()
        // A disconnected vault (no defaults connection) → prior meetings only.
        let vault = ObsidianVaultService(defaults: makeDefaults())
        let stub = StubProcessor()
        let brief = MeetingBriefService(meetingService: service, vaultService: vault, processor: stub)

        let target = seedMeetings(on: service)
        let output = try await brief.generateBrief(for: target)

        let call = try XCTUnwrap(stub.calls.first)
        XCTAssertTrue(call.text.contains("PRIOR_MARKER_B"))
        XCTAssertTrue(call.text.contains("PRIOR_MARKER_C"))
        XCTAssertFalse(call.text.contains("VAULT_MARKER_XYZ"))
        XCTAssertEqual(output.kind, .brief)
    }

    func testBriefWithVaultButNoPriorMeetingsUsesKnowledgeBaseOnly() async throws {
        let defaults = makeDefaults()
        let service = try makeService()
        let vault = try makeConnectedVault(defaults: defaults)
        let stub = StubProcessor()
        let brief = MeetingBriefService(meetingService: service, vaultService: vault, processor: stub)

        // A lone meeting whose title matches the vault note, with no prior related meetings
        // (no series, no shared-attendee history). Degrades to knowledge-base-only (M5 finding 4).
        let target = service.createMeeting(title: "Acme Sync", source: .adHoc, state: .scheduled)
        let output = try await brief.generateBrief(for: target)

        XCTAssertEqual(stub.calls.count, 1)
        let call = try XCTUnwrap(stub.calls.first)
        // The vault passage is present; no prior-meeting markers leak in.
        XCTAssertTrue(call.text.contains("VAULT_MARKER_XYZ"))
        XCTAssertFalse(call.text.contains("PRIOR_MARKER_B"))
        XCTAssertFalse(call.text.contains("PRIOR_MARKER_C"))
        XCTAssertEqual(output.kind, .brief)
        XCTAssertEqual(service.latestOutput(ofKind: .brief, for: target)?.id, output.id)
    }

    func testInsufficientContextThrowsAndPersistsNothing() async throws {
        let service = try makeService()
        let vault = ObsidianVaultService(defaults: makeDefaults())
        let stub = StubProcessor()
        let brief = MeetingBriefService(meetingService: service, vaultService: vault, processor: stub)

        // A lone meeting with no prior related meetings and no vault → no context.
        let lonely = service.createMeeting(title: "Solo", source: .adHoc, state: .scheduled)

        do {
            _ = try await brief.generateBrief(for: lonely)
            XCTFail("Expected insufficientContext")
        } catch {
            XCTAssertEqual(error as? MeetingBriefError, .insufficientContext)
        }
        XCTAssertTrue(stub.calls.isEmpty)
        XCTAssertTrue(lonely.outputs.isEmpty)
    }

    func testFailedLLMCallPersistsNoBrief() async throws {
        let service = try makeService()
        let vault = ObsidianVaultService(defaults: makeDefaults())
        let stub = StubProcessor()
        struct Boom: Error {}
        stub.errorToThrow = Boom()
        let brief = MeetingBriefService(meetingService: service, vaultService: vault, processor: stub)

        let target = seedMeetings(on: service)
        do {
            _ = try await brief.generateBrief(for: target)
            XCTFail("Expected the stubbed failure to propagate")
        } catch {
            XCTAssertTrue(error is Boom)
        }
        XCTAssertTrue(target.outputs.filter { $0.kind == .brief }.isEmpty)
    }

    // MARK: - M6: editable brief template

    /// Plan M6 (DA1/DA2): the resolved `.brief` template's prompt becomes the brief's system prompt,
    /// while the assembled prior-meeting + KB context stays the `text` argument (fixed assembly).
    func testBriefUsesResolvedTemplatePromptAsSystemPrompt() async throws {
        let defaults = makeDefaults()
        let service = try makeService()
        let vault = try makeConnectedVault(defaults: defaults)
        let prompts = try makePromptActionService(defaults: defaults)
        try addBriefTemplate(to: prompts, prompt: "CUSTOM_BRIEF_INSTRUCTION")
        let stub = StubProcessor()
        let brief = MeetingBriefService(
            meetingService: service, vaultService: vault, processor: stub, promptActionService: prompts
        )

        let target = seedMeetings(on: service)
        let output = try await brief.generateBrief(for: target)

        let call = try XCTUnwrap(stub.calls.first)
        // The template prompt is the system prompt (no language set → unchanged).
        XCTAssertEqual(call.prompt, "CUSTOM_BRIEF_INSTRUCTION")
        // Context assembly is unchanged — prior-meeting + KB blocks still ride in `text`.
        XCTAssertTrue(call.text.contains("PRIOR_MARKER_B"))
        XCTAssertTrue(call.text.contains("VAULT_MARKER_XYZ"))
        // The output records the resolving template's id.
        XCTAssertEqual(output.templateID, prompts.meetingTemplates(ofKind: .brief).first?.id)
    }

    /// Plan M6 (DA2): with no `.brief` template present the brief falls back to the localized default
    /// system prompt and still generates.
    func testBriefFallsBackToDefaultWhenNoTemplate() async throws {
        let defaults = makeDefaults()
        let service = try makeService()
        let vault = try makeConnectedVault(defaults: defaults)
        // A prompt store with zero brief templates (fresh, no migration).
        let prompts = try makePromptActionService(defaults: defaults)
        let stub = StubProcessor()
        let brief = MeetingBriefService(
            meetingService: service, vaultService: vault, processor: stub, promptActionService: prompts
        )

        let target = seedMeetings(on: service)
        let output = try await brief.generateBrief(for: target)

        let call = try XCTUnwrap(stub.calls.first)
        XCTAssertEqual(call.prompt, String(localized: "meetings.brief.systemPrompt"))
        XCTAssertNil(call.providerOverride)
        XCTAssertNil(call.cloudModelOverride)
        XCTAssertNil(output.templateID)
        XCTAssertEqual(output.kind, .brief)
    }

    /// Plan M6 (DA1): the meeting's language directive is appended on top of the resolved template
    /// prompt (and also on the fallback default).
    func testLanguageDirectiveAppendedOnTopOfTemplateAndFallback() async throws {
        let defaults = makeDefaults()
        let service = try makeService()
        let vault = try makeConnectedVault(defaults: defaults)

        // Template path.
        let prompts = try makePromptActionService(defaults: defaults)
        try addBriefTemplate(to: prompts, prompt: "CUSTOM_BRIEF_INSTRUCTION")
        let stub = StubProcessor()
        let brief = MeetingBriefService(
            meetingService: service, vaultService: vault, processor: stub, promptActionService: prompts
        )
        let target = seedMeetings(on: service)
        service.setLanguage("de", for: target)
        _ = try await brief.generateBrief(for: target)
        let templateCall = try XCTUnwrap(stub.calls.first)
        XCTAssertTrue(templateCall.prompt.hasPrefix("CUSTOM_BRIEF_INSTRUCTION"))
        XCTAssertTrue(templateCall.prompt.contains("German (de)"))

        // Fallback path (no template) still carries the directive.
        let promptsEmpty = try makePromptActionService(defaults: defaults)
        let stub2 = StubProcessor()
        let briefFallback = MeetingBriefService(
            meetingService: service, vaultService: vault, processor: stub2, promptActionService: promptsEmpty
        )
        let target2 = seedMeetings(on: service)
        service.setLanguage("de", for: target2)
        _ = try await briefFallback.generateBrief(for: target2)
        let fallbackCall = try XCTUnwrap(stub2.calls.first)
        XCTAssertTrue(fallbackCall.prompt.hasPrefix(String(localized: "meetings.brief.systemPrompt")))
        XCTAssertTrue(fallbackCall.prompt.contains("German (de)"))
    }

    /// Plan M6 (DA2): the resolved template's provider/model/temperature overrides are forwarded to
    /// the processor and recorded as the brief's provenance.
    func testTemplateProviderModelTemperatureOverridesForwarded() async throws {
        let defaults = makeDefaults()
        let service = try makeService()
        let vault = try makeConnectedVault(defaults: defaults)
        let prompts = try makePromptActionService(defaults: defaults)
        try addBriefTemplate(
            to: prompts,
            prompt: "CUSTOM_BRIEF_INSTRUCTION",
            provider: "anthropic",
            model: "claude-3",
            temperatureMode: .custom,
            temperatureValue: 0.25
        )
        let stub = StubProcessor()
        let brief = MeetingBriefService(
            meetingService: service, vaultService: vault, processor: stub, promptActionService: prompts
        )

        let target = seedMeetings(on: service)
        let output = try await brief.generateBrief(for: target)

        let call = try XCTUnwrap(stub.calls.first)
        XCTAssertEqual(call.providerOverride, "anthropic")
        XCTAssertEqual(call.cloudModelOverride, "claude-3")
        XCTAssertEqual(call.temperatureDirective, .custom(0.25))
        // Provenance prefers the template overrides over the global selection.
        XCTAssertEqual(output.providerUsed, "anthropic")
        XCTAssertEqual(output.modelUsed, "claude-3")
    }

    /// [M4 carried minor] Brief provenance follows the purpose rung. Mirrors the summaries-purpose
    /// provenance test against the brief service: with a `.brief` template carrying **no** provider/model
    /// and the `briefs` purpose keys set, the call uses the purpose override and the persisted brief
    /// records the purpose values (`template ?? purpose ?? app default` — the template rung is empty so
    /// the purpose wins).
    func testBriefRecordsPurposeAsProvenanceWhenTemplateHasNoModel() async throws {
        let defaults = makeDefaults()
        defaults.set("purpose-p", forKey: UserDefaultsKeys.meetingsModelBriefsProviderId)
        defaults.set("purpose-m", forKey: UserDefaultsKeys.meetingsModelBriefsModel)
        let service = try makeService()
        let vault = try makeConnectedVault(defaults: defaults)
        let prompts = try makePromptActionService(defaults: defaults)
        // A template without provider/model, so the briefs purpose rung applies.
        try addBriefTemplate(to: prompts, prompt: "CUSTOM_BRIEF_INSTRUCTION")
        let stub = StubProcessor()
        let router = MeetingModelRouter(processor: stub, defaults: defaults)
        let brief = MeetingBriefService(
            meetingService: service, vaultService: vault, processor: stub,
            promptActionService: prompts, modelRouter: router
        )

        let target = seedMeetings(on: service)
        let output = try await brief.generateBrief(for: target)

        // The call used the purpose override, and provenance records the same effective value.
        XCTAssertEqual(stub.calls.first?.providerOverride, "purpose-p")
        XCTAssertEqual(stub.calls.first?.cloudModelOverride, "purpose-m")
        XCTAssertEqual(output.providerUsed, "purpose-p")
        XCTAssertEqual(output.modelUsed, "purpose-m")
    }

    // MARK: - M8: curated related-docs consumption (Amendment 2, DB5)

    /// A connected vault with three equally query-matching "Acme" notes, each carrying a unique marker
    /// so the assembled KB block reveals exactly which notes were retrieved.
    private func makeCuratedVault(defaults: UserDefaults) throws -> ObsidianVaultService {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "MeetingBriefCuratedVault")
        addTeardownBlock { TestSupport.remove(dir) }
        func write(_ name: String, marker: String) throws {
            try """
            # \(name)
            Background on the acme sync roadmap. \(marker)
            """.write(to: dir.appendingPathComponent("\(name).md"), atomically: true, encoding: .utf8)
        }
        try write("Acme One", marker: "CURATED_ONE")
        try write("Acme Two", marker: "CURATED_TWO")
        try write("Acme Three", marker: "UNCURATED_THREE")
        let service = ObsidianVaultService(defaults: defaults)
        service.connect(to: dir.path)
        return service
    }

    /// The brief's KB block draws **only** from the meeting's curated related notes (discovered ∪
    /// manual, minus exclusions) threaded into `retrievalScope`, never the whole vault (Amendment 2,
    /// DB5). Curates two notes and excludes one, then asserts only the surviving curated note reaches
    /// the `text` argument — a non-curated vault note and the excluded one are both absent. This
    /// exercises the `curatedNotePaths`/`excludedNotePaths` wiring that a whole-vault fallback would
    /// silently pass.
    func testBriefKnowledgeBaseDrawsOnlyFromCuratedNotesHonoringExclusions() async throws {
        let defaults = makeDefaults()
        let service = try makeService()
        let vault = try makeCuratedVault(defaults: defaults)
        let folderStore = MeetingFolderMetadataStore(defaults: defaults)
        let stub = StubProcessor()
        let brief = MeetingBriefService(
            meetingService: service,
            vaultService: vault,
            processor: stub,
            folderMetadataStore: folderStore
        )

        let target = service.createMeeting(title: "Acme Sync", source: .adHoc, state: .scheduled)
        // Curate One and Two, then remove Two → curated = {One}, excluded = {Two}.
        service.addManualRelatedNote("Acme One.md", for: target)
        service.addManualRelatedNote("Acme Two.md", for: target)
        service.removeRelatedNote("Acme Two.md", for: target)

        _ = try await brief.generateBrief(for: target)

        let call = try XCTUnwrap(stub.calls.first)
        XCTAssertTrue(call.text.contains("CURATED_ONE"))
        XCTAssertFalse(call.text.contains("CURATED_TWO"), "an excluded curated note must not be retrieved")
        XCTAssertFalse(call.text.contains("UNCURATED_THREE"), "a non-curated vault note must not leak in")
    }
}
