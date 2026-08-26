import Foundation
import SwiftData

/// A persisted, LLM-generated output for a meeting (summary, extended analysis, or brief).
/// Regeneration inserts a new row; the UI shows the newest per kind while retaining history.
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

    init(
        id: UUID = UUID(),
        kind: MeetingOutputKind,
        templateID: UUID? = nil,
        content: String,
        providerUsed: String? = nil,
        modelUsed: String? = nil,
        createdAt: Date = Date(),
        meeting: Meeting? = nil
    ) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.templateID = templateID
        self.content = content
        self.providerUsed = providerUsed
        self.modelUsed = modelUsed
        self.createdAt = createdAt
        self.meeting = meeting
    }

    var kind: MeetingOutputKind {
        get { MeetingOutputKind(rawValue: kindRaw) ?? .summary }
        set { kindRaw = newValue.rawValue }
    }
}
