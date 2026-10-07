import XCTest
@testable import TypeWhisper

/// Home's needs-attention rows (`HomeAttentionSection.attentionRows`) show the clean display title,
/// like the archive rows and the timeline: a legacy Drive import may still store its raw doc name.
@MainActor
final class HomeAttentionRowsTests: XCTestCase {
    private let rawTitle = "Seguimiento BD Daniel - 2026/04/02 09:00 CST"
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    func testEveryAttentionKindShowsTheCleanTitle() {
        let start = now.addingTimeInterval(-3600)
        let interrupted = Meeting(title: rawTitle, state: .interrupted, startDate: start)
        let openActions = Meeting(title: rawTitle, state: .completed, startDate: start)
        let noSummary = Meeting(title: rawTitle, state: .completed, startDate: start)

        let rows = HomeAttentionSection.attentionRows(
            meetings: [interrupted, openActions, noSummary],
            now: now,
            actionFacts: { $0.id == openActions.id ? MeetingActionFacts(openCount: 2, totalCount: 3) : nil },
            hasTranscript: { $0.id == noSummary.id }
        )

        XCTAssertEqual(rows.map(\.meetingID), [interrupted.id, openActions.id, noSummary.id])
        XCTAssertEqual(rows.map(\.detail), Array(repeating: "Seguimiento BD Daniel", count: 3))
        XCTAssertEqual(interrupted.title, rawTitle, "display derivation never rewrites the stored title")
    }

    func testPlainTitlePassesThrough() {
        let meeting = Meeting(title: "Planning poker (2)", state: .interrupted, startDate: now)
        let rows = HomeAttentionSection.attentionRows(
            meetings: [meeting], now: now, actionFacts: { _ in nil }, hasTranscript: { _ in false }
        )
        XCTAssertEqual(rows.map(\.detail), ["Planning poker (2)"])
    }
}
