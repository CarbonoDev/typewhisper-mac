import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

/// Unit tests for agentic related-document discovery (Amendment 2, M8): staged candidate priority,
/// the fail-closed judge output contract (DB3), budget caps (DB7), the DB9 "judge never runs inside
/// brief generation" invariant, and `relatedDiscovery` job wiring. The LLM is stubbed via the
/// `PromptProcessing` seam; the vault is a temp directory.
@MainActor
final class MeetingRelatedDocsServiceTests: XCTestCase {
    // MARK: - Stub processor

    @MainActor
    private final class StubProcessor: PromptProcessing {
        struct Call { let prompt: String; let text: String }
        var selectedProviderId = "judge-provider"
        var selectedCloudModel = "judge-model"
        private(set) var calls: [Call] = []
        var errorToThrow: Error?
        var response = "NONE"

        func process(
            prompt: String,
            text: String,
            providerOverride: String?,
            cloudModelOverride: String?,
            temperatureDirective: PluginLLMTemperatureDirective,
            skipMemoryInjection: Bool
        ) async throws -> String {
            calls.append(Call(prompt: prompt, text: text))
            if let errorToThrow { throw errorToThrow }
            return response
        }
    }

    // MARK: - Fixtures

    private func makeDefaults() -> UserDefaults {
        let suite = "MeetingRelatedDocsServiceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return defaults
    }

    private func makeService() throws -> MeetingService {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "RelatedDocs")
        addTeardownBlock { TestSupport.remove(dir) }
        return MeetingService(appSupportDirectory: dir)
    }

    private func writeNote(_ relativePath: String, contents: String, in vault: URL) throws {
        let url = vault.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// A temp vault seeded with folder-attached, prefix-covered, manual, excluded, and free notes — all
    /// matching an "acme" query so lexical ranking surfaces every non-covered one.
    private func makeVault(defaults: UserDefaults) throws -> ObsidianVaultService {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "RelatedDocsVault")
        addTeardownBlock { TestSupport.remove(dir) }
        try writeNote("Acme/Roadmap.md", contents: "# Roadmap\nacme roadmap milestones", in: dir)          // folder-attached
        try writeNote("Projects/AcmeProj/Spec.md", contents: "# Spec\nacme project spec", in: dir)         // under attached folder
        try writeNote("Projects/Acme2/Other.md", contents: "# Other\nacme sibling lookalike", in: dir)     // look-alike, NOT covered
        try writeNote("Wider/Deal.md", contents: "# Deal\nacme deal terms", in: dir)                       // manual (covered)
        try writeNote("Wider/Excluded.md", contents: "# Excluded\nacme excluded note", in: dir)            // excluded (covered)
        try writeNote("Wider/Relevant.md", contents: "# Relevant\nacme relevant wider note", in: dir)      // free candidate
        let vault = ObsidianVaultService(defaults: defaults)
        vault.connect(to: dir.path)
        return vault
    }

    private func makeDocsService(
        service: MeetingService,
        vault: ObsidianVaultService,
        store: MeetingFolderMetadataStore,
        processor: StubProcessor,
        charBudget: Int = TranscriptContextBuilder.defaultCharBudget,
        maxCandidates: Int = 24,
        candidateExcerptCap: Int = 240
    ) -> MeetingRelatedDocsService {
        MeetingRelatedDocsService(
            meetingService: service,
            vaultService: vault,
            folderMetadataStore: store,
            processor: processor,
            charBudget: charBudget,
            maxCandidates: maxCandidates,
            candidateExcerptCap: candidateExcerptCap
        )
    }

    private func seedMeeting(on service: MeetingService, store: MeetingFolderMetadataStore) -> Meeting {
        let meeting = service.createMeeting(title: "Acme Sync", source: .calendar, state: .scheduled)
        service.setFolder("Clients/Acme", for: meeting)
        // Folder-attached context (stage a): one note + one folder prefix.
        store.attachNotes(["Acme/Roadmap.md"], to: "Clients/Acme")
        store.attachFolders(["Projects/AcmeProj"], to: "Clients/Acme")
        // Pre-existing manual + excluded per-meeting entries.
        service.addManualRelatedNote("Wider/Deal.md", for: meeting)
        service.removeRelatedNote("Wider/Excluded.md", for: meeting)
        return meeting
    }

    // MARK: - Staged candidate priority (DB2)

    func testJudgeSeesOnlyUncoveredWiderVaultCandidates() async throws {
        let defaults = makeDefaults()
        let service = try makeService()
        let vault = try makeVault(defaults: defaults)
        let store = MeetingFolderMetadataStore(defaults: defaults)
        let processor = StubProcessor()
        processor.response = "NONE"
        let docs = makeDocsService(service: service, vault: vault, store: store, processor: processor)
        let meeting = seedMeeting(on: service, store: store)

        try await docs.discoverRelated(for: meeting)

        // The candidate generation (stage b) excludes every covered path, exactly as the service builds
        // its exclusion sets: folder note ∪ manual ∪ excluded, plus attached folder prefixes.
        let candidates = vault.candidateNotes(
            query: "Acme Sync",
            limit: 24,
            excludingPaths: ["Acme/Roadmap.md", "Wider/Deal.md", "Wider/Excluded.md"],
            excludingFolderPrefixes: ["Projects/AcmeProj"],
            excerptCap: 240
        )
        let candidatePaths = Set(candidates.map(\.path))
        XCTAssertEqual(
            candidatePaths,
            ["Projects/Acme2/Other.md", "Wider/Relevant.md"],
            "only uncovered notes are candidates; Acme2 is not under the Acme prefix (component-wise)"
        )

        // And the judge input carries only those candidates (by title), never a covered note's title.
        let judgeInput = try XCTUnwrap(processor.calls.first?.text)
        XCTAssertTrue(judgeInput.contains("Other"))
        XCTAssertTrue(judgeInput.contains("Relevant"))
        XCTAssertFalse(judgeInput.contains("Roadmap"), "folder-attached note must not be judged")
        XCTAssertFalse(judgeInput.contains("Spec"), "note under attached folder prefix excluded")
        XCTAssertFalse(judgeInput.contains("Deal"), "existing manual note excluded")
        XCTAssertFalse(judgeInput.contains("Excluded"), "excluded path excluded")
    }

    // MARK: - Judge output contract (DB3) — static parse cases

    func testParseJudgeReplyContractCases() throws {
        // (i) integer list ⇒ those (0-based) indices, deduped/order-preserved.
        XCTAssertEqual(try MeetingRelatedDocsService.parseJudgeReply("2, 5", candidateCount: 6), [1, 4])
        XCTAssertEqual(try MeetingRelatedDocsService.parseJudgeReply("5\n2\n5", candidateCount: 6), [4, 1])
        // (ii) NONE sentinel (case/punctuation-insensitive) ⇒ success, zero kept.
        XCTAssertEqual(try MeetingRelatedDocsService.parseJudgeReply("NONE", candidateCount: 6), [])
        XCTAssertEqual(try MeetingRelatedDocsService.parseJudgeReply(" none. ", candidateCount: 6), [])
        // (iii) out-of-range integers ⇒ zero kept, still a success (not a throw).
        XCTAssertEqual(try MeetingRelatedDocsService.parseJudgeReply("99", candidateCount: 6), [])
        // (iv) prose with no integer ⇒ throws (fail-closed).
        XCTAssertThrowsError(try MeetingRelatedDocsService.parseJudgeReply("Here are the ones I think are relevant:", candidateCount: 6)) { error in
            XCTAssertEqual(error as? MeetingRelatedDocsError, .unparseableJudgeReply)
        }
    }

    /// The diagnostic log rendering (fail-closed path) flattens newlines and clips to the cap so a
    /// runaway reply can't spill unbounded content into the log.
    func testTruncatedForLogFlattensAndClips() {
        XCTAssertEqual(MeetingRelatedDocsService.truncatedForLog("  keep\nthis  "), "keep this")
        let long = String(repeating: "x", count: 500)
        let clipped = MeetingRelatedDocsService.truncatedForLog(long, limit: 200)
        XCTAssertEqual(clipped.count, 201, "200 chars + the ellipsis")
        XCTAssertTrue(clipped.hasSuffix("…"))
    }

    // MARK: - Judge output contract (DB3) — end-to-end persistence

    func testKeptCandidatesPersistedAsDiscovered() async throws {
        let defaults = makeDefaults()
        let service = try makeService()
        let vault = try makeVault(defaults: defaults)
        let store = MeetingFolderMetadataStore(defaults: defaults)
        let processor = StubProcessor()
        let docs = makeDocsService(service: service, vault: vault, store: store, processor: processor)
        let meeting = seedMeeting(on: service, store: store)

        // Keep candidate #1 (whatever it ranks to). Assert it's persisted `discovered` and is NOT a
        // covered path.
        processor.response = "1"
        try await docs.discoverRelated(for: meeting)

        let discovered = meeting.relatedNotePaths.filter { $0.provenance == .discovered }
        XCTAssertEqual(discovered.count, 1)
        let path = try XCTUnwrap(discovered.first?.path)
        XCTAssertFalse(["Acme/Roadmap.md", "Projects/AcmeProj/Spec.md", "Wider/Deal.md", "Wider/Excluded.md"].contains(path))
        XCTAssertNotNil(meeting.relatedDiscoveryAt)
        // Manual entry survives a discovery run.
        XCTAssertTrue(meeting.relatedNotePaths.contains { $0.provenanceRaw == "manual" && $0.path == "Wider/Deal.md" })
    }

    func testNoneReplyIsSuccessWithZeroKept() async throws {
        let defaults = makeDefaults()
        let service = try makeService()
        let vault = try makeVault(defaults: defaults)
        let store = MeetingFolderMetadataStore(defaults: defaults)
        let processor = StubProcessor()
        processor.response = "NONE"
        let docs = makeDocsService(service: service, vault: vault, store: store, processor: processor)
        let meeting = seedMeeting(on: service, store: store)

        try await docs.discoverRelated(for: meeting)  // must not throw
        XCTAssertTrue(meeting.relatedNotePaths.filter { $0.provenance == .discovered }.isEmpty)
        XCTAssertNotNil(meeting.relatedDiscoveryAt, "a successful empty run still stamps the timestamp")
    }

    func testUnparseableReplyFailsClosedAndPersistsNothing() async throws {
        let defaults = makeDefaults()
        let service = try makeService()
        let vault = try makeVault(defaults: defaults)
        let store = MeetingFolderMetadataStore(defaults: defaults)
        let processor = StubProcessor()
        processor.response = "I could not decide which are relevant."
        let docs = makeDocsService(service: service, vault: vault, store: store, processor: processor)
        let meeting = seedMeeting(on: service, store: store)

        do {
            try await docs.discoverRelated(for: meeting)
            XCTFail("expected the fail-closed judge to throw")
        } catch {
            XCTAssertEqual(error as? MeetingRelatedDocsError, .unparseableJudgeReply)
        }
        XCTAssertTrue(meeting.relatedNotePaths.filter { $0.provenance == .discovered }.isEmpty, "nothing persisted")
        XCTAssertNil(meeting.relatedDiscoveryAt, "timestamp not stamped on a failed run")
    }

    // MARK: - Budget caps (DB7)

    func testBudgetCapsClampCandidatesExcerptsAndInput() async throws {
        let defaults = makeDefaults()
        let service = try makeService()
        let vault = try makeVault(defaults: defaults)
        let store = MeetingFolderMetadataStore(defaults: defaults)
        let processor = StubProcessor()
        processor.response = "NONE"
        // Tiny caps: at most 2 candidates, 12-char excerpts, 400-char total input.
        let charBudget = 400
        let excerptCap = 12
        let docs = makeDocsService(
            service: service, vault: vault, store: store, processor: processor,
            charBudget: charBudget, maxCandidates: 2, candidateExcerptCap: excerptCap
        )
        let meeting = service.createMeeting(title: "Acme Sync", source: .calendar, state: .scheduled)

        // Candidate generation is capped independently of discovery too.
        let candidates = vault.candidateNotes(
            query: "acme", limit: 2, excludingPaths: [], excludingFolderPrefixes: [], excerptCap: excerptCap
        )
        XCTAssertLessThanOrEqual(candidates.count, 2, "candidate count clamped to maxCandidates")
        for candidate in candidates {
            XCTAssertLessThanOrEqual(candidate.excerpt.count, excerptCap, "excerpt truncated to cap")
        }

        try await docs.discoverRelated(for: meeting)
        let judgeInput = try XCTUnwrap(processor.calls.first?.text)
        XCTAssertLessThanOrEqual(judgeInput.count, charBudget, "assembled judge input truncated to charBudget")
    }

    // MARK: - DB9 invariant — the judge never runs inside brief generation

    func testBriefGenerationInvokesProcessOnceWithBriefPromptNeverJudge() async throws {
        let defaults = makeDefaults()
        let service = try makeService()
        let vault = try makeVault(defaults: defaults)
        let store = MeetingFolderMetadataStore(defaults: defaults)
        let processor = StubProcessor()
        processor.response = "BRIEF_BODY"

        let brief = MeetingBriefService(
            meetingService: service,
            vaultService: vault,
            processor: processor,
            promptActionService: nil,
            folderMetadataStore: store
        )

        // A meeting with a folder + candidates present so a naive impl might be tempted to judge.
        let meeting = service.createMeeting(
            title: "Acme Sync", source: .calendar, state: .scheduled,
            attendees: [Attendee(name: "Alex", email: "alex@acme.com")]
        )
        service.setFolder("Clients/Acme", for: meeting)
        // A prior meeting so the brief has context and won't throw insufficientContext.
        let prior = service.createMeeting(
            title: "Acme Sync", source: .calendar, state: .completed,
            attendees: [Attendee(name: "Alex", email: "alex@acme.com")]
        )
        service.addOutput(to: prior, kind: .summary, content: "Prior discussion of the acme roadmap.")

        _ = try await brief.generateBrief(for: meeting)

        XCTAssertEqual(processor.calls.count, 1, "brief generation is exactly one process() call")
        let judgePrompt = String(localized: "meetings.related.judge.systemPrompt")
        XCTAssertNotEqual(processor.calls.first?.prompt, judgePrompt, "the judge prompt is never used inside generateBrief")
    }

    // MARK: - Job wiring (DB1)

    func testRelatedDiscoveryIsOnLLMLaneAndDedupesAndPromotes() {
        XCTAssertEqual(MeetingJobKind.relatedDiscovery.lane, .llm)

        let queue = JobQueueService()
        let meetingID = UUID()
        // Hold the lane so both enqueues stay queued.
        let held = UUID()
        let first = queue.enqueue(kind: .relatedDiscovery, meetingID: meetingID, priority: .background) {}
        let second = queue.enqueue(kind: .relatedDiscovery, meetingID: meetingID, priority: .userInitiated) {}
        XCTAssertEqual(first, second, "(relatedDiscovery, meetingID) dedupe drops the second enqueue")
        // The surviving job is promoted to userInitiated by the second enqueue.
        let job = queue.jobs.first { $0.id == first }
        XCTAssertEqual(job?.priority, .userInitiated, "a user press promotes a queued background discovery")
        _ = held
    }
}
