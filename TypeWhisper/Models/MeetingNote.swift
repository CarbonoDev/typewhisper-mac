import Foundation
import SwiftData

/// A free-form note the user takes during (or after) a meeting.
@Model
final class MeetingNote {
    @Attribute(.unique) var id: UUID
    var text: String
    /// Elapsed seconds from the start of capture when the note was taken, if known.
    var timestampOffset: Double?
    var createdAt: Date
    var meeting: Meeting?

    init(
        id: UUID = UUID(),
        text: String,
        timestampOffset: Double? = nil,
        createdAt: Date = Date(),
        meeting: Meeting? = nil
    ) {
        self.id = id
        self.text = text
        self.timestampOffset = timestampOffset
        self.createdAt = createdAt
        self.meeting = meeting
    }
}
