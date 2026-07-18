import Foundation

/// Pure, SwiftUI-free helpers for Track E's meeting↔Space bridge (ME-2). Kept a static surface (like
/// `SpaceSelection`) so both bridge decisions — "Reveal in Space" on a meeting document and "Open
/// meeting" on a Space note — are unit-testable without the views, coordinator, or a live vault.
enum SpaceReveal {
    /// The **folder-precise** "Reveal in Space" route for an exported meeting (D2/V11). `nil` when the
    /// meeting was never exported (`hasExported == false`) — the gate the overflow item honors, so the
    /// item is absent rather than dead. The payload is the **vault-relative** Space folder: the
    /// sanitized meetings root joined with the meeting's sanitized folder components, mirroring
    /// `MeetingObsidianExporter.resolveFolderPath` so the reveal lands 1:1 on the aligned Space node
    /// (note-precise reveal is deferred, owner-veto 7). An empty root + no folder yields
    /// `.spaceFolder("")` — the Space root — matching an export written at the vault root.
    static func route(rootFolder: String, meetingFolder: String?, hasExported: Bool) -> MainWindowRoute? {
        guard hasExported else { return nil }
        let components = [rootFolder, meetingFolder ?? ""]
            .flatMap { segment in segment.split(separator: "/").map { sanitize(String($0)) } }
            .filter { !$0.isEmpty }
        return .spaceFolder(components.joined(separator: "/"))
    }

    /// Resolve a Space note's parsed `typewhisper-meeting` backlink to an **existing** meeting id, or
    /// `nil` (D2). The pure seam behind the "Open meeting" quiet row: an absent field (`uuid == nil`)
    /// or an unknown UUID (not in `existingMeetingIDs`) both yield `nil`, so the row appears only when
    /// the backlink truly resolves — never an error state, per the tolerant-parsing rule.
    static func linkedMeeting(uuid: UUID?, existingMeetingIDs: Set<UUID>) -> UUID? {
        guard let uuid, existingMeetingIDs.contains(uuid) else { return nil }
        return uuid
    }

    /// Strip characters illegal in a filename, mirroring `MeetingObsidianExporter.sanitizeFilename`, so
    /// a revealed path matches the folder the exporter actually wrote.
    static func sanitize(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/:\\*?\"<>|")
        return name.components(separatedBy: illegal).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
