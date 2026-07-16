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
        let meeting = meetingService.createFromImport(
            title: resolvedTitle(title, fallbackFileName: url),
            source: .importedTranscript,
            segments: segments,
            segmentSource: .importedTranscript
        )
        return meeting
    }

    /// Parse raw transcript **text** (not a file) into a new `.importedTranscript` meeting. Same
    /// parser as `importTranscriptFile`, for callers that already hold the transcript in memory (the
    /// HTTP API's raw-text body / bulk archive import). Throws `.emptyTranscript` when nothing
    /// parseable is found.
    @discardableResult
    func importTranscriptText(_ text: String, title: String? = nil) throws -> Meeting {
        let segments = TranscriptFileParser.parse(text)
        guard !segments.isEmpty else { throw ImportError.emptyTranscript }
        return meetingService.createFromImport(
            title: resolvedTitle(title, fallbackText: text),
            source: .importedTranscript,
            segments: segments,
            segmentSource: .importedTranscript
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
        let meeting = meetingService.createFromImport(
            title: resolvedTitle(title, fallbackFileName: url),
            source: .importedAudio,
            segments: result.segments,
            segmentSource: .importedAudio,
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
    /// the overlap with already-captured content (plan D12).
    func mergeTranscriptFile(at url: URL, into meeting: Meeting) throws {
        let segments = try parseTranscriptFile(at: url)
        meetingService.mergeImport(into: meeting, segments: segments, source: .importedTranscript)
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
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        let base = url.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !base.isEmpty { return base }
        return String(localized: "meetings.import.defaultTitle")
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
