import Combine
import Foundation

/// Navigation coordinator for the meetings-first main window (UI Step 0, D3). Singleton set in
/// `TypeWhisperApp.init` (same lifecycle as `SettingsNavigationCoordinator.shared`). The API is
/// frozen at Step 0: other tracks call `openMeeting(id:)` / `show(_:)` but never edit this type.
///
/// All cross-navigation in the main window flows through this single channel — the menu-bar
/// "Start Meeting Recording", meeting-start notifications, Home rows, and (Phase 2) Space backlinks
/// all resolve to a `MainWindowRoute` here, so there is never a second navigation mechanism.
@MainActor
final class MainWindowCoordinator: ObservableObject {
    nonisolated(unsafe) static var shared: MainWindowCoordinator!

    @Published var route: MainWindowRoute = .home

    /// The active first-party **tag** filter (plan D8, M3). Held here (not on `MeetingsViewModel`,
    /// whose stored state is off-limits under the extension-file discipline) so the filtered
    /// `MeetingsListView` and the sidebar highlight read one source of truth. `nil` = no tag filter.
    @Published private(set) var activeTag: String?

    /// The active first-party **folder** filter (plan D8, M4). Composes (AND) with `activeTag` —
    /// folders are vertical, tags horizontal. `nil` = no folder filter.
    @Published private(set) var activeFolder: String?

    /// Whether the **Unfiled** filter (meetings with no folder) is active (owner request). A second
    /// vertical facet: it composes (AND) with `activeTag` exactly like `activeFolder`, and is mutually
    /// exclusive with `activeFolder` (an invariant `show(_:)` maintains). `false` = not filtering.
    @Published private(set) var unfiledOnly = false

    /// Focus a specific meeting document. Used by the focus bridge (menu bar / notifications) and
    /// by Home / list rows.
    func openMeeting(id: UUID) {
        route = .meeting(id)
    }

    /// Navigate to an arbitrary route. The vertical (folder / unfiled) and horizontal (tag) filters
    /// **compose (AND)** (plan D8): `.tag` sets `activeTag` while preserving the active vertical filter,
    /// `.folder` sets `activeFolder` (clearing `unfiledOnly` — the two verticals are mutually exclusive)
    /// while preserving `activeTag`, `.unfiled` sets `unfiledOnly` (clearing `activeFolder`) while
    /// preserving `activeTag`, and any other destination clears all three so a stale filter never bleeds
    /// across surfaces (Home stays the unfiltered landing surface, owner-veto 5).
    func show(_ route: MainWindowRoute) {
        switch route {
        case let .tag(tag):
            activeTag = tag
        case let .folder(folder):
            activeFolder = folder
            unfiledOnly = false
        case .unfiled:
            unfiledOnly = true
            activeFolder = nil
        default:
            activeTag = nil
            activeFolder = nil
            unfiledOnly = false
        }
        self.route = route
    }

    /// Filter the meetings list by a first-party tag (plan D8, M3). Sets `activeTag` and routes to the
    /// filtered list; the active folder (if any) is preserved so the two compose.
    func showTag(_ tag: String) {
        show(.tag(tag))
    }

    /// Filter the meetings list by a first-party folder (plan D8, M4). Sets `activeFolder` and routes
    /// to the filtered list; the active tag (if any) is preserved so the two compose.
    func showFolder(_ folder: String) {
        show(.folder(folder))
    }

    /// Filter the meetings list to the Unfiled set (owner request). Sets `unfiledOnly` and routes to the
    /// filtered list; the active tag (if any) is preserved so the two compose.
    func showUnfiled() {
        show(.unfiled)
    }

    /// Clear only the tag filter, keeping any active vertical filter (plan D8 AND composition). Routes
    /// back to the folder- or unfiled-filtered list when one is still active, else the unfiltered list.
    func clearTagFilter() {
        activeTag = nil
        if let folder = activeFolder {
            route = .folder(folder)
        } else if unfiledOnly {
            route = .unfiled
        } else {
            route = .meetings
        }
    }

    /// Clear only the folder filter, keeping any active tag filter (plan D8 AND composition).
    func clearFolderFilter() {
        activeFolder = nil
        if let tag = activeTag {
            route = .tag(tag)
        } else {
            route = .meetings
        }
    }

    /// Clear only the Unfiled filter, keeping any active tag filter (plan D8 AND composition). Routes
    /// back to the tag-filtered list when a tag is still active, else the unfiltered list.
    func clearUnfiledFilter() {
        unfiledOnly = false
        if let tag = activeTag {
            route = .tag(tag)
        } else {
            route = .meetings
        }
    }

    /// Clear every filter and return to the unfiltered meetings list (the combined header's Clear).
    func clearAllFilters() {
        activeTag = nil
        activeFolder = nil
        unfiledOnly = false
        route = .meetings
    }

    /// Pure bridge from the existing `MeetingsViewModel.pendingFocusMeetingID` mechanism to a route.
    /// Returns the route to apply, or `nil` when there is no pending focus request. Kept pure and
    /// static so the focus-bridge behavior is unit-testable without SwiftUI.
    static func focusRoute(forPendingMeetingID id: UUID?) -> MainWindowRoute? {
        id.map { .meeting($0) }
    }
}
