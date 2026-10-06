import Foundation

/// Startup work that does not have to exist before the first frame (perf plan Phase 3, finding 16).
///
/// `initialize()` keeps everything the first frame, the menu bar and dictation need, in its original
/// order: crash recovery of interrupted meetings, the template migration, hotkeys, the API server,
/// plugin loading and provider restore, the watch folder. It then awaits this, which first waits for
/// the main run loop to go idle — the first frame is committed — and only then starts the fork's
/// background-only work. None of it is read by a first render or by the dictation path, and each step
/// is idempotent or app-lifetime, so running it a frame later changes nothing a user can observe.
extension ServiceContainer {
    func runDeferredStartup() async {
        LaunchMetrics.mark("critical startup done")
        await LaunchMetrics.mainRunLoopIdle()
        LaunchMetrics.mark("first frame")

        // [Google Phase 1 · M3] App-lifetime calendar sync cadence (D-G7 — deliberately not the
        // UI-visibility-scoped poll). Immediate first sync, then every 5 minutes, plus an
        // immediate re-sync on account connect/disconnect. Guarded out of tests by `initialize()`.
        googleCalendarSyncEngine.start()

        // [Google Phase 2 · M2] Drive discovery cadence (D-D6 — 15 min, app-lifetime). Polls only
        // `.connected` + Drive-enabled accounts; with every toggle off (the default until M3's
        // UI) it issues zero Drive requests.
        googleDriveSyncEngine.start()

        // [M2-Participants] One-time, idempotent backfill of the participant directory over every
        // existing meeting's roster (plan D7). Runs inline for a normally-sized archive; a large archive
        // (e.g. a bulk email import) is offloaded to the `io` lane so launch never blocks. Re-running is
        // a no-op because `ingest` is idempotent.
        let existingMeetings = meetingService.meetings
        if existingMeetings.count > ParticipantDirectoryService.largeArchiveThreshold {
            meetingJobQueue.enqueue(
                kind: .participantBackfill,
                meetingID: nil,
                priority: .background
            ) { [weak participantDirectoryService, weak meetingService] in
                await participantDirectoryService?.backfill(from: meetingService?.meetings ?? [])
            }
        } else {
            await participantDirectoryService.backfill(from: existingMeetings)
        }

        // Trim SwiftData persistent history nothing reads (off the main actor, one store at a time).
        await PersistentHistoryPruner.pruneRegisteredStores()
        LaunchMetrics.mark("deferred startup done")
    }
}
