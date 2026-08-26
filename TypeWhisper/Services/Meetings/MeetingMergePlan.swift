import Foundation

/// Value snapshot of a single transcript segment, carrying exactly what the merge planner needs
/// (timing + provenance). Pure value type so the planner is testable without SwiftData.
struct MeetingMergeSegmentSnapshot: Equatable, Sendable {
    var start: Double
    var end: Double
    var source: MeetingSegmentSource

    init(start: Double, end: Double, source: MeetingSegmentSource = .liveCapture) {
        self.start = start
        self.end = end
        self.source = source
    }
}

/// Value snapshot of one `Meeting` for merge planning (the `SpeakerSourcePlan` pattern: pure logic
/// over plain values, no `@Model` access inside the planner). Built on the MainActor from a live
/// row via `init(of:)`; unit tests construct snapshots directly.
struct MeetingMergeSnapshot: Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    /// Whether `title` is empty or one of the app's generated defaults
    /// (`MeetingService.isDefaultOrEmptyTitle`), captured at snapshot time so the planner never
    /// needs to touch localization.
    var titleIsGenerated: Bool
    var state: MeetingState
    var startDate: Date?
    var endDate: Date?
    var calendarEventID: String?
    var seriesID: String?
    /// The linked event's snapshotted description ([Google Phase 1 · M5]) — carried with the
    /// calendar linkage, never independently (PR #7 review finding 9).
    var calendarNotes: String?
    /// The linked event's snapshotted join URL, carried with the calendar linkage.
    var conferencingURL: String?
    var externalSessionKey: String?
    var folderPath: String?
    var languageCode: String?
    var languageProvenance: MeetingLanguageProvenance?
    var createdAt: Date
    var segments: [MeetingMergeSegmentSnapshot]

    init(
        id: UUID = UUID(),
        title: String,
        titleIsGenerated: Bool = false,
        state: MeetingState = .completed,
        startDate: Date? = nil,
        endDate: Date? = nil,
        calendarEventID: String? = nil,
        seriesID: String? = nil,
        calendarNotes: String? = nil,
        conferencingURL: String? = nil,
        externalSessionKey: String? = nil,
        folderPath: String? = nil,
        languageCode: String? = nil,
        languageProvenance: MeetingLanguageProvenance? = nil,
        createdAt: Date = Date(),
        segments: [MeetingMergeSegmentSnapshot] = []
    ) {
        self.id = id
        self.title = title
        self.titleIsGenerated = titleIsGenerated
        self.state = state
        self.startDate = startDate
        self.endDate = endDate
        self.calendarEventID = calendarEventID
        self.seriesID = seriesID
        self.calendarNotes = calendarNotes
        self.conferencingURL = conferencingURL
        self.externalSessionKey = externalSessionKey
        self.folderPath = folderPath
        self.languageCode = languageCode
        self.languageProvenance = languageProvenance
        self.createdAt = createdAt
        self.segments = segments
    }
}

extension MeetingMergeSnapshot {
    /// Snapshot a live `Meeting` row for planning. MainActor because `Meeting` is owned by the
    /// MainActor-bound `MeetingService`.
    @MainActor
    init(of meeting: Meeting) {
        self.init(
            id: meeting.id,
            title: meeting.title,
            titleIsGenerated: MeetingService.isDefaultOrEmptyTitle(meeting.title),
            state: meeting.state,
            startDate: meeting.startDate,
            endDate: meeting.endDate,
            calendarEventID: meeting.calendarEventID,
            seriesID: meeting.seriesID,
            calendarNotes: meeting.calendarNotes,
            conferencingURL: meeting.conferencingURL,
            externalSessionKey: meeting.externalSessionKey,
            folderPath: meeting.folderPath,
            languageCode: meeting.languageCode,
            languageProvenance: meeting.languageProvenance,
            createdAt: meeting.createdAt,
            segments: meeting.segments.map {
                MeetingMergeSegmentSnapshot(start: $0.start, end: $0.end, source: $0.source)
            }
        )
    }
}

/// A conflict the deterministic rules could not settle. v1 escalates only `.title` to the LLM seam;
/// `.overlappingTranscripts` is recorded (and the segments concatenated chronologically) — a future
/// pass may de-duplicate the overlap with an LLM.
enum MeetingMergeConflict: Equatable, Sendable {
    /// Two or more *distinct human-chosen* titles (case-insensitive, trimmed). Candidates are in
    /// priority order — the deterministic fallback is the first.
    case title(candidates: [String])
    /// Two source meetings contributed same-source transcript segments whose re-anchored time spans
    /// overlap (e.g. two `.liveCapture` recordings of the same minutes). v1 concatenates them in
    /// chronological order and merely notes the conflict.
    case overlappingTranscripts(MeetingSegmentSource)
}

/// The deterministic merge decision for a set of meetings: which one survives, what its scalar
/// fields become, how each source meeting's transcript timeline is re-anchored, and which conflicts
/// remain for the LLM pass. Produced by `MeetingMergePlanner.plan(_:)`; applied by
/// `MeetingService.applyMerge(_:resolvedTitle:)` (the single writer).
struct MeetingMergePlan: Equatable, Sendable {
    /// The surviving meeting (see `MeetingMergePlanner` for the selection ladder).
    var primaryID: UUID
    /// The meetings absorbed into the primary and then deleted, in deterministic priority order.
    var absorbedIDs: [UUID]
    /// The deterministic title pick: the single human title when exactly one exists; the first
    /// candidate (priority order) when several conflict; the primary's own (generated) title when
    /// none do. An LLM resolution, when available, supersedes this at apply time.
    var title: String
    /// Distinct human-chosen titles in priority order. `count > 1` ⇒ a `.title` conflict.
    var titleCandidates: [String]
    /// `min` of all non-nil start dates — the merged meeting spans every source meeting.
    var startDate: Date?
    /// `max` of all non-nil end dates.
    var endDate: Date?
    /// First non-nil in priority order (the primary-selection ladder already prefers the
    /// calendar-linked meeting, so this is normally the primary's own link).
    var calendarEventID: String?
    var seriesID: String?
    /// The event snapshot ([Google Phase 1 · M5]) taken from **the same meeting the calendar
    /// linkage came from** (PR #7 review finding 9) — a merge that adopts a calendar link must
    /// bring its Event-details disclosure and Join button with it, and must never pair one event's
    /// link with another's agenda. Falls back to the first non-nil in priority order when no input
    /// carries a link at all, so an orphaned snapshot is not silently dropped either.
    var calendarNotes: String?
    /// The linked event's join URL — see `calendarNotes` for the sourcing rule.
    var conferencingURL: String?
    /// First non-nil in priority order, so a live caption-bridge session key survives a merge with
    /// its calendar-created duplicate and `POST /v1/meetings/live` keeps resuming the same meeting.
    var externalSessionKey: String?
    /// First non-nil in priority order (the primary's folder wins when it is filed).
    var folderPath: String?
    /// Strongest-provenance language across the inputs: `manual > rule > detected > none`, ties
    /// broken by priority order (mirrors the `MeetingLanguageProvenance` ladder).
    var languageCode: String?
    var languageProvenance: MeetingLanguageProvenance?
    /// Most-complete lifecycle state across the inputs:
    /// `completed > processing > interrupted > failed > live > scheduled`. (Live/processing inputs
    /// are rejected before planning — see `MeetingMergePlanner.isMergeable` — so in practice this
    /// picks among completed/interrupted/failed/scheduled.)
    var state: MeetingState
    /// Seconds to add to every segment `start`/`end` (and note `timestampOffset`) of each source
    /// meeting so all timelines share the merged meeting's start anchor. Dated meetings are anchored
    /// by their wall-clock delta from the merged start; undated meetings are appended after all
    /// dated content, in priority order, so timelines never collide incorrectly.
    var segmentOffsets: [UUID: Double]
    /// Conflicts the deterministic rules could not settle (title) or only noted (overlap).
    var conflicts: [MeetingMergeConflict]

    var hasTitleConflict: Bool { titleCandidates.count > 1 }

    /// All source meetings, primary first — the stable order the apply step walks so provisional
    /// segment ordering (and thus equal-start tie-breaks) is deterministic.
    var sourceOrder: [UUID] { [primaryID] + absorbedIDs }
}

/// Pure merge planning for duplicate meetings (a live caption-bridge meeting + its calendar-created
/// twin, a re-join of the same call, an import overlapping a live capture). No I/O, no SwiftData —
/// every decision is a function of `[MeetingMergeSnapshot]`, so the rules are fully unit-testable
/// (the `SpeakerSourcePlan` pattern). The LLM pass only ever sees what this planner could not
/// settle deterministically.
enum MeetingMergePlanner {
    /// Whether a set of meeting states is mergeable: at least two meetings, none currently
    /// `.live` or `.processing` (merging a meeting mid-capture/mid-finalization would race the
    /// capture pipeline's writes; stop the recording first).
    static func isMergeable(_ states: [MeetingState]) -> Bool {
        states.count >= 2 && states.allSatisfy { $0 != .live && $0 != .processing }
    }

    /// Build the deterministic merge plan. Returns `nil` for fewer than two snapshots.
    static func plan(_ snapshots: [MeetingMergeSnapshot]) -> MeetingMergePlan? {
        guard snapshots.count >= 2 else { return nil }

        // Priority (= primary-selection) order: one total order used for the primary pick AND for
        // every "first non-nil" adoption below, so all rules share a single deterministic ranking.
        let ordered = snapshots.sorted(by: ranksBefore)
        let primary = ordered[0]

        // Title: a human-chosen title always beats a generated one. Distinct human titles
        // (case-insensitive, trimmed) beyond the first are a conflict for the LLM pass; the
        // deterministic fallback is the highest-priority candidate.
        var titleCandidates: [String] = []
        var seenTitles = Set<String>()
        for snapshot in ordered where !snapshot.titleIsGenerated {
            let trimmed = snapshot.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seenTitles.insert(trimmed.lowercased()).inserted else { continue }
            titleCandidates.append(trimmed)
        }
        let title = titleCandidates.first ?? primary.title

        // Time range: the merged meeting spans every source meeting.
        let startDate = ordered.compactMap(\.startDate).min()
        let endDate = ordered.compactMap(\.endDate).max()

        // Language: strongest provenance wins (`manual > rule > detected > none` — the same ladder
        // MeetingService's language setters enforce), priority order breaks ties.
        let languagePick = ordered
            .enumerated()
            .filter { normalized($0.element.languageCode) != nil }
            .min { lhs, rhs in
                let lp = provenanceRank(lhs.element.languageProvenance)
                let rp = provenanceRank(rhs.element.languageProvenance)
                if lp != rp { return lp < rp }
                return lhs.offset < rhs.offset
            }?
            .element

        // Segment re-anchoring. Dated meetings: offset = wall-clock delta from the merged start.
        // Undated meetings: appended after all dated content in priority order (their internal
        // relative timing is preserved; only the anchor shifts), so nothing overlaps by accident.
        var offsets: [UUID: Double] = [:]
        var anchoredMaxEnd: Double = 0
        for snapshot in ordered {
            guard let mergedStart = startDate, let ownStart = snapshot.startDate else { continue }
            let offset = ownStart.timeIntervalSince(mergedStart)
            offsets[snapshot.id] = offset
            let localMaxEnd = snapshot.segments.map(\.end).max() ?? 0
            anchoredMaxEnd = max(anchoredMaxEnd, offset + localMaxEnd)
        }
        var runningEnd = anchoredMaxEnd
        for snapshot in ordered where offsets[snapshot.id] == nil {
            offsets[snapshot.id] = runningEnd
            runningEnd += max(0, snapshot.segments.map(\.end).max() ?? 0)
        }

        // Conflicts: distinct human titles; same-source transcript spans that still overlap after
        // re-anchoring (two recordings of the same minutes — v1 concatenates and notes it).
        var conflicts: [MeetingMergeConflict] = []
        if titleCandidates.count > 1 {
            conflicts.append(.title(candidates: titleCandidates))
        }
        for source in MeetingSegmentSource.allCases {
            var spans: [(start: Double, end: Double)] = []
            for snapshot in ordered {
                let matching = snapshot.segments.filter { $0.source == source }
                guard let minStart = matching.map(\.start).min(),
                      let maxEnd = matching.map(\.end).max() else { continue }
                let offset = offsets[snapshot.id] ?? 0
                spans.append((minStart + offset, maxEnd + offset))
            }
            guard spans.count > 1 else { continue }
            spans.sort { $0.start < $1.start }
            var coveredEnd = spans[0].end
            for span in spans.dropFirst() {
                if span.start < coveredEnd {
                    conflicts.append(.overlappingTranscripts(source))
                    break
                }
                coveredEnd = max(coveredEnd, span.end)
            }
        }

        // The event snapshot travels with the calendar linkage (PR #7 review finding 9): take both
        // fields from the meeting that supplied `calendarEventID`, so the surviving meeting can
        // never show one event's link beside another's agenda/join URL. With no linked input at
        // all, fall back to the first non-nil so an orphaned snapshot survives the merge.
        let linkSource = ordered.first { normalized($0.calendarEventID) != nil }

        return MeetingMergePlan(
            primaryID: primary.id,
            absorbedIDs: ordered.dropFirst().map(\.id),
            title: title,
            titleCandidates: titleCandidates,
            startDate: startDate,
            endDate: endDate,
            calendarEventID: firstNonNil(ordered, \.calendarEventID),
            seriesID: firstNonNil(ordered, \.seriesID),
            calendarNotes: linkSource.map { normalized($0.calendarNotes) }
                ?? firstNonNil(ordered, \.calendarNotes),
            conferencingURL: linkSource.map { normalized($0.conferencingURL) }
                ?? firstNonNil(ordered, \.conferencingURL),
            externalSessionKey: firstNonNil(ordered, \.externalSessionKey),
            folderPath: firstNonNil(ordered, \.folderPath),
            languageCode: normalized(languagePick?.languageCode),
            languageProvenance: languagePick.flatMap { $0.languageProvenance },
            state: ordered.map(\.state).min { stateRank($0) < stateRank($1) } ?? primary.state,
            segmentOffsets: offsets,
            conflicts: conflicts
        )
    }

    // MARK: - Primary selection ladder

    /// Strict primary-selection order (first = primary):
    ///   1. a calendar-linked meeting wins (its identity anchors dedupe, briefs, and series matching);
    ///   2. else the earliest `startDate` (a dated meeting beats an undated one — the merged
    ///      timeline is anchored on it anyway);
    ///   3. else the meeting with the most segments (the richest capture);
    ///   4. else the earliest `createdAt`;
    ///   5. else the lexicographically smallest id — a total order, so the plan is deterministic
    ///      for any input permutation.
    static func ranksBefore(_ lhs: MeetingMergeSnapshot, _ rhs: MeetingMergeSnapshot) -> Bool {
        let lhsLinked = normalized(lhs.calendarEventID) != nil
        let rhsLinked = normalized(rhs.calendarEventID) != nil
        if lhsLinked != rhsLinked { return lhsLinked }
        switch (lhs.startDate, rhs.startDate) {
        case let (l?, r?) where l != r: return l < r
        case (.some, nil): return true
        case (nil, .some): return false
        default: break
        }
        if lhs.segments.count != rhs.segments.count { return lhs.segments.count > rhs.segments.count }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    // MARK: - Helpers

    /// Trimmed, empty-collapsed-to-nil string, so `""` never wins a "first non-nil" adoption.
    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func firstNonNil(
        _ ordered: [MeetingMergeSnapshot],
        _ keyPath: KeyPath<MeetingMergeSnapshot, String?>
    ) -> String? {
        for snapshot in ordered {
            if let value = normalized(snapshot[keyPath: keyPath]) { return value }
        }
        return nil
    }

    /// `manual > rule > detected > none` — the `MeetingLanguageProvenance` ladder as a sort rank.
    private static func provenanceRank(_ provenance: MeetingLanguageProvenance?) -> Int {
        switch provenance {
        case .manual: return 0
        case .rule: return 1
        case .detected: return 2
        case nil: return 3
        }
    }

    /// `completed > processing > interrupted > failed > live > scheduled` as a sort rank ("most
    /// complete" wins — merging a completed capture into its scheduled calendar twin must yield a
    /// completed meeting).
    private static func stateRank(_ state: MeetingState) -> Int {
        switch state {
        case .completed: return 0
        case .processing: return 1
        case .interrupted: return 2
        case .failed: return 3
        case .live: return 4
        case .scheduled: return 5
        }
    }
}
