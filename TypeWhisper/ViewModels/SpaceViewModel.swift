import Foundation
import Combine
import AppKit

/// The Space browser's view model (Track E, ME-1). MVVM + `ServiceContainer` DI (static `_shared`
/// assigned at startup, per project pattern). It holds **one cached snapshot** of
/// `ObsidianVaultService.listEntries()` and rebuilds the vault tree in memory from it — it never
/// enumerates in a view `body`, never on a timer, and never through the body-parsing
/// `enumerateNotes`/`retrieve` path (plan D6). The snapshot is refreshed only on appear, on
/// `$vaultPath` change, and on manual Refresh.
@MainActor
final class SpaceViewModel: ObservableObject {
    nonisolated(unsafe) static var _shared: SpaceViewModel?
    static var shared: SpaceViewModel {
        guard let instance = _shared else {
            fatalError("SpaceViewModel not initialized")
        }
        return instance
    }

    /// The last `listEntries()` snapshot. The tree is derived from this in memory (no I/O in `body`).
    @Published private(set) var entries: [VaultEntry] = []
    /// Mirrors the vault connection so the sidebar section and route views gate without reaching into
    /// the service (kept live by the `$vaultPath` sink, like `MeetingsViewModel`).
    @Published private(set) var isConnected = false
    @Published private(set) var vaultName: String?
    /// True when the last enumeration hit the vault-scan cap, so the folder index can be honest about
    /// showing only the first N entries.
    @Published private(set) var didTruncate = false

    /// The sidebar tree (immediate children of the meetings root, recursively): rebuilt in-memory
    /// **once per snapshot** in `refresh()`, not per `body` evaluation, so navigation clicks don't
    /// re-run the recursive builder over the whole snapshot on every SwiftUI redraw (plan D6 / ME-1
    /// review). Pure, cached, safe to read from `body`.
    @Published private(set) var tree: [SpaceNode] = []

    private let vaultService: ObsidianVaultService
    private let defaults: UserDefaults
    private var cancellables = Set<AnyCancellable>()

    init(vaultService: ObsidianVaultService, defaults: UserDefaults = .standard) {
        self.vaultService = vaultService
        self.defaults = defaults
        refresh()
        // Re-enumerate whenever the connected vault changes (connect / disconnect / switch), mirroring
        // how `MeetingsViewModel` keeps its `isVaultConnected`/`vaultName` mirrors live. `.dropFirst()`
        // skips the `@Published` initial-value replay so app launch doesn't scan the vault twice (the
        // `init` `refresh()` above already captured the initial state) — for a feature the user may
        // never open.
        vaultService.$vaultPath
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
    }

    /// The configured meetings root folder Space is rooted at (plan D3/D5). Default `"Meetings"`; an
    /// empty setting collapses the scope to the whole vault (the exporter's documented escape hatch).
    var rootFolderPath: String {
        (defaults.string(forKey: UserDefaultsKeys.meetingsObsidianRootFolder) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The immediate children of `folderPath` for the folder index (each carries its own subtree so a
    /// child folder's item count is `child.children.count`). Pure, in-memory over the cached snapshot.
    func children(of folderPath: String) -> [SpaceNode] {
        SpaceTreeModel.build(from: entries, root: folderPath)
    }

    /// Re-read the single cached vault snapshot. The only place Space touches the disk enumerator
    /// (via the shared `listEntries()` primitive — no second scanner). Also refreshes the connection
    /// mirrors synchronously so callers (and tests) never depend on the async `$vaultPath` sink.
    func refresh() {
        isConnected = vaultService.isConnected
        vaultName = vaultService.vaultName
        let snapshot = vaultService.listEntries()
        entries = snapshot
        didTruncate = snapshot.count >= vaultService.maxEntriesScanned
        // Rebuild the sidebar tree once, here, off the snapshot — never in a view `body`.
        tree = SpaceTreeModel.build(from: snapshot, root: rootFolderPath)
    }

    /// Prompt for and connect a vault (the disconnected affordance). Reuses the single vault picker —
    /// no second picker (plan §6 non-goals).
    func chooseVault() {
        vaultService.chooseVault()
        refresh()
    }

    /// Reveal a vault-relative path in Finder (folder-index / note toolbar). No-op when disconnected.
    func revealInFinder(_ relativePath: String) {
        guard let vaultPath = vaultService.vaultPath else { return }
        let url = URL(fileURLWithPath: vaultPath, isDirectory: true)
            .appendingPathComponent(relativePath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
