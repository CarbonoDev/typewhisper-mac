import Foundation

/// Lifecycle state of a `Meeting`.
///
/// Stored on the model as a raw `String` (`Meeting.stateRaw`) so the schema stays
/// additive-safe under the destructive-reset persistence policy — adding a case never
/// changes the stored column shape.
enum MeetingState: String, CaseIterable, Codable, Sendable {
    case scheduled
    case live
    case interrupted
    case processing
    case completed
    case failed
}

/// How a `Meeting` originated.
enum MeetingSource: String, CaseIterable, Codable, Sendable {
    case adHoc
    case calendar
    case importedAudio
    case importedTranscript
}

/// The kind of LLM-generated output persisted as a `MeetingOutput`.
enum MeetingOutputKind: String, CaseIterable, Codable, Sendable {
    case summary
    case extended
    case brief
}

/// The provenance of an individual transcript segment.
enum MeetingSegmentSource: String, CaseIterable, Codable, Sendable {
    case liveCapture
    case importedAudio
    case importedTranscript
}
