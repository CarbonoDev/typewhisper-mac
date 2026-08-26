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
    /// The meetings list filtered to a first-party tag (plan D8, M3). Renders `MeetingsListView`
    /// under the coordinator-held `activeTag` filter. Additive case on the otherwise-frozen contract
    /// (the M3/M4/M5 coordinated edits are the only ones permitted to grow this enum).
    case tag(String)
    /// The meetings list filtered to a first-party folder (plan D8, M4). Renders `MeetingsListView`
    /// under the coordinator-held `activeFolder` filter, which composes (AND) with `activeTag`.
    /// Additive case — the M4 coordinated edit (the second coordinated growth of this enum).
    /// (M7 re-targets this same case to a folder detail view without adding an enum case.)
    case folder(String)
    /// The meetings list filtered to the **Unfiled** set — meetings carrying no first-party folder —
    /// so they can be organized (owner request, reversing the M4 non-interactive "Unfiled" count).
    /// Renders `MeetingsListView` under the coordinator-held `unfiledOnly` flag, which composes (AND)
    /// with `activeTag` and is mutually exclusive with `activeFolder` (a meeting is either filed under
    /// some folder or unfiled, never both). Additive case — the M5 coordinated edit on the same footing
    /// as the M3 `.tag` / M4 `.folder` growths, and the third and last permitted growth of this enum.
    case unfiled
    /// Phase 2 — a vault-relative meeting-export folder path (Track E).
    case spaceFolder(String)
    /// Phase 2 — a vault-relative note path (Track E).
    case spaceNote(String)
}
