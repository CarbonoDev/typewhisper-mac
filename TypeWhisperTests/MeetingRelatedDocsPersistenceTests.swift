import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

/// Persistence + precedence tests for related documents (Amendment 2, M8): the DB4 single-writer
/// setters (discovered-replace, manual-add, remove→exclusion, no-resurrect, stale retention) and the
/// DB5 consumption precedence ladder computed by `MeetingFolderMetadataStore.retrievalScope`.
@MainActor
final class MeetingRelatedDocsPersistenceTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "MeetingRelatedDocsPersistenceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return defaults
    }

    private func makeService() throws -> MeetingService {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "RelatedDocsPersist")
        addTeardownBlock { TestSupport.remove(dir) }
        return MeetingService(appSupportDirectory: dir)
    }

    private func discovered(_ meeting: Meeting) -> [String] {
        meeting.relatedNotePaths.filter { $0.provenance == .discovered }.map(\.path)
    }
    private func manual(_ meeting: Meeting) -> [String] {
        meeting.relatedNotePaths.filter { $0.provenance == .manual }.map(\.path)
    }

    // MARK: - DB4 setters

    func testSetDiscoveredReplacesKeepsManualDropsExcludedStampsDate() throws {
        let service = try makeService()
        let meeting = service.createMeeting(title: "M", source: .adHoc, state: .completed)

        service.addManualRelatedNote("Notes/Manual.md", for: meeting)
        service.removeRelatedNote("Notes/Removed.md", for: meeting)   // records an exclusion
        XCTAssertNil(meeting.relatedDiscoveryAt)

        service.setDiscoveredRelatedNotes(["Notes/A.md", "Notes/Removed.md", "Notes/B.md"], for: meeting)

        // Excluded path dropped even though the judge re-returned it; discovered set is A + B.
        XCTAssertEqual(discovered(meeting), ["Notes/A.md", "Notes/B.md"])
        // Manual entry untouched.
        XCTAssertEqual(manual(meeting), ["Notes/Manual.md"])
        XCTAssertNotNil(meeting.relatedDiscoveryAt)

        // A second run replaces the discovered set entirely (stale discovered evaporate).
        service.setDiscoveredRelatedNotes(["Notes/C.md"], for: meeting)
        XCTAssertEqual(discovered(meeting), ["Notes/C.md"])
        XCTAssertEqual(manual(meeting), ["Notes/Manual.md"])
    }

    func testRemoveRecordsExclusionAndRemovesFromRelated() throws {
        let service = try makeService()
        let meeting = service.createMeeting(title: "M", source: .adHoc, state: .completed)
        service.setDiscoveredRelatedNotes(["Notes/A.md"], for: meeting)

        service.removeRelatedNote("Notes/A.md", for: meeting)
        XCTAssertTrue(discovered(meeting).isEmpty)
        XCTAssertEqual(meeting.excludedNotePaths, ["Notes/A.md"])

        // No-resurrect: re-running discovery with the same path does NOT re-add it.
        service.setDiscoveredRelatedNotes(["Notes/A.md", "Notes/B.md"], for: meeting)
        XCTAssertEqual(discovered(meeting), ["Notes/B.md"])
    }

    func testManualAddClearsPriorExclusion() throws {
        let service = try makeService()
        let meeting = service.createMeeting(title: "M", source: .adHoc, state: .completed)
        service.setDiscoveredRelatedNotes(["Notes/A.md"], for: meeting)
        service.removeRelatedNote("Notes/A.md", for: meeting)
        XCTAssertEqual(meeting.excludedNotePaths, ["Notes/A.md"])

        // An explicit manual add of the same path clears the exclusion and re-adds it as manual.
        service.addManualRelatedNote("Notes/A.md", for: meeting)
        XCTAssertTrue(meeting.excludedNotePaths.isEmpty, "manual add clears the exclusion")
        XCTAssertEqual(manual(meeting), ["Notes/A.md"])

        // And a subsequent discovery run may now re-surface it as discovered (exclusion gone), but the
        // manual entry keeps it deduped (a path is not stored twice).
        service.setDiscoveredRelatedNotes(["Notes/A.md"], for: meeting)
        XCTAssertTrue(discovered(meeting).isEmpty, "path already manual is not duplicated as discovered")
        XCTAssertEqual(manual(meeting), ["Notes/A.md"])
    }

    func testStaleManualRetainedAcrossDiscovery() throws {
        let service = try makeService()
        let meeting = service.createMeeting(title: "M", source: .adHoc, state: .completed)
        service.addManualRelatedNote("Notes/Gone.md", for: meeting)   // will "go stale" in the vault
        // A discovery run that returns nothing must not drop the manual pick (show-as-missing is a UI
        // concern; the stored entry is retained).
        service.setDiscoveredRelatedNotes([], for: meeting)
        XCTAssertEqual(manual(meeting), ["Notes/Gone.md"])
    }

    // MARK: - DB5 precedence ladder (computed scope)

    func testPrecedenceLadder() {
        let store = MeetingFolderMetadataStore(defaults: makeDefaults())

        // Both empty ⇒ whole vault.
        XCTAssertEqual(store.retrievalScope(forFolderPath: "Clients/Acme"), .wholeVault)

        // Curated only (no folder config) ⇒ restricted to the curated notes.
        XCTAssertEqual(
            store.retrievalScope(forFolderPath: nil, curatedNotePaths: ["Notes/Cur.md"]),
            .restricted(notePaths: ["Notes/Cur.md"], folderPrefixes: [], excludedPaths: [])
        )

        // Folder attachments only ⇒ folder-only restricted (Amendment-1 behavior preserved).
        store.attachNotes(["Vault/Folder.md"], to: "Clients/Acme")
        store.attachFolders(["Vault/Proj"], to: "Clients/Acme")
        XCTAssertEqual(
            store.retrievalScope(forFolderPath: "Clients/Acme"),
            .restricted(notePaths: ["Vault/Folder.md"], folderPrefixes: ["Vault/Proj"], excludedPaths: [])
        )

        // Curated ∪ folder, with an exclusion carried through.
        let scope = store.retrievalScope(
            forFolderPath: "Clients/Acme",
            curatedNotePaths: ["Notes/Cur.md", "Vault/Excl.md"],
            excludedNotePaths: ["Vault/Excl.md"]
        )
        XCTAssertEqual(
            scope,
            .restricted(
                notePaths: ["Notes/Cur.md", "Vault/Folder.md"],
                folderPrefixes: ["Vault/Proj"],
                excludedPaths: ["Vault/Excl.md"]
            )
        )

        // noVaultContext ⇒ .none, absolute (even with curated + folder attachments present).
        store.setNoVaultContext(true, for: "Clients/Acme")
        XCTAssertEqual(
            store.retrievalScope(forFolderPath: "Clients/Acme", curatedNotePaths: ["Notes/Cur.md"]),
            VaultRetrievalScope.none
        )
    }

    func testExcludedPathFilteredEvenUnderLiveFolderPrefix() {
        let store = MeetingFolderMetadataStore(defaults: makeDefaults())
        store.attachFolders(["Clients/Acme"], to: "Clients/Acme")
        let scope = store.retrievalScope(
            forFolderPath: "Clients/Acme",
            curatedNotePaths: [],
            excludedNotePaths: ["Clients/Acme/secret.md"]
        )
        XCTAssertTrue(scope.includes("Clients/Acme/public.md"))
        XCTAssertFalse(scope.includes("Clients/Acme/secret.md"), "removal honored inside a live folder prefix")
    }

    // MARK: - DB8 row removability (folder-prefix rows are not removable here)

    /// A folder-prefix (directory) row expands *live* to every note under it, so the section suppresses
    /// its ✕: recording the directory path as an exclusion would not suppress those notes (the exclusion
    /// only matches note paths exactly). Folder-level scope is edited in the M7 folder detail view — this
    /// keeps the UI and the consumption scope consistent (Amendment 2, DB4/DB5). Note rows (including
    /// concrete folder-attached notes) stay removable, since their exact path is what the exclusion and
    /// `VaultRetrievalScope.includes` both key on.
    func testFolderPrefixRowsAreNotRemovable() {
        let folderRow = MeetingsViewModel.RelatedDocRow(
            path: "Clients/Acme", displayName: "Acme", folderCaption: "Clients",
            provenance: .folder, isDirectory: true, isMissing: false
        )
        let noteRow = MeetingsViewModel.RelatedDocRow(
            path: "Clients/Acme/Kickoff.md", displayName: "Kickoff", folderCaption: "Clients/Acme",
            provenance: .suggested, isDirectory: false, isMissing: false
        )
        XCTAssertFalse(folderRow.isRemovable, "a folder-prefix row must not expose an ineffective ✕")
        XCTAssertTrue(noteRow.isRemovable, "a note row is removable via an exact-path exclusion")
    }
}
