import Combine
import Foundation

/// [Perf Phase 2] Multi-select on the Meetings list and folder detail (plan LX-1, D3), lifted off
/// `MeetingsViewModel`: there, every ⌘/⇧-click republished the singleton and re-ran all of its ~50
/// observers. Only the two selectable list surfaces and their row menus observe this.
///
/// Shared rather than view-local `@State` so the selection survives opening a meeting and coming
/// back, as it did on the view model. It holds ids only; the lists normalize it to their visible set
/// whenever that set changes (which also drops deleted and merged-away meetings).
@MainActor
final class MeetingSelectionModel: ObservableObject {
    static let shared = MeetingSelectionModel()

    @Published var ids: Set<UUID> = []

    /// The selection intersected with a visible id list — the effective, on-screen selection.
    func visibleSelection(in visibleIDs: [UUID]) -> Set<UUID> {
        ids.intersection(visibleIDs)
    }

    /// Drop selected ids that are no longer visible; publishes only on an actual change.
    func normalize(toVisibleIDs visibleIDs: [UUID]) {
        let normalized = MeetingsViewModel.normalizedSelection(ids, toVisibleIDs: visibleIDs)
        if normalized != ids { ids = normalized }
    }

    /// The selected meetings among `meetings`, in that order.
    func selectedMeetings(in meetings: [Meeting]) -> [Meeting] {
        meetings.filter { ids.contains($0.id) }
    }
}
