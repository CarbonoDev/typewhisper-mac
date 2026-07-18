import Foundation
import Combine

/// Per-folder context configuration attached to a first-party folder path (Amendment 1, DA4). A
/// folder is a *derived* path over meetings (there is no `Folder` entity), so its context lives in a
/// small UserDefaults-backed codable map keyed by the normalized folder path rather than a SwiftData
/// row: the map is the one place a configured-but-empty folder (context attached, no meetings yet)
/// can exist, and a folder rename is a manual path-prefix rewrite either way (SwiftData would not
/// cascade a string rename).
struct FolderContextConfig: Codable, Equatable, Sendable {
    /// Free-text description shown at the top of the folder detail view.
    var description: String = ""
    /// Vault-relative `.md` note paths explicitly attached as context.
    var attachedNotePaths: [String] = []
    /// Vault-relative folder paths attached as context — every `.md` under one is in scope, live at
    /// retrieval time (a fresh vault enumeration filters against these on every call, no snapshot).
    var attachedFolderPaths: [String] = []
    /// Explicit "no vault context" toggle — briefs/Q&A skip vault retrieval entirely for this folder.
    var noVaultContext: Bool = false

    /// True when nothing is configured — such a config is dropped from the map so it never lingers and
    /// never surfaces a phantom folder in the sidebar tree.
    var isEmpty: Bool {
        description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && attachedNotePaths.isEmpty
            && attachedFolderPaths.isEmpty
            && !noVaultContext
    }

    /// Whether any vault items are attached (drives `.wholeVault` vs `.restricted` scope).
    var hasAttachments: Bool {
        !attachedNotePaths.isEmpty || !attachedFolderPaths.isEmpty
    }
}

/// UserDefaults-backed store of `[folderPath: FolderContextConfig]` (Amendment 1, DA4). `_shared` +
/// ServiceContainer-wired so SwiftUI observes it directly (mirroring `MeetingOrganizationIndex`).
///
/// Attaches to M4's folder mutators: `MeetingService.renameFolder`/`moveFolder` fire
/// `onFolderPathRewrite` and `deleteFolder` fires `onFolderDeleted`; the wired handlers here rewrite
/// or drop the matching keys (component-wise prefix) so a folder's config follows a rename and dies
/// with the folder. `configuredFolderPaths()` feeds `MeetingOrganizationIndex`'s union point so a
/// configured-but-empty folder still appears in the tree.
@MainActor
final class MeetingFolderMetadataStore: ObservableObject {
    nonisolated(unsafe) static var _shared: MeetingFolderMetadataStore?
    static var shared: MeetingFolderMetadataStore {
        guard let instance = _shared else {
            fatalError("MeetingFolderMetadataStore not initialized")
        }
        return instance
    }

    /// The persisted config map, keyed by normalized folder path. Published so the folder detail view
    /// and the sidebar tree refresh when a config changes.
    @Published private(set) var configs: [String: FolderContextConfig] = [:]

    private let defaults: UserDefaults
    private let storageKey = UserDefaultsKeys.meetingsFolderContextConfigs

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: - Reads

    /// The config for a folder path (an empty default when none is stored). Path is normalized so a
    /// caller need not pre-normalize.
    func config(for folderPath: String) -> FolderContextConfig {
        configs[normalizedKey(folderPath)] ?? FolderContextConfig()
    }

    /// Folder paths that carry any configuration — the union input for `MeetingOrganizationIndex` so a
    /// configured-but-empty folder still surfaces in the tree.
    func configuredFolderPaths() -> [String] {
        configs.keys.sorted()
    }

    // MARK: - Writes

    /// Replace a folder's config. An empty config drops the key (so it never lingers or shows a
    /// phantom tree node); a no-op change avoids a redundant publish/persist.
    func setConfig(_ config: FolderContextConfig, for folderPath: String) {
        let key = normalizedKey(folderPath)
        guard !key.isEmpty else { return }
        if config.isEmpty {
            guard configs[key] != nil else { return }
            configs.removeValue(forKey: key)
        } else {
            guard configs[key] != config else { return }
            configs[key] = config
        }
        persist()
    }

    /// In-place mutation convenience over `config(for:)` + `setConfig(_:for:)`.
    func update(for folderPath: String, _ mutate: (inout FolderContextConfig) -> Void) {
        var config = config(for: folderPath)
        mutate(&config)
        setConfig(config, for: folderPath)
    }

    func setDescription(_ description: String, for folderPath: String) {
        update(for: folderPath) { $0.description = description }
    }

    func setNoVaultContext(_ value: Bool, for folderPath: String) {
        update(for: folderPath) { $0.noVaultContext = value }
    }

    /// Attach vault-relative note paths (deduped, preserving order); blanks are dropped.
    func attachNotes(_ paths: [String], to folderPath: String) {
        update(for: folderPath) { config in
            for path in paths {
                let rel = normalizeVaultPath(path)
                guard !rel.isEmpty, !config.attachedNotePaths.contains(rel) else { continue }
                config.attachedNotePaths.append(rel)
            }
        }
    }

    /// Attach vault-relative folder paths (deduped, preserving order); blanks are dropped.
    func attachFolders(_ paths: [String], to folderPath: String) {
        update(for: folderPath) { config in
            for path in paths {
                let rel = normalizeVaultPath(path)
                guard !rel.isEmpty, !config.attachedFolderPaths.contains(rel) else { continue }
                config.attachedFolderPaths.append(rel)
            }
        }
    }

    func removeAttachedNote(_ path: String, from folderPath: String) {
        let rel = normalizeVaultPath(path)
        update(for: folderPath) { $0.attachedNotePaths.removeAll { $0 == rel } }
    }

    func removeAttachedFolder(_ path: String, from folderPath: String) {
        let rel = normalizeVaultPath(path)
        update(for: folderPath) { $0.attachedFolderPaths.removeAll { $0 == rel } }
    }

    // MARK: - M4 folder-mutator seams (DA4)

    /// Rewrite the config keys for a folder rename/move (`old` → `new`, component-wise prefix) so a
    /// folder's config follows its path — including descendant configs. Wired to
    /// `MeetingService.onFolderPathRewrite`.
    func handleFolderRewrite(from old: String, to new: String) {
        let oldComps = MeetingService.folderComponents(old)
        let newComps = MeetingService.folderComponents(new)
        guard !oldComps.isEmpty, !newComps.isEmpty else { return }
        guard oldComps != newComps else { return }

        var updated = configs
        var changed = false
        for (key, value) in configs {
            let comps = MeetingService.folderComponents(key)
            guard comps.count >= oldComps.count, Array(comps.prefix(oldComps.count)) == oldComps else { continue }
            let newKey = (newComps + comps.dropFirst(oldComps.count)).joined(separator: "/")
            updated.removeValue(forKey: key)
            // M7 minor: a rename can collide with a config already present at the destination (a
            // pre-existing sibling folder renamed onto). Silently overwriting would drop the
            // destination's attachments/description — **merge** instead so no configuration is lost.
            if let existing = updated[newKey] {
                updated[newKey] = Self.merge(source: value, into: existing)
            } else {
                updated[newKey] = value
            }
            changed = true
        }
        guard changed else { return }
        configs = updated
        persist()
    }

    /// Merge a moved-from config into a config already present at the destination (M7 minor): union
    /// the attachments (destination order first, then any new source paths), keep the destination's
    /// non-empty description (else adopt the source's), and OR the `noVaultContext` flags.
    static func merge(source: FolderContextConfig, into destination: FolderContextConfig) -> FolderContextConfig {
        var result = destination
        if result.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.description = source.description
        }
        for path in source.attachedNotePaths where !result.attachedNotePaths.contains(path) {
            result.attachedNotePaths.append(path)
        }
        for path in source.attachedFolderPaths where !result.attachedFolderPaths.contains(path) {
            result.attachedFolderPaths.append(path)
        }
        result.noVaultContext = result.noVaultContext || source.noVaultContext
        return result
    }

    /// Drop the config for a deleted folder and every descendant config. Wired to
    /// `MeetingService.onFolderDeleted`.
    func handleFolderDeleted(_ path: String) {
        let comps = MeetingService.folderComponents(path)
        guard !comps.isEmpty else { return }
        let doomed = configs.keys.filter { key in
            let kc = MeetingService.folderComponents(key)
            return kc.count >= comps.count && Array(kc.prefix(comps.count)) == comps
        }
        guard !doomed.isEmpty else { return }
        for key in doomed { configs.removeValue(forKey: key) }
        persist()
    }

    // MARK: - Scope computation (DA5) — shared by brief + Q&A

    /// Resolve a meeting's vault-retrieval scope (Amendment 1, DA5; **extended** for Amendment 2, DB5).
    /// The precedence ladder:
    /// 1. Folder `noVaultContext` ⇒ `.none` — **absolute** (owner constraint).
    /// 2. Otherwise the **curated union**: per-meeting `curatedNotePaths` (discovered ∪ manual, minus
    ///    exclusions) ∪ the folder's live `attachedNotePaths` / `attachedFolderPaths`. If that union is
    ///    non-empty ⇒ `.restricted(...)` carrying `excludedNotePaths` so a removal is honored even
    ///    inside a live folder prefix.
    /// 3. Otherwise ⇒ `.wholeVault` (unchanged behavior for a meeting with no context configured).
    ///
    /// The zero-curated defaults keep every Amendment-1 caller/test valid (folder-only scope).
    func retrievalScope(
        forFolderPath folderPath: String?,
        curatedNotePaths: [String] = [],
        excludedNotePaths: [String] = []
    ) -> VaultRetrievalScope {
        var config = FolderContextConfig()
        if let folderPath, !MeetingService.folderComponents(folderPath).isEmpty {
            config = self.config(for: folderPath)
        }
        if config.noVaultContext { return .none }

        let excluded = Set(excludedNotePaths)
        let curated = Set(curatedNotePaths).subtracting(excluded)
        let folderNotes = Set(config.attachedNotePaths)
        let folderPrefixes = config.attachedFolderPaths

        if curated.isEmpty && folderNotes.isEmpty && folderPrefixes.isEmpty {
            return .wholeVault
        }
        return .restricted(
            notePaths: curated.union(folderNotes),
            folderPrefixes: folderPrefixes,
            excludedPaths: excluded
        )
    }

    /// The **pass-1** ("meeting-grounded") retrieval scope for in-meeting Q&A — the EXPLICITLY curated
    /// subset of `retrievalScope`. Owner decision: broad vault retrieval is OFF by default, so this
    /// differs from `retrievalScope` in two load-bearing ways:
    ///   • It drops the folder's `attachedFolderPaths` **prefixes** — a live folder is a *search* (rank
    ///     every `.md` under it), which is deferred to model-requested escalation (pass 2), not run by
    ///     default.
    ///   • It **never** falls back to `.wholeVault`: with nothing explicitly curated it returns `.none`
    ///     (retrieve nothing) rather than the whole-vault default fallback.
    /// The precedence ladder otherwise mirrors `retrievalScope`:
    /// 1. Folder `noVaultContext` ⇒ `.none` (absolute).
    /// 2. The curated **note** union `curatedNotePaths ∪ folder.attachedNotePaths` (minus exclusions):
    ///    non-empty ⇒ `.restricted(notePaths:, folderPrefixes: [])`; empty ⇒ `.none`.
    func curatedRetrievalScope(
        forFolderPath folderPath: String?,
        curatedNotePaths: [String] = [],
        excludedNotePaths: [String] = []
    ) -> VaultRetrievalScope {
        var config = FolderContextConfig()
        if let folderPath, !MeetingService.folderComponents(folderPath).isEmpty {
            config = self.config(for: folderPath)
        }
        if config.noVaultContext { return .none }

        let excluded = Set(excludedNotePaths)
        let curated = Set(curatedNotePaths).subtracting(excluded)
        let folderNotes = Set(config.attachedNotePaths)
        let notePaths = curated.union(folderNotes)
        guard !notePaths.isEmpty else { return .none }
        return .restricted(notePaths: notePaths, folderPrefixes: [], excludedPaths: excluded)
    }

    // MARK: - Persistence

    private func load() {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: FolderContextConfig].self, from: data) else {
            return
        }
        configs = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(configs) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private func normalizedKey(_ path: String) -> String {
        MeetingService.normalizedFolderPath(path) ?? ""
    }

    /// Trim surrounding slashes/whitespace from a vault-relative path so attachments compare cleanly
    /// against the vault enumerator's relative paths.
    private func normalizeVaultPath(_ path: String) -> String {
        path
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
