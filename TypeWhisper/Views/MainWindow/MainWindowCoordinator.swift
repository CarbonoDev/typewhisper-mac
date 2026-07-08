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
    /// Folders (`activeFolder`) join this in M4; the two compose (AND) then.
    @Published private(set) var activeTag: String?

    /// Focus a specific meeting document. Used by the focus bridge (menu bar / notifications) and
    /// by Home / list rows.
    func openMeeting(id: UUID) {
        route = .meeting(id)
    }

    /// Navigate to an arbitrary route. Selecting anything other than the tag-filtered list clears the
    /// active tag filter so a stale filter never bleeds across destinations.
    func show(_ route: MainWindowRoute) {
        if case let .tag(tag) = route {
            activeTag = tag
        } else {
            activeTag = nil
        }
        self.route = route
    }

    /// Filter the meetings list by a first-party tag (plan D8, M3). Sets `activeTag` and routes to the
    /// filtered list; Home stays the unfiltered landing surface (owner-veto 5).
    func showTag(_ tag: String) {
        show(.tag(tag))
    }

    /// Clear the active tag filter and return to the unfiltered meetings list.
    func clearTagFilter() {
        show(.meetings)
    }

    /// Pure bridge from the existing `MeetingsViewModel.pendingFocusMeetingID` mechanism to a route.
    /// Returns the route to apply, or `nil` when there is no pending focus request. Kept pure and
    /// static so the focus-bridge behavior is unit-testable without SwiftUI.
    static func focusRoute(forPendingMeetingID id: UUID?) -> MainWindowRoute? {
        id.map { .meeting($0) }
    }
}
