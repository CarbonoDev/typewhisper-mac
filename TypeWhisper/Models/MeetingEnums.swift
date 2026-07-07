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

    /// Localized, user-facing label for the state (used in the meetings list). The raw value
    /// is an implementation detail and must never be rendered directly.
    var displayName: String {
        switch self {
        case .scheduled: return String(localized: "meetings.state.scheduled")
        case .live: return String(localized: "meetings.state.live")
        case .interrupted: return String(localized: "meetings.state.interrupted")
        case .processing: return String(localized: "meetings.state.processing")
        case .completed: return String(localized: "meetings.state.completed")
        case .failed: return String(localized: "meetings.state.failed")
        }
    }
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
