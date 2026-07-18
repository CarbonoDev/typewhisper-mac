import Foundation
import SwiftData
import Combine
import TypeWhisperPluginSDK
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "MeetingService")

/// The sole writer of the `meetings.store` aggregate. Owns its own `ModelContainer`/`ModelContext`
/// (mirrors `HistoryService`'s shape) plus a sibling `meetings-audio/` directory for on-disk audio
/// blobs keyed by meeting UUID.
@MainActor
final class MeetingService: ObservableObject {
    @Published private(set) var meetings: [Meeting] = []

    private let modelContainer: ModelContainer
    private let modelContext: ModelContext
    private let audioDirectory: URL
    /// Publishes `MeetingEvent`s to plugins (addendum AD4). Defaulted no-op so v1 call sites/tests
    /// are unchanged. `addOutput` is the single output-persistence choke point, so emitting here
    /// covers LLM summaries/extended, briefs, and auto-briefs with one emit.
    private let eventEmitter: MeetingEventEmitting
    /// Meeting output templates now live in `promptActions.store` as `.meeting`-surface rows
    /// (plan AD6). `MeetingService.templates(ofKind:)` delegates here so Track C and existing UI
    /// call sites keep the same signature. Optional so unit tests that only exercise meeting CRUD
    /// can construct the service without the prompt-action store.
    private weak var promptActionService: PromptActionService?

    /// Amendment 1 / M7 seam (plan §M4 amendment): invoked when a folder path is renamed or moved
    /// (`old` → `new`, component-wise prefix) so the future `MeetingFolderMetadataStore` can rewrite
    /// its keyed config to follow the path — even when no meeting currently sits under the folder.
    /// `nil` until M7 attaches it; folder core (M4) works without it.
    var onFolderPathRewrite: ((String, String) -> Void)?
    /// Amendment 1 / M7 seam: invoked when a folder is deleted so M7 metadata can drop its config.
    var onFolderDeleted: ((String) -> Void)?
    /// M2 seam (plan D7): invoked with the attendees written by every attendee choke point
    /// (`createMeeting`, `linkToCalendarEvent`, `addAttendee`) so `ParticipantDirectoryService` can fold
    /// them into the participant directory through its single `ingest(_:)` writer. `nil` until
    /// `ServiceContainer` attaches it; meeting CRUD (and every existing unit test) works without it.
    /// Removing an attendee deliberately does **not** fire this — a removal never deletes a Person.
    var onAttendeesIngested: (([Attendee]) -> Void)?
    /// M3 seam (plan D8): resolves a roster to directory Person ids so `priorMeetings(matching:)` can
    /// union on shared resolved identity — unlocking the owner's largely email-less imported archive,
    /// where two meetings share a person by name only. `nil` until `ServiceContainer` attaches it to
    /// `ParticipantDirectoryService`; email/series matching (and every existing test) works without it.
    var resolvePersonIDs: (([Attendee]) -> Set<UUID>)?
    /// M4 seam (M3 review minor): a factory that builds a person-ID resolver **once per query** so
    /// `priorMeetings(matching:)` no longer rebuilds the directory resolution index per candidate
    /// meeting (was O(meetings × persons) on the MainActor — worst on the owner's large email-less
    /// archive). When set it supersedes the per-call `resolvePersonIDs` seam inside `priorMeetings`;
    /// when nil, `priorMeetings` falls back to `resolvePersonIDs` (existing tests and the
    /// email/series-only path are unaffected). `ServiceContainer` attaches it to
    /// `ParticipantDirectoryService.makePersonIDResolver()`.
    var makePersonIDResolver: (() -> ([Attendee]) -> Set<UUID>)?

    init(
        appSupportDirectory: URL = AppConstants.appSupportDirectory,
        eventEmitter: MeetingEventEmitting = NoopMeetingEventEmitter(),
        promptActionService: PromptActionService? = nil
    ) {
        self.eventEmitter = eventEmitter
        self.promptActionService = promptActionService
        let audioDir = appSupportDirectory.appendingPathComponent("meetings-audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        self.audioDirectory = audioDir

        do {
            let (container, context) = try SwiftDataStoreFactory.create(
                for: [
                    Meeting.self,
                    MeetingSegment.self,
                    MeetingNote.self,
                    MeetingOutput.self,
                    MeetingQATurn.self,
                    MeetingTemplate.self
                ],
                storeName: "meetings",
                in: appSupportDirectory
            )
            modelContainer = container
            modelContext = context
        } catch {
            fatalError("Failed to initialize meetings store: \(error)")
        }

        fetchMeetings()
    }

    // MARK: - Meeting CRUD

    @discardableResult
    func createMeeting(
        title: String,
        source: MeetingSource = .adHoc,
        state: MeetingState = .scheduled,
        startDate: Date? = nil,
        endDate: Date? = nil,
        calendarEventID: String? = nil,
        seriesID: String? = nil,
        attendees: [Attendee] = []
    ) -> Meeting {
        let meeting = Meeting(
            title: title,
            state: state,
            source: source,
            startDate: startDate,
            endDate: endDate,
            calendarEventID: calendarEventID,
            seriesID: seriesID
        )
        if !attendees.isEmpty {
            meeting.attendees = attendees
        }
        modelContext.insert(meeting)
        save()
        fetchMeetings()
        if !attendees.isEmpty { onAttendeesIngested?(attendees) }
        return meeting
    }

    func deleteMeeting(_ meeting: Meeting) {
        deleteAudioFile(for: meeting)
        modelContext.delete(meeting)
        save()
        fetchMeetings()
    }

    /// Persist any pending changes made to a fetched meeting (e.g. state transitions,
    /// attendee/speaker-map edits) and refresh the published list.
    func update(_ meeting: Meeting) {
        meeting.updatedAt = Date()
        save()
        fetchMeetings()
    }

    // MARK: - Title / date / calendar linking (meeting-identity milestone)

    /// Rename a meeting's title **without touching any calendar linkage**. `calendarEventID`,
    /// `seriesID`, and `attendees` identify the backing calendar event and drive the upcoming-list
    /// dedupe/exclusion (keyed on `calendarEventID`, never the title) and prior-meeting matching
    /// (attendees / `seriesID`), so a title edit must never clear them (owner requirement 1). Blank
    /// titles are ignored — a meeting always keeps a title. Single-writer on the MainActor.
    func setTitle(_ title: String, for meeting: Meeting) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, meeting.title != trimmed else { return }
        meeting.title = trimmed
        meeting.updatedAt = Date()
        save()
        fetchMeetings()
    }

    /// Set (or clear) a meeting's date — the single `startDate` column that the timeline
    /// day-grouping, prior-meeting matching, and related-docs signals all already read (owner
    /// requirement 2). Surfaced only for meetings **not** linked to a calendar event (a linked
    /// meeting's date is owned by its event); callers gate on `calendarEventID == nil`. `nil` clears
    /// the date. Single-writer on the MainActor.
    func setMeetingDate(_ date: Date?, for meeting: Meeting) {
        guard meeting.startDate != date else { return }
        meeting.startDate = date
        meeting.updatedAt = Date()
        save()
        fetchMeetings()
    }

    /// Link a meeting to a (typically historical) calendar event: adopt its `calendarEventID`,
    /// `seriesID`, `attendees`, and start/end date so the calendar pipeline dedupes on it and
    /// prior-meeting briefs can find it (owner requirement 3, powering the bulk archive import).
    /// The title is adopted from the event **only when the meeting's current title is empty or a
    /// generated default** (`isDefaultOrEmptyTitle`) — a user-chosen title is never clobbered.
    /// Single-writer on the MainActor.
    func linkToCalendarEvent(
        calendarEventID: String,
        seriesID: String?,
        title eventTitle: String,
        startDate: Date,
        endDate: Date?,
        attendees: [Attendee],
        for meeting: Meeting
    ) {
        meeting.calendarEventID = calendarEventID
        meeting.seriesID = seriesID
        meeting.startDate = startDate
        meeting.endDate = endDate
        meeting.attendees = attendees
        let trimmedEventTitle = eventTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.isDefaultOrEmptyTitle(meeting.title), !trimmedEventTitle.isEmpty {
            meeting.title = trimmedEventTitle
        }
        meeting.updatedAt = Date()
        save()
        fetchMeetings()
        if !attendees.isEmpty { onAttendeesIngested?(attendees) }
    }

    /// Add a single attendee to a meeting's roster (M2 attendee choke point, plan D7). De-duplicates by
    /// `Attendee.id` (email when present, else name) so re-adding is a no-op, appends to
    /// `attendeesJSON`, and folds the attendee into the participant directory via the ingest seam.
    /// Single-writer on the MainActor. Returns whether the roster actually changed.
    @discardableResult
    func addAttendee(_ attendee: Attendee, to meeting: Meeting) -> Bool {
        let trimmedName = attendee.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedEmail = attendee.email?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = Attendee(
            name: trimmedName,
            email: (normalizedEmail?.isEmpty == false) ? normalizedEmail : nil,
            isSelf: attendee.isSelf
        )
        guard !cleaned.name.isEmpty || cleaned.email != nil else { return false }
        var roster = meeting.attendees
        guard !roster.contains(where: { $0.id == cleaned.id }) else { return false }
        roster.append(cleaned)
        meeting.attendees = roster
        meeting.updatedAt = Date()
        save()
        fetchMeetings()
        onAttendeesIngested?([cleaned])
        return true
    }

    /// Remove an attendee from a meeting's roster (M2 attendee choke point, plan D7 / Part F #6). Matched
    /// by `Attendee.id`. This **never** deletes the backing `Person` — the directory is decoupled from a
    /// single meeting's roster (directory deletion is a separate settings action). Single-writer on the
    /// MainActor. Returns whether the roster actually changed.
    @discardableResult
    func removeAttendee(_ attendee: Attendee, from meeting: Meeting) -> Bool {
        let roster = meeting.attendees
        let filtered = roster.filter { $0.id != attendee.id }
        guard filtered.count != roster.count else { return false }
        meeting.attendees = filtered
        meeting.updatedAt = Date()
        save()
        fetchMeetings()
        return true
    }

    /// Unlink a meeting from its calendar event: clear the linkage identifiers (`calendarEventID`,
    /// `seriesID`) while keeping all content — title, date, attendees, transcript, outputs (owner
    /// requirement 3). Attendees are retained deliberately (they are content the user may still want,
    /// and prior-meeting matching can keep using them). Idempotent. Single-writer on the MainActor.
    func unlinkCalendarEvent(for meeting: Meeting) {
        guard meeting.calendarEventID != nil || meeting.seriesID != nil else { return }
        meeting.calendarEventID = nil
        meeting.seriesID = nil
        meeting.updatedAt = Date()
        save()
        fetchMeetings()
    }

    /// Whether a title is empty or one of the app's generated default titles (ad-hoc / untitled
    /// calendar event / import fallback). Used by `linkToCalendarEvent` to decide whether adopting
    /// the event's title would clobber a real user title (it never should). Pure + static.
    static func isDefaultOrEmptyTitle(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let defaults: Set<String> = [
            String(localized: "meetings.adHoc.defaultTitle"),
            String(localized: "meetings.calendar.untitledEvent"),
            String(localized: "meetings.import.defaultTitle")
        ]
        return defaults.contains(trimmed)
    }

    // MARK: - Speaker labels & mapping (M9)

    /// Apply diarization speaker labels to a meeting's segments (plan M9). Each assignment targets a
    /// segment by id; unmatched segments are left unchanged. An optional `speakerMap` (e.g. the
    /// separate-track heuristic's seeded `Me`/`Others` names) is stored alongside in the same
    /// transaction so labels and their display names stay consistent.
    func applySpeakerLabels(
        _ assignments: [MeetingSpeakerAssignment],
        speakerMap: [String: String]? = nil,
        to meeting: Meeting
    ) {
        guard !assignments.isEmpty || speakerMap != nil else { return }
        let byID = Dictionary(assignments.map { ($0.segmentID, $0) }, uniquingKeysWith: { first, _ in first })
        for segment in meeting.segments {
            guard let assignment = byID[segment.id] else { continue }
            segment.speakerLabel = assignment.label
            segment.speakerConfidence = assignment.confidence
        }
        if let speakerMap {
            meeting.speakerMap = speakerMap
        }
        meeting.updatedAt = Date()
        save()
        fetchMeetings()
    }

    /// Clear every segment's speaker label/confidence **and** the meeting's speaker map in one
    /// transaction (speaker-recognition amendment, Fix B). Called when capture is *restarted* on a
    /// previously-labeled meeting: the restart stitches a second recording onto the timeline, which
    /// makes the whole meeting a `.timelineMismatch` for labeling (it can never be honestly
    /// re-verified/completed), so the pre-restart labels must not persist as a permanent partial
    /// attribution. Idempotent: a no-op when nothing is labeled.
    func clearSpeakerLabels(for meeting: Meeting) {
        let hasLabels = meeting.segments.contains { $0.speakerLabel != nil || $0.speakerConfidence != nil }
        let hasMap = !meeting.speakerMap.isEmpty
        guard hasLabels || hasMap else { return }
        for segment in meeting.segments {
            segment.speakerLabel = nil
            segment.speakerConfidence = nil
        }
        meeting.speakerMap = [:]
        meeting.updatedAt = Date()
        save()
        fetchMeetings()
    }

    /// Set the additive two-person-call override (speaker-recognition amendment, D-A4). Surfaced only
    /// for attendee-less meetings; enables the automatic two-person channel labeling fast path. `nil`
    /// clears it. Single-writer on the MainActor.
    func setTwoPersonCall(_ enabled: Bool?, for meeting: Meeting) {
        guard meeting.twoPersonCall != enabled else { return }
        meeting.twoPersonCall = enabled
        meeting.updatedAt = Date()
        save()
        fetchMeetings()
    }

    /// Mark whether the meeting's per-segment timestamps have been refined by a genuine final
    /// re-transcription / timing re-pass (speaker-recognition amendment, D-A6). Single-writer.
    func setTimestampsRefined(_ refined: Bool, for meeting: Meeting) {
        guard meeting.timestampsRefined != refined else { return }
        meeting.timestampsRefined = refined
        meeting.updatedAt = Date()
        save()
        fetchMeetings()
    }

    /// Apply refined per-segment start/end times from the keep-live timing re-pass (speaker-recognition
    /// amendment M9-SPK-B / D-A6) and **nothing else**: `text`, `speakerLabel`, `speakerConfidence`,
    /// `order`, and `source` are deliberately left untouched, so the kept live text stays byte-identical
    /// while its timing snaps to real speech. Ids not present on the meeting are ignored; a no-op when
    /// no time actually changes. Single-writer on the MainActor.
    func updateSegmentTimings(_ timings: [(id: UUID, start: Double, end: Double)], for meeting: Meeting) {
        guard !timings.isEmpty else { return }
        let byID = Dictionary(timings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var didChange = false
        for segment in meeting.segments {
            guard let timing = byID[segment.id] else { continue }
            if segment.start != timing.start || segment.end != timing.end {
                segment.start = timing.start
                segment.end = timing.end
                didChange = true
            }
        }
        guard didChange else { return }
        meeting.updatedAt = Date()
        save()
        fetchMeetings()
    }

    /// Persist the `SPEAKER_xx → attendee name` map edited in the speaker-mapping editor (plan M9).
    /// Empty/whitespace names are dropped so a segment falls back to rendering its raw label.
    func setSpeakerMap(_ map: [String: String], for meeting: Meeting) {
        let cleaned = map.reduce(into: [String: String]()) { result, pair in
            let name = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { result[pair.key] = name }
        }
        guard meeting.speakerMap != cleaned else { return }
        meeting.speakerMap = cleaned
        meeting.updatedAt = Date()
        save()
        fetchMeetings()
    }

    // MARK: - Segment writes

    /// Append newly-stabilized transcript segments to a meeting, continuing the existing
    /// `order` sequence. Used incrementally during live capture (durable persistence per batch).
    func appendStableSegments(
        _ segments: [TranscriptionSegment],
        source: MeetingSegmentSource = .liveCapture,
        to meeting: Meeting
    ) {
        guard !segments.isEmpty else { return }
        var nextOrder = (meeting.segments.map(\.order).max() ?? -1) + 1
        for segment in segments {
            let modelSegment = MeetingSegmentMapper.makeSegment(
                from: segment,
                order: nextOrder,
                source: source,
                isStable: true
            )
            modelSegment.meeting = meeting
            modelContext.insert(modelSegment)
            nextOrder += 1
        }
        meeting.updatedAt = Date()
        save()
        fetchMeetings()
    }

    /// Replace all segments of a meeting that carry the given source with a fresh set (e.g. the
    /// final timestamped transcription supersedes live-stabilized segments). Segments from other
    /// sources are preserved; `order` is renumbered chronologically across the whole meeting.
    ///
    /// `preservingSegmentIDs` scopes the replacement to a single capture session: same-source
    /// segments whose id is in the set are kept (they belong to an earlier, already-finalized
    /// session and must never be destroyed — plan D3 "never lose content"). Only same-source
    /// segments *created during the current session* are deleted and replaced.
    func replaceSegments(
        of meeting: Meeting,
        source: MeetingSegmentSource,
        with segments: [TranscriptionSegment],
        preservingSegmentIDs preserved: Set<UUID> = []
    ) {
        // Segments from other sources — and same-source segments explicitly preserved — survive;
        // delete only the ones being replaced. We track the surviving/new set explicitly because
        // SwiftData does not remove deleted rows from the relationship array until save, so
        // `meeting.segments` cannot be trusted for renumbering yet.
        let surviving = meeting.segments.filter { $0.source != source || preserved.contains($0.id) }
        for existing in meeting.segments where existing.source == source && !preserved.contains(existing.id) {
            modelContext.delete(existing)
        }
        var newSegments: [MeetingSegment] = []
        // Assign sequential provisional orders (not all 0) so that when `renumber` sorts by
        // (start, order), segments that share an identical start time keep their input order —
        // Swift's sort is not stable, so equal keys would otherwise scramble.
        for (offset, segment) in segments.enumerated() {
            let modelSegment = MeetingSegmentMapper.makeSegment(
                from: segment,
                order: offset,
                source: source,
                isStable: true
            )
            modelSegment.meeting = meeting
            modelContext.insert(modelSegment)
            newSegments.append(modelSegment)
        }
        renumber(surviving + newSegments)
        meeting.updatedAt = Date()
        save()
        fetchMeetings()
    }

    // MARK: - Import (M8)

    /// Create a new meeting from an imported source (audio or transcript file). Segments are
    /// appended in file/transcription order (already chronological); when they all carry a zero
    /// timestamp (plain-text imports) the sequential `order` keeps them stable (plan reminder 4).
    /// An optional audio file is adopted into `meetings-audio/`.
    @discardableResult
    func createFromImport(
        title: String,
        source: MeetingSource,
        segments: [TranscriptionSegment],
        segmentSource: MeetingSegmentSource,
        startDate: Date? = nil,
        audioFileURL: URL? = nil,
        state: MeetingState = .completed
    ) -> Meeting {
        let meeting = createMeeting(title: title, source: source, state: state, startDate: startDate)
        if !segments.isEmpty {
            appendStableSegments(segments, source: segmentSource, to: meeting)
        }
        if let audioFileURL {
            adoptAudioFile(audioFileURL, for: meeting)
        }
        return meeting
    }

    /// Restore meetings from a settings backup (fork adaptation of #932). Additive by `id`: a meeting
    /// whose id already exists in `meetings.store` is skipped, never overwritten. The full aggregate —
    /// scalar/JSON columns plus the cascade children (segments, notes, outputs, Q&A turns) — is
    /// reconstructed so the round-trip is faithful. Saved audio is not part of a backup, so
    /// `audioFileName` is carried as metadata only (playback resolves to nil if the file is absent on
    /// the destination). Single-writer on the MainActor. Returns the number of meetings inserted.
    @discardableResult
    func importMeetings(_ dtos: [SettingsBackupExporter.MeetingDTO]) -> Int {
        let existingIDs = Set(meetings.map(\.id))
        var imported = 0
        for dto in dtos where !existingIDs.contains(dto.id) {
            let meeting = Meeting(
                id: dto.id,
                title: dto.title,
                startDate: dto.startDate,
                endDate: dto.endDate,
                calendarEventID: dto.calendarEventID,
                seriesID: dto.seriesID,
                attendeesJSON: dto.attendeesJSON,
                speakerMapJSON: dto.speakerMapJSON,
                audioFileName: dto.audioFileName,
                finalRetranscriptionRaw: dto.finalRetranscriptionRaw,
                notesIncludedInOutputs: dto.notesIncludedInOutputs,
                languageCode: dto.languageCode,
                languageProvenanceRaw: dto.languageProvenanceRaw,
                obsidianFolder: dto.obsidianFolder,
                obsidianTagsJSON: dto.obsidianTagsJSON,
                lastObsidianExportAt: dto.lastObsidianExportAt,
                relatedNotePathsJSON: dto.relatedNotePathsJSON,
                excludedNotePathsJSON: dto.excludedNotePathsJSON,
                relatedDiscoveryAt: dto.relatedDiscoveryAt,
                twoPersonCall: dto.twoPersonCall,
                timestampsRefined: dto.timestampsRefined,
                createdAt: dto.createdAt,
                updatedAt: dto.updatedAt
            )
            // Preserve the raw state/source strings verbatim (an unknown future value degrades
            // gracefully via the enum accessors rather than being silently normalized on import).
            meeting.stateRaw = dto.stateRaw
            meeting.sourceRaw = dto.sourceRaw
            modelContext.insert(meeting)

            for segmentDTO in dto.segments {
                let segment = MeetingSegment(
                    id: segmentDTO.id,
                    order: segmentDTO.order,
                    start: segmentDTO.start,
                    end: segmentDTO.end,
                    text: segmentDTO.text,
                    speakerLabel: segmentDTO.speakerLabel,
                    speakerConfidence: segmentDTO.speakerConfidence,
                    source: MeetingSegmentSource(rawValue: segmentDTO.sourceRaw) ?? .importedTranscript,
                    isStable: segmentDTO.isStable,
                    meeting: meeting
                )
                segment.sourceRaw = segmentDTO.sourceRaw
                modelContext.insert(segment)
            }

            for noteDTO in dto.notes {
                let note = MeetingNote(
                    id: noteDTO.id,
                    text: noteDTO.text,
                    timestampOffset: noteDTO.timestampOffset,
                    createdAt: noteDTO.createdAt,
                    meeting: meeting
                )
                modelContext.insert(note)
            }

            for outputDTO in dto.outputs {
                let output = MeetingOutput(
                    id: outputDTO.id,
                    kind: MeetingOutputKind(rawValue: outputDTO.kindRaw) ?? .summary,
                    templateID: outputDTO.templateID,
                    content: outputDTO.content,
                    providerUsed: outputDTO.providerUsed,
                    modelUsed: outputDTO.modelUsed,
                    createdAt: outputDTO.createdAt,
                    meeting: meeting
                )
                output.kindRaw = outputDTO.kindRaw
                modelContext.insert(output)
            }

            for turnDTO in dto.qaTurns {
                let turn = MeetingQATurn(
                    id: turnDTO.id,
                    question: turnDTO.question,
                    answer: turnDTO.answer,
                    createdAt: turnDTO.createdAt,
                    meeting: meeting
                )
                modelContext.insert(turn)
            }

            imported += 1
        }
        if imported > 0 {
            save()
            fetchMeetings()
        }
        return imported
    }

    /// Merge an imported transcript into an existing meeting (plan M8 / D12). Captured content is
    /// preserved; imported segments duplicating the overlap are dropped by `TranscriptMerger`; the
    /// union is re-numbered chronologically and deterministically (stable for equal start times).
    func mergeImport(
        into meeting: Meeting,
        segments: [TranscriptionSegment],
        source: MeetingSegmentSource = .importedTranscript
    ) {
        guard !segments.isEmpty else { return }

        let existing = meeting.segments
            .sorted { $0.order < $1.order }
            .map {
                TranscriptMerger.Segment(
                    text: $0.text,
                    start: $0.start,
                    end: $0.end,
                    speakerLabel: $0.speakerLabel,
                    speakerConfidence: $0.speakerConfidence,
                    source: $0.source
                )
            }
        let imported = segments.map {
            TranscriptMerger.Segment(
                text: $0.text,
                start: $0.start,
                end: $0.end,
                speakerLabel: $0.speakerLabel,
                speakerConfidence: $0.speakerConfidence,
                source: source
            )
        }

        let merged = TranscriptMerger.merge(existing: existing, imported: imported)

        // Replace the meeting's segments with the merged set. The old rows are deleted and the
        // merged sequence re-inserted so provenance tags and ordering are authoritative. `renumber`
        // re-sorts by (start, provisional order); the merger already produced the final order, so
        // provisional order == index preserves it (including all-zero-timestamp stability).
        for existingSegment in meeting.segments {
            modelContext.delete(existingSegment)
        }
        var inserted: [MeetingSegment] = []
        inserted.reserveCapacity(merged.count)
        for (offset, segment) in merged.enumerated() {
            let modelSegment = MeetingSegment(
                order: offset,
                start: segment.start,
                end: segment.end,
                text: segment.text,
                speakerLabel: segment.speakerLabel,
                speakerConfidence: segment.speakerConfidence,
                source: segment.source,
                isStable: true
            )
            modelSegment.meeting = meeting
            modelContext.insert(modelSegment)
            inserted.append(modelSegment)
        }
        renumber(inserted)
        meeting.updatedAt = Date()
        save()
        fetchMeetings()
    }

    private func renumber(_ segments: [MeetingSegment]) {
        let ordered = segments.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.order < $1.order
        }
        for (index, segment) in ordered.enumerated() {
            segment.order = index
        }
    }

    // MARK: - Child CRUD

    @discardableResult
    func addNote(to meeting: Meeting, text: String, timestampOffset: Double? = nil) -> MeetingNote {
        let note = MeetingNote(text: text, timestampOffset: timestampOffset, meeting: meeting)
        modelContext.insert(note)
        meeting.updatedAt = Date()
        save()
        fetchMeetings()
        return note
    }

    @discardableResult
    func addOutput(
        to meeting: Meeting,
        kind: MeetingOutputKind,
        content: String,
        templateID: UUID? = nil,
        providerUsed: String? = nil,
        modelUsed: String? = nil
    ) -> MeetingOutput {
        let output = MeetingOutput(
            kind: kind,
            templateID: templateID,
            content: content,
            providerUsed: providerUsed,
            modelUsed: modelUsed,
            meeting: meeting
        )
        modelContext.insert(output)
        meeting.updatedAt = Date()
        save()
        fetchMeetings()

        // AD4 emission point 5/5: an output was generated/persisted (summary/extended/brief).
        // Single choke point → covers MeetingLLMService, MeetingBriefService, and auto-briefs.
        eventEmitter.emit(.outputGenerated(MeetingOutputGeneratedPayload(
            meetingID: meeting.id,
            kindRaw: kind.rawValue,
            templateID: templateID,
            content: content,
            provider: providerUsed,
            model: modelUsed
        )))

        return output
    }

    @discardableResult
    func addQATurn(to meeting: Meeting, question: String, answer: String) -> MeetingQATurn {
        let turn = MeetingQATurn(question: question, answer: answer, meeting: meeting)
        modelContext.insert(turn)
        meeting.updatedAt = Date()
        save()
        fetchMeetings()
        return turn
    }

    /// Remove a generated output (e.g. discarding a stale regeneration). History is otherwise
    /// retained — regeneration inserts a new row rather than mutating an existing one (plan D15).
    func deleteOutput(_ output: MeetingOutput) {
        let meeting = output.meeting
        modelContext.delete(output)
        meeting?.updatedAt = Date()
        save()
        fetchMeetings()
    }

    /// The newest output of a given kind for a meeting (what the UI surfaces; older rows are kept).
    func latestOutput(ofKind kind: MeetingOutputKind, for meeting: Meeting) -> MeetingOutput? {
        meeting.outputs
            .filter { $0.kind == kind }
            .max { $0.createdAt < $1.createdAt }
    }

    /// Toggle whether in-meeting notes are folded into generated outputs (plan M4; written here,
    /// read by `MeetingLLMService`).
    func setNotesIncludedInOutputs(_ included: Bool, for meeting: Meeting) {
        guard meeting.notesIncludedInOutputs != included else { return }
        meeting.notesIncludedInOutputs = included
        meeting.updatedAt = Date()
        save()
        fetchMeetings()
    }

    // MARK: - Per-meeting language (plan D1 — provenance ladder manual > rule > detected)

    /// The transcription language for a meeting, derived from the one persisted column (plan D3):
    /// `.exact(code)` when a language is set, else `.auto`. Every transcription consumer (live
    /// capture, both final-pass paths, audio import) resolves through this so there is exactly one
    /// notion of "the meeting's language".
    func transcriptionLanguageSelection(for meeting: Meeting) -> LanguageSelection {
        guard let code = meeting.languageCode?.trimmingCharacters(in: .whitespacesAndNewlines),
              !code.isEmpty else { return .auto }
        return .exact(code)
    }

    /// Explicit per-meeting language pick (plan D1). Writes `.manual` **unconditionally** — a
    /// deliberate user choice outranks any rule or detection. A blank code clears the language.
    /// Single-writer on the MainActor with no `await` between check and write.
    func setLanguage(_ code: String?, for meeting: Meeting) {
        let normalized = code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let normalized, !normalized.isEmpty else {
            clearLanguage(for: meeting)
            return
        }
        guard meeting.languageCode != normalized || meeting.languageProvenance != .manual else { return }
        meeting.languageCode = normalized
        meeting.languageProvenance = .manual
        meeting.updatedAt = Date()
        save()
        fetchMeetings()
    }

    /// Clear a meeting's language (both columns to `nil`) — returns it to the `.auto` /
    /// detection-eligible state (plan D1).
    func clearLanguage(for meeting: Meeting) {
        guard meeting.languageCode != nil || meeting.languageProvenanceRaw != nil else { return }
        meeting.languageCode = nil
        meeting.languageProvenanceRaw = nil
        meeting.updatedAt = Date()
        save()
        fetchMeetings()
    }

    /// Seed the language from a matched capture-context rule at capture start (plan D1/D2). A rule is
    /// standing user configuration, so it writes when provenance is **nil, `.rule`, or `.detected`**
    /// — it outranks an inference but **never** overwrites an explicit per-meeting `.manual` pick.
    /// Single-writer on the MainActor with no `await` between the ladder check and the write.
    func seedRuleLanguage(_ code: String, for meeting: Meeting) {
        // M2 (M1-review fix): the rule language field is free text, and `LanguageSelection(storedValue:)`
        // maps *any* non-empty value to `.exact(value)` — so a rule value like "german" or garbage would
        // otherwise be persisted verbatim as a meeting language code. Normalize/validate it here through
        // the same catalog detection uses: a recognizable value (ISO code or language name, "german" →
        // "de") normalizes to a canonical lowercased code; **unrecognizable garbage is silently skipped**
        // (seeds nothing) rather than becoming a bogus `languageCode`.
        guard let normalized = MeetingLanguageCatalog.normalize(code) else { return }
        // Never over a manual pick.
        if meeting.languageProvenance == .manual { return }
        guard meeting.languageCode != normalized || meeting.languageProvenance != .rule else { return }
        meeting.languageCode = normalized
        meeting.languageProvenance = .rule
        meeting.updatedAt = Date()
        save()
        fetchMeetings()
    }

    /// Persist an auto-detected language (plan D1/D5, M2). Writes `.detected` **only when the meeting
    /// has no language yet** — a manual or rule value always wins. The `languageCode == nil` guard is
    /// re-checked here, on the MainActor, with no `await` between the check and the write, so a manual
    /// pick that lands while a detection job is in flight is never clobbered by the finishing job.
    func setDetectedLanguage(_ code: String, for meeting: Meeting) {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return }
        guard meeting.languageCode == nil else { return }
        meeting.languageCode = normalized
        meeting.languageProvenance = .detected
        meeting.updatedAt = Date()
        save()
        fetchMeetings()
    }

    // MARK: - Obsidian export metadata (M7)

    /// Persist the per-meeting Obsidian export folder (a vault-relative path). Empty/whitespace
    /// clears it (export then writes to the vault root).
    func setObsidianFolder(_ folder: String?, for meeting: Meeting) {
        let trimmed = folder?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (trimmed?.isEmpty == false) ? trimmed : nil
        guard meeting.obsidianFolder != value else { return }
        meeting.obsidianFolder = value
        meeting.updatedAt = Date()
        save()
        fetchMeetings()
    }

    /// Record that `meeting` was just successfully exported to the connected vault. This timestamp
    /// (not the mere presence of an `obsidianFolder` path) is the source of truth for the "In vault"
    /// badge, so it only ever changes as a result of a real export.
    func recordObsidianExport(for meeting: Meeting, at date: Date = Date()) {
        meeting.lastObsidianExportAt = date
        meeting.updatedAt = date
        save()
        fetchMeetings()
    }

    /// Persist the per-meeting Obsidian frontmatter tags, trimming blanks and de-duplicating while
    /// preserving order.
    func setObsidianTags(_ tags: [String], for meeting: Meeting) {
        let cleaned = Self.normalizedTags(tags)
        guard meeting.obsidianTags != cleaned else { return }
        meeting.obsidianTags = cleaned
        meeting.updatedAt = Date()
        save()
        fetchMeetings()
    }

    // MARK: - First-party tags (plan D6, M3)

    /// Bulk-rename a tag across every meeting that carries it, in a **single** `save()` +
    /// `fetchMeetings()` (plan D6 — not O(n) per-meeting `update()` calls). Case-folded match; the
    /// replacement is re-run through the trim/dedupe policy so a rename onto a tag a meeting already
    /// has **merges** (no case-variant duplicate). No-op when the source is blank, the target trims
    /// empty, or nothing carries the tag.
    func renameTag(_ tag: String, to newName: String) {
        let fromKey = tag.trimmingCharacters(in: .whitespaces).lowercased()
        let trimmedNew = newName.trimmingCharacters(in: .whitespaces)
        guard !fromKey.isEmpty, !trimmedNew.isEmpty else { return }

        var didChange = false
        for meeting in meetings {
            let current = meeting.obsidianTags
            guard current.contains(where: { $0.lowercased() == fromKey }) else { continue }
            // Replace the matched tag with the new name, then dedupe case-insensitively (preserving
            // the first occurrence) so a rename that collides with an existing tag merges instead of
            // leaving `["Recruiting", "recruiting"]`.
            let replaced = current.map { $0.lowercased() == fromKey ? trimmedNew : $0 }
            let cleaned = Self.caseFoldedDedupe(replaced)
            guard cleaned != current else { continue }
            meeting.obsidianTags = cleaned
            meeting.updatedAt = Date()
            didChange = true
        }
        guard didChange else { return }
        save()
        fetchMeetings()
    }

    /// Bulk-delete a tag from every meeting that carries it, in a single save (plan D6). Case-folded.
    func deleteTag(_ tag: String) {
        let key = tag.trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty else { return }

        var didChange = false
        for meeting in meetings {
            let current = meeting.obsidianTags
            guard current.contains(where: { $0.lowercased() == key }) else { continue }
            meeting.obsidianTags = current.filter { $0.lowercased() != key }
            meeting.updatedAt = Date()
            didChange = true
        }
        guard didChange else { return }
        save()
        fetchMeetings()
    }

    /// Trim blanks and drop exact-string duplicates while preserving order (the canonical tag policy
    /// shared by `setObsidianTags`).
    static func normalizedTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Trim blanks and drop **case-insensitive** duplicates, keeping the first occurrence's casing.
    /// Used by `renameTag` so a rename merge never yields a case-variant twin.
    private static func caseFoldedDedupe(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    // MARK: - First-party folders (plan D7, M4)

    /// Split a `/`-separated folder path into trimmed, non-empty components (the canonical folder
    /// tokenization shared by the mutators, the tree, and the filter). `nil`/blank ⇒ `[]` (Unfiled).
    static func folderComponents(_ path: String?) -> [String] {
        guard let path else { return [] }
        return path
            .split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Canonical string form of a folder path (components rejoined); `nil` when Unfiled.
    static func normalizedFolderPath(_ path: String?) -> String? {
        let comps = folderComponents(path)
        return comps.isEmpty ? nil : comps.joined(separator: "/")
    }

    /// Set a meeting's folder (first-party alias over `obsidianFolder`), normalizing components.
    /// Empty/blank clears it (the meeting becomes Unfiled).
    func setFolder(_ path: String?, for meeting: Meeting) {
        let normalized = Self.normalizedFolderPath(path)
        guard meeting.obsidianFolder != normalized else { return }
        meeting.obsidianFolder = normalized
        meeting.updatedAt = Date()
        save()
        fetchMeetings()
    }

    /// Bulk-rename a folder across every meeting at or under it, in a **single** `save()` (plan D7).
    /// A rename is a component-wise prefix rewrite of the whole subtree, so `renameFolder` and
    /// `moveFolder` share one implementation.
    func renameFolder(_ old: String, to new: String) {
        rewriteFolderPrefix(from: old, to: new)
    }

    /// Move a folder (and its whole subtree) under a new path — component-wise prefix rewrite, one
    /// save (plan D7). Functionally identical to `renameFolder`; the two names document intent.
    func moveFolder(_ old: String, to new: String) {
        rewriteFolderPrefix(from: old, to: new)
    }

    /// Delete a folder: unfile every meeting at or under `path` (their `folderPath` becomes `nil`),
    /// in one save. The M7 metadata seam is notified so a configured folder's config is dropped.
    func deleteFolder(_ path: String) {
        let comps = Self.folderComponents(path)
        guard !comps.isEmpty else { return }

        var didChange = false
        for meeting in meetings {
            let mc = Self.folderComponents(meeting.obsidianFolder)
            guard mc.count >= comps.count, Array(mc.prefix(comps.count)) == comps else { continue }
            meeting.obsidianFolder = nil
            meeting.updatedAt = Date()
            didChange = true
        }
        onFolderDeleted?(comps.joined(separator: "/"))
        guard didChange else { return }
        save()
        fetchMeetings()
    }

    /// Rewrite the folder prefix `old` → `new` (component-wise, so `Acme` never matches `Acme2`) on
    /// every meeting at or under `old`, in one save. The M7 metadata seam always fires (even when no
    /// meeting currently sits under the folder) so a configured-but-empty folder's config follows the
    /// rename atomically.
    private func rewriteFolderPrefix(from old: String, to new: String) {
        let oldComps = Self.folderComponents(old)
        let newComps = Self.folderComponents(new)
        guard !oldComps.isEmpty, !newComps.isEmpty else { return }
        let oldPath = oldComps.joined(separator: "/")
        let newPath = newComps.joined(separator: "/")
        guard oldPath != newPath else { return }

        var didChange = false
        for meeting in meetings {
            let comps = Self.folderComponents(meeting.obsidianFolder)
            guard comps.count >= oldComps.count, Array(comps.prefix(oldComps.count)) == oldComps else { continue }
            meeting.obsidianFolder = (newComps + comps.dropFirst(oldComps.count)).joined(separator: "/")
            meeting.updatedAt = Date()
            didChange = true
        }
        onFolderPathRewrite?(oldPath, newPath)
        guard didChange else { return }
        save()
        fetchMeetings()
    }

    // MARK: - Bulk mutators (plan LX-2, D5 — single-save, mirrors `renameTag`/`deleteTag`)

    /// Set the folder of every meeting in `meetings` in a **single** `save()` + `fetchMeetings()`
    /// (plan LX-2 D5 — not O(n) per-meeting `setFolder`/`update` calls). The path is normalized once;
    /// meetings already at the target are skipped, and a `didChange` guard makes the whole call a no-op
    /// when nothing moved. Empty/blank ⇒ Unfiled.
    func setFolder(_ path: String?, for meetings: [Meeting]) {
        let normalized = Self.normalizedFolderPath(path)
        var didChange = false
        for meeting in meetings where meeting.obsidianFolder != normalized {
            meeting.obsidianFolder = normalized
            meeting.updatedAt = Date()
            didChange = true
        }
        guard didChange else { return }
        save()
        fetchMeetings()
    }

    /// Add `tag` to every meeting in `meetings` in one save (plan LX-2 D5). Case-folded: a meeting
    /// already carrying the tag (any casing) is skipped, and the result is re-run through the canonical
    /// trim/dedupe policy. Blank tag or no change ⇒ no-op.
    func addTag(_ tag: String, to meetings: [Meeting]) {
        let trimmed = tag.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let key = trimmed.lowercased()
        var didChange = false
        for meeting in meetings {
            guard !meeting.obsidianTags.contains(where: { $0.lowercased() == key }) else { continue }
            meeting.obsidianTags = Self.normalizedTags(meeting.obsidianTags + [trimmed])
            meeting.updatedAt = Date()
            didChange = true
        }
        guard didChange else { return }
        save()
        fetchMeetings()
    }

    /// Remove `tag` (case-folded) from every meeting in `meetings` in one save (plan LX-2 D5). A
    /// meeting that does not carry the tag is skipped; no change ⇒ no-op.
    func removeTag(_ tag: String, from meetings: [Meeting]) {
        let key = tag.trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty else { return }
        var didChange = false
        for meeting in meetings {
            let filtered = meeting.obsidianTags.filter { $0.lowercased() != key }
            guard filtered.count != meeting.obsidianTags.count else { continue }
            meeting.obsidianTags = filtered
            meeting.updatedAt = Date()
            didChange = true
        }
        guard didChange else { return }
        save()
        fetchMeetings()
    }

    /// Delete every meeting in `meetings` — each audio blob removed, each row deleted — in a single
    /// save (plan LX-2 D5). No-op on an empty input.
    func deleteMeetings(_ meetings: [Meeting]) {
        guard !meetings.isEmpty else { return }
        for meeting in meetings {
            deleteAudioFile(for: meeting)
            modelContext.delete(meeting)
        }
        save()
        fetchMeetings()
    }

    // MARK: - Templates (plan AD6 — unified into `promptActions.store`)

    /// No-op shim (plan AD6). Meeting templates are seeded/migrated into the unified
    /// `promptActions.store` by `PromptActionService.migrateMeetingTemplatesIfNeeded`; this method is
    /// retained so any stray caller compiles. Kept intentionally empty.
    func seedTemplatesIfNeeded() {}

    /// Templates of a given output kind, in sort order (drives the generate menus). Delegates to the
    /// unified store (plan AD6); the signature is unchanged so Track C and the output views are
    /// unaffected. Returns `[]` when no prompt-action service is wired (unit tests).
    func templates(ofKind kind: MeetingOutputKind) -> [PromptAction] {
        promptActionService?.meetingTemplates(ofKind: kind) ?? []
    }

    /// Snapshot the frozen legacy `MeetingTemplate` rows still living in `meetings.store` so
    /// `PromptActionService` can migrate them into unified `.meeting` `PromptAction` rows (plan AD6).
    /// The `MeetingTemplate` `@Model` stays registered in the schema — removing it would risk a
    /// destructive reset of every stored meeting — but is otherwise frozen and never written again.
    func legacyMeetingTemplateSnapshots() -> [MeetingTemplateSnapshot] {
        let descriptor = FetchDescriptor<MeetingTemplate>(
            sortBy: [SortDescriptor(\.sortOrder, order: .forward)]
        )
        do {
            return try modelContext.fetch(descriptor).map { template in
                MeetingTemplateSnapshot(
                    id: template.id,
                    name: template.name,
                    kindRaw: template.kindRaw,
                    prompt: template.prompt,
                    providerType: template.providerType,
                    cloudModel: template.cloudModel,
                    temperatureModeRaw: template.temperatureModeRaw,
                    temperatureValue: template.temperatureValue,
                    isPreset: template.isPreset,
                    sortOrder: template.sortOrder
                )
            }
        } catch {
            logger.error("Failed to snapshot legacy meeting templates: \(error.localizedDescription)")
            return []
        }
    }

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

    // MARK: - Queries

    /// Meetings related to the given one — sharing at least one attendee email, the same recurrence
    /// `seriesID`, OR (plan D8) a shared resolved directory `Person` identity. Excludes the meeting
    /// itself. Used by pre-meeting briefs (M5) and the related-meetings surface.
    ///
    /// The directory union is what unlocks the owner's largely email-less imported archive: two archive
    /// meetings that share a person only by name resolve — via the participant directory — to the same
    /// `Person` id and match. Email/series stay primary; the union is purely additive, and when the
    /// directory seam is unwired (`resolvePersonIDs == nil`, e.g. in a unit test that does not build the
    /// directory) behavior is exactly the prior email-OR-series rule.
    func priorMeetings(matching meeting: Meeting) -> [Meeting] {
        let emails = Set(
            meeting.attendees.compactMap { $0.email?.lowercased() }.filter { !$0.isEmpty }
        )
        let seriesID = meeting.seriesID
        // M4 (M3 review minor): build the directory resolution index ONCE per query via the factory
        // seam, then reuse the returned resolver for the target and every candidate. Falls back to the
        // per-call seam (or nil) when the factory is unwired, so the email/series-only path and existing
        // tests are unchanged.
        let resolver = makePersonIDResolver?() ?? resolvePersonIDs
        let targetPersonIDs = resolver?(meeting.attendees) ?? []

        return meetings.filter { candidate in
            guard candidate.id != meeting.id else { return false }
            if let seriesID, !seriesID.isEmpty, candidate.seriesID == seriesID {
                return true
            }
            let candidateEmails = Set(
                candidate.attendees.compactMap { $0.email?.lowercased() }.filter { !$0.isEmpty }
            )
            if !emails.isDisjoint(with: candidateEmails) {
                return true
            }
            guard !targetPersonIDs.isEmpty else { return false }
            let candidatePersonIDs = resolver?(candidate.attendees) ?? []
            return !targetPersonIDs.isDisjoint(with: candidatePersonIDs)
        }
    }

    // MARK: - Crash recovery

    /// Startup recovery pass (plan D2). Any meeting still marked `.live` when the app launches
    /// was interrupted by a crash/force-quit mid-capture; flip it to `.interrupted` so its
    /// already-persisted segments remain visible while making clear capture did not finish.
    /// Returns the meetings that were recovered.
    @discardableResult
    func recoverInterruptedMeetings() -> [Meeting] {
        // Both `.live` (never reached stop) and `.processing` (crashed during stop()'s finalize
        // window — state is set to `.processing` before several awaits, incl. a potentially long
        // final transcription) are stuck states with no other exit on relaunch. Recover both; the
        // persisted live segments remain visible either way.
        let interrupted = meetings.filter { $0.state == .live || $0.state == .processing }
        guard !interrupted.isEmpty else { return [] }
        for meeting in interrupted {
            meeting.state = .interrupted
            meeting.updatedAt = Date()
        }
        save()
        fetchMeetings()
        return interrupted
    }

    // MARK: - Audio blobs

    /// Move a finished recording into the meetings audio directory, keyed by the meeting UUID,
    /// and record its filename on the meeting. The source file (born in the Recorder library) is
    /// removed by the move so it never lingers there (plan D17).
    ///
    /// If capture was *restarted* on an already-finalized meeting, an audio file for this UUID may
    /// already exist. We must not overwrite it (plan D3 "never lose content"): the new file gets a
    /// versioned suffix (`<uuid>-2.<ext>`, …) and the meeting points at the newest, leaving the
    /// prior session's audio on disk for manual salvage. `deleteAudioFile` sweeps every version.
    func adoptAudioFile(_ sourceURL: URL, for meeting: Meeting) {
        let ext = sourceURL.pathExtension.isEmpty ? "wav" : sourceURL.pathExtension
        let destination = uniqueAudioDestination(for: meeting, ext: ext)
        do {
            try FileManager.default.moveItem(at: sourceURL, to: destination)
            meeting.audioFileName = destination.lastPathComponent
            meeting.updatedAt = Date()
            save()
            fetchMeetings()
        } catch {
            logger.error("Failed to adopt audio file for meeting: \(error.localizedDescription)")
        }
    }

    /// A non-colliding destination in the audio directory: `<uuid>.<ext>` when free, otherwise
    /// `<uuid>-2.<ext>`, `<uuid>-3.<ext>`, … so a restarted session never clobbers prior audio.
    private func uniqueAudioDestination(for meeting: Meeting, ext: String) -> URL {
        let base = meeting.id.uuidString
        var candidate = audioDirectory.appendingPathComponent("\(base).\(ext)")
        var version = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = audioDirectory.appendingPathComponent("\(base)-\(version).\(ext)")
            version += 1
        }
        return candidate
    }

    func audioFileURL(for meeting: Meeting) -> URL? {
        guard let fileName = meeting.audioFileName else { return nil }
        let url = audioDirectory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private func deleteAudioFile(for meeting: Meeting) {
        // Remove every version keyed to this meeting's UUID (`<uuid>.ext`, `<uuid>-2.ext`, …),
        // not just the currently-referenced one, so restarted-session versions are not orphaned.
        let prefix = meeting.id.uuidString
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: audioDirectory,
            includingPropertiesForKeys: nil
        ) {
            for url in entries where url.lastPathComponent.hasPrefix(prefix) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Fetch / persist

    private func fetchMeetings() {
        let descriptor = FetchDescriptor<Meeting>(
            sortBy: [SortDescriptor(\.startDate, order: .reverse), SortDescriptor(\.createdAt, order: .reverse)]
        )
        do {
            meetings = try modelContext.fetch(descriptor)
        } catch {
            logger.error("Failed to fetch meetings: \(error.localizedDescription)")
            meetings = []
        }
    }

    private func save() {
        do {
            try modelContext.save()
        } catch {
            logger.error("Save failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Demo Data (DEBUG only)

    #if DEBUG
    @discardableResult
    func seedDemoMeeting() -> Meeting {
        let meeting = createMeeting(
            title: "Product Sync",
            source: .adHoc,
            state: .completed,
            startDate: Date(),
            attendees: [
                Attendee(name: "Marco", email: "marco@example.com"),
                Attendee(name: "Alex", email: "alex@example.com")
            ]
        )
        appendStableSegments(
            [
                TranscriptionSegment(text: "Let's review the roadmap.", start: 0, end: 3),
                TranscriptionSegment(text: "The Meetings feature ships next.", start: 3, end: 6)
            ],
            to: meeting
        )
        addNote(to: meeting, text: "Follow up on the schema review.", timestampOffset: 4)
        return meeting
    }
    #endif
}
