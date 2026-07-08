import Foundation
import SwiftData

/// Root aggregate of the Meetings feature. One `Meeting` owns its transcript segments,
/// notes, generated outputs, and Q&A turns via cascade relationships, all in a single
/// `meetings.store`.
///
/// Schema discipline (see plan D4/D5): every field is optional or defaulted and attendees
/// / speaker maps are Codable JSON columns rather than child models, so the schema shape
/// never changes after M1 (the store is destructively reset on incompatibility).
@Model
final class Meeting {
    @Attribute(.unique) var id: UUID
    var title: String
    var stateRaw: String
    var sourceRaw: String
    var startDate: Date?
    var endDate: Date?
    var calendarEventID: String?
    var seriesID: String?
    /// JSON-encoded `[Attendee]` (see `attendees`).
    var attendeesJSON: String?
    /// JSON-encoded `[String: String]` mapping `SPEAKER_xx` → attendee name (see `speakerMap`).
    var speakerMapJSON: String?
    var audioFileName: String?
    /// JSON-encoded per-meeting `FinalRetranscriptionPolicy` override (addendum AD8, additive;
    /// nil = inherit the matched rule / global default / `.sameEngine`).
    var finalRetranscriptionRaw: String?
    var notesIncludedInOutputs: Bool
    /// The meeting's spoken/output language as a BCP-47 / ISO-639-1 code, lowercased ("en", "de",
    /// "pt-br"); `nil` = unset (plan D1, additive). Read on hot paths — engine config, every LLM
    /// call, export frontmatter — so it is a directly-queryable column, not a JSON blob.
    var languageCode: String?
    /// How `languageCode` was decided: `"manual" | "rule" | "detected"` (see
    /// `MeetingLanguageProvenance`). `nil` whenever `languageCode` is `nil`. Additive column;
    /// written only by the single-writer setters on `MeetingService`.
    var languageProvenanceRaw: String?
    var obsidianFolder: String?
    /// JSON-encoded `[String]` (see `obsidianTags`).
    var obsidianTagsJSON: String?
    /// Timestamp of the most recent successful Obsidian vault export (additive, AD/M-review).
    /// `nil` until the meeting has actually been exported at least once; this is the source of truth
    /// for the "In vault" badge (never the mere presence of an `obsidianFolder` path).
    var lastObsidianExportAt: Date?
    /// JSON-encoded `[RelatedNote]` — the per-meeting explicit related vault notes *beyond* folder
    /// scope: judge-kept wider-vault suggestions (`discovered`) and user picks (`manual`) (Amendment 2,
    /// DB4). Additive/optional ⇒ no migration. Folder-attached notes are NOT stored here (they stay
    /// live folder scope, DB5). Written only by the single-writer setters on `MeetingService`.
    var relatedNotePathsJSON: String?
    /// JSON-encoded `[String]` of vault-relative paths the user removed (Amendment 2, DB4). A removal
    /// suppresses a path **everywhere** (curated *and* folder-derived) so it "never resurrects."
    var excludedNotePathsJSON: String?
    /// Timestamp of the last successful related-docs discovery run (Amendment 2, DB4); backs the
    /// auto-trigger freshness gate (DB6). `nil` until discovery has succeeded at least once.
    var relatedDiscoveryAt: Date?
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \MeetingSegment.meeting)
    var segments: [MeetingSegment]

    @Relationship(deleteRule: .cascade, inverse: \MeetingNote.meeting)
    var notes: [MeetingNote]

    @Relationship(deleteRule: .cascade, inverse: \MeetingOutput.meeting)
    var outputs: [MeetingOutput]

    @Relationship(deleteRule: .cascade, inverse: \MeetingQATurn.meeting)
    var qaTurns: [MeetingQATurn]

    init(
        id: UUID = UUID(),
        title: String,
        state: MeetingState = .scheduled,
        source: MeetingSource = .adHoc,
        startDate: Date? = nil,
        endDate: Date? = nil,
        calendarEventID: String? = nil,
        seriesID: String? = nil,
        attendeesJSON: String? = nil,
        speakerMapJSON: String? = nil,
        audioFileName: String? = nil,
        finalRetranscriptionRaw: String? = nil,
        notesIncludedInOutputs: Bool = true,
        languageCode: String? = nil,
        languageProvenanceRaw: String? = nil,
        obsidianFolder: String? = nil,
        obsidianTagsJSON: String? = nil,
        lastObsidianExportAt: Date? = nil,
        relatedNotePathsJSON: String? = nil,
        excludedNotePathsJSON: String? = nil,
        relatedDiscoveryAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.stateRaw = state.rawValue
        self.sourceRaw = source.rawValue
        self.startDate = startDate
        self.endDate = endDate
        self.calendarEventID = calendarEventID
        self.seriesID = seriesID
        self.attendeesJSON = attendeesJSON
        self.speakerMapJSON = speakerMapJSON
        self.audioFileName = audioFileName
        self.finalRetranscriptionRaw = finalRetranscriptionRaw
        self.notesIncludedInOutputs = notesIncludedInOutputs
        self.languageCode = languageCode
        self.languageProvenanceRaw = languageProvenanceRaw
        self.obsidianFolder = obsidianFolder
        self.obsidianTagsJSON = obsidianTagsJSON
        self.lastObsidianExportAt = lastObsidianExportAt
        self.relatedNotePathsJSON = relatedNotePathsJSON
        self.excludedNotePathsJSON = excludedNotePathsJSON
        self.relatedDiscoveryAt = relatedDiscoveryAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.segments = []
        self.notes = []
        self.outputs = []
        self.qaTurns = []
    }

    // MARK: - Enum accessors

    var state: MeetingState {
        get { MeetingState(rawValue: stateRaw) ?? .scheduled }
        set { stateRaw = newValue.rawValue }
    }

    var source: MeetingSource {
        get { MeetingSource(rawValue: sourceRaw) ?? .adHoc }
        set { sourceRaw = newValue.rawValue }
    }

    /// How `languageCode` was decided (plan D1). `nil` when no language is set; otherwise decoded
    /// from `languageProvenanceRaw`. Never written directly by call sites — the `MeetingService`
    /// setters own the ladder.
    var languageProvenance: MeetingLanguageProvenance? {
        get {
            guard let languageProvenanceRaw else { return nil }
            return MeetingLanguageProvenance(rawValue: languageProvenanceRaw)
        }
        set { languageProvenanceRaw = newValue?.rawValue }
    }

    // MARK: - JSON column accessors

    var attendees: [Attendee] {
        get { Meeting.decode([Attendee].self, from: attendeesJSON) ?? [] }
        set { attendeesJSON = Meeting.encode(newValue) }
    }

    var speakerMap: [String: String] {
        get { Meeting.decode([String: String].self, from: speakerMapJSON) ?? [:] }
        set { speakerMapJSON = Meeting.encode(newValue) }
    }

    var obsidianTags: [String] {
        get { Meeting.decode([String].self, from: obsidianTagsJSON) ?? [] }
        set { obsidianTagsJSON = Meeting.encode(newValue) }
    }

    /// First-party alias over the canonical `obsidianTags` store (plan D6, M3). A **computed forward**
    /// — zero schema delta, since renaming the stored property would be a non-additive schema change.
    /// Obsidian export keeps reading `obsidianTags` unchanged; first-party tag surfaces read/write
    /// `tags`.
    var tags: [String] {
        get { obsidianTags }
        set { obsidianTags = newValue }
    }

    /// First-party alias over the canonical `obsidianFolder` store (plan D7, M4). A **computed
    /// forward** — zero schema delta (renaming the stored property would be a non-additive schema
    /// change). A single `/`-separated vertical path; `nil`/empty = "Unfiled". Obsidian export keeps
    /// reading `obsidianFolder`; first-party folder surfaces read/write `folderPath`.
    var folderPath: String? {
        get { obsidianFolder }
        set { obsidianFolder = newValue }
    }

    /// Per-meeting final re-transcription override (addendum AD8). `nil` = inherit.
    var finalRetranscriptionPolicy: FinalRetranscriptionPolicy? {
        get { FinalRetranscriptionPolicy(jsonString: finalRetranscriptionRaw) }
        set { finalRetranscriptionRaw = newValue?.jsonString }
    }

    /// The per-meeting curated related notes beyond folder scope (Amendment 2, DB4): `discovered`
    /// (judge-kept) and `manual` (user picks). Never written directly by call sites — the
    /// `MeetingService` single-writer setters own the provenance rules.
    var relatedNotePaths: [RelatedNote] {
        get { Meeting.decode([RelatedNote].self, from: relatedNotePathsJSON) ?? [] }
        set { relatedNotePathsJSON = Meeting.encode(newValue) }
    }

    /// Vault-relative paths the user removed (Amendment 2, DB4). A removal suppresses a path
    /// everywhere and is never resurrected by a later discovery run.
    var excludedNotePaths: [String] {
        get { Meeting.decode([String].self, from: excludedNotePathsJSON) ?? [] }
        set { excludedNotePathsJSON = Meeting.encode(newValue) }
    }

    // MARK: - Codable helpers

    static func encode<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode<T: Decodable>(_ type: T.Type, from json: String?) -> T? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

/// One per-meeting curated related note (Amendment 2, DB4). Persisted as a `[RelatedNote]` JSON blob
/// on `Meeting.relatedNotePathsJSON`. `provenanceRaw` is stored (not the enum) so an unknown value
/// decoded from a future version degrades to `nil` rather than failing the whole decode.
struct RelatedNote: Codable, Equatable, Sendable {
    /// Vault-relative `.md` path.
    var path: String
    /// `"discovered"` (judge-kept wider-vault suggestion) or `"manual"` (user pick).
    var provenanceRaw: String

    init(path: String, provenanceRaw: String) {
        self.path = path
        self.provenanceRaw = provenanceRaw
    }

    init(path: String, provenance: RelatedNoteProvenance) {
        self.path = path
        self.provenanceRaw = provenance.rawValue
    }

    var provenance: RelatedNoteProvenance? {
        RelatedNoteProvenance(rawValue: provenanceRaw)
    }
}

/// How a `RelatedNote` entered the per-meeting set (Amendment 2, DB4).
enum RelatedNoteProvenance: String, Sendable {
    /// Kept by the LLM relevance judge from wider-vault lexical candidates.
    case discovered
    /// Added by the user via the vault picker.
    case manual
}
