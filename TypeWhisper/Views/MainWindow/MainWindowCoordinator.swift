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

    /// Focus a specific meeting document. Used by the focus bridge (menu bar / notifications) and
    /// by Home / list rows.
    func openMeeting(id: UUID) {
        route = .meeting(id)
    }

    /// Navigate to an arbitrary route.
    func show(_ route: MainWindowRoute) {
        self.route = route
    }

    /// Pure bridge from the existing `MeetingsViewModel.pendingFocusMeetingID` mechanism to a route.
    /// Returns the route to apply, or `nil` when there is no pending focus request. Kept pure and
    /// static so the focus-bridge behavior is unit-testable without SwiftUI.
    static func focusRoute(forPendingMeetingID id: UUID?) -> MainWindowRoute? {
        id.map { .meeting($0) }
    }
}
