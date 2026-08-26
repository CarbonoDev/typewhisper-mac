import Foundation

/// Pure, SwiftUI-free mapping from the main window's navigation state (route + active folder/tag
/// filters) to *which sidebar row is highlighted* (plan M5 — sidebar IA finalization: one source of
/// truth so Home / Meetings / Folder / Tag rows highlight consistently across every route type).
///
/// Selection is not a single winner: folders (vertical) and tags (horizontal) **compose (AND)**
/// (plan D8), so when both filters are active the folder row *and* the active tag row are both
/// highlighted at once. Callers therefore ask a per-row question (`isFolderSelected(_:)` /
/// `isTagSelected(_:)`) rather than reading one selected value. The Home / Meetings destinations are
/// mutually exclusive with the filtered routes.
///
/// Kept a pure static surface (like `MainWindowCoordinator.focusRoute`) so the highlight contract is
/// unit-testable without instantiating the sidebar view. `@MainActor` because `isFolderSelected`
/// reuses `MeetingService`'s main-actor folder tokenization (the canonical path normalizer) rather
/// than duplicating it; the sidebar view already runs on the main actor.
@MainActor
enum SidebarSelection {
    /// The **Home** destination is highlighted only on the unfiltered Home feed. Home is deliberately
    /// the unfiltered landing surface (owner-veto 5), so a folder/tag filter never lights it up.
    static func isHomeSelected(route: MainWindowRoute) -> Bool {
        route == .home
    }

    /// The **Meetings** destination covers the full list and any single meeting document (both live
    /// under "Meetings"), but **not** a folder- or tag-filtered route — those highlight their own
    /// sidebar rows instead.
    static func isMeetingsSelected(route: MainWindowRoute) -> Bool {
        switch route {
        case .meetings, .meeting:
            return true
        default:
            return false
        }
    }

    /// A **folder** row is highlighted when it is the active folder filter (compared on the normalized
    /// path so casing/slash differences don't strand the highlight). Independent of the tag filter, so
    /// it stays lit under folder+tag AND composition.
    static func isFolderSelected(_ nodePath: String, activeFolder: String?) -> Bool {
        guard let activeFolder else { return false }
        return MeetingService.normalizedFolderPath(activeFolder) == MeetingService.normalizedFolderPath(nodePath)
    }

    /// The **Unfiled** row is highlighted while the "meetings with no folder" filter is active. Like the
    /// folder/tag rows it reads the coordinator's filter state (not the route), so it stays lit under
    /// unfiled+tag AND composition and when a single meeting is opened from the filtered list. It is
    /// independent of `isFolderSelected` — Unfiled is not a folder path; the two verticals are mutually
    /// exclusive, so only one is ever lit at a time.
    static func isUnfiledSelected(unfiledOnly: Bool) -> Bool {
        unfiledOnly
    }

    /// A **tag** row is highlighted when it is the active tag filter. The comparison is case-folded so
    /// the row stays selected regardless of the casing the filter was set from (the sidebar sets tags
    /// by display name, the coordinator stores that name verbatim).
    static func isTagSelected(_ tagKey: String, activeTag: String?) -> Bool {
        guard let activeTag else { return false }
        return activeTag.lowercased() == tagKey.lowercased()
    }
}
