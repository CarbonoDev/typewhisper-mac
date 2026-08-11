import Foundation

/// `CalendarEventProviding` over the sync engine's cached snapshot ([Google Phase 1 · M3], D-G7).
/// The seam is synchronous and main-actor, so a network provider cannot answer inline — this one
/// never touches the network: it filters the in-memory snapshot the engine maintains on its
/// 5-minute cadence. Built and tested in M3; `CalendarService` adopts it as a secondary provider
/// in M4 (D-G4), so constructing it changes no behavior yet.
@MainActor
final class GoogleCalendarProvider: CalendarEventProviding {
    private let accountStore: GoogleAccountStore
    /// Snapshot seam: `{ engine.snapshot }` in production; tests inject a canned snapshot so the
    /// provider is testable without a sync engine (§7).
    private let snapshot: @MainActor () -> [GoogleCalendarSyncEngine.CalendarEvents]

    init(
        accountStore: GoogleAccountStore,
        snapshot: @escaping @MainActor () -> [GoogleCalendarSyncEngine.CalendarEvents]
    ) {
        self.accountStore = accountStore
        self.snapshot = snapshot
    }

    convenience init(accountStore: GoogleAccountStore, engine: GoogleCalendarSyncEngine) {
        self.init(accountStore: accountStore, snapshot: { engine.snapshot })
    }

    /// `.authorized` iff ≥ 1 account is `.connected`, else `.notDetermined` (D-G7). Google
    /// connect state is not a permission, so `.denied`/`.restricted` never apply; and once every
    /// account drops to `.needsReauth`, falling out of `.authorized` is what clears Google events
    /// from the lists — intended, mirroring EventKit-denied (D-G4).
    var authorizationStatus: CalendarAuthorizationStatus {
        accountStore.accounts.contains { $0.status == .connected } ? .authorized : .notDetermined
    }

    /// No system permission to prompt for — connecting accounts happens in Settings. Returns the
    /// current status (D-G7).
    func requestAccess() async -> CalendarAuthorizationStatus {
        authorizationStatus
    }

    /// Events overlapping the closed `[start, end]` window, from the snapshot — pure, synchronous,
    /// fast. Far-window queries (the ±7 d link picker) are answered best-effort from whatever the
    /// −1 d/+48 h synced window holds (explicit Phase 1 non-goal, spec §8).
    func events(from start: Date, to end: Date) -> [CalendarEventDTO] {
        guard authorizationStatus == .authorized else { return [] }
        return snapshot()
            .flatMap(\.events)
            .filter { $0.startDate <= end && $0.endDate >= start }
    }

    /// Every synced calendar across the connected accounts, for the selection list. Empty when no
    /// account is connected (matching the EventKit provider's unauthorized behavior).
    func calendars() -> [CalendarInfo] {
        guard authorizationStatus == .authorized else { return [] }
        return snapshot().map(\.calendar)
    }
}
