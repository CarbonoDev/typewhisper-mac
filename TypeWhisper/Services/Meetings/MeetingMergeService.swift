import Foundation
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "MeetingMergeService")

/// The LLM seam of the meeting merge (the `MeetingContextRuleMatching` / diarization-provider
/// pattern): only conflicts the deterministic `MeetingMergePlanner` could not settle reach this
/// protocol, so tests exercise the merge with a fake and never touch a provider.
///
/// v1 scope: resolve the *title* conflict (several distinct human-chosen titles). Returning `nil`
/// — for any reason: no resolver wired, provider failure, empty answer — keeps the plan's
/// deterministic fallback, so a merge can never fail on the LLM pass.
@MainActor
protocol MeetingMergeConflictResolving: AnyObject {
    /// Pick (or synthesize) the merged meeting's title from the conflicting human-chosen
    /// `candidates` (priority order, first = deterministic fallback). Return `nil` to keep the
    /// deterministic pick.
    func resolveMergedTitle(candidates: [String]) async -> String?
}

/// The v1 default resolver: **deterministic by design** — it always defers to the planner's own
/// fallback (the highest-priority human title) by returning `nil`. Documented choice: wiring a real
/// provider call through `MeetingModelRouter` deserves its own purpose rung + settings surface, so
/// v1 ships the seam with this stand-in rather than a half-wired LLM call. A future
/// `LLMMergeConflictResolver` conforms to `MeetingMergeConflictResolving` and routes through the
/// `PromptProcessing` / `MeetingModelRouter` conventions (per-call resolution, provenance honesty).
@MainActor
final class DeterministicMergeConflictResolver: MeetingMergeConflictResolving {
    init() {}

    func resolveMergedTitle(candidates: [String]) async -> String? { nil }
}

/// Orchestrates a meeting merge: snapshot → deterministic plan (`MeetingMergePlanner`) → LLM pass
/// for unresolved conflicts (the `MeetingMergeConflictResolving` seam) → apply through
/// `MeetingService.applyMerge` (the meetings store's single writer). Owns no store of its own.
@MainActor
final class MeetingMergeService {
    private let meetingService: MeetingService
    private let conflictResolver: MeetingMergeConflictResolving

    init(
        meetingService: MeetingService,
        conflictResolver: MeetingMergeConflictResolving = DeterministicMergeConflictResolver()
    ) {
        self.meetingService = meetingService
        self.conflictResolver = conflictResolver
    }

    /// Whether this set of meetings can be merged right now: at least two, none mid-capture or
    /// mid-finalization (`.live` / `.processing`) — stop the recording first. Gates the UI
    /// affordance and is re-checked in `merge(_:)`.
    static func canMerge(_ meetings: [Meeting]) -> Bool {
        MeetingMergePlanner.isMergeable(meetings.map(\.state))
    }

    /// Merge `meetings` into one: the planner picks the primary and assembles the best data
    /// deterministically; the conflict resolver settles only what the rules could not (v1: the
    /// title); the absorbed meetings are deleted through the service's normal delete path.
    /// Returns the surviving meeting, or `nil` when the set is not mergeable.
    ///
    /// `willAbsorb` is a pre-apply seam (review finding, single-plan design): it runs exactly once,
    /// with the one deterministic plan's `absorbedIDs`, after `canMerge`/`MeetingMergePlanner.plan`
    /// have both already succeeded and *before* `applyMerge` deletes those rows. A caller that needs
    /// to react to "these ids are about to be absorbed" (cancel their queued/running jobs, navigate
    /// off an open document) does it here instead of re-snapshotting and re-planning on its own side —
    /// two independent plans over the same live `Meeting` rows can disagree if main-actor work lands
    /// between them (a running transcription appending a segment shifts the segment-count tiebreak; a
    /// caption-bridge resume or a state flip changes the primary pick), and a caller that acts on its
    /// own early plan can cancel jobs / navigate away for a merge that this function then refuses
    /// (returns `nil`) for completely unrelated reasons. Because this callback only ever fires once
    /// `merge` is already committed to applying *this exact* plan, "abort" and "side effect" can never
    /// diverge. Optional and `nil` by default so every existing call site (tests included) is
    /// unaffected.
    @discardableResult
    func merge(
        _ meetings: [Meeting],
        willAbsorb: (@MainActor ([UUID]) async -> Void)? = nil
    ) async -> Meeting? {
        guard Self.canMerge(meetings) else { return nil }
        let snapshots = meetings.map { MeetingMergeSnapshot(of: $0) }
        guard let plan = MeetingMergePlanner.plan(snapshots) else { return nil }

        if let willAbsorb {
            await willAbsorb(plan.absorbedIDs)
        }

        var resolvedTitle: String?
        if plan.hasTitleConflict {
            resolvedTitle = await conflictResolver.resolveMergedTitle(candidates: plan.titleCandidates)
        }
        if !plan.conflicts.isEmpty {
            logger.info("Merging \(meetings.count) meetings with \(plan.conflicts.count) noted conflict(s)")
        }
        return meetingService.applyMerge(plan, resolvedTitle: resolvedTitle)
    }
}
