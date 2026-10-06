import XCTest
@testable import TypeWhisper

/// [Perf Phase 2] `RelatedDocumentsMemo` + the pure `resolveRelatedDocuments`: the union is resolved
/// (and the vault statted) once per input change, not per body pass; it still refreshes on any input
/// change and after `maxAge`, and stays bounded.
@MainActor
final class RelatedDocumentsMemoTests: XCTestCase {
    private typealias Row = MeetingsViewModel.RelatedDocRow

    private var clock = Date(timeIntervalSince1970: 1_000)

    private func makeMemo(capacity: Int = 16, maxAge: TimeInterval = 30) -> RelatedDocumentsMemo {
        RelatedDocumentsMemo(capacity: capacity, maxAge: maxAge, now: { [unowned self] in self.clock })
    }

    private func input(
        meetingID: UUID = UUID(),
        vaultPath: String? = "/vault",
        attachedNotes: [String] = [],
        relatedJSON: String? = nil,
        excludedJSON: String? = nil
    ) -> RelatedDocumentsMemo.Input {
        RelatedDocumentsMemo.Input(
            meetingID: meetingID,
            vaultPath: vaultPath,
            attachedFolderPaths: [],
            attachedNotePaths: attachedNotes,
            relatedNotePathsJSON: relatedJSON,
            excludedNotePathsJSON: excludedJSON
        )
    }

    // MARK: - Pure resolve

    func testResolveUnionDedupesExcludesAndMarksMissing() {
        var config = FolderContextConfig()
        config.attachedFolderPaths = ["Projects"]
        config.attachedNotePaths = ["Projects/Plan.md", "Gone.md"]
        let related = [
            RelatedNote(path: "Projects/Plan.md", provenance: .discovered),   // dup of folder note
            RelatedNote(path: "Ideas/Pitch.md", provenance: .discovered),
            RelatedNote(path: "Mine.md", provenance: .manual),
            RelatedNote(path: "Hidden.md", provenance: .manual),
        ]
        var statted: [String] = []
        let rows = MeetingsViewModel.resolveRelatedDocuments(
            config: config,
            relatedNotes: related,
            excludedPaths: ["Hidden.md"],
            noteExists: { statted.append($0); return $0 != "Gone.md" }
        )
        XCTAssertEqual(rows.map(\.path), ["Projects", "Projects/Plan.md", "Gone.md", "Ideas/Pitch.md", "Mine.md"])
        XCTAssertEqual(rows.map(\.provenance), [.folder, .folder, .folder, .suggested, .manual])
        XCTAssertEqual(rows.filter(\.isMissing).map(\.path), ["Gone.md"])
        XCTAssertEqual(rows.first { $0.path == "Ideas/Pitch.md" }?.displayName, "Pitch")
        XCTAssertEqual(rows.first { $0.path == "Ideas/Pitch.md" }?.folderCaption, "Ideas")
        XCTAssertEqual(statted.count, 4, "one stat per note row, none for folders or excluded/dup paths")
    }

    // MARK: - Memo

    func testRepeatedReadsComputeOnce() {
        let memo = makeMemo()
        let key = input(attachedNotes: ["A.md"])
        let row = Row(path: "A.md", displayName: "A", folderCaption: "", provenance: .folder, isDirectory: false, isMissing: false)
        for _ in 0..<5 {
            XCTAssertEqual(memo.rows(for: key) { [row] }, [row])
        }
        XCTAssertEqual(memo.computeCount, 1)
    }

    func testInputChangeRecomputes() {
        let memo = makeMemo()
        let id = UUID()
        _ = memo.rows(for: input(meetingID: id)) { [] }
        _ = memo.rows(for: input(meetingID: id, relatedJSON: "[1]")) { [] }   // discovery / manual add
        _ = memo.rows(for: input(meetingID: id, relatedJSON: "[1]", excludedJSON: "[2]")) { [] }   // removal
        _ = memo.rows(for: input(meetingID: id, attachedNotes: ["B.md"], relatedJSON: "[1]", excludedJSON: "[2]")) { [] }
        _ = memo.rows(for: input(meetingID: id, vaultPath: "/other", attachedNotes: ["B.md"], relatedJSON: "[1]", excludedJSON: "[2]")) { [] }
        XCTAssertEqual(memo.computeCount, 5)
    }

    func testUnrelatedMeetingChangeDoesNotRecompute() {
        // The key carries only related-docs inputs; a transcript append / rename (which bumps
        // `updatedAt`) produces the same Input.
        let memo = makeMemo()
        let meeting = Meeting(title: "Sync")
        func key() -> RelatedDocumentsMemo.Input {
            input(meetingID: meeting.id, relatedJSON: meeting.relatedNotePathsJSON, excludedJSON: meeting.excludedNotePathsJSON)
        }
        _ = memo.rows(for: key()) { [] }
        meeting.title = "Sync (renamed)"
        meeting.updatedAt = Date().addingTimeInterval(60)
        _ = memo.rows(for: key()) { [] }
        XCTAssertEqual(memo.computeCount, 1)

        meeting.relatedNotePaths = [RelatedNote(path: "New.md", provenance: .manual)]
        _ = memo.rows(for: key()) { [] }
        XCTAssertEqual(memo.computeCount, 2)
    }

    func testEntryExpiresAfterMaxAge() {
        let memo = makeMemo(maxAge: 30)
        let key = input()
        _ = memo.rows(for: key) { [] }
        clock = clock.addingTimeInterval(29)
        _ = memo.rows(for: key) { [] }
        XCTAssertEqual(memo.computeCount, 1)
        clock = clock.addingTimeInterval(2)
        _ = memo.rows(for: key) { [] }
        XCTAssertEqual(memo.computeCount, 2, "re-stat after maxAge so external renames surface")
    }

    func testMemoIsBoundedLeastRecentlyUsed() {
        let memo = makeMemo(capacity: 2)
        let a = input(), b = input(), c = input()
        _ = memo.rows(for: a) { [] }
        _ = memo.rows(for: b) { [] }
        _ = memo.rows(for: a) { [] }   // a most recent
        _ = memo.rows(for: c) { [] }   // evicts b
        XCTAssertEqual(memo.count, 2)
        _ = memo.rows(for: a) { [] }
        XCTAssertEqual(memo.computeCount, 3)
        _ = memo.rows(for: b) { [] }
        XCTAssertEqual(memo.computeCount, 4)
    }
}
