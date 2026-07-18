import Foundation

/// Pure, SwiftUI-free sidebar-highlight predicates for Space's vault rows (Track E, ME-1). The
/// first-party `SidebarSelection` is the shell's highlight contract and Track E never edits it (plan
/// D5/V7): the `.spaceFolder`/`.spaceNote` route families are **disjoint** from `.folder`/`.tag` by
/// construction, so Space highlight is trivial route equality and needs none of `SidebarSelection`'s
/// filter-state inputs. Kept a pure static surface (like `SidebarSelection`) so the highlight
/// contract is unit-testable without instantiating the sidebar view.
///
/// `@MainActor` to sit on the same actor as the sidebar view and `SidebarSelection`; the predicates
/// touch no main-actor state themselves.
@MainActor
enum SpaceSelection {
    /// A **Space folder** row is highlighted only while the current route is `.spaceFolder(path)` for
    /// the same (normalized) vault-relative path. Disjoint from `.folder`/`.tag`/`.spaceNote`.
    static func isSpaceFolderSelected(_ path: String, route: MainWindowRoute) -> Bool {
        guard case let .spaceFolder(routePath) = route else { return false }
        return SpaceTreeModel.normalize(routePath) == SpaceTreeModel.normalize(path)
    }

    /// A **Space note** row is highlighted only while the current route is `.spaceNote(path)` for the
    /// same (normalized) vault-relative path. Disjoint from `.folder`/`.tag`/`.spaceFolder`.
    static func isSpaceNoteSelected(_ path: String, route: MainWindowRoute) -> Bool {
        guard case let .spaceNote(routePath) = route else { return false }
        return SpaceTreeModel.normalize(routePath) == SpaceTreeModel.normalize(path)
    }
}
