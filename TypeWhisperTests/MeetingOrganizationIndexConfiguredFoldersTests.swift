import XCTest
@testable import TypeWhisper

/// [Perf · stale-state audit] The folder tree must follow the folder-metadata store, not only the
/// meetings list: renaming / deleting a configured folder with no meetings, or clearing its last
/// config, writes no meeting and so never reaches `meetingsListPublisher`.
@MainActor
final class MeetingOrganizationIndexConfiguredFoldersTests: XCTestCase {
    private func mainHop() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    private func makeIndex() throws -> (MeetingOrganizationIndex, MeetingFolderMetadataStore) {
        let dir = try TestSupport.makeTemporaryDirectory(prefix: "OrganizationIndexConfigured")
        let suite = "OrganizationIndexConfigured-\(UUID().uuidString)"
        addTeardownBlock {
            TestSupport.remove(dir)
            UserDefaults().removePersistentDomain(forName: suite)
        }
        let service = MeetingService(appSupportDirectory: dir)
        let store = MeetingFolderMetadataStore(defaults: UserDefaults(suiteName: suite)!)
        let index = MeetingOrganizationIndex(meetingService: service)
        index.configuredFolderPathsProvider = { [weak store] in store?.configuredFolderPaths() ?? [] }
        index.rebuild(on: store.$configs.dropFirst())
        return (index, store)
    }

    func testConfiguringAnEmptyFolderAddsItsNode() async throws {
        let (index, store) = try makeIndex()
        store.setDescription("Context", for: "Clients/Acme")
        await mainHop()
        XCTAssertEqual(index.folderTree.map(\.path), ["Clients"])
        XCTAssertEqual(index.folderTree.first?.children.map(\.path), ["Clients/Acme"])
    }

    func testRenamingAnEmptyConfiguredFolderMovesItsNode() async throws {
        let (index, store) = try makeIndex()
        store.setDescription("Context", for: "Old")
        await mainHop()
        XCTAssertEqual(index.folderTree.map(\.path), ["Old"])

        store.handleFolderRewrite(from: "Old", to: "New")
        await mainHop()
        XCTAssertEqual(index.folderTree.map(\.path), ["New"])
    }

    func testDeletingOrClearingAnEmptyConfiguredFolderDropsItsNode() async throws {
        let (index, store) = try makeIndex()
        store.setDescription("Context", for: "Gone")
        store.setDescription("Context", for: "Cleared")
        await mainHop()
        XCTAssertEqual(Set(index.folderTree.map(\.path)), ["Gone", "Cleared"])

        store.handleFolderDeleted("Gone")
        store.setDescription("", for: "Cleared")   // the last config field → the key is dropped
        await mainHop()
        XCTAssertEqual(index.folderTree.map(\.path), [])
    }
}
