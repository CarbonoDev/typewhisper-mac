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
}
