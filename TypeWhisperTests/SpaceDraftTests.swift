import XCTest
@testable import TypeWhisper

/// Track E (ME-3) — the pure quick-note draft seam (plan D1). Deterministic, vault-free coverage of
/// first-line filename derivation (incl. the empty / whitespace-only / heading-only branches and
/// illegal-character sanitization) and the discard-confirmation decision.
final class SpaceDraftTests: XCTestCase {
    // MARK: - firstLineTitle

    func testFirstLineTitlePlainLine() {
        XCTAssertEqual(SpaceDraft.firstLineTitle("Roadmap Q3\nmore body"), "Roadmap Q3")
    }

    func testFirstLineTitleStripsLeadingHeadingMarker() {
        XCTAssertEqual(SpaceDraft.firstLineTitle("# Roadmap\nbody"), "Roadmap")
        XCTAssertEqual(SpaceDraft.firstLineTitle("###   Deep heading"), "Deep heading")
    }

    func testFirstLineTitleSkipsBlankAndHeadingOnlyLeadingLines() {
        // Leading blank lines and a bare "##" (heading marker with no text) are skipped.
        XCTAssertEqual(SpaceDraft.firstLineTitle("\n\n##\nActual title"), "Actual title")
    }

    func testFirstLineTitleNilWhenNoUsableLine() {
        XCTAssertNil(SpaceDraft.firstLineTitle(""))
        XCTAssertNil(SpaceDraft.firstLineTitle("   \n\t\n"))
        XCTAssertNil(SpaceDraft.firstLineTitle("#\n##\n###"))
    }

    // MARK: - filename

    func testFilenameDerivesFromFirstLine() {
        XCTAssertEqual(SpaceDraft.filename(from: "Roadmap Q3\nbody"), "Roadmap Q3")
        XCTAssertEqual(SpaceDraft.filename(from: "# Kickoff Notes"), "Kickoff Notes")
    }

    func testFilenameSanitizesIllegalCharacters() {
        XCTAssertEqual(SpaceDraft.filename(from: "Plan: A/B?\nbody"), "Plan AB")
    }

    func testFilenameFallsBackToUntitled() {
        XCTAssertEqual(SpaceDraft.filename(from: ""), "Untitled")
        XCTAssertEqual(SpaceDraft.filename(from: "   \n  "), "Untitled")
        // A first line of only illegal characters sanitizes to empty → the fallback.
        XCTAssertEqual(SpaceDraft.filename(from: "/:*?"), "Untitled")
    }

    // MARK: - discard / emptiness

    func testIsEmpty() {
        XCTAssertTrue(SpaceDraft.isEmpty(""))
        XCTAssertTrue(SpaceDraft.isEmpty("  \n\t "))
        XCTAssertFalse(SpaceDraft.isEmpty("x"))
    }

    func testShouldConfirmDiscardOnlyWhenNonEmpty() {
        XCTAssertFalse(SpaceDraft.shouldConfirmDiscard(""))
        XCTAssertFalse(SpaceDraft.shouldConfirmDiscard("   \n "))
        XCTAssertTrue(SpaceDraft.shouldConfirmDiscard("draft content"))
    }
}
