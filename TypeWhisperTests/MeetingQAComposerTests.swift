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
            let providerOverride: String?
            let cloudModelOverride: String?
            let skipMemoryInjection: Bool
        }

        var selectedProviderId = "qa-provider"
        var selectedCloudModel = "qa-model"
        private(set) var calls: [Call] = []
        var errorToThrow: Error?
        var response = "ANSWER_TEXT"
        /// Optional per-call (1-based index) response override; `nil` ⇒ `response`. Lets an escalation
        /// test return a `VAULT_SEARCH:` marker on pass 1 and a normal answer on pass 2.
        var responder: ((Int) -> String)?

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
            return responder?(calls.count) ?? response
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

    // MARK: - Service: retrieval wiring (redesign — broad vault retrieval OFF by default)

    /// Redesign (owner decision): the default pass grounds ONLY on the meeting's own material. A
    /// connected vault whose query-matching note is NOT curated must not contribute to the pass-1
    /// prompt — no whole-vault fallback, no folder-prefix search — unless the model explicitly
    /// escalates. With a normal (non-marker) answer there is exactly one pass and no vault content.
    func testConnectedVaultDoesNotContributeByDefault() async throws {
        let service = try makeService()
        let stub = StubProcessor()
        let vault = try makeConnectedVault()
        let llm = MeetingLLMService(meetingService: service, vaultService: vault, processor: stub)

        let meeting = service.createMeeting(title: "Acme", source: .adHoc, state: .completed)
        service.appendStableSegments(
            [TranscriptionSegment(text: "Talking about the plan.", start: 0, end: 3)],
            to: meeting
        )

        let turn = try await llm.answerQuestion(for: meeting, question: "What is the acme roadmap?")
        XCTAssertEqual(stub.calls.count, 1, "a non-marker answer settles in one pass")
        XCTAssertFalse(
            stub.calls.first?.text.contains("VAULT_MARKER_QA") == true,
            "a non-curated vault note must not enter the default (pass-1) prompt"
        )
        XCTAssertEqual(turn.answer, "ANSWER_TEXT")
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

    // MARK: - Model-requested vault-search escalation (owner decision)

    /// The marker parser: any LINE whose trimmed form begins with `VAULT_SEARCH:` yields its terms —
    /// including a prose-then-marker reply — while a mid-sentence mention (not at a line start) never
    /// fires. Tolerant of case and surrounding whitespace; only the marker line's remainder is terms.
    func testVaultSearchTermsParsing() {
        XCTAssertEqual(MeetingQAComposer.vaultSearchTerms(in: "VAULT_SEARCH: acme roadmap"), "acme roadmap")
        XCTAssertEqual(MeetingQAComposer.vaultSearchTerms(in: "  vault_search:  acme  \n more"), "acme")
        XCTAssertEqual(MeetingQAComposer.vaultSearchTerms(in: "VAULT_SEARCH:"), "", "empty terms ⇒ empty string, not nil")
        XCTAssertEqual(
            MeetingQAComposer.vaultSearchTerms(in: "I couldn't find this in the meeting.\nVAULT_SEARCH: acme roadmap"),
            "acme roadmap",
            "a marker line after prose is still the model asking for a search"
        )
        XCTAssertNil(MeetingQAComposer.vaultSearchTerms(in: "The meeting decided to ship on Tuesday."))
        XCTAssertNil(
            MeetingQAComposer.vaultSearchTerms(in: "See VAULT_SEARCH: in the middle of a sentence."),
            "a mention that does not start a line is not an escalation request"
        )
    }

    /// The sanitizer strips exactly the marker lines (the parser's line predicate), keeps prose —
    /// including mid-sentence mentions — and collapses an all-marker reply to the empty string.
    func testStrippingVaultSearchLines() {
        XCTAssertEqual(
            MeetingQAComposer.strippingVaultSearchLines(from: "Prose first.\nVAULT_SEARCH: acme\nProse after."),
            "Prose first.\nProse after."
        )
        XCTAssertEqual(MeetingQAComposer.strippingVaultSearchLines(from: "  vault_search: acme  "), "")
        XCTAssertEqual(
            MeetingQAComposer.strippingVaultSearchLines(from: "See VAULT_SEARCH: mid-sentence."),
            "See VAULT_SEARCH: mid-sentence.",
            "mid-sentence mentions are not markers and must not be stripped"
        )
    }

    /// A `VAULT_SEARCH:` reply triggers exactly one escalation round: pass 1 carries no vault content,
    /// pass 2 carries the retrieved excerpt under the labeled secondary header, the marker never
    /// surfaces, and the persisted answer discloses the vault consult and carries the pass-2 answer.
    func testModelRequestedVaultSearchTriggersOneEscalationRound() async throws {
        let service = try makeService()
        let stub = StubProcessor()
        stub.responder = { $0 == 1 ? "VAULT_SEARCH: acme roadmap" : "PASS2_ANSWER_MARKER" }
        let vault = try makeConnectedVault()
        let llm = MeetingLLMService(meetingService: service, vaultService: vault, processor: stub)

        let meeting = service.createMeeting(title: "Acme", source: .adHoc, state: .completed)
        service.appendStableSegments(
            [TranscriptionSegment(text: "Talking about the plan.", start: 0, end: 3)],
            to: meeting
        )

        let turn = try await llm.answerQuestion(for: meeting, question: "What is the acme roadmap?")

        // Exactly two passes: default pass then one escalation round.
        XCTAssertEqual(stub.calls.count, 2)
        XCTAssertFalse(stub.calls[0].text.contains("VAULT_MARKER_QA"), "pass 1 grounds only on the meeting")
        XCTAssertTrue(stub.calls[1].text.contains("VAULT_MARKER_QA"), "pass 2 includes the retrieved excerpt")
        XCTAssertTrue(
            stub.calls[1].text.contains(String(localized: "meetings.qa.context.retrievedHeader")),
            "the retrieved excerpt is under the labeled secondary header"
        )
        // The marker never surfaces; the answer discloses the vault consult and carries the pass-2 answer.
        XCTAssertFalse(turn.answer.contains("VAULT_SEARCH"), "the marker must never surface to the user")
        XCTAssertTrue(turn.answer.contains("PASS2_ANSWER_MARKER"))
        XCTAssertTrue(turn.answer.contains(String(localized: "meetings.qa.answer.vaultConsultedPrefix")))
        XCTAssertEqual(meeting.qaTurns.count, 1, "exactly one turn is persisted")
    }

    /// Empty escalation results ⇒ skip pass 2 and answer "not covered" (no second LLM call); the marker
    /// never surfaces.
    func testVaultSearchWithNoResultsSkipsPass2AndAnswersNotCovered() async throws {
        let service = try makeService()
        let stub = StubProcessor()
        // Search terms that match nothing in the vault ⇒ empty retrieval.
        stub.responder = { _ in "VAULT_SEARCH: nonexistent zzz" }
        let vault = try makeConnectedVault()
        let llm = MeetingLLMService(meetingService: service, vaultService: vault, processor: stub)

        let meeting = service.createMeeting(title: "Acme", source: .adHoc, state: .completed)
        service.appendStableSegments(
            [TranscriptionSegment(text: "Talking about the plan.", start: 0, end: 3)],
            to: meeting
        )

        let turn = try await llm.answerQuestion(for: meeting, question: "What is the acme roadmap?")
        XCTAssertEqual(stub.calls.count, 1, "empty retrieval ⇒ no pass 2")
        XCTAssertEqual(turn.answer, String(localized: "meetings.qa.answer.notCovered"))
        XCTAssertFalse(turn.answer.contains("VAULT_SEARCH"))
        XCTAssertEqual(meeting.qaTurns.count, 1)
    }

    /// Loop guard: a `VAULT_SEARCH:` reply in pass 2 is treated as "not covered" — no third round — and
    /// the marker never surfaces.
    func testVaultSearchInPass2IsTreatedAsNotCovered() async throws {
        let service = try makeService()
        let stub = StubProcessor()
        stub.responder = { _ in "VAULT_SEARCH: acme roadmap" } // marker on every call
        let vault = try makeConnectedVault()
        let llm = MeetingLLMService(meetingService: service, vaultService: vault, processor: stub)

        let meeting = service.createMeeting(title: "Acme", source: .adHoc, state: .completed)
        service.appendStableSegments(
            [TranscriptionSegment(text: "Talking about the plan.", start: 0, end: 3)],
            to: meeting
        )

        let turn = try await llm.answerQuestion(for: meeting, question: "What is the acme roadmap?")
        XCTAssertEqual(stub.calls.count, 2, "no third round after a pass-2 escalation request")
        XCTAssertEqual(turn.answer, String(localized: "meetings.qa.answer.notCovered"))
        XCTAssertFalse(turn.answer.contains("VAULT_SEARCH"), "the marker must never surface to the user")
        XCTAssertEqual(meeting.qaTurns.count, 1)
    }

    /// A pass-1 reply that wraps the marker in prose ("I couldn't find this…\nVAULT_SEARCH: …") is
    /// still the model asking for a search: it escalates (using the marker line's terms) instead of
    /// persisting the prose-plus-marker reply verbatim.
    func testProseThenMarkerInPass1StillEscalates() async throws {
        let service = try makeService()
        let stub = StubProcessor()
        stub.responder = { call in
            call == 1
                ? "I couldn't find this in the meeting.\nVAULT_SEARCH: acme roadmap"
                : "PASS2_ANSWER_MARKER"
        }
        let vault = try makeConnectedVault()
        let llm = MeetingLLMService(meetingService: service, vaultService: vault, processor: stub)

        let meeting = service.createMeeting(title: "Acme", source: .adHoc, state: .completed)
        service.appendStableSegments(
            [TranscriptionSegment(text: "Talking about the plan.", start: 0, end: 3)],
            to: meeting
        )

        let turn = try await llm.answerQuestion(for: meeting, question: "What is the acme roadmap?")

        XCTAssertEqual(stub.calls.count, 2, "the wrapped marker still triggers the escalation round")
        XCTAssertTrue(stub.calls[1].text.contains("VAULT_MARKER_QA"), "the marker line's terms drive the retrieval")
        XCTAssertFalse(turn.answer.contains("VAULT_SEARCH"), "the marker must never surface to the user")
        XCTAssertTrue(turn.answer.contains("PASS2_ANSWER_MARKER"))
        XCTAssertEqual(meeting.qaTurns.count, 1)
    }

    /// A pass-2 reply that wraps the marker in prose keeps the prose: the marker line is stripped from
    /// the persisted turn, the loop guard still means no third call, and the vault-consulted disclosure
    /// applies to the surviving answer.
    func testProseThenMarkerInPass2IsStrippedWithoutThirdCall() async throws {
        let service = try makeService()
        let stub = StubProcessor()
        stub.responder = { call in
            call == 1
                ? "VAULT_SEARCH: acme roadmap"
                : "The roadmap ships in Q3.\nVAULT_SEARCH: acme roadmap details"
        }
        let vault = try makeConnectedVault()
        let llm = MeetingLLMService(meetingService: service, vaultService: vault, processor: stub)

        let meeting = service.createMeeting(title: "Acme", source: .adHoc, state: .completed)
        service.appendStableSegments(
            [TranscriptionSegment(text: "Talking about the plan.", start: 0, end: 3)],
            to: meeting
        )

        let turn = try await llm.answerQuestion(for: meeting, question: "What is the acme roadmap?")

        XCTAssertEqual(stub.calls.count, 2, "loop guard: never a third LLM call")
        XCTAssertFalse(turn.answer.contains("VAULT_SEARCH"), "the marker line is stripped from the persisted turn")
        XCTAssertTrue(turn.answer.contains("The roadmap ships in Q3."), "the prose around the marker survives")
        XCTAssertTrue(turn.answer.contains(String(localized: "meetings.qa.answer.vaultConsultedPrefix")))
        XCTAssertEqual(meeting.qaTurns.count, 1)
    }

    /// A mid-sentence `VAULT_SEARCH:` mention (not at a line start) is not an escalation request: no
    /// second pass, and the answer is persisted with the mention intact (not stripped).
    func testMidSentenceMarkerMentionNeitherEscalatesNorIsStripped() async throws {
        let service = try makeService()
        let stub = StubProcessor()
        stub.response = "The meeting explained that VAULT_SEARCH: is the app's escalation token."
        let vault = try makeConnectedVault()
        let llm = MeetingLLMService(meetingService: service, vaultService: vault, processor: stub)

        let meeting = service.createMeeting(title: "Acme", source: .adHoc, state: .completed)
        service.appendStableSegments(
            [TranscriptionSegment(text: "Talking about the plan.", start: 0, end: 3)],
            to: meeting
        )

        let turn = try await llm.answerQuestion(for: meeting, question: "What is the escalation token?")

        XCTAssertEqual(stub.calls.count, 1, "a mid-sentence mention is not an escalation request")
        XCTAssertEqual(
            turn.answer,
            "The meeting explained that VAULT_SEARCH: is the app's escalation token.",
            "a mid-sentence mention is not stripped from the persisted answer"
        )
        XCTAssertEqual(meeting.qaTurns.count, 1)
    }

    /// The `VAULT_SEARCH` invitation appears in the pass-1 system prompt only when a vault is available
    /// to search — the model is never invited to escalate into a void.
    func testVaultSearchInvitationOnlyWhenVaultAvailable() async throws {
        let invitation = String(localized: "meetings.qa.systemPrompt.vaultSearchInvitation")

        // No connected vault ⇒ no invitation in the composed system prompt.
        let disconnectedService = try makeService()
        let disconnectedStub = StubProcessor()
        let disconnectedLLM = MeetingLLMService(
            meetingService: disconnectedService, vaultService: makeDisconnectedVault(), processor: disconnectedStub
        )
        let meetingA = disconnectedService.createMeeting(title: "Acme", source: .adHoc, state: .completed)
        disconnectedService.appendStableSegments(
            [TranscriptionSegment(text: "Talking about the plan.", start: 0, end: 3)],
            to: meetingA
        )
        _ = try await disconnectedLLM.answerQuestion(for: meetingA, question: "What is the acme roadmap?")
        let disconnectedPrompt = try XCTUnwrap(disconnectedStub.calls.first?.prompt)
        XCTAssertFalse(
            disconnectedPrompt.contains(invitation),
            "no vault ⇒ the system prompt must not invite a VAULT_SEARCH escalation"
        )
        XCTAssertFalse(disconnectedPrompt.contains("VAULT_SEARCH"), "no marker mention at all without a vault")

        // Connected vault ⇒ the invitation is present.
        let connectedService = try makeService()
        let connectedStub = StubProcessor()
        let connectedLLM = MeetingLLMService(
            meetingService: connectedService, vaultService: try makeConnectedVault(), processor: connectedStub
        )
        let meetingB = connectedService.createMeeting(title: "Acme", source: .adHoc, state: .completed)
        connectedService.appendStableSegments(
            [TranscriptionSegment(text: "Talking about the plan.", start: 0, end: 3)],
            to: meetingB
        )
        _ = try await connectedLLM.answerQuestion(for: meetingB, question: "What is the acme roadmap?")
        let connectedPrompt = try XCTUnwrap(connectedStub.calls.first?.prompt)
        XCTAssertTrue(connectedPrompt.contains(invitation), "a connected vault restores the invitation")
    }

    /// Provenance/PART-M5: the per-purpose `.qa` provider/model overrides are honored on BOTH the default
    /// pass and the escalation pass.
    func testEscalationHonorsQAOverridesOnBothPasses() async throws {
        let service = try makeService()
        let stub = StubProcessor()
        stub.responder = { $0 == 1 ? "VAULT_SEARCH: acme roadmap" : "PASS2" }
        let vault = try makeConnectedVault()

        let routerDefaults = makeDefaults()
        routerDefaults.set("qa-purpose-provider", forKey: UserDefaultsKeys.meetingsModelQAProviderId)
        routerDefaults.set("qa-purpose-model", forKey: UserDefaultsKeys.meetingsModelQAModel)
        let router = MeetingModelRouter(processor: stub, defaults: routerDefaults)

        let llm = MeetingLLMService(
            meetingService: service,
            vaultService: vault,
            processor: stub,
            modelRouter: router
        )

        let meeting = service.createMeeting(title: "Acme", source: .adHoc, state: .completed)
        service.appendStableSegments(
            [TranscriptionSegment(text: "Talking about the plan.", start: 0, end: 3)],
            to: meeting
        )

        _ = try await llm.answerQuestion(for: meeting, question: "What is the acme roadmap?")

        XCTAssertEqual(stub.calls.count, 2)
        for (index, call) in stub.calls.enumerated() {
            XCTAssertEqual(call.providerOverride, "qa-purpose-provider", "pass \(index + 1) provider override")
            XCTAssertEqual(call.cloudModelOverride, "qa-purpose-model", "pass \(index + 1) model override")
        }
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
