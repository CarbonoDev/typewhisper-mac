import Foundation
import SwiftData
import Combine
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "MeetingService")

/// The sole writer of the `meetings.store` aggregate. Owns its own `ModelContainer`/`ModelContext`
/// (mirrors `HistoryService`'s shape) plus a sibling `meetings-audio/` directory for on-disk audio
/// blobs keyed by meeting UUID.
@MainActor
final class MeetingService: ObservableObject {
    @Published private(set) var meetings: [Meeting] = []
    @Published private(set) var templates: [MeetingTemplate] = []

    private let modelContainer: ModelContainer
    private let modelContext: ModelContext
    private let audioDirectory: URL

    init(appSupportDirectory: URL = AppConstants.appSupportDirectory) {
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
        fetchTemplates()
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

    /// Persist the per-meeting Obsidian frontmatter tags, trimming blanks and de-duplicating while
    /// preserving order.
    func setObsidianTags(_ tags: [String], for meeting: Meeting) {
        var seen = Set<String>()
        let cleaned = tags
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        guard meeting.obsidianTags != cleaned else { return }
        meeting.obsidianTags = cleaned
        meeting.updatedAt = Date()
        save()
        fetchMeetings()
    }

    // MARK: - Templates

    /// Idempotently seed the curated starter templates (plan M4 §3). Mirrors
    /// `PromptActionService.seedPresetsIfNeeded`: presets missing by name are inserted, existing
    /// user/preset rows are never overwritten, so re-running is safe and additive.
    func seedTemplatesIfNeeded() {
        let existingNames = Set(templates.map(\.name))
        let missing = MeetingTemplatePresets.all.filter { !existingNames.contains($0.name) }
        guard !missing.isEmpty else { return }

        let nextSortOrder = (templates.map(\.sortOrder).max() ?? -1) + 1
        for (offset, preset) in missing.enumerated() {
            let template = MeetingTemplate(
                name: preset.name,
                kind: preset.kind,
                prompt: preset.prompt,
                providerType: preset.providerType,
                cloudModel: preset.cloudModel,
                temperatureModeRaw: preset.temperatureModeRaw,
                temperatureValue: preset.temperatureValue,
                isPreset: true,
                sortOrder: templates.isEmpty ? preset.sortOrder : nextSortOrder + offset
            )
            modelContext.insert(template)
        }
        save()
        fetchTemplates()
    }

    /// Templates of a given output kind, in sort order (drives the generate menu).
    func templates(ofKind kind: MeetingOutputKind) -> [MeetingTemplate] {
        templates.filter { $0.kind == kind }
    }

    @discardableResult
    func addTemplate(
        name: String,
        kind: MeetingOutputKind,
        prompt: String,
        providerType: String? = nil,
        cloudModel: String? = nil,
        temperatureModeRaw: String? = nil,
        temperatureValue: Double? = nil
    ) -> MeetingTemplate {
        let template = MeetingTemplate(
            name: name,
            kind: kind,
            prompt: prompt,
            providerType: providerType,
            cloudModel: cloudModel,
            temperatureModeRaw: temperatureModeRaw,
            temperatureValue: temperatureValue,
            isPreset: false,
            sortOrder: (templates.map(\.sortOrder).max() ?? -1) + 1
        )
        modelContext.insert(template)
        save()
        fetchTemplates()
        return template
    }

    /// Persist edits to a fetched template.
    func updateTemplate(_ template: MeetingTemplate) {
        save()
        fetchTemplates()
    }

    func deleteTemplate(_ template: MeetingTemplate) {
        modelContext.delete(template)
        save()
        fetchTemplates()
    }

    private func fetchTemplates() {
        let descriptor = FetchDescriptor<MeetingTemplate>(
            sortBy: [SortDescriptor(\.sortOrder, order: .forward)]
        )
        do {
            templates = try modelContext.fetch(descriptor)
        } catch {
            logger.error("Failed to fetch meeting templates: \(error.localizedDescription)")
            templates = []
        }
    }

    // MARK: - Queries

    /// Meetings related to the given one — sharing at least one attendee email OR the same
    /// recurrence `seriesID`. Excludes the meeting itself. Used by pre-meeting briefs (M5).
    func priorMeetings(matching meeting: Meeting) -> [Meeting] {
        let emails = Set(
            meeting.attendees.compactMap { $0.email?.lowercased() }.filter { !$0.isEmpty }
        )
        let seriesID = meeting.seriesID

        return meetings.filter { candidate in
            guard candidate.id != meeting.id else { return false }
            if let seriesID, !seriesID.isEmpty, candidate.seriesID == seriesID {
                return true
            }
            let candidateEmails = Set(
                candidate.attendees.compactMap { $0.email?.lowercased() }.filter { !$0.isEmpty }
            )
            return !emails.isDisjoint(with: candidateEmails)
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
