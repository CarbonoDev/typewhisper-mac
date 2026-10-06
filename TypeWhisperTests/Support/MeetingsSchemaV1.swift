import Foundation
import SwiftData

/// Frozen replica of the `meetings.store` schema as it shipped before the Perf 2 denormalised fact
/// columns (main at ca0b4748). `MeetingsStoreMigrationTests` writes a store with these models and
/// reopens it through `MeetingService` to prove later schema changes stay additive: the store
/// factory deletes a store it cannot open, so a non-additive change would silently lose every row.
///
/// Never edit this to track the live models. It is the baseline the live schema must stay a
/// superset of; entity names match the live ones because SwiftData names entities by class name.
enum MeetingsSchemaV1 {
    static var models: [any PersistentModel.Type] {
        [Meeting.self, MeetingSegment.self, MeetingNote.self, MeetingOutput.self, MeetingQATurn.self, MeetingTemplate.self]
    }

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
        var attendeesJSON: String?
        var speakerMapJSON: String?
        var audioFileName: String?
        var finalRetranscriptionRaw: String?
        var notesIncludedInOutputs: Bool
        var languageCode: String?
        var languageProvenanceRaw: String?
        var obsidianFolder: String?
        var obsidianTagsJSON: String?
        var lastObsidianExportAt: Date?
        var relatedNotePathsJSON: String?
        var excludedNotePathsJSON: String?
        var relatedDiscoveryAt: Date?
        var twoPersonCall: Bool?
        var timestampsRefined: Bool?
        var externalSessionKey: String?
        var calendarNotes: String?
        var conferencingURL: String?
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

        init(id: UUID = UUID(), title: String, startDate: Date?, createdAt: Date = Date()) {
            self.id = id
            self.title = title
            self.stateRaw = "completed"
            self.sourceRaw = "adHoc"
            self.startDate = startDate
            self.notesIncludedInOutputs = true
            self.createdAt = createdAt
            self.updatedAt = createdAt
            self.segments = []
            self.notes = []
            self.outputs = []
            self.qaTurns = []
        }
    }

    @Model
    final class MeetingSegment {
        @Attribute(.unique) var id: UUID
        var order: Int
        var start: Double
        var end: Double
        var text: String
        var speakerLabel: String?
        var speakerConfidence: Double?
        var sourceRaw: String
        var isStable: Bool
        var meeting: Meeting?

        init(order: Int, start: Double, end: Double, text: String, speakerLabel: String? = nil, meeting: Meeting) {
            self.id = UUID()
            self.order = order
            self.start = start
            self.end = end
            self.text = text
            self.speakerLabel = speakerLabel
            self.sourceRaw = "liveCapture"
            self.isStable = true
            self.meeting = meeting
        }
    }

    @Model
    final class MeetingNote {
        @Attribute(.unique) var id: UUID
        var text: String
        var timestampOffset: Double?
        var createdAt: Date
        var meeting: Meeting?

        init(text: String, meeting: Meeting) {
            self.id = UUID()
            self.text = text
            self.createdAt = Date()
            self.meeting = meeting
        }
    }

    @Model
    final class MeetingOutput {
        @Attribute(.unique) var id: UUID
        var kindRaw: String
        var templateID: UUID?
        var content: String
        var providerUsed: String?
        var modelUsed: String?
        var createdAt: Date
        var meeting: Meeting?

        init(kindRaw: String, content: String, meeting: Meeting) {
            self.id = UUID()
            self.kindRaw = kindRaw
            self.content = content
            self.createdAt = Date()
            self.meeting = meeting
        }
    }

    @Model
    final class MeetingQATurn {
        @Attribute(.unique) var id: UUID
        var question: String
        var answer: String
        var createdAt: Date
        var meeting: Meeting?

        init(question: String, answer: String, meeting: Meeting) {
            self.id = UUID()
            self.question = question
            self.answer = answer
            self.createdAt = Date()
            self.meeting = meeting
        }
    }

    @Model
    final class MeetingTemplate {
        @Attribute(.unique) var id: UUID
        var name: String
        var kindRaw: String
        var prompt: String
        var providerType: String?
        var cloudModel: String?
        var temperatureModeRaw: String?
        var temperatureValue: Double?
        var isPreset: Bool
        var sortOrder: Int

        init(name: String) {
            self.id = UUID()
            self.name = name
            self.kindRaw = "summary"
            self.prompt = ""
            self.isPreset = false
            self.sortOrder = 0
        }
    }
}
