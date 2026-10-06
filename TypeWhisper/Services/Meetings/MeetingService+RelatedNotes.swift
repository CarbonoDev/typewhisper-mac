import Foundation

/// Related documents (Amendment 2, DB4): the single-writer setters for a meeting's curated set.
extension MeetingService {
    // MARK: - Related documents (Amendment 2, DB4 — single-writer setters)

    /// Normalize a vault-relative path for comparison: trim whitespace and surrounding slashes so a
    /// stored/attached path compares cleanly against the vault enumerator's relative paths.
    static func normalizeVaultRelPath(_ path: String) -> String {
        path
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// **Replace** the `discovered` entries of a meeting's curated related set (keeping every `manual`
    /// entry untouched), drop any path present in `excludedNotePaths` (belt-and-suspenders vs DB3/DB5),
    /// and stamp `relatedDiscoveryAt` (Amendment 2, DB4). This is the discovery job's only write.
    /// Because the whole `discovered` set is replaced, stale discovered paths evaporate on the next run.
    func setDiscoveredRelatedNotes(_ paths: [String], for meeting: Meeting) {
        let excluded = Set(meeting.excludedNotePaths)
        let manual = meeting.relatedNotePaths.filter { $0.provenance == .manual }
        let manualPaths = Set(manual.map(\.path))

        var seen = Set<String>()
        var discovered: [RelatedNote] = []
        for raw in paths {
            let rel = Self.normalizeVaultRelPath(raw)
            guard !rel.isEmpty,
                  !excluded.contains(rel),
                  !manualPaths.contains(rel),
                  seen.insert(rel).inserted else { continue }
            discovered.append(RelatedNote(path: rel, provenance: .discovered))
        }
        meeting.relatedNotePaths = manual + discovered
        meeting.relatedDiscoveryAt = Date()
        meeting.updatedAt = Date()
        save()
        fetchMeetings()
    }

    /// Append a `manual` related note (dedup by path) and **clear any prior exclusion** of that path —
    /// an explicit add overrides a prior removal (Amendment 2, DB4). No-op when the path is blank.
    func addManualRelatedNote(_ path: String, for meeting: Meeting) {
        let rel = Self.normalizeVaultRelPath(path)
        guard !rel.isEmpty else { return }

        var excluded = meeting.excludedNotePaths
        let hadExclusion = excluded.contains(rel)
        excluded.removeAll { $0 == rel }

        var related = meeting.relatedNotePaths
        let alreadyPresent = related.contains { $0.path == rel }
        if !alreadyPresent {
            related.append(RelatedNote(path: rel, provenance: .manual))
        }
        guard hadExclusion || !alreadyPresent else { return }

        meeting.excludedNotePaths = excluded
        meeting.relatedNotePaths = related
        meeting.updatedAt = Date()
        save()
        fetchMeetings()
    }

    /// Remove a related note (the UI's ✕): **record an exclusion** for the path and drop it from
    /// `relatedNotePaths` (whether `discovered` or `manual`) (Amendment 2, DB4). Folder-derived notes
    /// aren't in `relatedNotePaths`, so removing one still records the exclusion, which the consumption
    /// union (DB5) honors — a removal never resurrects.
    func removeRelatedNote(_ path: String, for meeting: Meeting) {
        let rel = Self.normalizeVaultRelPath(path)
        guard !rel.isEmpty else { return }

        var related = meeting.relatedNotePaths
        let hadNote = related.contains { $0.path == rel }
        related.removeAll { $0.path == rel }

        var excluded = meeting.excludedNotePaths
        let alreadyExcluded = excluded.contains(rel)
        if !alreadyExcluded { excluded.append(rel) }
        guard hadNote || !alreadyExcluded else { return }

        meeting.relatedNotePaths = related
        meeting.excludedNotePaths = excluded
        meeting.updatedAt = Date()
        save()
        fetchMeetings()
    }
}
