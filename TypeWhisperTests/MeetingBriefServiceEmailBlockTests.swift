import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

/// The brief's related-emails block ([Google Phase 3 · M3], D-M3) over a stub
/// `GmailContextRetrieving`: sole-grounding guard in both directions, block rendering, thrown
/// retrieval degrading to an empty block, the reserved-slice budget mechanics (including the
/// KB-subtracts-emailReserve fix), section ordering, and the nil-seam regression.
@MainActor
final class MeetingBriefServiceEmailBlockTests: XCTestCase {
    // MARK: - Stubs

    @MainActor
    private final class StubProcessor: PromptProcessing {
        var selectedProviderId = "brief-provider"
        var selectedCloudModel = "brief-model"
        private(set) var texts: [String] = []
        func process(
            prompt: String,
            text: String,
            providerOverride: String?,
            cloudModelOverride: String?,
            temperatureDirective: PluginLLMTemperatureDirective,
            skipMemoryInjection: Bool
        ) async throws -> String {
            texts.append(text)
            return "BRIEF_RESULT"
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
        let suite = "MeetingBriefEmailTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return defaults
    }

    private func makeMeetingService() throws -> MeetingService {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "MeetingBriefEmail")
        addTeardownBlock { TestSupport.remove(dir) }
        return MeetingService(appSupportDirectory: dir)
    }

    private func disconnectedVault() -> ObsidianVaultService {
        ObsidianVaultService(defaults: makeDefaults())
    }

    /// A vault whose single matching note is large enough to overflow a small KB slice.
    private func hugeVault(defaults: UserDefaults) throws -> ObsidianVaultService {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "MeetingBriefEmailVault")
        addTeardownBlock { TestSupport.remove(dir) }
        let filler = String(repeating: "acme sync roadmap filler ", count: 120)
        try "# Acme\nVAULT_HEAD_MARKER \(filler)"
            .write(to: dir.appendingPathComponent("Acme Overview.md"), atomically: true, encoding: .utf8)
        let service = ObsidianVaultService(defaults: defaults)
        service.connect(to: dir.path)
        return service
    }

    private func briefService(
        meetings: MeetingService,
        vault: ObsidianVaultService,
        processor: StubProcessor,
        gmail: GmailContextRetrieving?,
        charBudget: Int = TranscriptContextBuilder.defaultCharBudget
    ) -> MeetingBriefService {
        MeetingBriefService(
            meetingService: meetings,
            vaultService: vault,
            processor: processor,
            gmailService: gmail,
            charBudget: charBudget
        )
    }

    /// A scheduled target meeting; `withPriors` adds N completed attendee-matched meetings whose
    /// summaries carry `PRIOR_MARKER_<i>` heads followed by `fillerChars` of padding.
    private func seedTarget(
        on service: MeetingService,
        attendees: [Attendee],
        priors: Int = 0,
        priorFillerChars: Int = 0
    ) -> Meeting {
        let target = service.createMeeting(
            title: "Acme Sync",
            source: .calendar,
            state: .scheduled,
            startDate: Date(timeIntervalSince1970: 1_786_399_200),
            seriesID: "series-em",
            attendees: attendees
        )
        for index in 0..<priors {
            // Series-matched so priors relate to the target regardless of its attendee shape
            // (the title-only tests carry a self-only attendee list).
            let prior = service.createMeeting(
                title: "Acme Sync #\(index)",
                source: .calendar,
                state: .completed,
                startDate: Date(timeIntervalSince1970: 1_786_399_200).addingTimeInterval(TimeInterval(-(index + 1)) * 86_400),
                seriesID: "series-em",
                attendees: [Attendee(name: "Ada", email: "ada@x.com")]
            )
            let filler = String(repeating: "p ", count: max(0, priorFillerChars / 2))
            service.addOutput(to: prior, kind: .summary, content: "PRIOR_MARKER_\(index) \(filler)")
        }
        return target
    }

    private func passage(subject: String = "Contract terms", content: String) -> EmailPassage {
        EmailPassage(
            id: "google:subA:m1",
            accountSub: "subA",
            accountEmail: "suba@example.com",
            threadID: "t1",
            subject: subject,
            from: "Ada Lovelace <ada@x.com>",
            date: Date(timeIntervalSince1970: 1_786_000_000),
            snippet: "snip",
            content: content
        )
    }

    private let attendeeAda = [Attendee(name: "Ada", email: "ada@x.com")]
    private var emailsHeader: String { String(localized: "meetings.brief.context.emailsHeader") }

    // MARK: - Sole-grounding guard (D-M3, both directions)

    func testEmailOnlyContextGroundsABriefWhenANonSelfAttendeeEmailExists() async throws {
        let meetings = try makeMeetingService()
        let processor = StubProcessor()
        let gmail = StubGmailRetriever()
        gmail.passages = [passage(content: "EMAIL_MARKER budget attached.")]
        let service = briefService(meetings: meetings, vault: disconnectedVault(), processor: processor, gmail: gmail)
        let target = seedTarget(on: meetings, attendees: attendeeAda)

        let output = try await service.generateBrief(for: target)

        XCTAssertEqual(output.kind, .brief)
        let text = try XCTUnwrap(processor.texts.first)
        XCTAssertTrue(text.contains(emailsHeader))
        XCTAssertTrue(text.contains("EMAIL_MARKER"))
        // Block rendering: "### <subject> — <from>, <date>" heads each passage.
        XCTAssertTrue(text.contains("### Contract terms — Ada Lovelace <ada@x.com>,"), "citation shape: \(text)")
        // The meeting-centric seam is called with the vault's retrieval query text, limit 3.
        let call = try XCTUnwrap(gmail.retrieveCalls.first)
        XCTAssertEqual(call.limit, 3)
        XCTAssertTrue(call.query.contains("Acme Sync"))
        XCTAssertTrue(call.query.contains("Ada"))
    }

    func testTitleOnlyEmailContextNeverSolelyGroundsABrief() async throws {
        let meetings = try makeMeetingService()
        let processor = StubProcessor()
        let gmail = StubGmailRetriever()
        gmail.passages = [passage(content: "EMAIL_MARKER title-term match only.")]
        let service = briefService(meetings: meetings, vault: disconnectedVault(), processor: processor, gmail: gmail)
        // Only a self attendee — the attendee clause of the Gmail query was nil, so the matches
        // are title-anchored only (D-M3 sole-grounding restriction).
        let target = seedTarget(on: meetings, attendees: [Attendee(name: "Me", email: "me@x.com", isSelf: true)])

        do {
            _ = try await service.generateBrief(for: target)
            XCTFail("title-only email context must not solely ground a brief")
        } catch let error as MeetingBriefError {
            XCTAssertEqual(error, .insufficientContext)
        }
        XCTAssertTrue(processor.texts.isEmpty, "no LLM call")
        XCTAssertTrue(target.outputs.isEmpty, "nothing persisted")
    }

    func testTitleOnlyEmailContextStillAugmentsABriefGroundedElsewhere() async throws {
        let meetings = try makeMeetingService()
        let processor = StubProcessor()
        let gmail = StubGmailRetriever()
        gmail.passages = [passage(content: "EMAIL_MARKER augmenting.")]
        let service = briefService(meetings: meetings, vault: disconnectedVault(), processor: processor, gmail: gmail)
        let target = seedTarget(
            on: meetings,
            attendees: [Attendee(name: "Me", email: "me@x.com", isSelf: true)],
            priors: 1
        )

        _ = try await service.generateBrief(for: target)

        let text = try XCTUnwrap(processor.texts.first)
        XCTAssertTrue(text.contains("PRIOR_MARKER_0"), "prior meetings ground the brief")
        XCTAssertTrue(text.contains("EMAIL_MARKER"), "title-only email context may still augment")
    }

    // MARK: - Failure degradation (D-M3)

    func testThrownRetrievalDegradesToEmptyBlockAndBriefStillGenerates() async throws {
        let meetings = try makeMeetingService()
        let processor = StubProcessor()
        let gmail = StubGmailRetriever()
        gmail.errorToThrow = URLError(.notConnectedToInternet)
        let service = briefService(meetings: meetings, vault: disconnectedVault(), processor: processor, gmail: gmail)
        let target = seedTarget(on: meetings, attendees: attendeeAda, priors: 1)

        let output = try await service.generateBrief(for: target)

        XCTAssertEqual(output.content, "BRIEF_RESULT", "a Gmail outage never fails the brief")
        let text = try XCTUnwrap(processor.texts.first)
        XCTAssertTrue(text.contains("PRIOR_MARKER_0"))
        XCTAssertFalse(text.contains(emailsHeader), "no empty emails section")
        XCTAssertEqual(gmail.retrieveCalls.count, 1)
    }

    // MARK: - Budget mechanics (D-M3 fix — REQUIRED)

    /// ~400 chars with head and tail markers: surviving in full proves the email slice kept at
    /// least ~its reserve (charBudget/4 = 500 here) despite two oversized upstream blocks.
    private var boundedEmailContent: String {
        "EMAIL_HEAD_MARKER \(String(repeating: "email filler ", count: 28))EMAIL_TAIL_MARKER"
    }

    func testEmailSliceSurvivesHugePriorPlusHugeKnowledgeBase() async throws {
        let defaults = makeDefaults()
        let meetings = try makeMeetingService()
        let processor = StubProcessor()
        let gmail = StubGmailRetriever()
        gmail.passages = [passage(content: boundedEmailContent)]
        let service = briefService(
            meetings: meetings,
            vault: try hugeVault(defaults: defaults),
            processor: processor,
            gmail: gmail,
            charBudget: 2_000
        )
        // Three priors with ~700-char summaries overflow the prior slice; the vault note
        // overflows the KB slice. Without the KB-subtracts-emailReserve fix the KB block would
        // absorb all remaining budget and the final whole-string bound would cut the email tail.
        let target = seedTarget(on: meetings, attendees: attendeeAda, priors: 3, priorFillerChars: 700)

        _ = try await service.generateBrief(for: target)

        let text = try XCTUnwrap(processor.texts.first)
        XCTAssertTrue(text.contains("PRIOR_MARKER_0"))
        XCTAssertTrue(text.contains("VAULT_HEAD_MARKER"))
        XCTAssertTrue(text.contains("EMAIL_HEAD_MARKER"))
        XCTAssertTrue(
            text.contains("EMAIL_TAIL_MARKER"),
            "the email slice must survive at ≥ its reserve — the KB block subtracts the trailing email reserve"
        )
        XCTAssertLessThanOrEqual(text.count, 2_000 + 50, "whole-context bound holds")
    }

    func testEmailSliceSurvivesHugePriorAlone() async throws {
        let meetings = try makeMeetingService()
        let processor = StubProcessor()
        let gmail = StubGmailRetriever()
        gmail.passages = [passage(content: boundedEmailContent)]
        let service = briefService(
            meetings: meetings,
            vault: disconnectedVault(),
            processor: processor,
            gmail: gmail,
            charBudget: 2_000
        )
        let target = seedTarget(on: meetings, attendees: attendeeAda, priors: 4, priorFillerChars: 700)

        _ = try await service.generateBrief(for: target)

        let text = try XCTUnwrap(processor.texts.first)
        XCTAssertTrue(text.contains("EMAIL_HEAD_MARKER"))
        XCTAssertTrue(text.contains("EMAIL_TAIL_MARKER"), "the prior block subtracts the email reserve")
    }

    // MARK: - Ordering + nil-seam regression

    func testSectionOrderIsPriorThenKnowledgeBaseThenEmails() async throws {
        let defaults = makeDefaults()
        let meetings = try makeMeetingService()
        let processor = StubProcessor()
        let gmail = StubGmailRetriever()
        gmail.passages = [passage(content: "EMAIL_HEAD_MARKER short.")]
        let service = briefService(
            meetings: meetings,
            vault: try hugeVault(defaults: defaults),
            processor: processor,
            gmail: gmail
        )
        let target = seedTarget(on: meetings, attendees: attendeeAda, priors: 1)

        _ = try await service.generateBrief(for: target)

        let text = try XCTUnwrap(processor.texts.first)
        let prior = try XCTUnwrap(text.range(of: "PRIOR_MARKER_0"))
        let vault = try XCTUnwrap(text.range(of: "VAULT_HEAD_MARKER"))
        let email = try XCTUnwrap(text.range(of: "EMAIL_HEAD_MARKER"))
        XCTAssertLessThan(prior.lowerBound, vault.lowerBound, "meta → prior → knowledge base → emails")
        XCTAssertLessThan(vault.lowerBound, email.lowerBound)
    }

    func testNilGmailServiceProducesByteIdenticalContext() async throws {
        let meetings = try makeMeetingService()
        let target = seedTarget(on: meetings, attendees: attendeeAda, priors: 2, priorFillerChars: 100)

        let nilProcessor = StubProcessor()
        let nilService = briefService(meetings: meetings, vault: disconnectedVault(), processor: nilProcessor, gmail: nil)
        _ = try await nilService.generateBrief(for: target)

        // A throwing retriever (empty block) must assemble the exact same bytes the nil seam does
        // — proving the email plumbing is inert when it contributes nothing.
        let throwingProcessor = StubProcessor()
        let gmail = StubGmailRetriever()
        gmail.errorToThrow = URLError(.timedOut)
        let throwingService = briefService(meetings: meetings, vault: disconnectedVault(), processor: throwingProcessor, gmail: gmail)
        _ = try await throwingService.generateBrief(for: target)

        let nilText = try XCTUnwrap(nilProcessor.texts.first)
        let throwingText = try XCTUnwrap(throwingProcessor.texts.first)
        XCTAssertEqual(nilText, throwingText)
        XCTAssertFalse(nilText.contains(emailsHeader))
    }
}
