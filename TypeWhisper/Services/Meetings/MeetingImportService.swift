import Foundation
import Combine
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "MeetingImportService")

/// The narrow transcription seam the import service depends on (plan M8 reuse note: audio import
/// goes through `ModelManagerService.transcribe`). Narrowed to one method so unit tests can stub it
/// without the plugin graph. `ModelManagerService` conforms via the extension below.
@MainActor
protocol MeetingAudioTranscribing: AnyObject {
    func transcribeImportedAudio(
        samples: [Float],
        languageSelection: LanguageSelection
    ) async throws -> TranscriptionResult

    /// [M5/D10] Re-transcribe meeting audio through a chosen speaker-capable cloud engine so its own
    /// diarization writes per-segment speaker labels (adopted via the `preferProviderLabels` path). The
    /// default implementation forwards to `transcribeImportedAudio` (dropping the override), so predating
    /// stubs that only implement the base method still conform; `ModelManagerService` supplies the real
    /// engine-override call below.
    func transcribeMeetingAudio(
        samples: [Float],
        languageSelection: LanguageSelection,
        engineOverrideId: String?,
        cloudModelOverride: String?
    ) async throws -> TranscriptionResult
}

extension MeetingAudioTranscribing {
    func transcribeMeetingAudio(
        samples: [Float],
        languageSelection: LanguageSelection,
        engineOverrideId: String?,
        cloudModelOverride: String?
    ) async throws -> TranscriptionResult {
        try await transcribeImportedAudio(samples: samples, languageSelection: languageSelection)
    }
}

extension ModelManagerService: MeetingAudioTranscribing {
    func transcribeImportedAudio(
        samples: [Float],
        languageSelection: LanguageSelection
    ) async throws -> TranscriptionResult {
        try await transcribe(
            audioSamples: samples,
            languageSelection: languageSelection,
            task: .transcribe,
            onProgress: { _ in true }
        )
    }

    func transcribeMeetingAudio(
        samples: [Float],
        languageSelection: LanguageSelection,
        engineOverrideId: String?,
        cloudModelOverride: String?
    ) async throws -> TranscriptionResult {
        try await transcribe(
            audioSamples: samples,
            languageSelection: languageSelection,
            task: .transcribe,
            engineOverrideId: engineOverrideId,
            cloudModelOverride: cloudModelOverride,
            onProgress: { _ in true }
        )
    }
}

/// Creates meetings from imported files and merges imported transcripts into existing meetings
/// (plan M8). Two new-meeting paths — an audio file (transcribed via `ModelManagerService`) and a
/// transcript-only file (`TranscriptFileParser`) — plus a merge-into-existing path
/// (`TranscriptMerger` through `MeetingService.mergeImport`). It never adds transcript extensions
/// to `AudioFileService.supportedExtensions` (plan D13).
@MainActor
final class MeetingImportService: ObservableObject {
    enum ImportError: LocalizedError, Equatable {
        case unsupportedTranscriptFile
        case unreadableTranscriptFile
        case emptyTranscript
        case emptyAudioTranscription
        case alreadyImporting

        var errorDescription: String? {
            switch self {
            case .unsupportedTranscriptFile:
                return String(localized: "meetings.import.error.unsupportedTranscript")
            case .unreadableTranscriptFile:
                return String(localized: "meetings.import.error.unreadableTranscript")
            case .emptyTranscript:
                return String(localized: "meetings.import.error.emptyTranscript")
            case .emptyAudioTranscription:
                return String(localized: "meetings.import.error.emptyAudioTranscription")
            case .alreadyImporting:
                return String(localized: "meetings.import.error.alreadyImporting")
            }
        }
    }

    @Published private(set) var isImporting = false

    private let meetingService: MeetingService
    private let audioFileService: AudioFileService
    private let transcriber: MeetingAudioTranscribing

    init(
        meetingService: MeetingService,
        audioFileService: AudioFileService,
        transcriber: MeetingAudioTranscribing
    ) {
        self.meetingService = meetingService
        self.audioFileService = audioFileService
        self.transcriber = transcriber
    }

    // MARK: - New meeting from a transcript-only file

    /// Parse a transcript file (Google Meet / `Speaker:` / timestamped / plain text) into a new
    /// `.importedTranscript` meeting. Throws when the extension is unsupported, the file is
    /// unreadable, or nothing parseable was found.
    @discardableResult
    func importTranscriptFile(at url: URL, title: String? = nil) throws -> Meeting {
        let segments = try parseTranscriptFile(at: url)
        let resolved = resolvedTitleAndDate(title, fallbackFileName: url)
        let meeting = meetingService.createFromImport(
            title: resolved.title,
            source: .importedTranscript,
            segments: segments,
            segmentSource: .importedTranscript,
            startDate: resolved.startDate
        )
        return meeting
    }

    /// Parse raw transcript **text** (not a file) into a new `.importedTranscript` meeting. Same
    /// parser as `importTranscriptFile`, for callers that already hold the transcript in memory (the
    /// HTTP API's raw-text body / bulk archive import / Drive auto-import). Throws
    /// `.emptyTranscript` when nothing parseable is found.
    ///
    /// `startDate` ([Google Phase 2 · M1], D-D4): the Drive importer dates a created meeting from
    /// the export filename (falling back to the doc's `createdTime`), so historical transcripts
    /// land on their real dates. `nil` (every pre-existing call site) keeps today's behavior.
    @discardableResult
    func importTranscriptText(_ text: String, title: String? = nil, startDate: Date? = nil) throws -> Meeting {
        let segments = TranscriptFileParser.parse(text)
        guard !segments.isEmpty else { throw ImportError.emptyTranscript }
        return meetingService.createFromImport(
            title: resolvedTitle(title, fallbackText: text),
            source: .importedTranscript,
            segments: segments,
            segmentSource: .importedTranscript,
            startDate: startDate
        )
    }

    // MARK: - New meeting from an audio file

    /// Decode an audio file, transcribe it through the file-transcription path, and create a new
    /// `.importedAudio` meeting with timestamped segments. A **copy** of the source audio is adopted
    /// into `meetings-audio/` (the user's original file is never moved). Throws when transcription
    /// yields no segments.
    ///
    /// `languageCode` (plan D1/M1): when the import sheet's optional language picker selects a
    /// specific language, its code drives transcription (`.exact`) **and** is persisted `.manual` on
    /// the created meeting so every downstream consumer honors it. `nil` = Auto (`.auto`
    /// transcription; the meeting is left language-unset for M2 detection).
    @discardableResult
    func importAudioFile(at url: URL, title: String? = nil, languageCode: String? = nil) async throws -> Meeting {
        guard !isImporting else { throw ImportError.alreadyImporting }
        isImporting = true
        defer { isImporting = false }

        let normalizedCode = languageCode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let selection: LanguageSelection = (normalizedCode?.isEmpty == false)
            ? .exact(normalizedCode!)
            : .auto

        let samples = try await audioFileService.loadAudioSamples(from: url)
        let result = try await transcriber.transcribeImportedAudio(samples: samples, languageSelection: selection)
        guard !result.segments.isEmpty else { throw ImportError.emptyAudioTranscription }

        // Adopt a copy so the original is untouched; `adoptAudioFile` moves, so stage a temp copy.
        let audioURL = stagedCopy(of: url)
        let resolved = resolvedTitleAndDate(title, fallbackFileName: url)
        let meeting = meetingService.createFromImport(
            title: resolved.title,
            source: .importedAudio,
            segments: result.segments,
            segmentSource: .importedAudio,
            startDate: resolved.startDate,
            audioFileURL: audioURL
        )
        // Persist the chosen language as an explicit `.manual` pick (a user selection in the sheet).
        if let normalizedCode, !normalizedCode.isEmpty {
            meetingService.setLanguage(normalizedCode, for: meeting)
        }
        return meeting
    }

    // MARK: - Merge a transcript into an existing meeting

    /// Parse a transcript file and merge it into `meeting`, time-ordered and source-tagged, deduping
    /// the overlap with already-captured content (plan D12). A timed import is authoritative for its
    /// covered span (`ImportOverlapPlan`): live rows it overlaps are dropped, and the count is
    /// returned (and logged) so callers can report it.
    @discardableResult
    func mergeTranscriptFile(at url: URL, into meeting: Meeting) throws -> Int {
        let segments = try parseTranscriptFile(at: url)
        let dropped = meetingService.mergeImport(into: meeting, segments: segments, source: .importedTranscript)
        if dropped > 0 {
            logger.info("Merge-import replaced \(dropped) overlapped live segment(s) in meeting \(meeting.id)")
        }
        return dropped
    }

    /// The text twin of `mergeTranscriptFile` ([Google Phase 2 · M1], D-D4): parse raw transcript
    /// text and merge it into `meeting`, for callers that already hold the content in memory (the
    /// Drive importer's `files.export` result). Same overlap policy (`ImportOverlapPlan`): a timed
    /// import is authoritative for its covered span, so overlapped live rows are dropped and the
    /// count returned. Throws `.emptyTranscript` when nothing parseable is found.
    @discardableResult
    func mergeTranscriptText(_ text: String, into meeting: Meeting) throws -> Int {
        let segments = TranscriptFileParser.parse(text)
        guard !segments.isEmpty else { throw ImportError.emptyTranscript }
        let dropped = meetingService.mergeImport(into: meeting, segments: segments, source: .importedTranscript)
        if dropped > 0 {
            logger.info("Merge-import replaced \(dropped) overlapped live segment(s) in meeting \(meeting.id)")
        }
        return dropped
    }

    // MARK: - Superseding a summary-shaped import (Drive repair)

    /// Value shape of one existing segment for the supersede decision — plain values so the rule is
    /// unit-testable without SwiftData (the `SpeakerSourcePlan` / `ImportOverlapPlan` pattern).
    struct ExistingSegmentShape: Equatable, Sendable {
        var start: Double
        var end: Double
        var source: MeetingSegmentSource

        init(start: Double, end: Double, source: MeetingSegmentSource) {
            self.start = start
            self.end = end
            self.source = source
        }
    }

    /// Whether exported Drive content is a *transcript* rather than Gemini's meeting-notes summary.
    ///
    /// This is the discriminator the Drive importer needs and the filename cannot give it: Meet names
    /// the doc `… - Notas de Gemini` whether or not Gemini appended the transcript, so the only
    /// reliable signal is what the parse actually recovered. A real Meet/Gemini transcript carries
    /// `### **HH:MM:SS**` section headers, which `TranscriptFileParser.parseGeminiNotes` turns into
    /// non-zero start times; a summary ("📝 Las notas", "Resumen", "Decisiones") has no timestamps
    /// anywhere, so it falls through to the plain-paragraph rung and lands as all-zero segments.
    ///
    /// Requiring timing is deliberately stricter than "parsed to something": importing a summary as a
    /// transcript is silent corruption that reads plausibly, which is far worse than importing
    /// nothing and leaving the doc for a later pass.
    nonisolated static func carriesRecoverableTiming(_ segments: [TranscriptionSegment]) -> Bool {
        segments.contains { $0.start > 0 || $0.end > 0 }
    }

    /// Whether a freshly parsed transcript should **replace** a meeting's existing transcript rows
    /// instead of merging alongside them.
    ///
    /// This exists for one specific, self-healing repair. Drive discovery used to import Meet's
    /// `… - Notas de Gemini` doc — a *summary* — as if it were the transcript; those imports land as
    /// `.importedTranscript` rows with no timing at all, because the summary has no timestamps to
    /// recover. `ImportOverlapPlan` deliberately never drops `.importedTranscript` rows ("they were
    /// reconciled by their own earlier merge"), so importing the real transcript into one of those
    /// meetings would interleave the summary bullets through the real turns rather than fix anything.
    ///
    /// The rule is deliberately narrow, because replacing content is destructive:
    ///   • every existing row is `.importedTranscript` — never touch live-captured or audio-imported
    ///     content, which the overlap plan already reconciles correctly;
    ///   • every existing row is untimed (`start == end == 0`) — a real transcript import always
    ///     carries timing, so this shape is only ever produced by the summary bug;
    ///   • the incoming transcript *does* carry timing — otherwise there is nothing better to put in
    ///     its place, and merging is still the safer move.
    /// Anything outside that shape merges exactly as before.
    static func supersedesUntimedImport(
        existing: [ExistingSegmentShape],
        imported: [TranscriptionSegment]
    ) -> Bool {
        guard !existing.isEmpty else { return false }
        guard existing.allSatisfy({ $0.source == .importedTranscript && $0.start == 0 && $0.end == 0 })
        else { return false }
        return imported.contains { $0.start > 0 || $0.end > 0 }
    }

    /// The Drive importer's write step: `mergeTranscriptText`, except that a timed transcript landing
    /// on a summary-shaped import (see `supersedesUntimedImport`) replaces it. Returns the number of
    /// existing rows dropped — overlapped live rows on the merge path, superseded summary rows on the
    /// replace path — so the caller's log line means the same thing either way.
    @discardableResult
    func mergeOrSupersedeTranscriptText(_ text: String, into meeting: Meeting) throws -> Int {
        let segments = TranscriptFileParser.parse(text)
        guard !segments.isEmpty else { throw ImportError.emptyTranscript }

        let existing = meeting.segments.map {
            ExistingSegmentShape(start: $0.start, end: $0.end, source: $0.source)
        }
        guard Self.supersedesUntimedImport(existing: existing, imported: segments) else {
            return try mergeTranscriptText(text, into: meeting)
        }

        let superseded = existing.count
        meetingService.replaceSegments(of: meeting, source: .importedTranscript, with: segments)
        logger.info(
            "Superseded \(superseded) untimed imported segment(s) in meeting \(meeting.id) with a timed transcript"
        )
        return superseded
    }

    // MARK: - Helpers

    private func parseTranscriptFile(at url: URL) throws -> [TranscriptionSegment] {
        guard TranscriptFileParser.supportedExtensions.contains(url.pathExtension.lowercased()) else {
            throw ImportError.unsupportedTranscriptFile
        }
        let raw: String
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) {
            raw = utf8
        } else if let latin1 = try? String(contentsOf: url, encoding: .isoLatin1) {
            raw = latin1
        } else {
            throw ImportError.unreadableTranscriptFile
        }
        let segments = TranscriptFileParser.parse(raw)
        guard !segments.isEmpty else { throw ImportError.emptyTranscript }
        return segments
    }

    /// Derive the title from the explicit argument, else the file name (sans extension), else a
    /// localized default.
    private func resolvedTitle(_ title: String?, fallbackFileName url: URL) -> String {
        resolvedTitleAndDate(title, fallbackFileName: url).title
    }

    /// [Sprint 3] Derive the title AND an embedded start date from an export filename. A user-typed
    /// title is never normalized; a filename fallback goes through `ImportedMeetingTitle` so Gemini
    /// exports ("Weekly sync - 2026_07_07 11_00 CST - Notas de Gemini (1)") land with a clean title
    /// and the meeting dated when it actually happened.
    private func resolvedTitleAndDate(_ title: String?, fallbackFileName url: URL) -> (title: String, startDate: Date?) {
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return (title, nil)
        }
        let base = url.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else {
            return (String(localized: "meetings.import.defaultTitle"), nil)
        }
        let parsed = ImportedMeetingTitle.parse(base)
        return (parsed.cleanTitle, parsed.date)
    }

    /// Derive the title for a raw-text import from the explicit argument, else the localized default
    /// (raw text has no file name to fall back to).
    private func resolvedTitle(_ title: String?, fallbackText: String) -> String {
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        return String(localized: "meetings.import.defaultTitle")
    }

    /// Copy the source audio to a temp file so `MeetingService.adoptAudioFile` (which moves) can
    /// adopt it without disturbing the user's original. Returns nil on failure (the meeting is still
    /// created, just without adopted audio).
    private func stagedCopy(of url: URL) -> URL? {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-import-\(UUID().uuidString).\(url.pathExtension)")
        do {
            try FileManager.default.copyItem(at: url, to: temp)
            return temp
        } catch {
            logger.error("Failed to stage imported audio copy: \(error.localizedDescription)")
            return nil
        }
    }
}
