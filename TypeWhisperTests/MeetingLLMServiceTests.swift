import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

@MainActor
final class MeetingLLMServiceTests: XCTestCase {
    // MARK: - Stub processor (the `PromptProcessing` seam)

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

        var selectedProviderId: String = "global-provider"
        var selectedCloudModel: String = "global-model"
        private(set) var calls: [Call] = []
        var errorToThrow: Error?
        /// Response for a call; defaults to a per-call-index marker so the reduced (last) call is
        /// identifiable in the persisted output.
        var responder: (Call, Int) -> String = { _, index in "resp-\(index)" }

        func process(
            prompt: String,
            text: String,
            providerOverride: String?,
            cloudModelOverride: String?,
            temperatureDirective: PluginLLMTemperatureDirective,
            skipMemoryInjection: Bool
        ) async throws -> String {
            let call = Call(
                prompt: prompt,
                text: text,
                providerOverride: providerOverride,
                cloudModelOverride: cloudModelOverride,
                temperatureDirective: temperatureDirective,
                skipMemoryInjection: skipMemoryInjection
            )
            calls.append(call)
            if let errorToThrow { throw errorToThrow }
            return responder(call, calls.count)
        }
    }

    // MARK: - Helpers

    /// A disconnected vault (unique defaults suite) — output generation never touches the KB, so
    /// these tests keep it empty. M6 Q&A composer/KB behavior is covered in `MeetingQAComposerTests`.
    private func makeVault() -> ObsidianVaultService {
        let suite = "MeetingLLMServiceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return ObsidianVaultService(defaults: defaults)
    }

    private func makeMeeting(
        on service: MeetingService,
        segmentTexts: [String],
        notesIncluded: Bool = true
    ) -> Meeting {
        let meeting = service.createMeeting(title: "Analysis", source: .adHoc, state: .completed)
        var start = 0.0
        service.appendStableSegments(
            segmentTexts.map { text in
                defer { start += 2 }
                return TranscriptionSegment(text: text, start: start, end: start + 2)
            },
            to: meeting
        )
        meeting.notesIncludedInOutputs = notesIncluded
        service.update(meeting)
        return meeting
    }

    private func makeTemplate(
        prompt: String = "Template prompt.",
        kind: MeetingOutputKind = .summary,
        providerType: String? = nil,
        cloudModel: String? = nil,
        temperatureValue: Double? = nil
    ) -> PromptAction {
        // Meeting templates are now `.meeting`-surface `PromptAction` rows (plan AD6).
        PromptAction(
            name: "T",
            prompt: prompt,
            providerType: providerType,
            cloudModel: cloudModel,
            temperatureModeRaw: temperatureValue == nil
                ? PluginLLMTemperatureMode.inheritProviderSetting.rawValue
                : PluginLLMTemperatureMode.custom.rawValue,
            temperatureValue: temperatureValue,
            surfaceRaw: PromptSurface.meeting.rawValue,
            meetingKindRaw: kind.rawValue
        )
    }

    // MARK: - Direct (single-chunk) path

    func testSingleChunkTakesDirectPathAndPersistsOutput() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }

        let service = MeetingService(appSupportDirectory: dir)
        let stub = StubProcessor()
        let llm = MeetingLLMService(meetingService: service, vaultService: makeVault(), processor: stub)

        let meeting = makeMeeting(on: service, segmentTexts: ["Short transcript."])
        let template = makeTemplate(prompt: "Summarize this.", kind: .summary)

        let output = try await llm.generateOutput(for: meeting, using: template)

        // Exactly one call, using the template prompt (no map step).
        XCTAssertEqual(stub.calls.count, 1)
        XCTAssertEqual(stub.calls.first?.prompt, "Summarize this.")
        XCTAssertTrue(stub.calls.first?.skipMemoryInjection == true)

        // Persisted with kind and provenance from the global selection.
        XCTAssertEqual(meeting.outputs.count, 1)
        XCTAssertEqual(output.kind, .summary)
        XCTAssertEqual(output.templateID, template.id)
        XCTAssertEqual(output.providerUsed, "global-provider")
        XCTAssertEqual(output.modelUsed, "global-model")
        XCTAssertEqual(output.content, "resp-1")
    }

    // MARK: - Map / reduce

    func testMapReduceProducesExactlyOneReducedOutput() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }

        let service = MeetingService(appSupportDirectory: dir)
        let stub = StubProcessor()
        // Tiny budget forces multiple map chunks over the rendered transcript.
        let llm = MeetingLLMService(meetingService: service, vaultService: makeVault(), processor: stub, charBudget: 30)

        let meeting = makeMeeting(on: service, segmentTexts: [
            "First segment of the discussion here.",
            "Second segment continues the discussion.",
            "Third segment wraps things up nicely."
        ])
        let template = makeTemplate(prompt: "Reduce prompt.", kind: .extended)

        let output = try await llm.generateOutput(for: meeting, using: template)

        // More than one call (maps + reduce); the final call is the reduce using the template prompt.
        XCTAssertGreaterThan(stub.calls.count, 1)
        XCTAssertEqual(stub.calls.last?.prompt, "Reduce prompt.")

        // Exactly one output persisted — the reduced result (last call's response).
        XCTAssertEqual(meeting.outputs.count, 1)
        XCTAssertEqual(output.content, "resp-\(stub.calls.count)")
        XCTAssertEqual(output.kind, .extended)
    }

    // MARK: - Regeneration & kind filtering (M4 review finding 2)

    func testRegenerateAddsSecondOutputAndKindFilteringIsRespected() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }

        let service = MeetingService(appSupportDirectory: dir)
        let stub = StubProcessor()
        let llm = MeetingLLMService(meetingService: service, vaultService: makeVault(), processor: stub)

        let meeting = makeMeeting(on: service, segmentTexts: ["Short transcript."])
        let summaryTemplate = makeTemplate(prompt: "Summarize.", kind: .summary)

        let first = try await llm.generateOutput(for: meeting, using: summaryTemplate)
        // Ensure a distinct createdAt so the "newest" tiebreak is unambiguous.
        try await Task.sleep(nanoseconds: 3_000_000)
        let second = try await llm.generateOutput(for: meeting, using: summaryTemplate)

        // Regeneration inserts a new row; both are retained.
        XCTAssertEqual(meeting.outputs.count, 2)
        XCTAssertNotEqual(first.id, second.id)
        // The newest summary is the second generation.
        XCTAssertEqual(service.latestOutput(ofKind: .summary, for: meeting)?.id, second.id)

        // An output of a different kind must be surfaced under its own kind and must not shadow the
        // summary's latest (kind filtering).
        try await Task.sleep(nanoseconds: 3_000_000)
        let extended = try await llm.generateOutput(
            for: meeting,
            using: makeTemplate(prompt: "Analyze.", kind: .extended)
        )
        XCTAssertEqual(meeting.outputs.count, 3)
        XCTAssertEqual(service.latestOutput(ofKind: .summary, for: meeting)?.id, second.id)
        XCTAssertEqual(service.latestOutput(ofKind: .extended, for: meeting)?.id, extended.id)
    }

    // MARK: - Template overrides flow into the call

    func testTemplateOverridesFlowIntoTheCall() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }

        let service = MeetingService(appSupportDirectory: dir)
        let stub = StubProcessor()
        let llm = MeetingLLMService(meetingService: service, vaultService: makeVault(), processor: stub)

        let meeting = makeMeeting(on: service, segmentTexts: ["Short."])
        let template = makeTemplate(
            prompt: "P",
            providerType: "openai",
            cloudModel: "gpt-4o",
            temperatureValue: 0.15
        )

        let output = try await llm.generateOutput(for: meeting, using: template)

        let call = try XCTUnwrap(stub.calls.first)
        XCTAssertEqual(call.providerOverride, "openai")
        XCTAssertEqual(call.cloudModelOverride, "gpt-4o")
        XCTAssertEqual(call.temperatureDirective, .custom(0.15))
        // Provenance records the overrides, not the global selection.
        XCTAssertEqual(output.providerUsed, "openai")
        XCTAssertEqual(output.modelUsed, "gpt-4o")
    }

    // MARK: - Notes toggle

    func testNotesIncludedWhenFlagOn() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }

        let service = MeetingService(appSupportDirectory: dir)
        let stub = StubProcessor()
        let llm = MeetingLLMService(meetingService: service, vaultService: makeVault(), processor: stub)

        let meeting = makeMeeting(on: service, segmentTexts: ["Body."], notesIncluded: true)
        service.addNote(to: meeting, text: "IMPORTANT_NOTE_MARKER", timestampOffset: 3)

        _ = try await llm.generateOutput(for: meeting, using: makeTemplate())
        XCTAssertTrue(stub.calls.first?.text.contains("IMPORTANT_NOTE_MARKER") == true)
    }

    func testNotesExcludedWhenFlagOff() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }

        let service = MeetingService(appSupportDirectory: dir)
        let stub = StubProcessor()
        let llm = MeetingLLMService(meetingService: service, vaultService: makeVault(), processor: stub)

        let meeting = makeMeeting(on: service, segmentTexts: ["Body."], notesIncluded: false)
        service.addNote(to: meeting, text: "IMPORTANT_NOTE_MARKER", timestampOffset: 3)

        _ = try await llm.generateOutput(for: meeting, using: makeTemplate())
        XCTAssertFalse(stub.calls.first?.text.contains("IMPORTANT_NOTE_MARKER") == true)
    }

    // MARK: - Failure modes

    func testEmptyTranscriptThrowsAndPersistsNothing() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }

        let service = MeetingService(appSupportDirectory: dir)
        let stub = StubProcessor()
        let llm = MeetingLLMService(meetingService: service, vaultService: makeVault(), processor: stub)

        let meeting = service.createMeeting(title: "Empty", source: .adHoc, state: .completed)

        do {
            _ = try await llm.generateOutput(for: meeting, using: makeTemplate())
            XCTFail("Expected emptyTranscript error")
        } catch {
            XCTAssertEqual(error as? MeetingLLMError, .emptyTranscript)
        }
        XCTAssertTrue(stub.calls.isEmpty)
        XCTAssertTrue(meeting.outputs.isEmpty)
    }

    func testFailedLLMCallPersistsNoOutput() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }

        let service = MeetingService(appSupportDirectory: dir)
        let stub = StubProcessor()
        struct Boom: Error {}
        stub.errorToThrow = Boom()
        let llm = MeetingLLMService(meetingService: service, vaultService: makeVault(), processor: stub)

        let meeting = makeMeeting(on: service, segmentTexts: ["Body."])

        do {
            _ = try await llm.generateOutput(for: meeting, using: makeTemplate())
            XCTFail("Expected the stubbed failure to propagate")
        } catch {
            XCTAssertTrue(error is Boom)
        }
        XCTAssertTrue(meeting.outputs.isEmpty)
    }

    // MARK: - Q&A meeting-scoping (plan J2)

    /// A resumable barrier so the processor can hold an answer in flight deterministically.
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

    /// A processor that blocks the LLM call on a gate so the test can observe the in-flight answer.
    @MainActor
    private final class GatedProcessor: PromptProcessing {
        var selectedProviderId = "p"
        var selectedCloudModel = "m"
        private(set) var callCount = 0
        private let gate: Gate
        init(gate: Gate) { self.gate = gate }
        func process(
            prompt: String, text: String, providerOverride: String?, cloudModelOverride: String?,
            temperatureDirective: PluginLLMTemperatureDirective, skipMemoryInjection: Bool
        ) async throws -> String {
            callCount += 1
            await gate.wait()
            return "answer"
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

    func testQAAnsweringIsMeetingScopedAndRejectsConcurrentSameMeeting() async throws {
        let dir = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(dir) }

        let service = MeetingService(appSupportDirectory: dir)
        let gate = Gate()
        let processor = GatedProcessor(gate: gate)
        let llm = MeetingLLMService(meetingService: service, vaultService: makeVault(), processor: processor)

        let a = makeMeeting(on: service, segmentTexts: ["A transcript."])
        let b = makeMeeting(on: service, segmentTexts: ["B transcript."])

        // Start answering meeting A; it blocks on the gate. Discard the (non-Sendable) turn inside the
        // Task so its result type is Void and never crosses the actor boundary.
        let task = Task { _ = try await llm.answerQuestion(for: a, question: "What did we decide?") }
        await waitUntil { llm.answeringMeetingIDs.contains(a.id) }

        // Answering A must not mark B as answering (meeting-scoped set, not a global bool).
        XCTAssertFalse(llm.answeringMeetingIDs.contains(b.id))

        // A second question for A while the first is in flight is rejected by the per-meeting guard.
        do {
            _ = try await llm.answerQuestion(for: a, question: "Follow-up?")
            XCTFail("Expected alreadyAnswering")
        } catch {
            XCTAssertEqual(error as? MeetingLLMError, .alreadyAnswering)
        }
        XCTAssertEqual(processor.callCount, 1, "the rejected second question must not reach the LLM")

        gate.open()
        _ = try await task.value
        XCTAssertFalse(llm.answeringMeetingIDs.contains(a.id), "the id clears when the answer settles")
        XCTAssertEqual(a.qaTurns.count, 1)
    }
}
