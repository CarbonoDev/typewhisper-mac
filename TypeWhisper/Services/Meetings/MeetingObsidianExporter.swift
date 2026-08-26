import Foundation
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "MeetingObsidianExporter")

/// A selectable portion of a meeting that can be exported to the vault (plan M7). Each maps either
/// to a persisted LLM output (`brief`/`summary`/`extended`) or to a rendered part of the meeting
/// (`transcript`/`notes`).
enum MeetingExportSection: String, CaseIterable, Identifiable, Codable, Sendable {
    case brief
    case summary
    case extended
    case transcript
    case notes

    var id: String { rawValue }

    /// Localized label, used both as the UI toggle title and as the section heading / filename
    /// suffix in the exported markdown.
    var displayName: String {
        switch self {
        case .brief: return String(localized: "meetings.export.section.brief")
        case .summary: return String(localized: "meetings.export.section.summary")
        case .extended: return String(localized: "meetings.export.section.extended")
        case .transcript: return String(localized: "meetings.export.section.transcript")
        case .notes: return String(localized: "meetings.export.section.notes")
        }
    }

    /// Language-independent suffix used in separate-note filenames (e.g. "Acme Sync - Summary.md").
    /// Kept stable across UI languages — unlike `displayName`, which localizes — so exported filenames
    /// don't drift by locale. Derived from `rawValue`, which contains no illegal filename characters.
    var filenameSuffix: String { rawValue.capitalized }
}

/// First-party core exporter (plan D9/M7): writes a meeting's outputs / transcript / notes into the
/// connected Obsidian vault as markdown with YAML frontmatter, in a per-meeting folder, either as a
/// single combined note or one note per selected section. The `ObsidianPlugin` bundle is untouched;
/// its `private` sanitize / frontmatter / unique-path helpers are re-implemented here. The vault
/// path is read from `ObsidianVaultService` (no second vault picker).
@MainActor
final class MeetingObsidianExporter: ObservableObject {
    private let vaultService: ObsidianVaultService
    private let defaults: UserDefaults

    init(vaultService: ObsidianVaultService, defaults: UserDefaults = .standard) {
        self.vaultService = vaultService
        self.defaults = defaults
    }

    /// Export the selected sections of `meeting` to the connected vault. When `combined` is true a
    /// single note holds every non-empty section; otherwise one note is written per non-empty
    /// section. Empty sections (e.g. a not-yet-generated summary) are skipped. Returns the URLs of
    /// the files written (never overwriting existing notes — see `uniquePath`).
    ///
    /// Synchronous: renders and writes on the caller's actor (the MainActor). Used by the single
    /// export sheet and the tests. Bulk io-lane jobs use `exportOffMain`, which keeps the file I/O
    /// off the main thread.
    @discardableResult
    func export(_ meeting: Meeting, sections: [MeetingExportSection], combined: Bool) throws -> [URL] {
        let plan = try makePlan(for: meeting, sections: sections, combined: combined)
        return try Self.write(plan)
    }

    /// Off-main variant of `export`: render the meeting into a `Sendable` `ExportPlan` on the
    /// MainActor (SwiftData `Meeting` is non-Sendable, so all model access stays here), then perform
    /// the `createDirectory`/`write` file I/O on a detached task. The `await` is a real suspension
    /// point, so the unbounded `io` lane's bulk `.export` jobs actually overlap on disk instead of
    /// serializing file writes on the main thread (plan LX-2 D6 / review finding). Resumes on the
    /// MainActor for the caller to record the export.
    @discardableResult
    func exportOffMain(_ meeting: Meeting, sections: [MeetingExportSection], combined: Bool) async throws -> [URL] {
        let plan = try makePlan(for: meeting, sections: sections, combined: combined)
        return try await Task.detached { try Self.write(plan) }.value
    }

    /// Render (on the MainActor) the meeting's selected, non-empty sections into a `Sendable` plan of
    /// pre-built frontmatter/bodies/filenames plus the target folder — everything the off-main write
    /// phase needs without touching the `Meeting` model again.
    private func makePlan(
        for meeting: Meeting,
        sections: [MeetingExportSection],
        combined: Bool
    ) throws -> ExportPlan {
        guard let vaultPath = vaultService.vaultPath, !vaultPath.isEmpty else {
            throw MeetingExportError.noVaultConnected
        }
        // Deduplicate and restore a stable section order regardless of selection order.
        let selected = MeetingExportSection.allCases.filter { sections.contains($0) }
        guard !selected.isEmpty else { throw MeetingExportError.noSectionsSelected }

        // Only sections that actually have content produce files.
        let rendered: [(section: MeetingExportSection, content: String)] = selected.compactMap { section in
            let content = renderSection(section, for: meeting).trimmingCharacters(in: .whitespacesAndNewlines)
            return content.isEmpty ? nil : (section, content)
        }
        guard !rendered.isEmpty else { throw MeetingExportError.noContent }

        let folderPath = resolveFolderPath(vaultPath: vaultPath, meeting: meeting)
        let frontmatter = buildFrontmatter(for: meeting)
        let baseName = sanitizedBaseName(for: meeting)
        var notes: [ExportPlan.Note] = []

        if combined {
            var body = "# \(meeting.title)\n"
            for item in rendered {
                body += "\n## \(item.section.displayName)\n\n\(item.content)\n"
            }
            notes.append(ExportPlan.Note(filename: baseName, body: body))
        } else {
            for item in rendered {
                let body = "# \(meeting.title) — \(item.section.displayName)\n\n\(item.content)\n"
                let filename = "\(baseName) - \(item.section.filenameSuffix)"
                notes.append(ExportPlan.Note(filename: filename, body: body))
            }
        }
        return ExportPlan(folderPath: folderPath, frontmatter: frontmatter, notes: notes)
    }

    /// The off-main (nonisolated) write phase: create the target folder and write each planned note,
    /// never overwriting an existing file. Delegates to the shared `VaultNoteWriter` (Track E, ME-3) —
    /// the same never-clobber discipline Space's quick-note uses — so there is exactly one write
    /// implementation; `VaultWriteError` is mapped to the exporter's own error. Operates only on the
    /// `Sendable` plan — no `Meeting` access — so it is safe to run on a detached task.
    nonisolated private static func write(_ plan: ExportPlan) throws -> [URL] {
        do {
            var written: [URL] = []
            for note in plan.notes {
                let content = "\(plan.frontmatter)\n\n\(note.body)"
                written.append(try VaultNoteWriter.write(
                    content: content,
                    toFolder: plan.folderPath,
                    filename: note.filename
                ))
            }
            return written
        } catch let error as VaultWriteError {
            logger.error("Failed to write meeting note: \(error.localizedDescription)")
            throw MeetingExportError.writeFailed(error.localizedDescription)
        }
    }

    // MARK: - Section rendering

    private func renderSection(_ section: MeetingExportSection, for meeting: Meeting) -> String {
        switch section {
        case .brief: return latestOutput(ofKind: .brief, for: meeting)
        case .summary: return latestOutput(ofKind: .summary, for: meeting)
        case .extended: return latestOutput(ofKind: .extended, for: meeting)
        case .transcript: return renderTranscript(meeting)
        case .notes: return renderNotes(meeting)
        }
    }

    /// The newest output of a kind (what the detail view surfaces), read directly off the meeting.
    private func latestOutput(ofKind kind: MeetingOutputKind, for meeting: Meeting) -> String {
        meeting.outputs
            .filter { $0.kind == kind }
            .max { $0.createdAt < $1.createdAt }?
            .content ?? ""
    }

    /// A markdown bullet list of the transcript in chronological order, `SubtitleExporter`-style:
    /// each line is prefixed with a `MM:SS` timestamp and the speaker label when one is present.
    private func renderTranscript(_ meeting: Meeting) -> String {
        let segments = meeting.segments.sorted { $0.order < $1.order }
        guard !segments.isEmpty else { return "" }
        let speakerMap = meeting.speakerMap
        return segments
            .map { segment in
                // Tag merged-in imported content so exported transcripts keep live vs. imported
                // sources distinguishable (M8), mirroring the detail view's badge.
                let marker = segment.source != .liveCapture
                    ? " _(\(String(localized: "meetings.export.importedTag")))_"
                    : ""
                return "- **\(Self.timestamp(segment.start))**\(marker) \(Self.displayText(for: segment, speakerMap: speakerMap))"
            }
            .joined(separator: "\n")
    }

    private func renderNotes(_ meeting: Meeting) -> String {
        let notes = meeting.notes.sorted { $0.createdAt < $1.createdAt }
        guard !notes.isEmpty else { return "" }
        return notes
            .map { note in
                if let offset = note.timestampOffset {
                    return "- **\(Self.timestamp(offset))** \(note.text)"
                }
                return "- \(note.text)"
            }
            .joined(separator: "\n")
    }

    /// Mirrors `SubtitleExporter.displayText`: prefix the segment with its speaker when present (and
    /// not already prefixed). The raw `SPEAKER_xx` label is resolved through the meeting's speaker map
    /// so mapped attendee names are exported (plan M9); an unmapped label falls back to itself.
    private static func displayText(for segment: MeetingSegment, speakerMap: [String: String]) -> String {
        guard let rawLabel = segment.speakerLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawLabel.isEmpty else {
            return segment.text
        }
        let speaker = speakerMap[rawLabel].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 } ?? rawLabel
        if segment.text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("\(speaker):") {
            return segment.text
        }
        return "\(speaker): \(segment.text)"
    }

    private static func timestamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    // MARK: - Frontmatter

    /// Build the YAML frontmatter block for a meeting (title, date, attendees, series, tags),
    /// mirroring `ObsidianPlugin.buildFrontmatter`'s shape.
    private func buildFrontmatter(for meeting: Meeting) -> String {
        var lines = ["---"]
        lines.append("title: \(yamlScalar(meeting.title))")
        // The Space↔meeting bridge key (Track E, D2): a stable meeting UUID that lets a Space note
        // resolve back to its meeting ("Open meeting") and the meeting reveal back to its Space folder.
        // Emitted only on new/re-exports — existing notes are never rewritten to backfill it.
        lines.append("typewhisper-meeting: \(yamlScalar(meeting.id.uuidString))")

        let date = meeting.startDate ?? meeting.createdAt
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        lines.append("date: \(formatter.string(from: date))")

        let attendees = meeting.attendees.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        if !attendees.isEmpty {
            lines.append("attendees:")
            for attendee in attendees {
                let display: String
                if let email = attendee.email, !email.isEmpty {
                    display = "\(attendee.name) <\(email)>"
                } else {
                    display = attendee.name
                }
                lines.append("  - \(yamlScalar(display))")
            }
        }

        if let series = meeting.seriesID, !series.isEmpty {
            lines.append("series: \(yamlScalar(series))")
        }

        if let language = meeting.languageCode?.trimmingCharacters(in: .whitespacesAndNewlines),
           !language.isEmpty {
            lines.append("language: \(yamlScalar(language))")
        }

        let tags = meeting.obsidianTags
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if !tags.isEmpty {
            lines.append("tags:")
            for tag in tags {
                lines.append("  - \(yamlScalar(tag))")
            }
        }

        lines.append("---")
        return lines.joined(separator: "\n")
    }

    /// Double-quote a YAML scalar only when it would otherwise be misparsed. YAML indicator
    /// characters are special only at the *start* of a plain scalar (so a mid-string `@` in an
    /// email address, or `<...>` around it, stays unquoted); the `": "` and `" #"` sequences and a
    /// trailing `:` are ambiguous anywhere; leading/trailing spaces and embedded quotes force
    /// quoting too.
    private func yamlScalar(_ value: String) -> String {
        let indicatorStarts = Set("-?:,[]{}#&*!|>'\"%@`")
        let needsQuote: Bool = {
            if value.isEmpty { return true }
            if value.first == " " || value.last == " " { return true }
            if let first = value.first, indicatorStarts.contains(first) { return true }
            if value.contains(": ") || value.contains(" #") { return true }
            if value.contains("\"") { return true }
            if value.hasSuffix(":") { return true }
            return false
        }()
        guard needsQuote else { return value }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    // MARK: - Paths

    /// The absolute folder the meeting's notes are written into: the vault root, plus the configured
    /// **meetings root folder** (plan D7/M4, default `"Meetings"`; empty collapses to today's
    /// behavior — the escape hatch), plus the meeting's per-meeting `obsidianFolder`. Every path
    /// component is sanitized; nested subfolders are allowed. The uniform root-prepend (Decision 8)
    /// means a meeting previously exported to `<vault>/Acme` writes, on its next export, under
    /// `<vault>/Meetings/Acme` — old notes are untouched (`uniquePath` never overwrites).
    private func resolveFolderPath(vaultPath: String, meeting: Meeting) -> String {
        var path = vaultPath
        let root = (defaults.string(forKey: UserDefaultsKeys.meetingsObsidianRootFolder) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = (meeting.obsidianFolder ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        for segment in [root, folder] {
            for component in segment.split(separator: "/") {
                let safe = VaultNoteWriter.sanitizeFilename(String(component))
                guard !safe.isEmpty else { continue }
                path = (path as NSString).appendingPathComponent(safe)
            }
        }
        return path
    }

    private func sanitizedBaseName(for meeting: Meeting) -> String {
        let sanitized = VaultNoteWriter.sanitizeFilename(meeting.title)
        return sanitized.isEmpty ? "Meeting" : sanitized
    }
}

/// The `Sendable` result of the MainActor render phase: everything the off-main write phase needs to
/// create files, with no reference to the non-Sendable `Meeting` model. Lets bulk io-lane exports
/// hand file I/O to a detached task (plan LX-2 D6).
private struct ExportPlan: Sendable {
    /// A single note to write: its filename base (no extension) and pre-rendered body.
    struct Note: Sendable {
        let filename: String
        let body: String
    }

    /// Absolute folder the notes are written into (created if needed).
    let folderPath: String
    /// Shared YAML frontmatter block prepended to every note.
    let frontmatter: String
    /// One entry per non-empty section (or a single combined note).
    let notes: [Note]
}

enum MeetingExportError: LocalizedError, Equatable {
    /// No Obsidian vault is connected (nothing to export into).
    case noVaultConnected
    /// The caller selected no sections to export.
    case noSectionsSelected
    /// Every selected section is empty (e.g. no outputs generated and no transcript/notes).
    case noContent
    /// Writing to the vault failed (permissions, disk, …).
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVaultConnected:
            return String(localized: "meetings.export.error.noVault")
        case .noSectionsSelected:
            return String(localized: "meetings.export.error.noSections")
        case .noContent:
            return String(localized: "meetings.export.error.noContent")
        case .writeFailed(let message):
            return String(format: String(localized: "meetings.export.error.writeFailed"), message)
        }
    }
}
