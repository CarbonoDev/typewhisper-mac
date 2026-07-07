import Foundation

/// A meeting attendee. Value data with no independent queries, so it is stored as a
/// Codable JSON column on `Meeting` (`attendeesJSON`) rather than as its own `@Model`.
struct Attendee: Codable, Hashable, Sendable, Identifiable {
    var name: String
    var email: String?

    var id: String { email ?? name }

    init(name: String, email: String? = nil) {
        self.name = name
        self.email = email
    }
}
