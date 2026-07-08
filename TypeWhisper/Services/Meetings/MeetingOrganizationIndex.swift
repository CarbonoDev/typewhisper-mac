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

/// A node in the derived folder tree (plan D7/M4). `path` is the full `/`-joined folder path; `name`
/// is the last path component; `count` is **descendant-inclusive** (meetings at this folder or any
/// nested subfolder); `children` are the immediate subfolders, sorted by display name.
struct MeetingFolderNode: Identifiable, Equatable, Sendable {
    let path: String
    let name: String
    let count: Int
    let children: [MeetingFolderNode]

    var id: String { path }
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

    /// The derived folder tree (plan D7/M4), sorted alphabetically at every level — the FOLDERS
    /// DisclosureGroup tree the sidebar renders.
    @Published private(set) var folderTree: [MeetingFolderNode] = []

    /// How many meetings carry no folder (Unfiled). Drives the sidebar's Unfiled row.
    @Published private(set) var unfiledCount: Int = 0

    /// Amendment 1 / M7 seam (plan §M4 amendment): supplies configured-but-empty folder paths (from
    /// the future `MeetingFolderMetadataStore`) to **union** into the derived tree, so a folder that
    /// was configured with context but has no meetings yet still appears. Defaults to none until M7
    /// attaches the store; assigning it (and re-triggering a rebuild) is the union point designed now.
    var configuredFolderPathsProvider: () -> [String] = { [] } {
        didSet { rebuild(from: lastMeetings) }
    }

    private var cancellables = Set<AnyCancellable>()
    private var lastMeetings: [Meeting] = []

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

    // MARK: - Folder tree (plan D7/M4)

    /// Pure derivation of the folder tree from a meetings snapshot, **unioned** with any configured
    /// folder paths (M7 seam) so configured-but-empty folders still appear. Counts are
    /// descendant-inclusive (a meeting under `Clients/Acme` counts toward both `Clients/Acme` and
    /// `Clients`); every level is sorted case-insensitively by display name. Configured paths add
    /// nodes but no count.
    static func folderTree(from meetings: [Meeting], configuredPaths: [String] = []) -> [MeetingFolderNode] {
        var counts: [String: Int] = [:]
        var allPaths = Set<String>()

        func registerPrefixes(_ components: [String], counting: Bool) {
            guard !components.isEmpty else { return }
            var accumulated: [String] = []
            for component in components {
                accumulated.append(component)
                let path = accumulated.joined(separator: "/")
                allPaths.insert(path)
                if counting { counts[path, default: 0] += 1 }
            }
        }

        for meeting in meetings {
            registerPrefixes(MeetingService.folderComponents(meeting.folderPath), counting: true)
        }
        for configured in configuredPaths {
            registerPrefixes(MeetingService.folderComponents(configured), counting: false)
        }

        return buildNodes(parentPath: "", allPaths: allPaths, counts: counts)
    }

    /// Immediate children of `parentPath` (`""` = tree roots) as `MeetingFolderNode`s, recursively.
    private static func buildNodes(
        parentPath: String,
        allPaths: Set<String>,
        counts: [String: Int]
    ) -> [MeetingFolderNode] {
        let parentDepth = parentPath.isEmpty ? 0 : MeetingService.folderComponents(parentPath).count
        let children = allPaths.filter { path in
            let comps = MeetingService.folderComponents(path)
            guard comps.count == parentDepth + 1 else { return false }
            return comps.dropLast().joined(separator: "/") == parentPath
        }
        return children
            .map { path -> MeetingFolderNode in
                let name = MeetingService.folderComponents(path).last ?? path
                return MeetingFolderNode(
                    path: path,
                    name: name,
                    count: counts[path] ?? 0,
                    children: buildNodes(parentPath: path, allPaths: allPaths, counts: counts)
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// How many meetings have no folder (Unfiled).
    static func unfiledCount(from meetings: [Meeting]) -> Int {
        meetings.filter { MeetingService.folderComponents($0.folderPath).isEmpty }.count
    }

    private func rebuild(from meetings: [Meeting]) {
        lastMeetings = meetings
        tagCounts = Self.tagCounts(from: meetings)
        folderTree = Self.folderTree(from: meetings, configuredPaths: configuredFolderPathsProvider())
        unfiledCount = Self.unfiledCount(from: meetings)
    }
}
