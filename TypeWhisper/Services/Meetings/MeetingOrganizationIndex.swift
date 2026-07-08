import Foundation
import Combine

/// One tag and how many meetings carry it (plan D6/M3). `key` is the case-folded grouping/filter key;
/// `name` is the display form (the first-seen original casing among the meetings that carry it).
struct MeetingTagCount: Identifiable, Equatable, Sendable {
    let key: String
    let name: String
    let count: Int

    var id: String { key }
}

/// In-memory **derived** aggregation over the meetings store (plan D6/M3). Owns no persistence: tags
/// are canonical on `Meeting.obsidianTags` (aliased `tags`), so a second store would create a two-way
/// sync obligation. Subscribes to `MeetingService.$meetings` and republishes a low-cardinality tag
/// index; because every `MeetingService` mutator ends with `save()` + `fetchMeetings()` → `$meetings`
/// fires, the sidebar counts, chip autocomplete, and filters refresh together with no manual poke.
///
/// `_shared` + ServiceContainer-wired so SwiftUI observes it directly, and the pure derivation is a
/// `static` function so it is unit-testable without any Combine wiring.
@MainActor
final class MeetingOrganizationIndex: ObservableObject {
    nonisolated(unsafe) static var _shared: MeetingOrganizationIndex?
    static var shared: MeetingOrganizationIndex {
        guard let instance = _shared else {
            fatalError("MeetingOrganizationIndex not initialized")
        }
        return instance
    }

    /// Case-folded tag counts, sorted alphabetically by display name (case-insensitive) — the flat
    /// TAGS list the sidebar renders.
    @Published private(set) var tagCounts: [MeetingTagCount] = []

    private var cancellables = Set<AnyCancellable>()

    init(meetingService: MeetingService) {
        rebuild(from: meetingService.meetings)
        meetingService.$meetings
            .sink { [weak self] meetings in
                self?.rebuild(from: meetings)
            }
            .store(in: &cancellables)
    }

    /// Pure derivation of the tag index from a meetings snapshot. Case-folds tag keys, de-dupes within
    /// a single meeting (so a meeting tagged both "Hiring" and "hiring" counts once), and sorts by
    /// display name.
    static func tagCounts(from meetings: [Meeting]) -> [MeetingTagCount] {
        var counts: [String: (name: String, count: Int)] = [:]
        for meeting in meetings {
            var seenInMeeting = Set<String>()
            for tag in meeting.tags {
                let trimmed = tag.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                let key = trimmed.lowercased()
                guard seenInMeeting.insert(key).inserted else { continue }
                if let existing = counts[key] {
                    counts[key] = (existing.name, existing.count + 1)
                } else {
                    counts[key] = (trimmed, 1)
                }
            }
        }
        return counts
            .map { MeetingTagCount(key: $0.key, name: $0.value.name, count: $0.value.count) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func rebuild(from meetings: [Meeting]) {
        tagCounts = Self.tagCounts(from: meetings)
    }
}
