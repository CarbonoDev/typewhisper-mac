import XCTest
@testable import TypeWhisper

/// [Perf 1C] The folder description is committed at commit points instead of per keystroke; these
/// pin that no edit is lost and that each write lands on the folder it was typed for.
final class FolderDescriptionDraftTests: XCTestCase {
    func testLoadedTextOwesNoWrite() {
        var draft = FolderDescriptionDraft(folderPath: "Clients/Acme", savedText: "acme")
        XCTAssertEqual(draft.text, "acme")
        XCTAssertFalse(draft.isDirty)
        XCTAssertNil(draft.takeCommit())
    }

    func testTypingOwesExactlyOneWriteOfTheLastText() {
        var draft = FolderDescriptionDraft(folderPath: "Clients/Acme", savedText: "")
        for text in ["A", "Ac", "Acme account"] { draft.text = text }

        XCTAssertEqual(draft.takeCommit(), .init(folderPath: "Clients/Acme", text: "Acme account"))
        XCTAssertNil(draft.takeCommit(), "a second commit point with no new typing writes nothing")

        draft.text = "Acme"
        XCTAssertEqual(draft.takeCommit(), .init(folderPath: "Clients/Acme", text: "Acme"))
    }

    func testClearingTheDescriptionIsAWrite() {
        var draft = FolderDescriptionDraft(folderPath: "Solo", savedText: "temp")
        draft.text = ""
        XCTAssertEqual(draft.takeCommit(), .init(folderPath: "Solo", text: ""))
    }

    func testSwitchingFoldersCommitsToThePreviousFolder() {
        var draft = FolderDescriptionDraft(folderPath: "Clients/Acme", savedText: "")
        draft.text = "typed for Acme"

        let owed = draft.switchFolder(to: "Clients/Globex", savedText: "globex")

        XCTAssertEqual(owed, .init(folderPath: "Clients/Acme", text: "typed for Acme"))
        XCTAssertEqual(draft.folderPath, "Clients/Globex")
        XCTAssertEqual(draft.text, "globex")
        XCTAssertFalse(draft.isDirty)
    }

    func testSwitchingWithoutEditsOwesNothing() {
        var draft = FolderDescriptionDraft(folderPath: "Clients/Acme", savedText: "acme")
        XCTAssertNil(draft.switchFolder(to: "Clients/Globex", savedText: ""))
    }
}
