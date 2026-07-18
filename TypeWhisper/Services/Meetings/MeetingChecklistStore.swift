import Foundation
import Combine

/// Done-state persistence for the completed-meeting action-item checkboxes (Sprint 1).
///
/// Checked state is UI-level progress tracking over parser-extracted items
/// (`MeetingOutputParser.ActionItem.stableID`), not meeting content — so it lives in a small
/// UserDefaults-backed codable map (`[meetingID: [stableID]]`) rather than a SwiftData column.
/// Regenerating an output that rewords an item changes its stableID and the item simply reverts to
/// unchecked, which is the desired behavior for changed wording. Upgradeable to a model-backed
/// store later without touching the UI surface.
@MainActor
final class MeetingChecklistStore: ObservableObject {
    static let shared = MeetingChecklistStore()

    /// Checked item IDs per meeting UUID string. Published so checkbox rows and section counts
    /// refresh on every mutation.
    @Published private(set) var doneItemIDs: [String: Set<String>] = [:]

    private let defaults: UserDefaults
    private let storageKey = "meetingActionChecklist.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: - Reads

    func isDone(meetingID: UUID, itemID: String) -> Bool {
        doneItemIDs[meetingID.uuidString]?.contains(itemID) ?? false
    }

    func doneCount(meetingID: UUID, itemIDs: [String]) -> Int {
        guard let done = doneItemIDs[meetingID.uuidString] else { return 0 }
        return itemIDs.reduce(into: 0) { count, id in
            if done.contains(id) { count += 1 }
        }
    }

    // MARK: - Writes

    func setDone(_ done: Bool, meetingID: UUID, itemID: String) {
        let key = meetingID.uuidString
        var set = doneItemIDs[key] ?? []
        if done {
            guard !set.contains(itemID) else { return }
            set.insert(itemID)
        } else {
            guard set.contains(itemID) else { return }
            set.remove(itemID)
        }
        if set.isEmpty {
            doneItemIDs.removeValue(forKey: key)
        } else {
            doneItemIDs[key] = set
        }
        persist()
    }

    /// Drop a meeting's checklist state entirely (call when the meeting itself is deleted so the
    /// map never accumulates orphaned entries).
    func removeAll(meetingID: UUID) {
        guard doneItemIDs.removeValue(forKey: meetingID.uuidString) != nil else { return }
        persist()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            return
        }
        doneItemIDs = decoded.mapValues(Set.init)
    }

    private func persist() {
        let encodable = doneItemIDs.mapValues { Array($0).sorted() }
        guard let data = try? JSONEncoder().encode(encodable) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
