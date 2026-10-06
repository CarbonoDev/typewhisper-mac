import Foundation
import SwiftData
import os

/// Prunes SwiftData **persistent history** (the `ATRANSACTION` / `ACHANGE` bookkeeping tables) from
/// the app's stores (perf plan Phase 3, finding 17).
///
/// SwiftData records history for every save, and nothing ever trims it — the meetings store carried
/// ~74k `ACHANGE` rows that every open and save dragged along. Nothing in the app consumes that
/// history: no history tokens or `fetchHistory` calls, no remote-change observers, no CloudKit
/// mirroring (the entitlements carry none), and neither the widget (app-group JSON via
/// `WidgetDataService`) nor the CLI (the localhost HTTP API) opens a store. So history older than a
/// short window is dead weight.
///
/// Safety: `deleteHistory` removes **only** history transactions — never a model row — and it
/// changes nothing about the schema, so `SwiftDataStoreFactory`'s incompatible-schema reset can
/// never be triggered by it. It runs on its own `ModelContext` off the main actor, after the first
/// frame, and a failure only logs. `PersistentHistoryPrunerTests` proves rows survive a prune and a
/// reopen over a real on-disk store.
enum PersistentHistoryPruner {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "PersistentHistoryPruner")

    /// History younger than this is kept. Nothing reads it; the window only avoids racing a save
    /// that is in flight while the prune runs.
    static let defaultRetention: TimeInterval = 24 * 60 * 60

    /// A store the factory opened, held weakly so the registry never extends a container's life.
    private struct Registration {
        let storeName: String
        weak var container: ModelContainer?
    }

    @MainActor private static var registrations: [Registration] = []

    /// Record a container opened by `SwiftDataStoreFactory` so the launch prune can reach it (the
    /// owning services keep their containers private).
    @MainActor
    static func register(_ container: ModelContainer, storeName: String) {
        registrations.removeAll { $0.container == nil }
        registrations.append(Registration(storeName: storeName, container: container))
    }

    /// The live registered containers, by store name (most recent registration last).
    @MainActor
    static func registeredContainers() -> [(storeName: String, container: ModelContainer)] {
        registrations.compactMap { registration in
            registration.container.map { (registration.storeName, $0) }
        }
    }

    /// Prune every registered store's history older than `retention`, one store at a time, off the
    /// main actor. Called once per launch, after the first frame.
    @MainActor
    static func pruneRegisteredStores(retention: TimeInterval = defaultRetention) async {
        let cutoff = Date().addingTimeInterval(-retention)
        for (storeName, container) in registeredContainers() {
            do {
                try await prune(container, olderThan: cutoff)
            } catch {
                logger.error("History prune failed for \(storeName, privacy: .public): \(error.localizedDescription)")
            }
        }
    }

    /// Delete `container`'s history transactions older than `cutoff` on a fresh context, off the main
    /// actor. A no-op before macOS 15, where SwiftData has no history API.
    static func prune(_ container: ModelContainer, olderThan cutoff: Date) async throws {
        guard #available(macOS 15, *) else { return }
        try await Task.detached(priority: .utility) {
            let context = ModelContext(container)
            var descriptor = HistoryDescriptor<DefaultHistoryTransaction>()
            descriptor.predicate = #Predicate { $0.timestamp < cutoff }
            try context.deleteHistory(descriptor)
        }.value
    }
}
