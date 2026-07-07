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
    var obsidianFolder: String?
    /// JSON-encoded `[String]` (see `obsidianTags`).
    var obsidianTagsJSON: String?
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
        obsidianFolder: String? = nil,
        obsidianTagsJSON: String? = nil,
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
        self.obsidianFolder = obsidianFolder
        self.obsidianTagsJSON = obsidianTagsJSON
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

    /// Per-meeting final re-transcription override (addendum AD8). `nil` = inherit.
    var finalRetranscriptionPolicy: FinalRetranscriptionPolicy? {
        get { FinalRetranscriptionPolicy(jsonString: finalRetranscriptionRaw) }
        set { finalRetranscriptionRaw = newValue?.jsonString }
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
