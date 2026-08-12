import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

/// The D-M4 Q&A escalation flow ([Google Phase 3 · M4]) over a stub processor + stub Gmail
/// retriever: single shared round across both sources, per-combination disclosure prefixes,
/// invitation gating, pass-2 markers stripped never honored, and failure degradation.
@MainActor
final class MeetingLLMServiceEmailEscalationTests: XCTestCase {
    // MARK: - Stubs

    @MainActor
    private final class StubProcessor: PromptProcessing {
        struct Call {
            let prompt: String
            let text: String
        }

        var selectedProviderId = "qa-provider"
        var selectedCloudModel = "qa-model"
        private(set) var calls: [Call] = []
        var responder: (Int) -> String = { _ in "Answer." }

        func process(
            prompt: String,
            text: String,
            providerOverride: String?,
            cloudModelOverride: String?,
            temperatureDirective: PluginLLMTemperatureDirective,
            skipMemoryInjection: Bool
        ) async throws -> String {
            calls.append(Call(prompt: prompt, text: text))
            return responder(calls.count)
        }
    }

    @MainActor
    private final class StubGmailRetriever: GmailContextRetrieving {
        var connected = true
        var passages: [EmailPassage] = []
        var errorToThrow: Error?
        private(set) var retrieveCalls: [(query: String, limit: Int)] = []

        var isConnected: Bool { connected }
        func isConnected(for meeting: Meeting) -> Bool { connected }
        func retrieve(for meeting: Meeting, query: String, limit: Int) async throws -> [EmailPassage] {
            retrieveCalls.append((query, limit))
            if let errorToThrow { throw errorToThrow }
            return passages
        }
    }

    // MARK: - Fixtures

    private func makeDefaults() -> UserDefaults {
        let suite = "MeetingLLMEmailEscalation-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return defaults
    }

    private func disconnectedVault() -> ObsidianVaultService {
        ObsidianVaultService(defaults: makeDefaults())
    }

    /// A vault with one note that lexically matches "acme" search terms.
    private func connectedVault() throws -> ObsidianVaultService {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "QAEmailVault")
        addTeardownBlock { TestSupport.remove(dir) }
        try "# Acme\nThe acme roadmap. VAULT_NOTE_MARKER"
            .write(to: dir.appendingPathComponent("Acme.md"), atomically: true, encoding: .utf8)
        let vault = ObsidianVaultService(defaults: makeDefaults())
        vault.connect(to: dir.path)
        return vault
    }

    private func makeHarness(
        vault: ObsidianVaultService? = nil,
        gmail: GmailContextRetrieving?
    ) throws -> (service: MeetingLLMService, meetings: MeetingService, processor: StubProcessor, meeting: Meeting) {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "QAEmailMeetings")
        addTeardownBlock { TestSupport.remove(dir) }
        let meetings = MeetingService(appSupportDirectory: dir)
        let processor = StubProcessor()
        let service = MeetingLLMService(
            meetingService: meetings,
            vaultService: vault ?? disconnectedVault(),
            processor: processor,
            gmailService: gmail
        )
        let meeting = meetings.createMeeting(title: "Acme Sync", source: .adHoc, state: .completed)
        meetings.appendStableSegments(
            [TranscriptionSegment(text: "We talked about the acme contract.", start: 0, end: 3)],
            to: meeting
        )
        return (service, meetings, processor, meeting)
    }

    private func passage(content: String = "EMAIL_PASSAGE_MARKER") -> EmailPassage {
        EmailPassage(
            id: "google:subA:m1",
            accountSub: "subA",
            accountEmail: "suba@example.com",
            threadID: "t1",
            subject: "Contract",
            from: "Ada <ada@x.com>",
            date: Date(timeIntervalSince1970: 1_786_000_000),
            snippet: "snip",
            content: content
        )
    }

    private var vaultPrefix: String { String(localized: "meetings.qa.answer.vaultConsultedPrefix") }
    private var emailsPrefix: String { String(localized: "meetings.qa.answer.emailsConsultedPrefix") }
    private var bothPrefix: String { String(localized: "meetings.qa.answer.vaultAndEmailsConsultedPrefix") }
    private var notCovered: String { String(localized: "meetings.qa.answer.notCovered") }

    // MARK: - Invitation gating

    func testEmailInvitationAppendedOnlyWhenGmailConnectedForTheMeeting() async throws {
        // Connected → invitation present (with the literal marker).
        let gmail = StubGmailRetriever()
        let (service, _, processor, meeting) = try makeHarness(gmail: gmail)
        _ = try await service.answerQuestion(for: meeting, question: "What was agreed?")
        XCTAssertTrue(try XCTUnwrap(processor.calls.first).prompt.contains("EMAIL_SEARCH:"))

        // Not connected → no invitation.
        let gmailOff = StubGmailRetriever()
        gmailOff.connected = false
        let (service2, _, processor2, meeting2) = try makeHarness(gmail: gmailOff)
        _ = try await service2.answerQuestion(for: meeting2, question: "What was agreed?")
        XCTAssertFalse(try XCTUnwrap(processor2.calls.first).prompt.contains("EMAIL_SEARCH:"))

        // Nil seam → no invitation either.
        let (service3, _, processor3, meeting3) = try makeHarness(gmail: nil)
        _ = try await service3.answerQuestion(for: meeting3, question: "What was agreed?")
        XCTAssertFalse(try XCTUnwrap(processor3.calls.first).prompt.contains("EMAIL_SEARCH:"))
    }

    // MARK: - Single escalation round, per-source and combined

    func testEmailOnlyEscalationRunsOneRoundWithEmailsDisclosure() async throws {
        let gmail = StubGmailRetriever()
        gmail.passages = [passage()]
        let (service, _, processor, meeting) = try makeHarness(gmail: gmail)
        processor.responder = { index in index == 1 ? "EMAIL_SEARCH: contract invoice" : "From the email: shipped." }

        let turn = try await service.answerQuestion(for: meeting, question: "Did they ship?")

        XCTAssertEqual(processor.calls.count, 2, "exactly one escalation round")
        XCTAssertEqual(gmail.retrieveCalls.map(\.query), ["contract invoice"], "the marker's terms drive retrieval")
        XCTAssertEqual(gmail.retrieveCalls.map(\.limit), [3])
        XCTAssertTrue(processor.calls[1].text.contains("EMAIL_PASSAGE_MARKER"), "pass 2 carries the email block")
        XCTAssertTrue(turn.answer.hasPrefix(emailsPrefix), "emails-only disclosure")
        XCTAssertFalse(turn.answer.contains("EMAIL_SEARCH"))
    }

    func testVaultOnlyEscalationKeepsVaultDisclosureAndSkipsGmail() async throws {
        let gmail = StubGmailRetriever()
        let (service, _, processor, meeting) = try makeHarness(vault: try connectedVault(), gmail: gmail)
        processor.responder = { index in index == 1 ? "VAULT_SEARCH: acme roadmap" : "From the note: on track." }

        let turn = try await service.answerQuestion(for: meeting, question: "Roadmap status?")

        XCTAssertEqual(processor.calls.count, 2)
        XCTAssertTrue(processor.calls[1].text.contains("VAULT_NOTE_MARKER"))
        XCTAssertTrue(turn.answer.hasPrefix(vaultPrefix), "vault-only disclosure unchanged")
        XCTAssertTrue(gmail.retrieveCalls.isEmpty, "no email marker ⇒ no Gmail call")
    }

    func testBothMarkersRunWithinOneSharedRoundWithCombinedDisclosure() async throws {
        let gmail = StubGmailRetriever()
        gmail.passages = [passage()]
        let (service, _, processor, meeting) = try makeHarness(vault: try connectedVault(), gmail: gmail)
        processor.responder = { index in
            index == 1 ? "VAULT_SEARCH: acme roadmap\nEMAIL_SEARCH: contract" : "Combined answer."
        }

        let turn = try await service.answerQuestion(for: meeting, question: "Everything?")

        XCTAssertEqual(processor.calls.count, 2, "both retrievals share the single round — never a third pass")
        XCTAssertEqual(gmail.retrieveCalls.count, 1)
        XCTAssertTrue(processor.calls[1].text.contains("VAULT_NOTE_MARKER"))
        XCTAssertTrue(processor.calls[1].text.contains("EMAIL_PASSAGE_MARKER"))
        XCTAssertTrue(turn.answer.hasPrefix(bothPrefix), "both-sources disclosure")
    }

    func testBareEmailMarkerFallsBackToTheQuestionText() async throws {
        let gmail = StubGmailRetriever()
        gmail.passages = [passage()]
        let (service, _, processor, meeting) = try makeHarness(gmail: gmail)
        processor.responder = { index in index == 1 ? "EMAIL_SEARCH:" : "Answer." }

        _ = try await service.answerQuestion(for: meeting, question: "Did they sign the contract?")

        XCTAssertEqual(gmail.retrieveCalls.map(\.query), ["Did they sign the contract?"])
    }

    // MARK: - Loop guard + degradation

    func testPassTwoMarkerIsStrippedNeverHonored() async throws {
        let gmail = StubGmailRetriever()
        gmail.passages = [passage()]
        let (service, _, processor, meeting) = try makeHarness(gmail: gmail)
        // Pass 2 wraps prose around ANOTHER marker (either form) — prose kept, marker stripped,
        // no third round.
        processor.responder = { index in
            index == 1 ? "EMAIL_SEARCH: contract" : "Partial answer.\nVAULT_SEARCH: more\nEMAIL_SEARCH: again"
        }

        let turn = try await service.answerQuestion(for: meeting, question: "Q?")

        XCTAssertEqual(processor.calls.count, 2, "loop guard: never a third LLM pass")
        XCTAssertEqual(gmail.retrieveCalls.count, 1, "the pass-2 marker triggers no retrieval")
        XCTAssertTrue(turn.answer.hasSuffix("Partial answer."))
        XCTAssertFalse(turn.answer.contains("SEARCH:"))
    }

    func testAllMarkerPassTwoReplyDegradesToNotCovered() async throws {
        let gmail = StubGmailRetriever()
        gmail.passages = [passage()]
        let (service, _, processor, meeting) = try makeHarness(gmail: gmail)
        processor.responder = { index in index == 1 ? "EMAIL_SEARCH: contract" : "EMAIL_SEARCH: again" }

        let turn = try await service.answerQuestion(for: meeting, question: "Q?")

        XCTAssertEqual(turn.answer, notCovered)
        XCTAssertEqual(processor.calls.count, 2)
    }

    func testEmptyEmailResultsDegradeToNotCoveredWithoutPassTwo() async throws {
        let gmail = StubGmailRetriever() // returns []
        let (service, _, processor, meeting) = try makeHarness(gmail: gmail)
        processor.responder = { _ in "EMAIL_SEARCH: contract" }

        let turn = try await service.answerQuestion(for: meeting, question: "Q?")

        XCTAssertEqual(turn.answer, notCovered)
        XCTAssertEqual(processor.calls.count, 1, "all requested retrievals empty ⇒ no pass 2")
    }

    func testGmailFailureDegradesToVaultOnlyPassTwo() async throws {
        let gmail = StubGmailRetriever()
        gmail.errorToThrow = URLError(.notConnectedToInternet)
        let (service, _, processor, meeting) = try makeHarness(vault: try connectedVault(), gmail: gmail)
        processor.responder = { index in
            index == 1 ? "VAULT_SEARCH: acme roadmap\nEMAIL_SEARCH: contract" : "Vault-grounded answer."
        }

        let turn = try await service.answerQuestion(for: meeting, question: "Q?")

        XCTAssertEqual(processor.calls.count, 2, "the retriever throw never fails the answer")
        XCTAssertTrue(processor.calls[1].text.contains("VAULT_NOTE_MARKER"))
        XCTAssertFalse(processor.calls[1].text.contains("EMAIL_PASSAGE_MARKER"))
        XCTAssertTrue(turn.answer.hasPrefix(vaultPrefix), "disclosure reflects what was actually consulted")
    }

    func testGmailFailureAloneDegradesToNotCovered() async throws {
        let gmail = StubGmailRetriever()
        gmail.errorToThrow = URLError(.timedOut)
        let (service, _, processor, meeting) = try makeHarness(gmail: gmail)
        processor.responder = { _ in "EMAIL_SEARCH: contract" }

        let turn = try await service.answerQuestion(for: meeting, question: "Q?")

        XCTAssertEqual(turn.answer, notCovered)
        XCTAssertEqual(processor.calls.count, 1)
    }

    // MARK: - Nil seam / unprompted marker

    func testNilSeamNormalAnswerIsUntouched() async throws {
        let (service, _, processor, meeting) = try makeHarness(gmail: nil)
        processor.responder = { _ in "A plain answer." }

        let turn = try await service.answerQuestion(for: meeting, question: "Q?")

        XCTAssertEqual(turn.answer, "A plain answer.")
        XCTAssertEqual(processor.calls.count, 1)
    }

    func testUnpromptedEmailMarkerWithNilSeamDegradesToNotCovered() async throws {
        // Spec-decided (D-M4 stripping supersession): the marker is honored as an escalation
        // request and both sources turn up empty ⇒ "not covered" — the token itself is never
        // persisted (mirrors the vault marker's no-vault safety net).
        let (service, _, processor, meeting) = try makeHarness(gmail: nil)
        processor.responder = { _ in "EMAIL_SEARCH: contract" }

        let turn = try await service.answerQuestion(for: meeting, question: "Q?")

        XCTAssertEqual(turn.answer, notCovered)
        XCTAssertEqual(processor.calls.count, 1)
    }
}
