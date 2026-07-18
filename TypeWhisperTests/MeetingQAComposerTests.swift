import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

/// Unit tests for in-meeting Q&A (plan M6): the pure `MeetingQAComposer` context assembly and the
/// `MeetingLLMService.answerQuestion` persistence/retrieval behavior. The LLM is stubbed through the
/// `PromptProcessing` seam; the vault is a temp directory.
@MainActor
final class MeetingQAComposerTests: XCTestCase {
    // MARK: - Stub processor

    @MainActor
    private final class StubProcessor: PromptProcessing {
        struct Call {
            let prompt: String
            let text: String
            let skipMemoryInjection: Bool
        }

        var selectedProviderId = "qa-provider"
        var selectedCloudModel = "qa-model"
        private(set) var calls: [Call] = []
        var errorToThrow: Error?
        var response = "ANSWER_TEXT"

        func process(
            prompt: String,
            text: String,
            providerOverride: String?,
            cloudModelOverride: String?,
            temperatureDirective: PluginLLMTemperatureDirective,
            skipMemoryInjection: Bool
        ) async throws -> String {
            calls.append(Call(prompt: prompt, text: text, skipMemoryInjection: skipMemoryInjection))
            if let errorToThrow { throw errorToThrow }
            return response
        }
    }

    // MARK: - Fixtures

    private func makeService() throws -> MeetingService {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "MeetingQA")
        addTeardownBlock { TestSupport.remove(dir) }
        return MeetingService(appSupportDirectory: dir)
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "MeetingQAComposerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return defaults
    }

    /// A disconnected vault (KB contributes nothing).
    private func makeDisconnectedVault() -> ObsidianVaultService {
        ObsidianVaultService(defaults: makeDefaults())
    }

    /// A temp vault with a single note matching an "acme roadmap" query, carrying a unique marker.
    private func makeConnectedVault() throws -> ObsidianVaultService {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "MeetingQAVault")
        addTeardownBlock { TestSupport.remove(dir) }
        let note = dir.appendingPathComponent("Acme.md")
        try """
        # Acme
        The acme roadmap notes. VAULT_MARKER_QA
        """.write(to: note, atomically: true, encoding: .utf8)
        let vault = ObsidianVaultService(defaults: makeDefaults())
        vault.connect(to: dir.path)
        return vault
    }

    private func seg(_ start: Double, _ text: String) -> TranscriptContextBuilder.Segment {
        TranscriptContextBuilder.Segment(start: start, text: text)
    }

    // MARK: - Composer: offset scoping

    func testComposerIncludesOnlySegmentsUpToOffset() {
        let text = MeetingQAComposer.compose(
            question: "What did we cover?",
            segments: [seg(0, "ALPHA point."), seg(60, "BRAVO point."), seg(120, "CHARLIE point.")],
            upTo: 90,
            priorTurns: [],
            knowledgePassages: [],
            charBudget: 16_000
        )
        XCTAssertTrue(text.contains("ALPHA"))
        XCTAssertTrue(text.contains("BRAVO"))
        XCTAssertFalse(text.contains("CHARLIE"), "a mid-meeting question must not see the future")
    }

    func testComposerNilOffsetIncludesEntireTranscript() {
        let text = MeetingQAComposer.compose(
            question: "What did we cover?",
            segments: [seg(0, "ALPHA point."), seg(60, "BRAVO point."), seg(120, "CHARLIE point.")],
            upTo: nil,
            priorTurns: [],
            knowledgePassages: [],
            charBudget: 16_000
        )
        XCTAssertTrue(text.contains("ALPHA") && text.contains("BRAVO") && text.contains("CHARLIE"))
    }

    // MARK: - Composer: char budget / relevance

    func testComposerRespectsCharBudgetAndKeepsMostRelevantChunk() {
        // A long transcript of filler with one segment carrying the answer to the question.
        var segments: [TranscriptContextBuilder.Segment] = []
        for i in 0..<200 {
            segments.append(seg(Double(i), "generic filler discussion line number \(i) padding padding padding"))
        }
        segments.append(seg(999, "The decision about NEEDLE_KEYWORD was to proceed on Tuesday."))

        let budget = 400
        let text = MeetingQAComposer.compose(
            question: "What was decided about NEEDLE_KEYWORD?",
            segments: segments,
            upTo: nil,
            priorTurns: [],
            knowledgePassages: [],
            charBudget: budget
        )
        XCTAssertLessThanOrEqual(text.count, budget, "the composed payload must stay within the char budget")
        XCTAssertTrue(text.contains("NEEDLE_KEYWORD"), "the most-relevant chunk must survive budgeting")
    }

    // MARK: - Composer: prior turns

    func testComposerReplaysPriorTurnsInOrder() {
        let text = MeetingQAComposer.compose(
            question: "And after that?",
            segments: [seg(0, "Some discussion.")],
            upTo: nil,
            priorTurns: [
                .init(question: "FIRST_Q_MARKER", answer: "FIRST_A_MARKER"),
                .init(question: "SECOND_Q_MARKER", answer: "SECOND_A_MARKER")
            ],
            knowledgePassages: [],
            charBudget: 16_000
        )
        let firstRange = try? XCTUnwrap(text.range(of: "FIRST_Q_MARKER"))
        let secondRange = try? XCTUnwrap(text.range(of: "SECOND_Q_MARKER"))
        XCTAssertNotNil(firstRange)
        XCTAssertNotNil(secondRange)
        if let firstRange, let secondRange {
            XCTAssertTrue(firstRange.lowerBound < secondRange.lowerBound, "prior turns must replay in order")
        }
        XCTAssertTrue(text.contains("FIRST_A_MARKER") && text.contains("SECOND_A_MARKER"))
    }

    // MARK: - Composer: knowledge base

    func testComposerIncludesKnowledgePassages() {
        let passage = VaultPassage(id: "n1", title: "Acme", tags: ["acme"], content: "VAULT_MARKER_QA content.")
        let text = MeetingQAComposer.compose(
            question: "What is the acme roadmap?",
            segments: [seg(0, "Discussion.")],
            upTo: nil,
            priorTurns: [],
            knowledgePassages: [passage],
            charBudget: 16_000
        )
        XCTAssertTrue(text.contains("VAULT_MARKER_QA"))
    }

    // MARK: - Composer: question survives a saturated budget

    /// Regression for M6 review finding 1: with a connected vault (3 x ~2,000-char passages), a
    /// transcript larger than half the budget, and prior turns larger than a quarter of the budget
    /// all present at once, the section budgets used to sum past `charBudget` and the final
    /// whole-payload truncation cut the trailing "## Question\n<question>" section — the model then
    /// received context with no question. The question must always survive.
    func testComposerKeepsQuestionWhenKBTranscriptAndPriorTurnsAllOverflow() {
        // KB: three ~2,000-char passages (~6k chars + headers, formerly unbudgeted).
        let passages = (0..<3).map { i in
            VaultPassage(
                id: "n\(i)",
                title: "Note \(i)",
                tags: [],
                content: String(repeating: "kb passage word \(i) ", count: 120) // ~2,160 chars
            )
        }
        // Transcript: > charBudget/2 (8,000 chars).
        var segments: [TranscriptContextBuilder.Segment] = []
        for i in 0..<400 {
            segments.append(seg(Double(i), "transcript filler discussion line number \(i) padding"))
        }
        // Prior turns: > charBudget/4 (4,000 chars).
        let priorTurns = (0..<40).map { i in
            MeetingQAComposer.PriorTurn(
                question: "prior question number \(i) with some padding text here",
                answer: "prior answer number \(i) with some more padding text here"
            )
        }

        let text = MeetingQAComposer.compose(
            question: "What did we decide about QUESTION_SURVIVES_MARKER?",
            segments: segments,
            upTo: nil,
            priorTurns: priorTurns,
            knowledgePassages: passages,
            charBudget: 16_000
        )

        XCTAssertLessThanOrEqual(text.count, 16_000, "the composed payload must stay within the char budget")
        XCTAssertTrue(
            text.contains("QUESTION_SURVIVES_MARKER"),
            "the question must survive when KB + transcript + prior turns all overflow their slices"
        )
        XCTAssertTrue(text.contains("## Question"), "the question section header must survive")
    }

    /// M6 review finding 2: when the Q&A history exceeds the prior-turn slice, the newest turns (which
    /// a follow-up depends on) must be kept and the oldest dropped.
    func testComposerPrefersRecentPriorTurnsWhenHistoryExceedsBudget() {
        let priorTurns = (0..<50).map { i in
            MeetingQAComposer.PriorTurn(
                question: "PRIOR_Q_\(i) padding padding padding padding",
                answer: "PRIOR_A_\(i) padding padding padding padding"
            )
        }
        let text = MeetingQAComposer.compose(
            question: "Follow-up?",
            segments: [seg(0, "Some discussion.")],
            upTo: nil,
            priorTurns: priorTurns,
            knowledgePassages: [],
            charBudget: 2_000 // prior slice (~500) can't hold all 50 turns
        )
        XCTAssertTrue(text.contains("PRIOR_Q_49"), "the newest turn must be retained")
        XCTAssertFalse(text.contains("PRIOR_Q_0"), "the oldest turns are dropped first")
    }

    // MARK: - Service: persistence

    func testAnswerPersistsExactlyOneTurnOnSuccess() async throws {
        let service = try makeService()
        let stub = StubProcessor()
        let llm = MeetingLLMService(meetingService: service, vaultService: makeDisconnectedVault(), processor: stub)

        let meeting = service.createMeeting(title: "Sync", source: .adHoc, state: .completed)
        service.appendStableSegments(
            [TranscriptionSegment(text: "We discussed the roadmap.", start: 0, end: 3)],
            to: meeting
        )

        let turn = try await llm.answerQuestion(for: meeting, question: "  What did we discuss?  ")

        XCTAssertEqual(stub.calls.count, 1)
        XCTAssertTrue(stub.calls.first?.skipMemoryInjection == true)
        XCTAssertEqual(meeting.qaTurns.count, 1)
        XCTAssertEqual(turn.question, "What did we discuss?", "the question is trimmed before persisting")
        XCTAssertEqual(turn.answer, "ANSWER_TEXT")
    }

    func testFailedAnswerPersistsNoTurn() async throws {
        let service = try makeService()
        let stub = StubProcessor()
        struct Boom: Error {}
        stub.errorToThrow = Boom()
        let llm = MeetingLLMService(meetingService: service, vaultService: makeDisconnectedVault(), processor: stub)

        let meeting = service.createMeeting(title: "Sync", source: .adHoc, state: .completed)
        service.appendStableSegments(
            [TranscriptionSegment(text: "Body.", start: 0, end: 2)],
            to: meeting
        )

        do {
            _ = try await llm.answerQuestion(for: meeting, question: "Anything?")
            XCTFail("Expected the stubbed failure to propagate")
        } catch {
            XCTAssertTrue(error is Boom)
        }
        XCTAssertTrue(meeting.qaTurns.isEmpty, "a failed call must persist no turn")
    }

    func testEmptyQuestionThrowsAndPersistsNothing() async throws {
        let service = try makeService()
        let stub = StubProcessor()
        let llm = MeetingLLMService(meetingService: service, vaultService: makeDisconnectedVault(), processor: stub)

        let meeting = service.createMeeting(title: "Sync", source: .adHoc, state: .completed)

        do {
            _ = try await llm.answerQuestion(for: meeting, question: "   \n ")
            XCTFail("Expected emptyQuestion error")
        } catch {
            XCTAssertEqual(error as? MeetingLLMError, .emptyQuestion)
        }
        XCTAssertTrue(stub.calls.isEmpty)
        XCTAssertTrue(meeting.qaTurns.isEmpty)
    }

    // MARK: - Service: retrieval wiring

    func testConnectedVaultContributesKnowledgeBasePassage() async throws {
        let service = try makeService()
        let stub = StubProcessor()
        let vault = try makeConnectedVault()
        let llm = MeetingLLMService(meetingService: service, vaultService: vault, processor: stub)

        let meeting = service.createMeeting(title: "Acme", source: .adHoc, state: .completed)
        service.appendStableSegments(
            [TranscriptionSegment(text: "Talking about the plan.", start: 0, end: 3)],
            to: meeting
        )

        _ = try await llm.answerQuestion(for: meeting, question: "What is the acme roadmap?")
        XCTAssertTrue(stub.calls.first?.text.contains("VAULT_MARKER_QA") == true)
    }

    func testDisconnectedVaultOmitsKnowledgeBase() async throws {
        let service = try makeService()
        let stub = StubProcessor()
        let llm = MeetingLLMService(meetingService: service, vaultService: makeDisconnectedVault(), processor: stub)

        let meeting = service.createMeeting(title: "Acme", source: .adHoc, state: .completed)
        service.appendStableSegments(
            [TranscriptionSegment(text: "Talking about the plan.", start: 0, end: 3)],
            to: meeting
        )

        let turn = try await llm.answerQuestion(for: meeting, question: "What is the acme roadmap?")
        XCTAssertFalse(stub.calls.first?.text.contains("VAULT_MARKER_QA") == true)
        XCTAssertEqual(meeting.qaTurns.count, 1)
        XCTAssertEqual(turn.answer, "ANSWER_TEXT")
    }

    // MARK: - Service: offset scoping + prior-turn replay through the service

    func testServiceScopesTranscriptToOffset() async throws {
        let service = try makeService()
        let stub = StubProcessor()
        let llm = MeetingLLMService(meetingService: service, vaultService: makeDisconnectedVault(), processor: stub)

        let meeting = service.createMeeting(title: "Sync", source: .adHoc, state: .live)
        service.appendStableSegments(
            [
                TranscriptionSegment(text: "EARLY_MARKER discussion.", start: 0, end: 5),
                TranscriptionSegment(text: "LATE_MARKER discussion.", start: 120, end: 125)
            ],
            to: meeting
        )

        _ = try await llm.answerQuestion(for: meeting, question: "What happened?", asOfOffset: 60)
        let text = try XCTUnwrap(stub.calls.first?.text)
        XCTAssertTrue(text.contains("EARLY_MARKER"))
        XCTAssertFalse(text.contains("LATE_MARKER"), "segments after the offset must be excluded")
    }

    func testServiceReplaysStoredPriorTurns() async throws {
        let service = try makeService()
        let stub = StubProcessor()
        let llm = MeetingLLMService(meetingService: service, vaultService: makeDisconnectedVault(), processor: stub)

        let meeting = service.createMeeting(title: "Sync", source: .adHoc, state: .completed)
        service.appendStableSegments(
            [TranscriptionSegment(text: "Body.", start: 0, end: 2)],
            to: meeting
        )
        service.addQATurn(to: meeting, question: "PRIOR_QUESTION_MARKER", answer: "PRIOR_ANSWER_MARKER")

        _ = try await llm.answerQuestion(for: meeting, question: "Follow-up?")
        let text = try XCTUnwrap(stub.calls.first?.text)
        XCTAssertTrue(text.contains("PRIOR_QUESTION_MARKER"))
        XCTAssertTrue(text.contains("PRIOR_ANSWER_MARKER"))
    }

    // MARK: - Cross-meeting-leak regressions (owner report: Q&A answered from another meeting)
    //
    // Mechanism being locked in: with no own-transcript guard the composer used to build a
    // knowledge-base-only prompt out of whatever whole-vault retrieval surfaced, so a meeting whose
    // segments were empty/unavailable answered from a *different* meeting's note (personal-coaching
    // content). Two invariants prevent that: (1) the meeting's own transcript is the primary grounding
    // and the knowledge base is supplementary/last and withheld when there is no transcript to
    // supplement; (2) the service refuses (`.noTranscriptContext`) rather than answering from
    // retrieval-only context; and the answer always lands on the meeting it was asked about.

    /// A connected vault whose only note is FOREIGN coaching content (a different meeting's material).
    private func makeForeignCoachingVault() throws -> ObsidianVaultService {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "MeetingQAForeignVault")
        addTeardownBlock { TestSupport.remove(dir) }
        try """
        # Coaching session
        The client's stress factors, family boundaries, and taking care of the dog. FOREIGN_COACHING_MARKER
        """.write(to: dir.appendingPathComponent("Coaching.md"), atomically: true, encoding: .utf8)
        let vault = ObsidianVaultService(defaults: makeDefaults())
        vault.connect(to: dir.path)
        return vault
    }

    /// Composer: the meeting's own transcript is the primary grounding and precedes the knowledge base.
    func testComposerPlacesTranscriptBeforeKnowledgeBase() {
        let passage = VaultPassage(id: "n1", title: "Acme", tags: [], content: "KB_ONLY_MARKER content.")
        let text = MeetingQAComposer.compose(
            question: "What is the plan?",
            segments: [seg(0, "TRANSCRIPT_ONLY_MARKER discussion.")],
            upTo: nil,
            priorTurns: [],
            knowledgePassages: [passage],
            charBudget: 16_000
        )
        let transcriptRange = text.range(of: "TRANSCRIPT_ONLY_MARKER")
        let kbRange = text.range(of: "KB_ONLY_MARKER")
        XCTAssertNotNil(transcriptRange)
        XCTAssertNotNil(kbRange)
        if let transcriptRange, let kbRange {
            XCTAssertTrue(
                transcriptRange.lowerBound < kbRange.lowerBound,
                "the meeting's own transcript must lead the context, ahead of the knowledge base"
            )
        }
    }

    /// Composer: with no transcript to supplement, the knowledge base is withheld — retrieval must
    /// never stand in as the sole grounding (this is what produced the cross-meeting answer).
    func testComposerWithholdsKnowledgeBaseWhenTranscriptEmpty() {
        let passage = VaultPassage(id: "n1", title: "Coaching", tags: [], content: "FOREIGN_COACHING_MARKER")
        let text = MeetingQAComposer.compose(
            question: "What is the most important point of the meeting?",
            segments: [],
            upTo: nil,
            priorTurns: [],
            knowledgePassages: [passage],
            charBudget: 16_000
        )
        XCTAssertFalse(
            text.contains("FOREIGN_COACHING_MARKER"),
            "foreign knowledge-base content must not become the sole grounding when there is no transcript"
        )
        XCTAssertFalse(
            text.contains(String(localized: "meetings.qa.context.knowledgeHeader")),
            "the knowledge-base section must be absent when there is no transcript to supplement"
        )
    }

    /// Service: a meeting with no visible transcript refuses with `.noTranscriptContext` and never
    /// calls the LLM with a connected vault's foreign note — the exact owner-reported leak.
    func testAnswerRefusesEmptyTranscriptAndNeverDrawsOnForeignVault() async throws {
        let service = try makeService()
        let stub = StubProcessor()
        let vault = try makeForeignCoachingVault()
        let llm = MeetingLLMService(meetingService: service, vaultService: vault, processor: stub)

        // A meeting whose transcript failed to load (no segments), like an import that didn't populate.
        let meeting = service.createMeeting(title: "Llamada semanal Dirección-TI", source: .adHoc, state: .completed)

        do {
            _ = try await llm.answerQuestion(
                for: meeting,
                question: "Cual sería el punto más importante sobre la reunión?"
            )
            XCTFail("Expected noTranscriptContext")
        } catch {
            XCTAssertEqual(error as? MeetingLLMError, .noTranscriptContext)
        }
        XCTAssertTrue(stub.calls.isEmpty, "the LLM must never be called with retrieval-only (foreign) context")
        XCTAssertTrue(meeting.qaTurns.isEmpty, "a refused answer persists no turn")
    }

    /// Service: the prompt is assembled from the *asked* meeting's own segments and the turn lands on
    /// it — a second meeting's transcript never enters the prompt and never receives the turn.
    func testAnswerUsesOnlyAskedMeetingsSegmentsAndLandsOnIt() async throws {
        let service = try makeService()
        let stub = StubProcessor()
        let llm = MeetingLLMService(meetingService: service, vaultService: makeDisconnectedVault(), processor: stub)

        let a = service.createMeeting(title: "A", source: .adHoc, state: .completed)
        service.appendStableSegments(
            [TranscriptionSegment(text: "ALPHA_ONLY_MARKER decision.", start: 0, end: 3)],
            to: a
        )
        let b = service.createMeeting(title: "B", source: .adHoc, state: .completed)
        service.appendStableSegments(
            [TranscriptionSegment(text: "BRAVO_ONLY_MARKER unrelated.", start: 0, end: 3)],
            to: b
        )

        _ = try await llm.answerQuestion(for: a, question: "What did we decide?")

        let text = try XCTUnwrap(stub.calls.first?.text)
        XCTAssertTrue(text.contains("ALPHA_ONLY_MARKER"))
        XCTAssertFalse(text.contains("BRAVO_ONLY_MARKER"), "another meeting's transcript must never enter the prompt")
        XCTAssertEqual(a.qaTurns.count, 1, "the answer lands on the asked meeting")
        XCTAssertEqual(b.qaTurns.count, 0, "the answer must not land on another meeting")
    }

    /// Service: two answers in flight at once (the user asked A, then switched and asked B while A was
    /// still answering). Each captures its own meeting's context at submission and lands on its own
    /// meeting — no cross-routing across the switch. The processor echoes its composed context so the
    /// persisted answer reveals which meeting's transcript it captured.
    func testConcurrentInFlightAnswersEachLandOnTheirOwnMeeting() async throws {
        let service = try makeService()
        let gate = Gate()
        let processor = EchoGatedProcessor(gate: gate)
        let llm = MeetingLLMService(meetingService: service, vaultService: makeDisconnectedVault(), processor: processor)

        let a = service.createMeeting(title: "A", source: .adHoc, state: .completed)
        service.appendStableSegments(
            [TranscriptionSegment(text: "ALPHA_ONLY_MARKER discussion.", start: 0, end: 2)],
            to: a
        )
        let b = service.createMeeting(title: "B", source: .adHoc, state: .completed)
        service.appendStableSegments(
            [TranscriptionSegment(text: "BRAVO_ONLY_MARKER discussion.", start: 0, end: 2)],
            to: b
        )

        // Ask A (blocks on the gate), then "switch" and ask B while A is still in flight.
        let taskA = Task { _ = try await llm.answerQuestion(for: a, question: "A question?") }
        await waitUntil { llm.answeringMeetingIDs.contains(a.id) }
        let taskB = Task { _ = try await llm.answerQuestion(for: b, question: "B question?") }
        await waitUntil { llm.answeringMeetingIDs.contains(b.id) }

        gate.open()
        _ = try await taskA.value
        _ = try await taskB.value

        XCTAssertEqual(a.qaTurns.count, 1)
        XCTAssertEqual(b.qaTurns.count, 1)
        XCTAssertTrue(a.qaTurns.first?.answer.contains("ALPHA_ONLY_MARKER") == true,
                      "meeting A's answer captured A's transcript")
        XCTAssertFalse(a.qaTurns.first?.answer.contains("BRAVO_ONLY_MARKER") == true,
                       "meeting A's answer must not capture the switched-to meeting's transcript")
        XCTAssertTrue(b.qaTurns.first?.answer.contains("BRAVO_ONLY_MARKER") == true,
                      "meeting B's answer captured B's transcript")
        XCTAssertFalse(b.qaTurns.first?.answer.contains("ALPHA_ONLY_MARKER") == true,
                       "meeting B's answer must not capture meeting A's transcript")
    }

    // MARK: - Concurrency test doubles

    /// A resumable barrier so the processor can hold answers in flight deterministically.
    @MainActor
    private final class Gate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var opened = false
        func wait() async { if opened { return }; await withCheckedContinuation { waiters.append($0) } }
        func open() {
            guard !opened else { return }
            opened = true
            let current = waiters
            waiters = []
            current.forEach { $0.resume() }
        }
    }

    /// Blocks each call on a gate, then echoes back the composed context so the persisted answer
    /// reveals which meeting's transcript that call captured.
    @MainActor
    private final class EchoGatedProcessor: PromptProcessing {
        var selectedProviderId = "p"
        var selectedCloudModel = "m"
        private let gate: Gate
        init(gate: Gate) { self.gate = gate }
        func process(
            prompt: String, text: String, providerOverride: String?, cloudModelOverride: String?,
            temperatureDirective: PluginLLMTemperatureDirective, skipMemoryInjection: Bool
        ) async throws -> String {
            await gate.wait()
            return text
        }
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async {
        var iterations = 0
        while !condition() {
            if iterations > 100_000 { XCTFail("condition never met"); return }
            await Task.yield()
            iterations += 1
        }
    }
}
