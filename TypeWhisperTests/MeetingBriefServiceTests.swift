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
}
