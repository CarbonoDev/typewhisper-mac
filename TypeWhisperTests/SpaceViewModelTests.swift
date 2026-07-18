import XCTest
@testable import TypeWhisper

/// Track E (ME-1) — the Space view model over a temp vault (vault access stubbed by pointing the
/// shared `ObsidianVaultService` at a temp directory via `connect(to:)`, exactly as
/// `ObsidianVaultServiceTests` does). Covers: the cached snapshot rebuilds the tree rooted at the
/// meetings root; `children(of:)` powers the folder index; the empty-root escape hatch; and the
/// disconnected gate.
@MainActor
final class SpaceViewModelTests: XCTestCase {
    private func makeDefaults(root: String? = "Meetings") -> UserDefaults {
        let suite = "SpaceViewModelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        if let root { defaults.set(root, forKey: UserDefaultsKeys.meetingsObsidianRootFolder) }
        return defaults
    }

    private func writeNote(_ relativePath: String, in vault: URL) throws {
        let url = vault.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# \(url.deletingPathExtension().lastPathComponent)\nbody".write(
            to: url, atomically: true, encoding: .utf8)
    }

    private func makeVault() throws -> URL {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "SpaceVault")
        addTeardownBlock { TestSupport.remove(dir) }
        try writeNote("Meetings/Clients/Acme/Roadmap.md", in: dir)
        try writeNote("Meetings/Zeta.md", in: dir)
        try writeNote("Personal/Diary.md", in: dir)
        return dir
    }

    func testConnectedSnapshotBuildsTreeRootedAtMeetings() throws {
        let defaults = makeDefaults()
        let vault = try makeVault()
        let service = ObsidianVaultService(defaults: defaults)
        service.connect(to: vault.path)

        let vm = SpaceViewModel(vaultService: service, defaults: defaults)
        vm.refresh()

        XCTAssertTrue(vm.isConnected)
        XCTAssertEqual(vm.rootFolderPath, "Meetings")
        // Rooted at "Meetings": top-level is folder Clients then note Zeta (Personal/* is out of scope).
        XCTAssertEqual(vm.tree.map(\.name), ["Clients", "Zeta"])
        let clients = try XCTUnwrap(vm.tree.first { $0.name == "Clients" })
        let acme = try XCTUnwrap(clients.children.first { $0.name == "Acme" })
        XCTAssertEqual(acme.children.map(\.name), ["Roadmap"])
    }

    func testChildrenOfFolderPowersTheIndex() throws {
        let defaults = makeDefaults()
        let vault = try makeVault()
        let service = ObsidianVaultService(defaults: defaults)
        service.connect(to: vault.path)
        let vm = SpaceViewModel(vaultService: service, defaults: defaults)
        vm.refresh()

        let acmeChildren = vm.children(of: "Meetings/Clients/Acme")
        XCTAssertEqual(acmeChildren.map(\.name), ["Roadmap"])
        XCTAssertFalse(acmeChildren[0].isDirectory)

        // The meetings-root index itself: Clients (folder) then Zeta (note).
        XCTAssertEqual(vm.children(of: "Meetings").map(\.name), ["Clients", "Zeta"])
    }

    func testEmptyRootBrowsesWholeVault() throws {
        let defaults = makeDefaults(root: "")
        let vault = try makeVault()
        let service = ObsidianVaultService(defaults: defaults)
        service.connect(to: vault.path)
        let vm = SpaceViewModel(vaultService: service, defaults: defaults)
        vm.refresh()

        XCTAssertEqual(vm.rootFolderPath, "")
        XCTAssertEqual(vm.tree.map(\.name), ["Meetings", "Personal"])
    }

    /// 1:1 alignment by construction (spec §4, plan D3): a meeting filed under `Clients/Acme` and
    /// exported through the real `MeetingObsidianExporter` (root `"Meetings"`) lands on disk at
    /// `Meetings/Clients/Acme/<title>.md`; that exact node then appears in the Space tree — the
    /// first-party folder `Clients/Acme` ↔ Space node `Meetings/Clients/Acme`.
    func testExportedMeetingAppearsUnderAlignedSpaceNode() throws {
        // One suite (root "Meetings"), distinct handles per MainActor consumer (Swift 6 region
        // isolation — a single `UserDefaults` value can't be sent into two isolated objects).
        let suite = "SpaceAlignTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        UserDefaults(suiteName: suite)!.set("Meetings", forKey: UserDefaultsKeys.meetingsObsidianRootFolder)

        let vaultDir = try TestSupport.makeTemporaryDirectory(prefix: "SpaceAlignVault")
        addTeardownBlock { TestSupport.remove(vaultDir) }
        let storeDir = try TestSupport.makeTemporaryDirectory(prefix: "SpaceAlignStore")
        addTeardownBlock { TestSupport.remove(storeDir) }

        let vault = ObsidianVaultService(defaults: UserDefaults(suiteName: suite)!)
        vault.connect(to: vaultDir.path)
        let store = MeetingService(appSupportDirectory: storeDir)
        let exporter = MeetingObsidianExporter(vaultService: vault, defaults: UserDefaults(suiteName: suite)!)

        // A meeting filed under Clients/Acme with one summary section (so the export produces a file).
        let meeting = store.createMeeting(title: "Q3 Kickoff", source: .calendar, state: .completed)
        store.setObsidianFolder("Clients/Acme", for: meeting)
        _ = store.addOutput(to: meeting, kind: .summary, content: "SUMMARY_BODY: shipped it.")
        let urls = try exporter.export(meeting, sections: [.summary], combined: true)

        // Filed on disk under root + meeting folder.
        let file = try XCTUnwrap(urls.first)
        XCTAssertTrue(
            file.path.contains("/Meetings/Clients/Acme/"),
            "expected export under Meetings/Clients/Acme, got \(file.path)")

        // The Space tree, rooted at "Meetings", contains the aligned node chain.
        let vm = SpaceViewModel(vaultService: vault, defaults: UserDefaults(suiteName: suite)!)
        vm.refresh()
        let clients = try XCTUnwrap(vm.tree.first { $0.name == "Clients" })
        let acme = try XCTUnwrap(clients.children.first { $0.name == "Acme" })
        XCTAssertEqual(acme.relativePath, "Meetings/Clients/Acme")
        let exportedName = file.deletingPathExtension().lastPathComponent
        let note = try XCTUnwrap(
            acme.children.first { !$0.isDirectory && $0.name == exportedName },
            "exported note \(exportedName) not found under Space node Meetings/Clients/Acme")
        XCTAssertEqual(note.relativePath, "Meetings/Clients/Acme/\(exportedName).md")

        // And the folder index for that node lists it too.
        XCTAssertEqual(vm.children(of: "Meetings/Clients/Acme").map(\.name), [exportedName])
    }

    // MARK: - Quick-note draft commit (Track E, ME-3)

    private func makeConnectedVM(root: String? = "Meetings") throws -> (SpaceViewModel, URL) {
        let defaults = makeDefaults(root: root)
        let vault = try makeVault()
        let service = ObsidianVaultService(defaults: defaults)
        service.connect(to: vault.path)
        let vm = SpaceViewModel(vaultService: service, defaults: defaults)
        vm.refresh()
        return (vm, vault)
    }

    /// Commit writes exactly one note under the drafted folder, the returned vault-relative path points
    /// at it, the file exists on disk, and the refreshed snapshot surfaces it in that folder's index.
    func testCommitDraftCreatesNoteUnderCurrentFolderAndRefreshes() throws {
        let (vm, vaultURL) = try makeConnectedVM()
        vm.beginDraft(inFolder: "Meetings/Clients/Acme")
        vm.updateDraftText("Kickoff Notes\nfirst item")

        let created = try XCTUnwrap(vm.commitDraft())
        XCTAssertEqual(created, "Meetings/Clients/Acme/Kickoff Notes.md")
        XCTAssertNil(vm.draft, "draft cleared after a successful commit")

        let onDisk = vaultURL.appendingPathComponent(created)
        XCTAssertTrue(FileManager.default.fileExists(atPath: onDisk.path))
        XCTAssertEqual(try String(contentsOf: onDisk, encoding: .utf8), "Kickoff Notes\nfirst item")

        // The refreshed snapshot lists the new note beside the folder's existing entries.
        let names = vm.children(of: "Meetings/Clients/Acme").map(\.name)
        XCTAssertTrue(names.contains("Kickoff Notes"), "new note missing from refreshed index: \(names)")
    }

    /// The filename derives from the first typed line (heading marker stripped), and a second draft with
    /// the same first line never clobbers — it suffixes ` 1`.
    func testCommitDraftDerivesFilenameAndSuffixesCollisions() throws {
        let (vm, _) = try makeConnectedVM()

        vm.beginDraft(inFolder: "Meetings")
        vm.updateDraftText("# Weekly Sync\nagenda")
        XCTAssertEqual(try XCTUnwrap(vm.commitDraft()), "Meetings/Weekly Sync.md")

        vm.beginDraft(inFolder: "Meetings")
        vm.updateDraftText("# Weekly Sync\ndifferent body")
        XCTAssertEqual(try XCTUnwrap(vm.commitDraft()), "Meetings/Weekly Sync 1.md")
    }

    /// An empty (whitespace-only) draft is discarded silently: no file, `nil` return, draft cleared.
    func testCommitEmptyDraftDiscardsWithoutWriting() throws {
        let (vm, _) = try makeConnectedVM()
        let before = vm.children(of: "Meetings").count

        vm.beginDraft(inFolder: "Meetings")
        vm.updateDraftText("   \n\t ")
        XCTAssertNil(vm.commitDraft())
        XCTAssertNil(vm.draft)
        XCTAssertEqual(vm.children(of: "Meetings").count, before, "no note created for an empty draft")
    }

    /// A draft with no usable first line still commits (non-empty content) under the "Untitled" fallback.
    func testCommitDraftFallsBackToUntitledFilename() throws {
        let (vm, _) = try makeConnectedVM()
        vm.beginDraft(inFolder: "Meetings")
        // Only illegal characters on the first line → sanitizes empty → fallback.
        vm.updateDraftText("/:*?\nreal content")
        XCTAssertEqual(try XCTUnwrap(vm.commitDraft()), "Meetings/Untitled.md")
    }

    /// Explicit discard drops the draft without writing anything.
    func testDiscardDraftDropsItWithoutWriting() throws {
        let (vm, _) = try makeConnectedVM()
        let before = vm.children(of: "Meetings").count
        vm.beginDraft(inFolder: "Meetings")
        vm.updateDraftText("some content")
        vm.discardDraft()
        XCTAssertNil(vm.draft)
        XCTAssertEqual(vm.children(of: "Meetings").count, before)
    }

    func testDisconnectGatesOffTheTree() throws {
        let defaults = makeDefaults()
        let vault = try makeVault()
        let service = ObsidianVaultService(defaults: defaults)
        service.connect(to: vault.path)
        let vm = SpaceViewModel(vaultService: service, defaults: defaults)
        vm.refresh()
        XCTAssertFalse(vm.tree.isEmpty)

        service.disconnect()
        vm.refresh()

        XCTAssertFalse(vm.isConnected)
        XCTAssertTrue(vm.entries.isEmpty)
        XCTAssertTrue(vm.tree.isEmpty)
    }
}
