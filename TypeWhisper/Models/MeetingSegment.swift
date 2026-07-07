import Foundation
import SwiftData

/// A single timestamped transcript segment belonging to a `Meeting`.
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

    init(
        id: UUID = UUID(),
        order: Int,
        start: Double,
        end: Double,
        text: String,
        speakerLabel: String? = nil,
        speakerConfidence: Double? = nil,
        source: MeetingSegmentSource = .liveCapture,
        isStable: Bool = true,
        meeting: Meeting? = nil
    ) {
        self.id = id
        self.order = order
        self.start = start
        self.end = end
        self.text = text
        self.speakerLabel = speakerLabel
        self.speakerConfidence = speakerConfidence
        self.sourceRaw = source.rawValue
        self.isStable = isStable
        self.meeting = meeting
    }

    var source: MeetingSegmentSource {
        get { MeetingSegmentSource(rawValue: sourceRaw) ?? .liveCapture }
        set { sourceRaw = newValue.rawValue }
    }
}
