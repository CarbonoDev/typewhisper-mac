import Foundation
import SwiftData

extension PersistentModel {
    /// Whether SwiftData has detached this instance from its context **because it was deleted from
    /// the store**.
    ///
    /// Deleting a model does not evict it from the SwiftUI views that are holding it: a body
    /// invalidated by the delete's own `save()` can run once more against the pre-delete data — the
    /// row is still in the array its parent passed down, because the parent has not re-rendered yet.
    /// Reading a persisted property (or a cascade-deleted child) on such an instance traps inside
    /// SwiftData with "backing data could no longer be found", so anything a disappearing row
    /// touches has to check this first and degrade instead.
    ///
    /// `isDeleted` is **not** that check — it goes back to `false` once the delete is saved. What
    /// distinguishes a deleted model is having lost its context while still carrying a store
    /// identifier: a model that was never inserted (a preview fixture, a test's detached `@Model`, a
    /// draft) is also context-less, but its identifier has no store behind it and every property is
    /// plain memory, so it stays perfectly safe to read.
    var isDeletedFromStore: Bool {
        modelContext == nil && persistentModelID.storeIdentifier != nil
    }
}
