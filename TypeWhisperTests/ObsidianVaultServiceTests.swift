import XCTest
@testable import TypeWhisper

/// Unit tests for the first-party Obsidian vault reader (plan M5): connection/persistence, markdown
/// enumeration, frontmatter/tag parsing, and lexical retrieval over a temp vault directory. No real
/// Obsidian install is required — the service is pointed at a temp folder via `connect(to:)`.
@MainActor
final class ObsidianVaultServiceTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "ObsidianVaultServiceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return defaults
    }

    private func writeNote(_ relativePath: String, contents: String, in vault: URL) throws {
        let url = vault.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeVault() throws -> URL {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "ObsidianVault")
        addTeardownBlock { TestSupport.remove(dir) }

        try writeNote("Acme Roadmap.md", contents: """
        ---
        tags: [project, acme]
        ---
        # Acme Roadmap
        We discussed the acme quarterly roadmap, milestones and the budget.
        """, in: dir)

        try writeNote("Cooking.md", contents: """
        # Cooking
        Recipes for dinner, pasta and salads.
        """, in: dir)

        try writeNote("Notes/Acme 1-1.md", contents: """
        ---
        tags:
          - meeting
          - acme
        ---
        Follow-ups from the acme sync about the roadmap.
        """, in: dir)

        return dir
    }

    // MARK: - Connection & persistence

    func testConnectSetsStateAndPersistsAcrossInstances() throws {
        let defaults = makeDefaults()
        let vault = try makeVault()

        let service = ObsidianVaultService(defaults: defaults)
        XCTAssertFalse(service.isConnected)

        service.connect(to: vault.path)
        XCTAssertTrue(service.isConnected)
        XCTAssertEqual(service.vaultPath, vault.path)
        XCTAssertEqual(service.vaultName, vault.lastPathComponent)

        // A second instance on the same defaults re-reads the connected vault.
        let reopened = ObsidianVaultService(defaults: defaults)
        XCTAssertTrue(reopened.isConnected)
        XCTAssertEqual(reopened.vaultPath, vault.path)
    }

    func testDisconnectClearsStateAndPersistence() throws {
        let defaults = makeDefaults()
        let vault = try makeVault()

        let service = ObsidianVaultService(defaults: defaults)
        service.connect(to: vault.path)
        service.disconnect()

        XCTAssertFalse(service.isConnected)
        XCTAssertNil(ObsidianVaultService(defaults: defaults).vaultPath)
    }

    func testConnectRejectsNonexistentPath() {
        let defaults = makeDefaults()
        let service = ObsidianVaultService(defaults: defaults)
        service.connect(to: "/definitely/not/a/real/vault/path")
        XCTAssertFalse(service.isConnected)
    }

    // MARK: - Retrieval & parsing

    func testRetrieveRanksOnTopicNoteFirstAndParsesTags() throws {
        let defaults = makeDefaults()
        let vault = try makeVault()
        let service = ObsidianVaultService(defaults: defaults)
        service.connect(to: vault.path)

        let passages = service.retrieve(query: "acme roadmap budget", limit: 3)
        XCTAssertFalse(passages.isEmpty)

        // The roadmap note (multiple query-term hits + title) outranks the 1-1 note; cooking
        // shares nothing and is excluded.
        XCTAssertEqual(passages.first?.title, "Acme Roadmap")
        XCTAssertEqual(passages.first?.tags, ["project", "acme"])
        XCTAssertFalse(passages.contains { $0.title == "Cooking" })
        XCTAssertTrue(passages.first?.content.contains("budget") == true)
    }

    func testMultiLineYamlTagsParsed() throws {
        let defaults = makeDefaults()
        let vault = try makeVault()
        let service = ObsidianVaultService(defaults: defaults)
        service.connect(to: vault.path)

        let passages = service.retrieve(query: "sync follow-ups roadmap", limit: 5)
        let oneOnOne = try XCTUnwrap(passages.first { $0.tags.contains("meeting") })
        XCTAssertEqual(oneOnOne.tags, ["meeting", "acme"])
    }

    func testRetrieveReturnsNothingWhenNotConnected() {
        let service = ObsidianVaultService(defaults: makeDefaults())
        XCTAssertTrue(service.retrieve(query: "acme").isEmpty)
    }

    func testRetrieveReturnsNothingForNonMatchingQuery() throws {
        let defaults = makeDefaults()
        let vault = try makeVault()
        let service = ObsidianVaultService(defaults: defaults)
        service.connect(to: vault.path)
        XCTAssertTrue(service.retrieve(query: "quantum astrophysics submarine").isEmpty)
    }

    // MARK: - Single-note read (Track E, ME-2)

    func testReadNoteReturnsFullBodyAndNilForMissing() throws {
        let defaults = makeDefaults()
        let vault = try makeVault()
        let service = ObsidianVaultService(defaults: defaults)
        service.connect(to: vault.path)

        let body = try XCTUnwrap(service.readNote("Notes/Acme 1-1.md"))
        XCTAssertTrue(body.contains("Follow-ups from the acme sync about the roadmap."))
        // Leading/surrounding slashes are tolerated (normalized).
        XCTAssertEqual(service.readNote("/Notes/Acme 1-1.md"), body)

        XCTAssertNil(service.readNote("Notes/Nope.md"))
        XCTAssertNil(service.readNote(""))
    }

    func testReadNoteReturnsNilWhenNotConnected() {
        let service = ObsidianVaultService(defaults: makeDefaults())
        XCTAssertNil(service.readNote("Cooking.md"))
    }

    /// A `..`-escaping relative path must never read a file outside the connected vault.
    func testReadNoteRejectsTraversalOutsideVault() throws {
        let defaults = makeDefaults()
        let vault = try makeVault()
        // A secret sibling to the vault (in the vault's parent dir), reachable only via traversal.
        let outside = vault.deletingLastPathComponent().appendingPathComponent("outside-secret.md")
        try "TOP SECRET".write(to: outside, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }

        let service = ObsidianVaultService(defaults: defaults)
        service.connect(to: vault.path)

        XCTAssertNil(service.readNote("../outside-secret.md"))
        XCTAssertNil(service.readNote("Notes/../../outside-secret.md"))
        // A traversal that resolves back inside the vault still reads.
        XCTAssertNotNil(service.readNote("Notes/../Cooking.md"))
    }

    // MARK: - typewhisper-meeting frontmatter (Track E, ME-2 bridge)

    func testMeetingIDExtractsValidFrontmatterUUID() throws {
        let defaults = makeDefaults()
        let vault = try makeVault()
        let uuid = UUID()
        try writeNote("Meetings/Linked.md", contents: """
        ---
        title: Linked meeting
        typewhisper-meeting: \(uuid.uuidString)
        tags: [meeting]
        ---
        # Linked meeting
        Body text.
        """, in: vault)

        let service = ObsidianVaultService(defaults: defaults)
        service.connect(to: vault.path)
        XCTAssertEqual(service.meetingID(inNoteAt: "Meetings/Linked.md"), uuid)
    }

    func testMeetingIDNilForMissingFrontmatter() throws {
        let defaults = makeDefaults()
        let vault = try makeVault()
        // Cooking.md has no frontmatter block at all.
        let service = ObsidianVaultService(defaults: defaults)
        service.connect(to: vault.path)
        XCTAssertNil(service.meetingID(inNoteAt: "Cooking.md"))
    }

    func testMeetingIDNilForMalformedFrontmatter() throws {
        let defaults = makeDefaults()
        let vault = try makeVault()
        // An unterminated frontmatter block (no closing `---`) is tolerated as "no field".
        try writeNote("Meetings/Malformed.md", contents: """
        ---
        typewhisper-meeting: \(UUID().uuidString)
        # Malformed heading, block never closed
        body
        """, in: vault)
        let service = ObsidianVaultService(defaults: defaults)
        service.connect(to: vault.path)
        XCTAssertNil(service.meetingID(inNoteAt: "Meetings/Malformed.md"))
    }

    func testMeetingIDNilForNonUUIDValue() throws {
        let defaults = makeDefaults()
        let vault = try makeVault()
        try writeNote("Meetings/Bad.md", contents: """
        ---
        typewhisper-meeting: not-a-uuid
        ---
        body
        """, in: vault)
        let service = ObsidianVaultService(defaults: defaults)
        service.connect(to: vault.path)
        XCTAssertNil(service.meetingID(inNoteAt: "Meetings/Bad.md"))
    }
}
