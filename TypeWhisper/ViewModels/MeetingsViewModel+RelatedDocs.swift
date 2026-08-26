import Foundation

/// First-party related-documents surface (Amendment 2, DB6/DB8, M8). Thin MainActor pass-throughs that
/// enqueue discovery on the job queue and route manual add/remove through the single-writer
/// `MeetingService` setters, plus the resolved-union rows the meeting document's Related Documents
/// section renders. Extension-file discipline: no stored state is added here.
@MainActor
extension MeetingsViewModel {
    /// How a related-document row entered the resolved union (drives its provenance caption, DB8).
    enum RelatedDocProvenance {
        case folder      // live folder-attached scope (Amendment 1)
        case suggested   // judge-kept discovery (Amendment 2)
        case manual      // user pick
    }

    /// One row in the meeting document's Related Documents list (DB8).
    struct RelatedDocRow: Identifiable {
        let path: String
        let displayName: String
        let folderCaption: String
        let provenance: RelatedDocProvenance
        let isDirectory: Bool
        /// A note path that no longer resolves in the vault (renamed/moved) — rendered greyed "Missing".
        let isMissing: Bool

        var id: String { (isDirectory ? "d:" : "f:") + path }

        /// Whether the section's ✕ may remove this row. Only note rows are removable via a per-meeting
        /// exclusion — an exclusion records the exact note path, which `VaultRetrievalScope.includes`
        /// honors by exact match. A folder-prefix (directory) row expands *live* to every note under it,
        /// so recording its directory path as an exclusion would not suppress those notes (the exclusion
        /// never matches a note's path). Folder-level scope is therefore edited in the M7 folder detail
        /// view, not here — this keeps the UI and the consumption scope consistent (Amendment 2, DB4/DB5).
        var isRemovable: Bool { !isDirectory }
    }

    // MARK: - Discovery (DB6)

    /// Enqueue a user-initiated related-document discovery for a meeting (Amendment 2, DB6). The queue's
    /// `(relatedDiscovery, meetingID)` dedupe drops a second press while one is in flight and promotes a
    /// queued background run. Fails visibly: a thrown (fail-closed) judge marks the job `.failed` (J3).
    func findRelatedDocuments(for meeting: Meeting) {
        jobQueue.enqueue(
            kind: .relatedDiscovery,
            meetingID: meeting.id,
            progressLabel: String(localized: "meetings.jobs.progress.findingRelated")
        ) { [weak relatedDocsService] in
            guard let relatedDocsService else { return }
            try await relatedDocsService.discoverRelated(for: meeting)
        }
    }

    /// Whether a `relatedDiscovery` job is in flight for this meeting — drives the section's working
    /// badge and disables re-trigger. Meeting-scoped so it does not follow navigation.
    func isDiscoveringRelated(for meeting: Meeting) -> Bool {
        jobQueue.hasActiveJob(kind: .relatedDiscovery, meetingID: meeting.id)
    }

    /// Whether the last settled `relatedDiscovery` job for this meeting failed (fail-closed judge or an
    /// LLM error). Drives the "Last search couldn't complete" hint (DB8); Retry lives in the J3 popover.
    ///
    /// M8 carried minor: a failed row is retained until dismissed, so a failure followed by a
    /// *successful* re-run would otherwise keep showing the failure banner (any `.failed` row matches).
    /// Consider **only the most recently settled** `relatedDiscovery` job (max by `finishedAt`): a
    /// later success supersedes the earlier failure and clears the banner.
    func lastRelatedDiscoveryFailed(for meeting: Meeting) -> Bool {
        Self.lastSettledJobFailed(jobQueue.jobs(for: meeting.id), kind: .relatedDiscovery)
    }

    /// Pure: whether the most recently *settled* (finished — not queued/running) job of `kind` failed.
    /// The most recent is `max` by `finishedAt`, so a later success/cancel supersedes an earlier
    /// failure. Returns `false` when no settled job of that kind exists. Unit-testable without the VM.
    static func lastSettledJobFailed(_ jobs: [MeetingJob], kind: MeetingJobKind) -> Bool {
        lastSettledFailureMessage(jobs, kind: kind) != nil
    }

    /// The specific (localized) failure reason of the most recently settled `relatedDiscovery` job, so
    /// the section's failure banner can surface *why* the last search couldn't complete without opening
    /// the activity popover. `nil` when the latest settled discovery didn't fail (or there is none).
    func lastRelatedDiscoveryFailureReason(for meeting: Meeting) -> String? {
        Self.lastSettledFailureMessage(jobQueue.jobs(for: meeting.id), kind: .relatedDiscovery)
    }

    /// Pure: the `.failed(message:)` payload of the most recently *settled* job of `kind` (`max` by
    /// `finishedAt`, so a later success/cancel supersedes an earlier failure), or `nil` when the latest
    /// settled job didn't fail / none exists. The message is `error.localizedDescription` captured by
    /// the queue, i.e. the localized `LocalizedError` reason. Unit-testable without the VM.
    static func lastSettledFailureMessage(_ jobs: [MeetingJob], kind: MeetingJobKind) -> String? {
        let settled = jobs.filter { $0.kind == kind && !$0.state.isActive }
        guard let latest = settled.max(by: {
            ($0.finishedAt ?? .distantPast) < ($1.finishedAt ?? .distantPast)
        }) else { return nil }
        if case let .failed(message) = latest.state { return message }
        return nil
    }

    // MARK: - Manual edits (DB4)

    /// Add manual related notes from picked vault entries (notes only). An explicit add clears a prior
    /// exclusion of the same path (DB4).
    func addManualRelatedNotes(_ entries: [VaultEntry], for meeting: Meeting) {
        for entry in entries where !entry.isDirectory {
            meetingService.addManualRelatedNote(entry.relativePath, for: meeting)
        }
    }

    /// Remove a related note (the ✕): records an exclusion so it never resurrects (DB4).
    func removeRelatedNote(_ path: String, for meeting: Meeting) {
        meetingService.removeRelatedNote(path, for: meeting)
    }

    // MARK: - Reads (DB5/DB8)

    /// Whether the meeting's folder has "No vault context" set — the section then notes that curated
    /// entries are not consumed (DB5 absolute).
    func relatedDocsNoVaultContext(for meeting: Meeting) -> Bool {
        folderMetadataStore.config(for: meeting.folderPath ?? "").noVaultContext
    }

    /// The resolved related-documents union for a meeting (DB5 minus excluded, DB8): folder-attached
    /// scope ("From folder"), discovered suggestions ("Suggested"), and manual picks ("Added by you"),
    /// deduped by path. Note rows resolve against the vault for show-as-missing.
    func relatedDocuments(for meeting: Meeting) -> [RelatedDocRow] {
        let config = folderMetadataStore.config(for: meeting.folderPath ?? "")
        let excluded = Set(meeting.excludedNotePaths)

        var rows: [RelatedDocRow] = []
        var seen = Set<String>()

        func add(_ path: String, provenance: RelatedDocProvenance, isDirectory: Bool) {
            let rel = MeetingService.normalizeVaultRelPath(path)
            guard !rel.isEmpty, !excluded.contains(rel), seen.insert(rel).inserted else { return }
            let missing = isDirectory ? false : !vaultService.noteExists(rel)
            let ns = rel as NSString
            // Match the established `VaultEntry` display convention (ObsidianVaultService.listEntries):
            // a note's title is its filename minus the `.md` extension; a folder's is its last component.
            let displayName = isDirectory
                ? ns.lastPathComponent
                : ns.deletingPathExtension.components(separatedBy: "/").last ?? ns.lastPathComponent
            rows.append(RelatedDocRow(
                path: rel,
                displayName: displayName,
                // The caption is the *containing* folder path (mirrors the judge input's folder-path
                // caption, `ObsidianVaultService.candidateNotes`), not the full path including the file.
                folderCaption: ns.deletingLastPathComponent,
                provenance: provenance,
                isDirectory: isDirectory,
                isMissing: missing
            ))
        }

        for path in config.attachedFolderPaths { add(path, provenance: .folder, isDirectory: true) }
        for path in config.attachedNotePaths { add(path, provenance: .folder, isDirectory: false) }
        for note in meeting.relatedNotePaths where note.provenance == .discovered {
            add(note.path, provenance: .suggested, isDirectory: false)
        }
        for note in meeting.relatedNotePaths where note.provenance == .manual {
            add(note.path, provenance: .manual, isDirectory: false)
        }
        return rows
    }
}
