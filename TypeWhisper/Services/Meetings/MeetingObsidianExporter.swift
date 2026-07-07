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
    private let fileManager = FileManager.default

    init(vaultService: ObsidianVaultService) {
        self.vaultService = vaultService
    }

    /// Export the selected sections of `meeting` to the connected vault. When `combined` is true a
    /// single note holds every non-empty section; otherwise one note is written per non-empty
    /// section. Empty sections (e.g. a not-yet-generated summary) are skipped. Returns the URLs of
    /// the files written (never overwriting existing notes — see `uniquePath`).
    @discardableResult
    func export(_ meeting: Meeting, sections: [MeetingExportSection], combined: Bool) throws -> [URL] {
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
        do {
            try fileManager.createDirectory(atPath: folderPath, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create export folder: \(error.localizedDescription)")
            throw MeetingExportError.writeFailed(error.localizedDescription)
        }

        let frontmatter = buildFrontmatter(for: meeting)
        let baseName = sanitizedBaseName(for: meeting)
        var written: [URL] = []

        if combined {
            var body = "# \(meeting.title)\n"
            for item in rendered {
                body += "\n## \(item.section.displayName)\n\n\(item.content)\n"
            }
            written.append(try writeNote(frontmatter: frontmatter, body: body, folderPath: folderPath, filename: baseName))
        } else {
            for item in rendered {
                let body = "# \(meeting.title) — \(item.section.displayName)\n\n\(item.content)\n"
                let filename = "\(baseName) - \(item.section.filenameSuffix)"
                written.append(try writeNote(frontmatter: frontmatter, body: body, folderPath: folderPath, filename: filename))
            }
        }
        return written
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
            .map { "- **\(Self.timestamp($0.start))** \(Self.displayText(for: $0, speakerMap: speakerMap))" }
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

    /// The absolute folder the meeting's notes are written into: the vault root, plus the meeting's
    /// per-meeting `obsidianFolder` (each path component sanitized; nested subfolders allowed).
    private func resolveFolderPath(vaultPath: String, meeting: Meeting) -> String {
        let folder = (meeting.obsidianFolder ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !folder.isEmpty else { return vaultPath }
        var path = vaultPath
        for component in folder.split(separator: "/") {
            let safe = sanitizeFilename(String(component))
            guard !safe.isEmpty else { continue }
            path = (path as NSString).appendingPathComponent(safe)
        }
        return path
    }

    private func sanitizedBaseName(for meeting: Meeting) -> String {
        let sanitized = sanitizeFilename(meeting.title)
        return sanitized.isEmpty ? "Meeting" : sanitized
    }

    private func writeNote(frontmatter: String, body: String, folderPath: String, filename: String) throws -> URL {
        let safe = filename.isEmpty ? "Meeting" : filename
        let filePath = (folderPath as NSString).appendingPathComponent("\(safe).md")
        let finalPath = uniquePath(for: filePath)
        let content = "\(frontmatter)\n\n\(body)"
        do {
            try content.write(toFile: finalPath, atomically: true, encoding: .utf8)
        } catch {
            logger.error("Failed to write meeting note: \(error.localizedDescription)")
            throw MeetingExportError.writeFailed(error.localizedDescription)
        }
        return URL(fileURLWithPath: finalPath)
    }

    /// Strip characters illegal in a filename (mirrors `ObsidianPlugin.sanitizeFilename`).
    private func sanitizeFilename(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/:\\*?\"<>|")
        return name.components(separatedBy: illegal).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Return `path` if free, else `<name> 1.<ext>`, `<name> 2.<ext>`, … (mirrors
    /// `ObsidianPlugin.uniquePath`) so an existing note is never overwritten.
    private func uniquePath(for path: String) -> String {
        guard fileManager.fileExists(atPath: path) else { return path }
        let dir = (path as NSString).deletingLastPathComponent
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let ext = (path as NSString).pathExtension
        var counter = 1
        while true {
            let candidate = (dir as NSString).appendingPathComponent("\(name) \(counter).\(ext)")
            if !fileManager.fileExists(atPath: candidate) {
                return candidate
            }
            counter += 1
        }
    }
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
