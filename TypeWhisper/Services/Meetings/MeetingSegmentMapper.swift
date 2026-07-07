import Foundation

/// Bridges the app-wide `TranscriptionSegment` normalization type (produced by live capture,
/// audio import, and transcript import) to the persisted `MeetingSegment` and back.
enum MeetingSegmentMapper {
    /// Build a persistable `MeetingSegment` from a normalized `TranscriptionSegment`.
    static func makeSegment(
        from segment: TranscriptionSegment,
        order: Int,
        source: MeetingSegmentSource,
        isStable: Bool = true
    ) -> MeetingSegment {
        MeetingSegment(
            order: order,
            start: segment.start,
            end: segment.end,
            text: segment.text,
            speakerLabel: segment.speakerLabel,
            speakerConfidence: segment.speakerConfidence,
            source: source,
            isStable: isStable
        )
    }

    /// Build a normalized `TranscriptionSegment` from a persisted `MeetingSegment`.
    static func transcriptionSegment(from segment: MeetingSegment) -> TranscriptionSegment {
        TranscriptionSegment(
            text: segment.text,
            start: segment.start,
            end: segment.end,
            speakerLabel: segment.speakerLabel,
            speakerConfidence: segment.speakerConfidence
        )
    }
}
