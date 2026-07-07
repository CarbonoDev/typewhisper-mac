import Foundation
import SwiftData

/// A single in-meeting Q&A turn: a question and its atomically-persisted answer. Modeled as
/// a question/answer pair (not role-based chat messages) because the LLM API is single-turn,
/// so a failed call never leaves a dangling user message.
@Model
final class MeetingQATurn {
    @Attribute(.unique) var id: UUID
    var question: String
    var answer: String
    var createdAt: Date
    var meeting: Meeting?

    init(
        id: UUID = UUID(),
        question: String,
        answer: String,
        createdAt: Date = Date(),
        meeting: Meeting? = nil
    ) {
        self.id = id
        self.question = question
        self.answer = answer
        self.createdAt = createdAt
        self.meeting = meeting
    }
}
