import XCTest
@testable import TypeWhisper

/// Track E (ME-3) — the shared never-clobber vault writer extracted from `MeetingObsidianExporter`
/// (plan D6). Proves the extracted trio in isolation against a temp directory: `sanitizeFilename`
/// strips illegal characters, `uniquePath` returns a free path as-is and suffixes an occupied one,
/// and `write` creates intermediate directories and **never overwrites** an existing note. The
/// exporter's own suite (`MeetingObsidianExporterTests`) is the end-to-end regression proof that this
/// extraction left export behavior bit-identical.
final class VaultNoteWriterTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = try TestSupport.makeTemporaryDirectory(prefix: "VaultNoteWriter")
        addTeardownBlock { [dir] in TestSupport.remove(dir!) }
    }

    // MARK: - sanitizeFilename

    func testSanitizeStripsIllegalCharactersAndTrims() {
        XCTAssertEqual(VaultNoteWriter.sanitizeFilename("Q3: Plan/Review*?"), "Q3 PlanReview")
        XCTAssertEqual(VaultNoteWriter.sanitizeFilename("  spaced  "), "spaced")
        XCTAssertEqual(VaultNoteWriter.sanitizeFilename("a\\b<c>d|e\"f"), "abcdef")
        // A clean name is unchanged (idempotent so caller-pre-sanitized names re-sanitize to themselves).
        XCTAssertEqual(VaultNoteWriter.sanitizeFilename("Acme Sync - Summary"), "Acme Sync - Summary")
    }

    // MARK: - uniquePath

    func testUniquePathReturnsFreePathUnchanged() {
        let free = (dir.path as NSString).appendingPathComponent("Note.md")
        XCTAssertEqual(VaultNoteWriter.uniquePath(for: free), free)
    }

    func testUniquePathSuffixesOccupiedPaths() throws {
        let base = (dir.path as NSString).appendingPathComponent("Note.md")
        try "one".write(toFile: base, atomically: true, encoding: .utf8)
        let second = VaultNoteWriter.uniquePath(for: base)
        XCTAssertEqual((second as NSString).lastPathComponent, "Note 1.md")

        try "two".write(toFile: second, atomically: true, encoding: .utf8)
        let third = VaultNoteWriter.uniquePath(for: base)
        XCTAssertEqual((third as NSString).lastPathComponent, "Note 2.md")
    }

    // MARK: - write

    func testWriteCreatesIntermediateDirectoriesAndFile() throws {
        let folder = (dir.path as NSString).appendingPathComponent("Clients/Acme")
        let url = try VaultNoteWriter.write(content: "# Hello\nbody", toFolder: folder, filename: "Roadmap")

        XCTAssertEqual(url.lastPathComponent, "Roadmap.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# Hello\nbody")
    }

    func testWriteNeverOverwritesAnExistingNote() throws {
        let folder = dir.path
        let first = try VaultNoteWriter.write(content: "first", toFolder: folder, filename: "Same")
        let second = try VaultNoteWriter.write(content: "second", toFolder: folder, filename: "Same")

        XCTAssertNotEqual(first.path, second.path)
        XCTAssertEqual(first.lastPathComponent, "Same.md")
        XCTAssertEqual(second.lastPathComponent, "Same 1.md")
        // Both survive with their own content — the first was never clobbered.
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "first")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "second")
    }

    func testWriteEmptyFilenameFallsBackToUntitled() throws {
        let url = try VaultNoteWriter.write(content: "x", toFolder: dir.path, filename: "")
        XCTAssertEqual(url.lastPathComponent, "Untitled.md")
    }
}
