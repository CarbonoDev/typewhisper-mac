import XCTest
@testable import TypeWhisper

/// Perf plan Phase 2 — the off-main vault reading core and its parse cache. The cache may only save a
/// read + parse: a note that changed, appeared or vanished on disk must always be seen (the vault is
/// the source of truth). `parseCount` counts cache misses.
final class VaultIndexerTests: XCTestCase {
    private func makeVault() throws -> URL {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "VaultIndexer")
        addTeardownBlock { TestSupport.remove(dir) }
        try write("# Alpha\nalpha body", to: "Alpha.md", in: dir)
        try write("# Beta\nbeta body", to: "Notes/Beta.md", in: dir)
        try write("not a note", to: "Notes/ignored.txt", in: dir)
        return dir
    }

    private func write(_ text: String, to relativePath: String, in vault: URL, atomically: Bool = false) throws {
        let url = vault.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: atomically, encoding: .utf8)
    }

    private func modificationDate(of relativePath: String, in vault: URL) throws -> Date {
        let attrs = try FileManager.default.attributesOfItem(
            atPath: vault.appendingPathComponent(relativePath).path)
        return try XCTUnwrap(attrs[.modificationDate] as? Date)
    }

    private func setModificationDate(_ date: Date, of relativePath: String, in vault: URL) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: date], ofItemAtPath: vault.appendingPathComponent(relativePath).path)
    }

    func testNotesAreParsedSortedAndUnchangedNotesAreNotReread() async throws {
        let vault = try makeVault()
        let indexer = VaultIndexer()

        let first = await indexer.notes(in: vault.path)
        XCTAssertEqual(first.map(\.id), ["Alpha.md", "Notes/Beta.md"])
        XCTAssertEqual(first.map(\.title), ["Alpha", "Beta"])
        let parsedOnce = await indexer.parseCount
        XCTAssertEqual(parsedOnce, 2)

        let second = await indexer.notes(in: vault.path)
        XCTAssertEqual(second, first)
        let parsedAfterSecond = await indexer.parseCount
        XCTAssertEqual(parsedAfterSecond, 2, "an unchanged note is served from the cache")
    }

    /// Same size, newer mtime ⇒ re-read (an in-place edit that keeps the length).
    func testEditKeepingSizeIsSeenViaModificationDate() async throws {
        let vault = try makeVault()
        let indexer = VaultIndexer()
        _ = await indexer.notes(in: vault.path)
        let original = try modificationDate(of: "Alpha.md", in: vault)

        try write("# Alpha\nALPHA BODY", to: "Alpha.md", in: vault)
        try setModificationDate(original.addingTimeInterval(5), of: "Alpha.md", in: vault)

        let notes = await indexer.notes(in: vault.path)
        XCTAssertEqual(notes.first { $0.id == "Alpha.md" }?.body, "# Alpha\nALPHA BODY")
        let parsed = await indexer.parseCount
        XCTAssertEqual(parsed, 3, "only the edited note is re-read")
    }

    /// Same mtime, different size ⇒ re-read (a tool that restores the mtime after writing).
    func testEditRestoringModificationDateIsSeenViaSize() async throws {
        let vault = try makeVault()
        let indexer = VaultIndexer()
        _ = await indexer.notes(in: vault.path)
        let original = try modificationDate(of: "Alpha.md", in: vault)

        try write("# Alpha\nalpha body, now longer", to: "Alpha.md", in: vault)
        try setModificationDate(original, of: "Alpha.md", in: vault)

        let notes = await indexer.notes(in: vault.path)
        XCTAssertEqual(notes.first { $0.id == "Alpha.md" }?.body, "# Alpha\nalpha body, now longer")
    }

    /// Same mtime and size, replaced atomically (new inode) ⇒ re-read.
    func testAtomicReplaceKeepingSizeAndModificationDateIsSeenViaInode() async throws {
        let vault = try makeVault()
        let indexer = VaultIndexer()
        _ = await indexer.notes(in: vault.path)
        let original = try modificationDate(of: "Alpha.md", in: vault)

        try write("# Alpha\nALPHA BODY", to: "Alpha.md", in: vault, atomically: true)
        try setModificationDate(original, of: "Alpha.md", in: vault)

        let notes = await indexer.notes(in: vault.path)
        XCTAssertEqual(notes.first { $0.id == "Alpha.md" }?.body, "# Alpha\nALPHA BODY")
    }

    func testDeletedNoteIsNeverServedAndNewNoteAppears() async throws {
        let vault = try makeVault()
        let indexer = VaultIndexer()
        _ = await indexer.notes(in: vault.path)

        try FileManager.default.removeItem(at: vault.appendingPathComponent("Notes/Beta.md"))
        try write("# Gamma\ngamma", to: "Gamma.md", in: vault)

        let notes = await indexer.notes(in: vault.path)
        XCTAssertEqual(notes.map(\.id), ["Alpha.md", "Gamma.md"])
    }

    func testSwitchingVaultsNeverServesTheOtherVaultsNotes() async throws {
        let vaultA = try makeVault()
        let vaultB = try TestSupport.makeTemporaryDirectory(prefix: "VaultIndexerB")
        addTeardownBlock { TestSupport.remove(vaultB) }
        // Same relative path, different content.
        try write("# Other Alpha\nfrom B", to: "Alpha.md", in: vaultB)
        let indexer = VaultIndexer()

        _ = await indexer.notes(in: vaultA.path)
        let fromB = await indexer.notes(in: vaultB.path)
        XCTAssertEqual(fromB.map(\.title), ["Other Alpha"])
        let fromA = await indexer.notes(in: vaultA.path)
        XCTAssertEqual(fromA.map(\.title), ["Alpha", "Beta"])
    }

    func testOversizedNotesAreSkipped() async throws {
        let vault = try makeVault()
        try write("# Big\n" + String(repeating: "x", count: 200), to: "Big.md", in: vault)
        let indexer = VaultIndexer(maxFileBytes: 100)

        let notes = await indexer.notes(in: vault.path)
        XCTAssertFalse(notes.contains { $0.id == "Big.md" })
    }

    // MARK: - Through the service

    /// `retrieve` reflects an on-disk edit on the very next call, even though the first call warmed
    /// the cache.
    @MainActor
    func testServiceRetrieveSeesEditAfterWarmCache() async throws {
        let suite = "VaultIndexerTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let vault = try makeVault()
        let service = ObsidianVaultService(defaults: UserDefaults(suiteName: suite)!)
        service.connect(to: vault.path)

        let before = await service.retrieve(query: "alpha", limit: 3)
        XCTAssertEqual(before.first?.content, "# Alpha\nalpha body")

        let original = try modificationDate(of: "Alpha.md", in: vault)
        try write("# Alpha\nalpha rewritten", to: "Alpha.md", in: vault)
        try setModificationDate(original.addingTimeInterval(5), of: "Alpha.md", in: vault)

        let after = await service.retrieve(query: "alpha", limit: 3)
        XCTAssertEqual(after.first?.content, "# Alpha\nalpha rewritten")
    }

    // MARK: - Picker filter

    func testFilterEntriesMatchesPathOrNameAndBounds() {
        let entries = [
            VaultEntry(relativePath: "Acme", displayName: "Acme", isDirectory: true),
            VaultEntry(relativePath: "Acme/Roadmap.md", displayName: "Roadmap", isDirectory: false),
            VaultEntry(relativePath: "Personal/Diary.md", displayName: "Diary", isDirectory: false),
        ]
        XCTAssertEqual(
            ObsidianVaultService.filterEntries(entries, query: " acme ").map(\.relativePath),
            ["Acme", "Acme/Roadmap.md"])
        XCTAssertEqual(ObsidianVaultService.filterEntries(entries, query: "DIARY").map(\.displayName), ["Diary"])
        XCTAssertEqual(ObsidianVaultService.filterEntries(entries, query: "", limit: 2).count, 2)
    }
}
