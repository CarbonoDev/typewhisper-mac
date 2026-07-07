import Foundation

// MARK: - Meeting Events (additive capability — see addendum AD1)
//
// Meeting events are delivered on a *separate* capability protocol
// (`MeetingEventObserving`) and a *new* enum (`MeetingEvent`), reached through the
// additive `HostServices.meetingEvents` accessor. This keeps `TypeWhisperEvent`,
// `EventBusProtocol`, and the `HostServices` requirement list byte-for-byte unchanged, so
// existing compiled community plugins are provably unaffected and keep declaring
// `sdkCompatibilityVersion: "v1"`. New (or rebuilt) plugins opt in with
// `host.meetingEvents?.subscribeMeetingEvents { … }`; on hosts that predate meeting events
// the accessor returns `nil` and plugins must tolerate that.

/// A namespaced meeting-lifecycle event. Distinct from `TypeWhisperEvent` (dictation) by
/// construction — a meeting event can never reach a classic dictation subscriber.
public enum MeetingEvent: Sendable {
    /// A meeting capture session started.
    case started(MeetingStartedPayload)
    /// A batch of newly-stabilized transcript segments (emitted once per throttled flush,
    /// never per partial-update).
    case transcriptSegment(MeetingTranscriptSegmentPayload)
    /// The final transcript is ready after `stop()`.
    case transcriptReady(MeetingTranscriptReadyPayload)
    /// An LLM-generated output (summary / extended / brief) was persisted for a meeting.
    case outputGenerated(MeetingOutputGeneratedPayload)
    /// A meeting capture session ended.
    case ended(MeetingEndedPayload)
}

// MARK: - Payloads
//
// Each payload carries `meetingID` so a subscriber tracking multiple meetings can
// disambiguate. All payloads are `Sendable, Codable` with explicit `CodingKeys` and use
// `decodeIfPresent` for optionals, mirroring `TranscriptionCompletedPayload`'s tolerance so
// the WebhookPlugin can JSON-encode them into POST bodies safely.

public struct MeetingStartedPayload: Sendable, Codable {
    public let meetingID: UUID
    public let title: String
    public let startedAt: Date
    public let isCalendarMeeting: Bool
    public let attendeeCount: Int

    enum CodingKeys: String, CodingKey {
        case meetingID
        case title
        case startedAt
        case isCalendarMeeting
        case attendeeCount
    }

    public init(
        meetingID: UUID,
        title: String,
        startedAt: Date = Date(),
        isCalendarMeeting: Bool,
        attendeeCount: Int
    ) {
        self.meetingID = meetingID
        self.title = title
        self.startedAt = startedAt
        self.isCalendarMeeting = isCalendarMeeting
        self.attendeeCount = attendeeCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        meetingID = try container.decode(UUID.self, forKey: .meetingID)
        title = try container.decode(String.self, forKey: .title)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        isCalendarMeeting = try container.decode(Bool.self, forKey: .isCalendarMeeting)
        attendeeCount = try container.decode(Int.self, forKey: .attendeeCount)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(meetingID, forKey: .meetingID)
        try container.encode(title, forKey: .title)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(isCalendarMeeting, forKey: .isCalendarMeeting)
        try container.encode(attendeeCount, forKey: .attendeeCount)
    }
}

/// A single stabilized transcript segment inside a `.transcriptSegment` batch.
public struct MeetingEventSegment: Sendable, Codable {
    public let text: String
    public let startSeconds: Double
    public let endSeconds: Double
    public let speakerLabel: String?

    enum CodingKeys: String, CodingKey {
        case text
        case startSeconds
        case endSeconds
        case speakerLabel
    }

    public init(text: String, startSeconds: Double, endSeconds: Double, speakerLabel: String? = nil) {
        self.text = text
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.speakerLabel = speakerLabel
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        startSeconds = try container.decode(Double.self, forKey: .startSeconds)
        endSeconds = try container.decode(Double.self, forKey: .endSeconds)
        speakerLabel = try container.decodeIfPresent(String.self, forKey: .speakerLabel)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encode(startSeconds, forKey: .startSeconds)
        try container.encode(endSeconds, forKey: .endSeconds)
        try container.encodeIfPresent(speakerLabel, forKey: .speakerLabel)
    }
}

public struct MeetingTranscriptSegmentPayload: Sendable, Codable {
    public let meetingID: UUID
    public let segments: [MeetingEventSegment]

    enum CodingKeys: String, CodingKey {
        case meetingID
        case segments
    }

    public init(meetingID: UUID, segments: [MeetingEventSegment]) {
        self.meetingID = meetingID
        self.segments = segments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        meetingID = try container.decode(UUID.self, forKey: .meetingID)
        segments = try container.decodeIfPresent([MeetingEventSegment].self, forKey: .segments) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(meetingID, forKey: .meetingID)
        try container.encode(segments, forKey: .segments)
    }
}

public struct MeetingTranscriptReadyPayload: Sendable, Codable {
    public let meetingID: UUID
    public let fullText: String
    public let segmentCount: Int
    public let durationSeconds: Double

    enum CodingKeys: String, CodingKey {
        case meetingID
        case fullText
        case segmentCount
        case durationSeconds
    }

    public init(meetingID: UUID, fullText: String, segmentCount: Int, durationSeconds: Double) {
        self.meetingID = meetingID
        self.fullText = fullText
        self.segmentCount = segmentCount
        self.durationSeconds = durationSeconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        meetingID = try container.decode(UUID.self, forKey: .meetingID)
        fullText = try container.decode(String.self, forKey: .fullText)
        segmentCount = try container.decode(Int.self, forKey: .segmentCount)
        durationSeconds = try container.decode(Double.self, forKey: .durationSeconds)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(meetingID, forKey: .meetingID)
        try container.encode(fullText, forKey: .fullText)
        try container.encode(segmentCount, forKey: .segmentCount)
        try container.encode(durationSeconds, forKey: .durationSeconds)
    }
}

public struct MeetingOutputGeneratedPayload: Sendable, Codable {
    /// Raw value matches `MeetingOutputKind` on the host: `summary` | `extended` | `brief`.
    public let meetingID: UUID
    public let kindRaw: String
    public let templateID: UUID?
    public let content: String
    public let provider: String?
    public let model: String?

    enum CodingKeys: String, CodingKey {
        case meetingID
        case kindRaw
        case templateID
        case content
        case provider
        case model
    }

    public init(
        meetingID: UUID,
        kindRaw: String,
        templateID: UUID? = nil,
        content: String,
        provider: String? = nil,
        model: String? = nil
    ) {
        self.meetingID = meetingID
        self.kindRaw = kindRaw
        self.templateID = templateID
        self.content = content
        self.provider = provider
        self.model = model
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        meetingID = try container.decode(UUID.self, forKey: .meetingID)
        kindRaw = try container.decode(String.self, forKey: .kindRaw)
        templateID = try container.decodeIfPresent(UUID.self, forKey: .templateID)
        content = try container.decode(String.self, forKey: .content)
        provider = try container.decodeIfPresent(String.self, forKey: .provider)
        model = try container.decodeIfPresent(String.self, forKey: .model)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(meetingID, forKey: .meetingID)
        try container.encode(kindRaw, forKey: .kindRaw)
        try container.encodeIfPresent(templateID, forKey: .templateID)
        try container.encode(content, forKey: .content)
        try container.encodeIfPresent(provider, forKey: .provider)
        try container.encodeIfPresent(model, forKey: .model)
    }
}

public struct MeetingEndedPayload: Sendable, Codable {
    /// Raw value matches `MeetingState` on the host (`completed` | `interrupted` | `failed`).
    public let meetingID: UUID
    public let endedAt: Date
    public let durationSeconds: Double
    public let stateRaw: String
    public let segmentCount: Int

    enum CodingKeys: String, CodingKey {
        case meetingID
        case endedAt
        case durationSeconds
        case stateRaw
        case segmentCount
    }

    public init(
        meetingID: UUID,
        endedAt: Date = Date(),
        durationSeconds: Double,
        stateRaw: String,
        segmentCount: Int
    ) {
        self.meetingID = meetingID
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.stateRaw = stateRaw
        self.segmentCount = segmentCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        meetingID = try container.decode(UUID.self, forKey: .meetingID)
        endedAt = try container.decode(Date.self, forKey: .endedAt)
        durationSeconds = try container.decode(Double.self, forKey: .durationSeconds)
        stateRaw = try container.decode(String.self, forKey: .stateRaw)
        segmentCount = try container.decode(Int.self, forKey: .segmentCount)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(meetingID, forKey: .meetingID)
        try container.encode(endedAt, forKey: .endedAt)
        try container.encode(durationSeconds, forKey: .durationSeconds)
        try container.encode(stateRaw, forKey: .stateRaw)
        try container.encode(segmentCount, forKey: .segmentCount)
    }
}

// MARK: - Capability Protocol

/// Additive capability a host advertises by conforming; plugins reach it via
/// `HostServices.meetingEvents`. Not part of the `HostServices` requirement list, so old
/// compiled plugins never reference it and are byte-for-byte unaffected.
public protocol MeetingEventObserving: Sendable {
    @discardableResult
    func subscribeMeetingEvents(_ handler: @escaping @Sendable (MeetingEvent) async -> Void) -> UUID
    func unsubscribeMeetingEvents(id: UUID)
}

public extension HostServices {
    /// `nil` on hosts that predate meeting events — plugins must tolerate `nil`.
    var meetingEvents: (any MeetingEventObserving)? { self as? any MeetingEventObserving }
}
