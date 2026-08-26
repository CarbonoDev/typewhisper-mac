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
    /// name** — mirroring `ObsidianVaultService.enumerateEntries`' deterministic sort.
    static func build(from entries: [VaultEntry], root: String = "") -> [SpaceNode] {
        let trimmed = normalize(root)
        let inScope = scoped(entries, under: trimmed)
        var meta: [String: (name: String, isDirectory: Bool)] = [:]
        for entry in inScope {
            meta[entry.relativePath] = (entry.displayName, entry.isDirectory)
        }
        let rootDepth = trimmed.isEmpty ? 0 : components(trimmed).count
        return buildNodes(parentPath: trimmed, parentDepth: rootDepth, meta: meta)
    }

    /// Immediate children of `parentPath` (`""` = vault roots) as `SpaceNode`s, recursively.
    private static func buildNodes(
        parentPath: String,
        parentDepth: Int,
        meta: [String: (name: String, isDirectory: Bool)]
    ) -> [SpaceNode] {
        let children = meta.keys.filter { path in
            let comps = components(path)
            guard comps.count == parentDepth + 1 else { return false }
            return comps.dropLast().joined(separator: "/") == parentPath
        }
        return children
            .map { path -> SpaceNode in
                let info = meta[path] ?? ((path as NSString).lastPathComponent, false)
                return SpaceNode(
                    relativePath: path,
                    name: info.name,
                    isDirectory: info.isDirectory,
                    children: info.isDirectory
                        ? buildNodes(parentPath: path, parentDepth: parentDepth + 1, meta: meta)
                        : []
                )
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }
}
