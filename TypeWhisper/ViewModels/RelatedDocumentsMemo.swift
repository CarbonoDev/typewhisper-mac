import Foundation

/// [Perf Phase 2] Memo for `MeetingsViewModel.relatedDocuments(for:)`. Resolving the union decodes two
/// JSON blobs and stats every related note on disk; the document body and the related-docs section
/// read it on every body pass. The rows are recomputed only when an `Input` changes — the meeting's
/// related / excluded paths, its folder's attached scope, or the connected vault — never on an
/// unrelated meeting change (transcript append, rename, note).
///
/// The disk stat is the one input a value key cannot see (a note renamed in Obsidian), so an entry
/// also expires after `maxAge`: show-as-missing catches up within that window instead of on every
/// render. Bounded to `capacity` meetings, least recently used evicted first. Not observable — it is
/// filled from `body`, so a write must never invalidate a view.
@MainActor
final class RelatedDocumentsMemo {
    struct Input: Equatable {
        let meetingID: UUID
        let vaultPath: String?
        let attachedFolderPaths: [String]
        let attachedNotePaths: [String]
        let relatedNotePathsJSON: String?
        let excludedNotePathsJSON: String?
    }

    private struct Entry {
        let input: Input
        let rows: [MeetingsViewModel.RelatedDocRow]
        let computedAt: Date
    }

    let capacity: Int
    let maxAge: TimeInterval
    private let now: () -> Date
    private var entries: [UUID: Entry] = [:]
    /// Recency order of meeting ids, least recent first.
    private var recency: [UUID] = []
    /// Number of resolves (misses) — observability for tests.
    private(set) var computeCount = 0

    init(capacity: Int = 16, maxAge: TimeInterval = 30, now: @escaping () -> Date = Date.init) {
        self.capacity = max(1, capacity)
        self.maxAge = maxAge
        self.now = now
    }

    var count: Int { entries.count }

    func rows(
        for input: Input,
        compute: () -> [MeetingsViewModel.RelatedDocRow]
    ) -> [MeetingsViewModel.RelatedDocRow] {
        let id = input.meetingID
        let timestamp = now()
        if let entry = entries[id], entry.input == input, timestamp.timeIntervalSince(entry.computedAt) < maxAge {
            touch(id)
            return entry.rows
        }
        let rows = compute()
        computeCount += 1
        entries[id] = Entry(input: input, rows: rows, computedAt: timestamp)
        touch(id)
        while recency.count > capacity {
            entries[recency.removeFirst()] = nil
        }
        return rows
    }

    private func touch(_ id: UUID) {
        if recency.last == id { return }
        if let index = recency.firstIndex(of: id) { recency.remove(at: index) }
        recency.append(id)
    }
}
