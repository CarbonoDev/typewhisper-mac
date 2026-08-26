import XCTest
@testable import TypeWhisper

/// Track E (ME-1) — the pure Space tree builder. SwiftUI-free and I/O-free: exercises building,
/// folders-before-notes ordering, nesting, component-wise root scoping, and the empty-root
/// (whole-vault) escape hatch directly over `[VaultEntry]` snapshots (no vault required).
final class SpaceTreeModelTests: XCTestCase {

    /// A representative `listEntries()`-shaped snapshot: folders (isDirectory) and `.md` note leaves,
    /// including a `Acme` / `Acme2` sibling pair to prove component-wise scoping and a note that must
    /// sort *after* folders at its level.
    private func sampleEntries() -> [VaultEntry] {
        func dir(_ p: String) -> VaultEntry {
            VaultEntry(relativePath: p, displayName: (p as NSString).lastPathComponent, isDirectory: true)
        }
        func note(_ p: String) -> VaultEntry {
            let stem = (((p as NSString).lastPathComponent) as NSString).deletingPathExtension
            return VaultEntry(relativePath: p, displayName: stem, isDirectory: false)
        }
        return [
            dir("Meetings"),
            dir("Meetings/Alpha"),
            dir("Meetings/Clients"),
            dir("Meetings/Clients/Acme"),
            note("Meetings/Clients/Acme/Roadmap.md"),
            dir("Meetings/Clients/Acme2"),
            note("Meetings/Clients/Acme2/Other.md"),
            note("Meetings/Zeta.md"),
            dir("Personal"),
            note("Personal/Diary.md"),
        ]
    }

    // MARK: - Building & nesting

    func testBuildRootedAtMeetingsYieldsImmediateChildren() {
        let tree = SpaceTreeModel.build(from: sampleEntries(), root: "Meetings")
        // Top level = immediate children of "Meetings": folders Alpha, Clients then note Zeta.
        XCTAssertEqual(tree.map(\.name), ["Alpha", "Clients", "Zeta"])
        XCTAssertEqual(tree.map(\.relativePath), ["Meetings/Alpha", "Meetings/Clients", "Meetings/Zeta.md"])
    }

    func testNestingCarriesNoteLeaves() {
        let tree = SpaceTreeModel.build(from: sampleEntries(), root: "Meetings")
        let clients = try! XCTUnwrap(tree.first { $0.name == "Clients" })
        XCTAssertEqual(clients.children.map(\.name), ["Acme", "Acme2"])
        let acme = try! XCTUnwrap(clients.children.first { $0.name == "Acme" })
        XCTAssertEqual(acme.children.map(\.name), ["Roadmap"])
        let roadmap = try! XCTUnwrap(acme.children.first)
        XCTAssertFalse(roadmap.isDirectory)
        XCTAssertTrue(roadmap.children.isEmpty, "note leaves carry no children")
    }

    // MARK: - Ordering (folders before notes, then case-insensitive by name)

    func testFoldersSortBeforeNotesAtEachLevel() {
        // A level mixing folders and notes: folders must precede notes regardless of name.
        let entries = [
            VaultEntry(relativePath: "Root", displayName: "Root", isDirectory: true),
            VaultEntry(relativePath: "Root/aaa.md", displayName: "aaa", isDirectory: false),
            VaultEntry(relativePath: "Root/ZFolder", displayName: "ZFolder", isDirectory: true),
        ]
        let tree = SpaceTreeModel.build(from: entries, root: "Root")
        XCTAssertEqual(tree.map(\.name), ["ZFolder", "aaa"], "folder ZFolder precedes note aaa")
        XCTAssertEqual(tree.map(\.isDirectory), [true, false])
    }

    // MARK: - Root scoping (component-wise: Acme never covers Acme2)

    func testScopedUnderRootIsComponentWise() {
        let scoped = SpaceTreeModel.scoped(sampleEntries(), under: "Meetings/Clients/Acme")
        let paths = scoped.map(\.relativePath)
        XCTAssertTrue(paths.contains("Meetings/Clients/Acme/Roadmap.md"))
        XCTAssertFalse(paths.contains("Meetings/Clients/Acme2/Other.md"), "Acme must not cover Acme2")
        XCTAssertFalse(paths.contains("Meetings/Clients/Acme2"))
        XCTAssertFalse(paths.contains("Meetings/Clients/Acme"), "the root itself is the scope boundary")
    }

    func testBuildRootedAtAcmeExcludesSibling() {
        let tree = SpaceTreeModel.build(from: sampleEntries(), root: "Meetings/Clients/Acme")
        XCTAssertEqual(tree.map(\.name), ["Roadmap"])
    }

    // MARK: - Empty root = whole vault

    func testEmptyRootIsWholeVault() {
        let tree = SpaceTreeModel.build(from: sampleEntries(), root: "")
        // Vault roots: folders Meetings, Personal (no top-level notes here).
        XCTAssertEqual(tree.map(\.name), ["Meetings", "Personal"])
        let personal = try! XCTUnwrap(tree.first { $0.name == "Personal" })
        XCTAssertEqual(personal.children.map(\.name), ["Diary"])
    }

    func testWhitespaceAndSlashPaddedRootNormalizes() {
        let tree = SpaceTreeModel.build(from: sampleEntries(), root: " /Meetings/ ")
        XCTAssertEqual(tree.map(\.name), ["Alpha", "Clients", "Zeta"])
    }

    func testEmptySnapshotYieldsEmptyTree() {
        XCTAssertTrue(SpaceTreeModel.build(from: [], root: "Meetings").isEmpty)
    }
}
