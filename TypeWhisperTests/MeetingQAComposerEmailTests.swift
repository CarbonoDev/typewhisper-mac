import XCTest
@testable import TypeWhisper

/// The D-M4 composer surface ([Google Phase 3 · M4]): `EMAIL_SEARCH:` detection mirroring the
/// vault marker's line-prefix contract, `strippingEscalationLines` covering both forms, and the
/// `retrievedEmailPassages` block — rendered last, budget-sliced, withheld without a transcript.
final class MeetingQAComposerEmailTests: XCTestCase {
    // MARK: - Fixtures

    private func segment(_ text: String, start: Double = 0) -> TranscriptContextBuilder.Segment {
        TranscriptContextBuilder.Segment(start: start, text: text)
    }

    private func emailPassage(content: String = "EMAIL_CONTENT_MARKER") -> EmailPassage {
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

    private func vaultPassage(content: String = "VAULT_CONTENT_MARKER") -> VaultPassage {
        VaultPassage(id: "note.md", title: "Note", tags: [], content: content)
    }

    private var emailsHeader: String { String(localized: "meetings.qa.context.emailsHeader") }
    private var retrievedHeader: String { String(localized: "meetings.qa.context.retrievedHeader") }

    // MARK: - Marker detection (the vaultSearchTerms twin)

    func testEmailSearchTermsDetectsLineStartCaseInsensitive() {
        XCTAssertEqual(MeetingQAComposer.emailSearchTerms(in: "EMAIL_SEARCH: contract terms"), "contract terms")
        XCTAssertEqual(
            MeetingQAComposer.emailSearchTerms(in: "I couldn't find this.\n  email_search: acme invoice"),
            "acme invoice",
            "any line start, case-insensitive, prose-wrapped"
        )
        XCTAssertEqual(MeetingQAComposer.emailSearchTerms(in: "EMAIL_SEARCH:"), "", "bare marker signals question-text fallback")
    }

    func testEmailSearchTermsIgnoresMidSentenceMentionsAndAbsence() {
        XCTAssertNil(MeetingQAComposer.emailSearchTerms(in: "The model can reply EMAIL_SEARCH: terms when needed."))
        XCTAssertNil(MeetingQAComposer.emailSearchTerms(in: "A normal answer."))
        XCTAssertNil(MeetingQAComposer.emailSearchTerms(in: "VAULT_SEARCH: acme"), "the vault marker is not the email marker")
    }

    func testMarkersDetectIndependentlyInOneReply() {
        let reply = "VAULT_SEARCH: roadmap\nEMAIL_SEARCH: contract"
        XCTAssertEqual(MeetingQAComposer.vaultSearchTerms(in: reply), "roadmap")
        XCTAssertEqual(MeetingQAComposer.emailSearchTerms(in: reply), "contract")
    }

    // MARK: - Stripping (both forms)

    func testStrippingEscalationLinesRemovesBothMarkerFormsKeepingProse() {
        let reply = "Some prose.\nVAULT_SEARCH: roadmap\nMore prose.\nEMAIL_SEARCH: contract\nEnd."
        XCTAssertEqual(
            MeetingQAComposer.strippingEscalationLines(from: reply),
            "Some prose.\nMore prose.\nEnd."
        )
    }

    func testStrippingKeepsMidSentenceMentionsAndCollapsesAllMarkerRepliesToEmpty() {
        XCTAssertEqual(
            MeetingQAComposer.strippingEscalationLines(from: "You could say EMAIL_SEARCH: here mid-sentence."),
            "You could say EMAIL_SEARCH: here mid-sentence."
        )
        XCTAssertEqual(
            MeetingQAComposer.strippingEscalationLines(from: "VAULT_SEARCH: a\nEMAIL_SEARCH: b"),
            "",
            "an all-marker reply collapses to empty (caller substitutes not-covered)"
        )
    }

    func testStrippingVaultSearchLinesCallThroughNowCoversBothForms() {
        XCTAssertEqual(
            MeetingQAComposer.strippingVaultSearchLines(from: "Keep.\nEMAIL_SEARCH: x"),
            "Keep.",
            "the predating entry point strips the email form too (D-M4 supersession)"
        )
    }

    // MARK: - compose: email block

    func testEmailBlockRendersLastWithCitationShape() throws {
        let text = MeetingQAComposer.compose(
            question: "What did the contract say?",
            segments: [segment("We discussed the contract.")],
            upTo: nil,
            priorTurns: [],
            knowledgePassages: [],
            retrievedPassages: [vaultPassage()],
            retrievedEmailPassages: [emailPassage()]
        )
        let vaultRange = try XCTUnwrap(text.range(of: retrievedHeader))
        let emailRange = try XCTUnwrap(text.range(of: emailsHeader))
        XCTAssertLessThan(vaultRange.lowerBound, emailRange.lowerBound, "emails render after the retrieved-vault block")
        XCTAssertTrue(text.contains("EMAIL_CONTENT_MARKER"))
        XCTAssertTrue(text.contains("### Contract — Ada <ada@x.com>,"), "the M3 citation shape")
        // The question section still closes the payload (it must survive the final bound).
        let questionRange = try XCTUnwrap(text.range(of: String(localized: "meetings.qa.context.questionHeader")))
        XCTAssertLessThan(emailRange.lowerBound, questionRange.lowerBound)
    }

    func testEmailBlockWithheldWhenTranscriptIsEmpty() {
        let text = MeetingQAComposer.compose(
            question: "Anything?",
            segments: [],
            upTo: nil,
            priorTurns: [],
            knowledgePassages: [],
            retrievedEmailPassages: [emailPassage()]
        )
        XCTAssertFalse(text.contains(emailsHeader), "retrieval never stands in as the sole grounding")
        XCTAssertFalse(text.contains("EMAIL_CONTENT_MARKER"))
    }

    func testEmailBlockWithheldForMidCaptureOffsetBeforeAnySpeech() {
        let text = MeetingQAComposer.compose(
            question: "Anything?",
            segments: [segment("Spoken later.", start: 100)],
            upTo: 10, // question asked before anything visible was spoken
            priorTurns: [],
            knowledgePassages: [],
            retrievedEmailPassages: [emailPassage()]
        )
        XCTAssertFalse(text.contains(emailsHeader))
    }

    func testEmailBlockIsBoundedToItsQuarterSlice() throws {
        let budget = 2_000
        let huge = "EMAIL_HEAD " + String(repeating: "filler ", count: 400) // ~2.8k chars ≫ slice
        let text = MeetingQAComposer.compose(
            question: "What about the contract?",
            segments: [segment("Contract talk.")],
            upTo: nil,
            priorTurns: [],
            knowledgePassages: [],
            retrievedEmailPassages: [emailPassage(content: huge)],
            charBudget: budget
        )
        let emailStart = try XCTUnwrap(text.range(of: emailsHeader)).lowerBound
        let questionStart = try XCTUnwrap(text.range(of: String(localized: "meetings.qa.context.questionHeader"))).lowerBound
        let emailSection = text[emailStart..<questionStart]
        XCTAssertTrue(emailSection.contains("EMAIL_HEAD"))
        XCTAssertLessThanOrEqual(
            emailSection.count,
            budget / 4 + emailsHeader.count + 64,
            "the email block gets its own charBudget/4 slice, not the remainder"
        )
    }
}
