import Foundation

/// Single source of truth for the app's managed `Window(id:)` scene identifiers (UI Step 0, D1).
///
/// Every `ManagedAppWindowOpener.shared.open(id:)` call site references these constants instead of
/// bare string literals so the ids can never drift. `main` is the new meetings-first main window
/// scene (D1, D10); it is matched by **prefix** (not substring) in `ManagedWindowMatching` because
/// `"main"` is a common substring and SwiftUI scene windows get identifiers like `main-AppWindow-1`.
enum AppWindowID {
    static let main = "main"
    static let settings = "settings"
    static let setup = "setup"
    static let history = "history"
    static let errors = "errors"
    static let meetings = "meetings"
}
