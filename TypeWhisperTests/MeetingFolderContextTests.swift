import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

// MARK: - Folder metadata store (Amendment 1, DA4)

@MainActor
final class MeetingFolderMetadataStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "MeetingFolderMetadataStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return defaults
    }

    /// A config round-trips through UserDefaults: a second store on the same defaults re-reads it.
    func testConfigRoundTripsThroughUserDefaults() {
        let defaults = makeDefaults()
        let store = MeetingFolderMetadataStore(defaults: defaults)
        store.setDescription("Acme account", for: "Clients/Acme")
        store.attachNotes(["Notes/Acme.md"], to: "Clients/Acme")
        store.attachFolders(["Projects/Acme"], to: "Clients/Acme")
        store.setNoVaultContext(true, for: "Clients/Globex")

        let reopened = MeetingFolderMetadataStore(defaults: defaults)
        let acme = reopened.config(for: "Clients/Acme")
        XCTAssertEqual(acme.description, "Acme account")
        XCTAssertEqual(acme.attachedNotePaths, ["Notes/Acme.md"])
        XCTAssertEqual(acme.attachedFolderPaths, ["Projects/Acme"])
        XCTAssertTrue(reopened.config(for: "Clients/Globex").noVaultContext)
    }

    /// An emptied config drops its key so it never lingers or shows a phantom tree node.
    func testEmptyConfigDropsKey() {
        let store = MeetingFolderMetadataStore(defaults: makeDefaults())
        store.setDescription("temp", for: "Solo")
        XCTAssertEqual(store.configuredFolderPaths(), ["Solo"])
        store.setDescription("", for: "Solo")
        XCTAssertTrue(store.configuredFolderPaths().isEmpty)
    }

    /// Attachments dedupe (preserving order) and blanks are dropped.
    func testAttachmentsDedupeAndDropBlanks() {
        let store = MeetingFolderMetadataStore(defaults: makeDefaults())
        store.attachNotes(["A.md", "A.md", "  ", "/B.md"], to: "F")
        XCTAssertEqual(store.config(for: "F").attachedNotePaths, ["A.md", "B.md"])
    }

    /// `configuredFolderPaths` reports only folders with a stored config — the union input that lets a
    /// configured-but-empty folder surface in the sidebar tree.
    func testConfiguredFolderPaths() {
        let store = MeetingFolderMetadataStore(defaults: makeDefaults())
        store.setDescription("x", for: "Clients/Acme")
        store.attachFolders(["Projects/X"], to: "Personal")
        XCTAssertEqual(Set(store.configuredFolderPaths()), ["Clients/Acme", "Personal"])
    }

    /// A folder rename/move rewrites the config key and every descendant key, component-wise, leaving a
    /// look-alike sibling (`Acme2`) untouched — the M4 `onFolderPathRewrite` seam.
    func testHandleFolderRewriteMovesKeyAndDescendants() {
        let store = MeetingFolderMetadataStore(defaults: makeDefaults())
        store.setDescription("acme", for: "Clients/Acme")
        store.setDescription("q3", for: "Clients/Acme/Q3")
        store.setDescription("lookalike", for: "Clients/Acme2")

        store.handleFolderRewrite(from: "Clients/Acme", to: "Clients/AcmeCorp")

        XCTAssertEqual(store.config(for: "Clients/AcmeCorp").description, "acme")
        XCTAssertEqual(store.config(for: "Clients/AcmeCorp/Q3").description, "q3")
        XCTAssertTrue(store.config(for: "Clients/Acme").description.isEmpty, "old key gone")
        XCTAssertEqual(store.config(for: "Clients/Acme2").description, "lookalike", "look-alike untouched")
    }

    /// M7 minor: a rename that collides with a config already at the destination **merges** instead of
    /// silently overwriting it — union attachments, keep the destination's non-empty description, OR the
    /// noVaultContext flags — so no configuration is lost.
    func testHandleFolderRewriteMergesOnDestinationCollision() {
        let store = MeetingFolderMetadataStore(defaults: makeDefaults())
        // Source (moving) folder.
        store.setDescription("source desc", for: "Clients/Acme")
        store.attachNotes(["Notes/Source.md"], to: "Clients/Acme")
        store.setNoVaultContext(true, for: "Clients/Acme")
        // Pre-existing destination folder with its own config.
        store.setDescription("dest desc", for: "Clients/AcmeCorp")
        store.attachNotes(["Notes/Dest.md"], to: "Clients/AcmeCorp")

        store.handleFolderRewrite(from: "Clients/Acme", to: "Clients/AcmeCorp")

        let merged = store.config(for: "Clients/AcmeCorp")
        XCTAssertEqual(merged.description, "dest desc", "destination's non-empty description kept")
        XCTAssertEqual(Set(merged.attachedNotePaths), ["Notes/Dest.md", "Notes/Source.md"], "attachments unioned")
        XCTAssertTrue(merged.noVaultContext, "noVaultContext OR-ed from the source")
        XCTAssertTrue(store.config(for: "Clients/Acme").isEmpty, "source key gone")
    }

    /// A folder delete drops the config and every descendant config; look-alike untouched — the M4
    /// `onFolderDeleted` seam.
    func testHandleFolderDeletedDropsKeyAndDescendants() {
        let store = MeetingFolderMetadataStore(defaults: makeDefaults())
        store.setDescription("acme", for: "Clients/Acme")
        store.setDescription("q3", for: "Clients/Acme/Q3")
        store.setDescription("lookalike", for: "Clients/Acme2")

        store.handleFolderDeleted("Clients/Acme")

        XCTAssertTrue(store.config(for: "Clients/Acme").isEmpty)
        XCTAssertTrue(store.config(for: "Clients/Acme/Q3").isEmpty)
        XCTAssertEqual(store.config(for: "Clients/Acme2").description, "lookalike")
    }

    /// The seams fire live off `MeetingService.renameFolder`/`deleteFolder` when wired, even with no
    /// meeting under the folder (configured-but-empty follow).
    func testWiredSeamsFollowServiceRenameAndDelete() throws {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "FolderMetaSeam")
        addTeardownBlock { TestSupport.remove(dir) }
        let service = MeetingService(appSupportDirectory: dir)
        let store = MeetingFolderMetadataStore(defaults: makeDefaults())
        service.onFolderPathRewrite = { [weak store] old, new in store?.handleFolderRewrite(from: old, to: new) }
        service.onFolderDeleted = { [weak store] path in store?.handleFolderDeleted(path) }

        store.setDescription("ghost folder", for: "Clients/Ghost") // no meeting under it
        service.renameFolder("Clients/Ghost", to: "Clients/Spectre")
        XCTAssertEqual(store.config(for: "Clients/Spectre").description, "ghost folder")

        service.deleteFolder("Clients/Spectre")
        XCTAssertTrue(store.config(for: "Clients/Spectre").isEmpty)
    }

    // MARK: - Scope computation (DA5)

    func testRetrievalScopeComputation() {
        let store = MeetingFolderMetadataStore(defaults: makeDefaults())

        // No folder / blank ⇒ whole vault.
        XCTAssertEqual(store.retrievalScope(forFolderPath: nil), .wholeVault)
        XCTAssertEqual(store.retrievalScope(forFolderPath: "   "), .wholeVault)

        // Configured but no attachments ⇒ whole vault (description alone doesn't restrict).
        store.setDescription("x", for: "Clients/Acme")
        XCTAssertEqual(store.retrievalScope(forFolderPath: "Clients/Acme"), .wholeVault)

        // Attachments ⇒ restricted to those notes/prefixes.
        store.attachNotes(["Notes/Acme.md"], to: "Clients/Acme")
        store.attachFolders(["Projects/Acme"], to: "Clients/Acme")
        XCTAssertEqual(
            store.retrievalScope(forFolderPath: "Clients/Acme"),
            .restricted(notePaths: ["Notes/Acme.md"], folderPrefixes: ["Projects/Acme"], excludedPaths: [])
        )

        // No-vault-context toggle ⇒ .none (absolute).
        store.setNoVaultContext(true, for: "Clients/Globex")
        XCTAssertEqual(store.retrievalScope(forFolderPath: "Clients/Globex"), VaultRetrievalScope.none)
    }
}

// MARK: - Vault retrieval scope + read-only listing (Amendment 1, DA5/DA8)

@MainActor
final class VaultRetrievalScopeTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "VaultRetrievalScopeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return defaults
    }

    private func writeNote(_ relativePath: String, contents: String, in vault: URL) throws {
        let url = vault.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeVault() throws -> URL {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "ScopeVault")
        addTeardownBlock { TestSupport.remove(dir) }
        try writeNote("Acme/Roadmap.md", contents: "# Roadmap\nacme roadmap milestones", in: dir)
        try writeNote("Acme2/Other.md", contents: "# Other\nacme roadmap sibling", in: dir)
        try writeNote("Personal/Diary.md", contents: "# Diary\nroadmap personal note", in: dir)
        return dir
    }

    // MARK: - Predicate (component-wise boundaries + excludedPaths)

    func testScopePredicateComponentWise() {
        let scope = VaultRetrievalScope.restricted(
            notePaths: ["Notes/A.md"],
            folderPrefixes: ["Clients/Acme"]
        )
        XCTAssertTrue(scope.includes("Notes/A.md"))
        XCTAssertTrue(scope.includes("Clients/Acme"))
        XCTAssertTrue(scope.includes("Clients/Acme/deep/x.md"))
        XCTAssertFalse(scope.includes("Clients/Acme2/x.md"), "component look-alike out of scope")
        XCTAssertFalse(scope.includes("Other.md"))
    }

    func testScopePredicateExcludedPathsSubtractEvenUnderPrefix() {
        let scope = VaultRetrievalScope.restricted(
            notePaths: [],
            folderPrefixes: ["Clients/Acme"],
            excludedPaths: ["Clients/Acme/secret.md"]
        )
        XCTAssertTrue(scope.includes("Clients/Acme/public.md"))
        XCTAssertFalse(scope.includes("Clients/Acme/secret.md"), "excluded even under a live folder prefix")
    }

    func testWholeVaultAndNonePredicate() {
        XCTAssertTrue(VaultRetrievalScope.wholeVault.includes("anything.md"))
        XCTAssertFalse(VaultRetrievalScope.none.includes("anything.md"))
    }

    // MARK: - Scoped retrieve

    func testRestrictedRetrieveKeepsOnlyAttachedFolder() throws {
        let vault = try makeVault()
        let service = ObsidianVaultService(defaults: makeDefaults())
        service.connect(to: vault.path)

        let scoped = service.retrieve(
            query: "acme roadmap",
            limit: 5,
            scope: .restricted(notePaths: [], folderPrefixes: ["Acme"])
        )
        XCTAssertEqual(scoped.map(\.id), ["Acme/Roadmap.md"], "only the attached folder's note; Acme2 excluded")

        // Whole vault (default) still ranks across every folder — regression guard.
        let whole = service.retrieve(query: "acme roadmap", limit: 5)
        XCTAssertTrue(whole.count > 1)
        XCTAssertTrue(whole.contains { $0.id == "Acme2/Other.md" })
    }

    func testNoneScopeReturnsNothing() throws {
        let vault = try makeVault()
        let service = ObsidianVaultService(defaults: makeDefaults())
        service.connect(to: vault.path)
        XCTAssertTrue(service.retrieve(query: "acme roadmap", limit: 5, scope: .none).isEmpty)
    }

    /// A note added under an attached folder appears on the next retrieve — the scope filters over a
    /// fresh enumeration on every call (no snapshot).
    func testLiveFolderAttachmentPicksUpNewNote() throws {
        let vault = try makeVault()
        let service = ObsidianVaultService(defaults: makeDefaults())
        service.connect(to: vault.path)
        let scope = VaultRetrievalScope.restricted(notePaths: [], folderPrefixes: ["Acme"])

        let before = service.retrieve(query: "acme roadmap", limit: 5, scope: scope)
        XCTAssertEqual(before.map(\.id), ["Acme/Roadmap.md"])

        try writeNote("Acme/Extra.md", contents: "# Extra\nacme roadmap extra note", in: vault)
        let after = service.retrieve(query: "acme roadmap", limit: 5, scope: scope)
        XCTAssertEqual(Set(after.map(\.id)), ["Acme/Roadmap.md", "Acme/Extra.md"], "new note picked up live")
    }

    // MARK: - Read-only listing (DA8 — the picker's search model)

    func testListEntriesReturnsNotesAndFoldersNoBodyParse() throws {
        let vault = try makeVault()
        let service = ObsidianVaultService(defaults: makeDefaults())
        service.connect(to: vault.path)

        let entries = service.listEntries()
        // Directories present.
        XCTAssertTrue(entries.contains { $0.isDirectory && $0.relativePath == "Acme" })
        XCTAssertTrue(entries.contains { $0.isDirectory && $0.relativePath == "Personal" })
        // Notes present with filename-stem display names.
        let roadmap = try XCTUnwrap(entries.first { $0.relativePath == "Acme/Roadmap.md" })
        XCTAssertFalse(roadmap.isDirectory)
        XCTAssertEqual(roadmap.displayName, "Roadmap")
        // Deterministic: folders sort before notes.
        let firstNoteIndex = entries.firstIndex { !$0.isDirectory }!
        let lastDirIndex = entries.lastIndex { $0.isDirectory }!
        XCTAssertLessThan(lastDirIndex, firstNoteIndex)
    }

    func testSearchEntriesFiltersCaseInsensitiveOverPathAndName() throws {
        let vault = try makeVault()
        let service = ObsidianVaultService(defaults: makeDefaults())
        service.connect(to: vault.path)

        let acme = service.searchEntries("acme")
        XCTAssertTrue(acme.allSatisfy { $0.relativePath.localizedCaseInsensitiveContains("acme") })
        XCTAssertTrue(acme.contains { $0.relativePath == "Acme/Roadmap.md" })
        XCTAssertFalse(acme.contains { $0.relativePath == "Personal/Diary.md" })

        // Matches display name too ("diary" is only in the filename, not the path segment casing).
        let diary = service.searchEntries("diary")
        XCTAssertEqual(diary.map(\.relativePath), ["Personal/Diary.md"])

        // Bounded.
        XCTAssertLessThanOrEqual(service.searchEntries("", limit: 2).count, 2)
    }

    func testListEntriesEmptyWhenNotConnected() {
        let service = ObsidianVaultService(defaults: makeDefaults())
        XCTAssertTrue(service.listEntries().isEmpty)
        XCTAssertTrue(service.searchEntries("x").isEmpty)
    }
}

// MARK: - Brief + Q&A scope computation (Amendment 1, DA5/DA6)

@MainActor
final class MeetingFolderContextScopeTests: XCTestCase {
    @MainActor
    private final class StubProcessor: PromptProcessing {
        struct Call { let prompt: String; let text: String }
        var selectedProviderId = "p"
        var selectedCloudModel = "m"
        private(set) var calls: [Call] = []
        var response = "RESULT"
        func process(
            prompt: String,
            text: String,
            providerOverride: String?,
            cloudModelOverride: String?,
            temperatureDirective: PluginLLMTemperatureDirective,
            skipMemoryInjection: Bool
        ) async throws -> String {
            calls.append(Call(prompt: prompt, text: text))
            return response
        }
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "MeetingFolderContextScopeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return defaults
    }

    private func makeService() throws -> MeetingService {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "FolderCtxMeetings")
        addTeardownBlock { TestSupport.remove(dir) }
        return MeetingService(appSupportDirectory: dir)
    }

    /// A vault with a note inside an attachable folder (`ProjectAcme`) and an unrelated note elsewhere
    /// that also matches the query — so scoping is what discriminates them.
    private func makeVault(defaults: UserDefaults) throws -> ObsidianVaultService {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "FolderCtxVault")
        addTeardownBlock { TestSupport.remove(dir) }
        try write("ProjectAcme/Spec.md", "# Spec\nacme sync roadmap SPEC_MARKER", in: dir)
        try write("Unrelated/Random.md", "# Random\nacme sync roadmap RANDOM_MARKER", in: dir)
        let service = ObsidianVaultService(defaults: defaults)
        service.connect(to: dir.path)
        return service
    }

    private func write(_ rel: String, _ contents: String, in vault: URL) throws {
        let url = vault.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Brief KB retrieval is restricted to the folder's attached vault folder — the unrelated note that
    /// whole-vault retrieval would surface is now absent.
    func testBriefKnowledgeBaseScopedToAttachedFolder() async throws {
        let defaults = makeDefaults()
        let service = try makeService()
        let vault = try makeVault(defaults: defaults)
        let store = MeetingFolderMetadataStore(defaults: defaults)
        let stub = StubProcessor()
        let brief = MeetingBriefService(
            meetingService: service, vaultService: vault, processor: stub, folderMetadataStore: store
        )

        let target = service.createMeeting(title: "Acme Sync", source: .adHoc, state: .scheduled)
        service.setFolder("Clients/Acme", for: target)
        store.attachFolders(["ProjectAcme"], to: "Clients/Acme")

        _ = try await brief.generateBrief(for: target)
        let call = try XCTUnwrap(stub.calls.first)
        XCTAssertTrue(call.text.contains("SPEC_MARKER"), "attached-folder note in scope")
        XCTAssertFalse(call.text.contains("RANDOM_MARKER"), "unrelated note excluded by folder scope")
    }

    /// No-vault-context ⇒ the brief KB block is empty; it falls back to prior meetings only.
    func testBriefNoVaultContextUsesPriorMeetingsOnly() async throws {
        let defaults = makeDefaults()
        let service = try makeService()
        let vault = try makeVault(defaults: defaults)
        let store = MeetingFolderMetadataStore(defaults: defaults)
        let stub = StubProcessor()
        let brief = MeetingBriefService(
            meetingService: service, vaultService: vault, processor: stub, folderMetadataStore: store
        )

        let target = service.createMeeting(
            title: "Acme Sync", source: .calendar, state: .scheduled, seriesID: "s1"
        )
        service.setFolder("Clients/Acme", for: target)
        // A prior meeting in the series gives priorBlock content so the brief still has context.
        let prior = service.createMeeting(title: "Acme Sync (prev)", source: .calendar, state: .completed, seriesID: "s1")
        service.addOutput(to: prior, kind: .summary, content: "PRIOR_MARKER agreed to ship")
        store.setNoVaultContext(true, for: "Clients/Acme")

        _ = try await brief.generateBrief(for: target)
        let call = try XCTUnwrap(stub.calls.first)
        XCTAssertTrue(call.text.contains("PRIOR_MARKER"))
        XCTAssertFalse(call.text.contains("SPEC_MARKER"))
        XCTAssertFalse(call.text.contains("RANDOM_MARKER"))
    }

    /// Q&A retrieval honors the identical folder scope.
    func testQAScopedIdenticallyToBrief() async throws {
        let defaults = makeDefaults()
        let service = try makeService()
        let vault = try makeVault(defaults: defaults)
        let store = MeetingFolderMetadataStore(defaults: defaults)
        let stub = StubProcessor()
        let llm = MeetingLLMService(
            meetingService: service, vaultService: vault, processor: stub, folderMetadataStore: store
        )

        let target = service.createMeeting(title: "Acme Sync", source: .adHoc, state: .completed)
        service.appendStableSegments(
            [TranscriptionSegment(text: "We talked about the acme roadmap.", start: 0, end: 4)],
            to: target
        )
        service.setFolder("Clients/Acme", for: target)
        store.attachFolders(["ProjectAcme"], to: "Clients/Acme")

        _ = try await llm.answerQuestion(for: target, question: "acme sync roadmap status")
        let call = try XCTUnwrap(stub.calls.first)
        XCTAssertTrue(call.text.contains("SPEC_MARKER"), "attached-folder note feeds Q&A")
        XCTAssertFalse(call.text.contains("RANDOM_MARKER"), "unrelated note excluded from Q&A too")
    }

    /// No folder config ⇒ whole-vault behavior (regression guard): both notes reachable.
    func testNoConfigKeepsWholeVault() async throws {
        let defaults = makeDefaults()
        let service = try makeService()
        let vault = try makeVault(defaults: defaults)
        let store = MeetingFolderMetadataStore(defaults: defaults)
        let stub = StubProcessor()
        let brief = MeetingBriefService(
            meetingService: service, vaultService: vault, processor: stub, folderMetadataStore: store
        )

        let target = service.createMeeting(title: "Acme Sync", source: .adHoc, state: .scheduled)
        // No folder set, no config.
        _ = try await brief.generateBrief(for: target)
        let call = try XCTUnwrap(stub.calls.first)
        XCTAssertTrue(call.text.contains("SPEC_MARKER"))
        XCTAssertTrue(call.text.contains("RANDOM_MARKER"), "whole-vault: both notes present")
    }
}
