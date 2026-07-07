import Foundation

/// The detail-pane destination of the meetings-first main window (UI Step 0, D3). Frozen contract:
/// other tracks route through `MainWindowCoordinator.shared` and never edit this enum. The Phase 2
/// `spaceFolder`/`spaceNote` cases are reserved now (dead until Track E) so Space can be wired
/// without touching the shell.
enum MainWindowRoute: Hashable {
    /// The meetings Home feed (Track C fills the stub).
    case home
    /// The full meetings list (`MeetingsListView`).
    case meetings
    /// A single meeting document (`MeetingDocumentView`).
    case meeting(UUID)
    /// Phase 2 — a vault-relative meeting-export folder path (Track E).
    case spaceFolder(String)
    /// Phase 2 — a vault-relative note path (Track E).
    case spaceNote(String)
}
