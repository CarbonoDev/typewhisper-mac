import Foundation
import Combine
import AppKit
import os.log

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "SpaceViewModel")

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

    /// The active compose-then-create quick-note draft, or `nil` when not composing (Track E, ME-3,
    /// plan D1). The editor exists **before any file does**; committing performs exactly one
    /// never-clobber creation write. `SpaceFolderView` renders the draft editor when the draft targets
    /// the folder it's showing.
    @Published var draft: SpaceDraftState?

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

    // MARK: - Note reading (Track E, ME-2 / ME-3)

    /// Read a single vault note **once**, returning its raw text (frontmatter included) and resolved
    /// `typewhisper-meeting` backlink together (Track E, ME-3 — one disk read replaces the ME-2 note
    /// view's two, `readNote` + `meetingID`). `nil` when unreadable / missing / out of the vault; the
    /// backlink stays tolerant. Callers load it into view `@State` on appear, never in a `body`.
    func loadNote(at path: String) -> VaultNoteRead? {
        vaultService.readNoteWithBacklink(path)
    }

    // MARK: - Quick-note draft (Track E, ME-3)

    /// Begin a compose-then-create draft targeting `folderPath` (the currently viewed Space folder). The
    /// editor opens empty — no file exists yet; one is created only on commit (plan D1).
    func beginDraft(inFolder folderPath: String) {
        draft = SpaceDraftState(folderPath: folderPath, text: "")
    }

    /// Update the active draft's text (the `TextEditor` binding). No-op when not drafting.
    func updateDraftText(_ text: String) {
        draft?.text = text
    }

    /// Discard the active draft without writing anything (the deliberate Discard affordance / an empty
    /// commit). Frictionless: the caller confirms only when `SpaceDraft.shouldConfirmDiscard` is true.
    func discardDraft() {
        draft = nil
    }

    /// Commit the active draft as **one** never-clobber creation write (plan D1/D6). An empty draft is
    /// discarded silently (no file). Otherwise the filename derives from the first typed line
    /// (`SpaceDraft.filename`), the note is written into the draft's folder via `VaultNoteWriter`
    /// (collisions suffix `<name> 1.md`, never overwrite), the cached snapshot refreshes so the note
    /// appears immediately, and the new note's **vault-relative path** is returned for the caller to
    /// route to (read mode). Returns `nil` on empty draft, no vault, or a write failure — on failure
    /// the draft is **kept** so the user never loses content.
    @discardableResult
    func commitDraft() -> String? {
        guard let draft else { return nil }
        guard !SpaceDraft.isEmpty(draft.text) else {
            self.draft = nil
            return nil
        }
        guard let vaultPath = vaultService.vaultPath else {
            // No vault (e.g. disconnected mid-draft): keep the draft on the page so the user never
            // loses typed content — the same contract as the write-failure branch below, and D1's
            // central guarantee. A later reconnect can commit it.
            return nil
        }
        let folderAbsolute = absoluteFolderPath(vaultPath: vaultPath, relativeFolder: draft.folderPath)
        let filename = SpaceDraft.filename(from: draft.text)
        do {
            let url = try VaultNoteWriter.write(
                content: draft.text, toFolder: folderAbsolute, filename: filename)
            self.draft = nil
            refresh()
            return vaultRelativePath(of: url, vaultPath: vaultPath)
        } catch {
            // Keep the draft on the page so a write failure never loses the user's content, and log
            // it (the exporter logs its write failures the same way) so a failing disk/permissions
            // state is diagnosable rather than a silently no-op Done.
            logger.error("Failed to write Space quick-note: \(error.localizedDescription)")
            return nil
        }
    }

    /// The absolute path of a vault-relative folder: the vault root joined with each path component
    /// (empty ⇒ the vault root itself). `VaultNoteWriter.write` creates any missing intermediates.
    /// `..`/`.` components are skipped so a malformed route can never escape the vault to create
    /// directories outside it (defense-in-depth mirroring `resolvedNoteURL`'s traversal rejection on
    /// the read path; folder paths originate from the enumerator's own tree, so this never fires today).
    private func absoluteFolderPath(vaultPath: String, relativeFolder: String) -> String {
        var path = vaultPath
        for component in relativeFolder.split(separator: "/") {
            let name = String(component)
            guard name != ".." && name != "." else { continue }
            path = (path as NSString).appendingPathComponent(name)
        }
        return path
    }

    /// The vault-relative path of an absolute file URL (the created note), for routing to `.spaceNote`.
    /// Mirrors `ObsidianVaultService`'s relative-path derivation (drop the vault prefix, trim slashes).
    private func vaultRelativePath(of url: URL, vaultPath: String) -> String {
        let full = url.standardizedFileURL.path
        let base = URL(fileURLWithPath: vaultPath, isDirectory: true).standardizedFileURL.path
        guard full.hasPrefix(base) else { return url.lastPathComponent }
        return String(full.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Focus a meeting document from a Space note's "Open meeting" bridge row — the single navigation
    /// channel (`MainWindowCoordinator`), no second mechanism (plan V12).
    func openMeeting(id: UUID) {
        MainWindowCoordinator.shared.openMeeting(id: id)
    }

    /// Open a vault note in Obsidian via the `obsidian://open` URL scheme (quiet-row affordance).
    /// No-op when disconnected or Obsidian can't be reached (silent — editing lives in Obsidian, D1).
    func openInObsidian(_ relativePath: String) {
        guard let vaultName else { return }
        var components = URLComponents()
        components.scheme = "obsidian"
        components.host = "open"
        components.queryItems = [
            URLQueryItem(name: "vault", value: vaultName),
            URLQueryItem(name: "file", value: relativePath),
        ]
        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }

    /// Reveal a vault-relative path in Finder (folder-index / note toolbar). No-op when disconnected.
    func revealInFinder(_ relativePath: String) {
        guard let vaultPath = vaultService.vaultPath else { return }
        let url = URL(fileURLWithPath: vaultPath, isDirectory: true)
            .appendingPathComponent(relativePath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
