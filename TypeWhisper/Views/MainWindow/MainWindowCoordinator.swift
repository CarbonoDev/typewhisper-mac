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

    /// Focus a specific meeting document. Used by the focus bridge (menu bar / notifications) and
    /// by Home / list rows.
    func openMeeting(id: UUID) {
        route = .meeting(id)
    }

    /// Navigate to an arbitrary route. The folder and tag filters **compose (AND)** (plan D8):
    /// navigating to `.tag` sets `activeTag` while preserving `activeFolder`, `.folder` sets
    /// `activeFolder` while preserving `activeTag`, and any other destination clears both so a stale
    /// filter never bleeds across surfaces (Home stays the unfiltered landing surface, owner-veto 5).
    func show(_ route: MainWindowRoute) {
        switch route {
        case let .tag(tag):
            activeTag = tag
        case let .folder(folder):
            activeFolder = folder
        default:
            activeTag = nil
            activeFolder = nil
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

    /// Clear only the tag filter, keeping any active folder filter (plan D8 AND composition). Routes
    /// back to the folder-filtered list when a folder is still active, else the unfiltered list.
    func clearTagFilter() {
        activeTag = nil
        if let folder = activeFolder {
            route = .folder(folder)
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

    /// Clear both filters and return to the unfiltered meetings list (the combined header's Clear).
    func clearAllFilters() {
        activeTag = nil
        activeFolder = nil
        route = .meetings
    }

    /// Pure bridge from the existing `MeetingsViewModel.pendingFocusMeetingID` mechanism to a route.
    /// Returns the route to apply, or `nil` when there is no pending focus request. Kept pure and
    /// static so the focus-bridge behavior is unit-testable without SwiftUI.
    static func focusRoute(forPendingMeetingID id: UUID?) -> MainWindowRoute? {
        id.map { .meeting($0) }
    }
}
