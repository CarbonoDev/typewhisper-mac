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

    /// A human-presentable name (Sprint 1): calendar invitees often arrive with an email address in
    /// `name`. When the name looks like an email, derive a readable form from its local part
    /// ("juan.sanchez@x.mx" → "Juan Sanchez"); otherwise the name passes through untouched.
    var displayName: String {
        Self.prettify(name)
    }

    /// The compact byline form: the given name(s) only ("Juan Sanchez" → "Juan").
    var shortDisplayName: String {
        displayName.split(separator: " ").first.map(String.init) ?? displayName
    }

    private static func prettify(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("@"), !trimmed.contains(" ") else { return trimmed }
        let local = trimmed.prefix(while: { $0 != "@" })
        let words = local
            .split(whereSeparator: { ".-_+".contains($0) })
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return trimmed }
        return words
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
