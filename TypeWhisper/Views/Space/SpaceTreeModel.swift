import Foundation

/// A node in Space's vault projection (Track E, ME-1). Unlike `MeetingFolderNode` this is a **file
/// tree**, not an aggregation: folders carry note *leaves*, and there are **no meeting counts** (the
/// grey count in the first-party tree means *meetings*; a Space count would poison that meaning —
/// plan D7). `relativePath` is the full **vault-relative** path (matching `VaultEntry.relativePath`
/// and the reserved `.spaceFolder`/`.spaceNote` route payloads, plan D3); `name` is the display
/// name (folder leaf name / note filename stem).
struct SpaceNode: Identifiable, Equatable, Sendable {
    let relativePath: String
    let name: String
    let isDirectory: Bool
    let children: [SpaceNode]

    /// Disjoint id per kind so a folder and a note that (impossibly) share a path never collide.
    var id: String { (isDirectory ? "d:" : "f:") + relativePath }
}

/// Pure, SwiftUI-free, I/O-free builder from a cached `[VaultEntry]` snapshot to the Space tree
/// (Track E, ME-1). It never enumerates the vault itself — `SpaceViewModel` owns the one cached
/// `listEntries()` snapshot and calls this to rebuild the tree in memory (plan D6). Kept a pure
/// static surface so building / sorting / nesting / root-scoping are unit-testable without a vault
/// (mirrors `MeetingOrganizationIndex.folderTree`, plan V8).
enum SpaceTreeModel {
    /// Normalize a folder path for component-wise comparison: trim whitespace and surrounding slashes.
    static func normalize(_ path: String) -> String {
        path.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func components(_ path: String) -> [String] {
        normalize(path).split(separator: "/").map(String.init)
    }

    /// Keep only the entries **strictly under** `root` (the root entry itself is the scope boundary
    /// and is excluded). Empty root ⇒ the whole vault (the exporter's documented escape hatch, plan
    /// D3/V5). Matching is **component-wise** so `Acme` never covers `Acme2` (the semantics of
    /// `VaultRetrievalScope.includes`).
    static func scoped(_ entries: [VaultEntry], under root: String) -> [VaultEntry] {
        let trimmed = normalize(root)
        guard !trimmed.isEmpty else { return entries }
        let prefix = trimmed + "/"
        return entries.filter { $0.relativePath.hasPrefix(prefix) }
    }

    /// Build the Space tree rooted at `root`: the returned top-level nodes are the **immediate
    /// children** of `root` (or the vault roots when `root` is empty). Folders carry their nested
    /// subtree; notes are leaves. Every level is ordered **folders-first, then case-insensitively by
    /// name** — mirroring `ObsidianVaultService.enumerateEntries`' deterministic sort. A one-off
    /// lookup; callers that ask repeatedly build a `SpaceTreeIndex` once instead.
    static func build(from entries: [VaultEntry], root: String = "") -> [SpaceNode] {
        SpaceTreeIndex(entries: entries).children(of: root)
    }

    /// The normalized parent folder of a vault-relative path (`""` for a vault-root entry).
    fileprivate static func parentKey(of path: String) -> String? {
        let comps = components(path)
        guard !comps.isEmpty else { return nil }
        return comps.dropLast().joined(separator: "/")
    }

    /// The normalized lookup key of a folder path.
    fileprivate static func key(of path: String) -> String {
        components(path).joined(separator: "/")
    }
}

/// The Space tree indexed **once per snapshot** (perf plan Phase 2): every folder path maps to its
/// immediate children, each carrying its full subtree. Built in one O(N log N) pass (group by parent,
/// then sort each level), so `children(of:)` is a dictionary lookup instead of a recursive rebuild
/// over the whole snapshot per call. Pure and `Sendable`, so it can be built off the main actor.
struct SpaceTreeIndex: Sendable, Equatable {
    static let empty = SpaceTreeIndex(entries: [])

    private let childrenByParent: [String: [SpaceNode]]

    init(entries: [VaultEntry]) {
        var meta: [String: (name: String, isDirectory: Bool)] = [:]
        for entry in entries {
            meta[entry.relativePath] = (entry.displayName, entry.isDirectory)
        }
        var pathsByParent: [String: [String]] = [:]
        for path in meta.keys {
            guard let parent = SpaceTreeModel.parentKey(of: path) else { continue }
            pathsByParent[parent, default: []].append(path)
        }

        var built: [String: [SpaceNode]] = [:]
        func nodes(under parent: String) -> [SpaceNode] {
            if let done = built[parent] { return done }
            let level = (pathsByParent[parent] ?? [])
                .map { path -> SpaceNode in
                    let info = meta[path] ?? ((path as NSString).lastPathComponent, false)
                    return SpaceNode(
                        relativePath: path,
                        name: info.name,
                        isDirectory: info.isDirectory,
                        children: info.isDirectory ? nodes(under: SpaceTreeModel.key(of: path)) : []
                    )
                }
                .sorted { lhs, rhs in
                    if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
            built[parent] = level
            return level
        }
        for parent in pathsByParent.keys {
            _ = nodes(under: parent)
        }
        childrenByParent = built
    }

    /// The immediate children of `folderPath` (`""` = the vault roots), each with its subtree. Empty
    /// for a note path or a folder not in the snapshot.
    func children(of folderPath: String) -> [SpaceNode] {
        childrenByParent[SpaceTreeModel.key(of: folderPath)] ?? []
    }
}
