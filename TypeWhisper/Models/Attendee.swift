import Foundation

/// A meeting attendee. Value data with no independent queries, so it is stored as a
/// Codable JSON column on `Meeting` (`attendeesJSON`) rather than as its own `@Model`.
struct Attendee: Codable, Hashable, Sendable, Identifiable {
    var name: String
    var email: String?
    /// Whether this attendee is the current user / device owner (speaker-recognition amendment, D-A8).
    /// Populated from `EKParticipant.isCurrentUser` on calendar meetings; `nil` when indeterminate
    /// (ad-hoc/manual attendees, or a provider that does not expose it). Additive/optional on the
    /// Codable JSON blob → decoding an older payload without the field simply yields `nil`. Used by the
    /// two-person channel path to name `SPEAKER_OTHERS` from the single non-self attendee.
    var isSelf: Bool?

    var id: String { email ?? name }

    init(name: String, email: String? = nil, isSelf: Bool? = nil) {
        self.name = name
        self.email = email
        self.isSelf = isSelf
    }
}
