import Foundation
import SwiftData

/// A participant identity in the isolated `participants.store` (plan D4/D5). One `Person` is the
/// canonical record for a human who has appeared as a meeting attendee (or was added by name), keyed
/// by a normalized `emailKey` when known and otherwise provisional (name-only).
///
/// Schema discipline (plan Part A #10): only `id` carries `@Attribute(.unique)`. Uniqueness of the
/// *optional* `emailKey` is enforced by the single-writer `ParticipantDirectoryService` on the
/// MainActor, never by a SwiftData constraint — a unique constraint on an Optional that is `nil` for
/// every provisional person is a SwiftData trap, and adding one later would be a non-additive schema
/// change. Aliases and secondary emails are Codable JSON columns so the schema shape never changes.
///
/// `meetingCount`/`lastSeen` are **not** stored here (plan D9): they are derived at read time from the
/// meetings snapshot by `ParticipantDirectoryService.derivedStats`, so deleting/importing a meeting can
/// never leave a stale counter behind.
@Model
final class Person {
    @Attribute(.unique) var id: UUID
    /// Normalized (trimmed + lowercased) primary email, or `nil` for a provisional (name-only) person.
    /// The service guarantees at most one person per non-nil `emailKey`.
    var emailKey: String?
    /// The current display label (plan D6 — the *current* name, resolved by email at display time;
    /// never rewritten onto historical `attendeesJSON`). Never clobbered by a later attendee name.
    var displayName: String
    /// JSON-encoded `[String]` of alternate spoken/spelled names folded in over time (see `aliases`).
    var aliasesJSON: String?
    /// JSON-encoded `[String]` of secondary emails recorded **only** by a manual merge (plan D5 #11 /
    /// Part A #11) — never by auto-adoption. Preserves matching signal from a merged-away person.
    var altEmailsJSON: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        emailKey: String? = nil,
        displayName: String,
        aliases: [String] = [],
        altEmails: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.emailKey = emailKey
        self.displayName = displayName
        self.aliasesJSON = Person.encode(aliases)
        self.altEmailsJSON = Person.encode(altEmails)
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    // MARK: - JSON column accessors

    /// Alternate names folded in over time (case preserved). The current label is `displayName`.
    var aliases: [String] {
        get { Person.decode([String].self, from: aliasesJSON) ?? [] }
        set { aliasesJSON = Person.encode(newValue) }
    }

    /// Secondary emails recorded by manual merge only (plan D5 #11).
    var altEmails: [String] {
        get { Person.decode([String].self, from: altEmailsJSON) ?? [] }
        set { altEmailsJSON = Person.encode(newValue) }
    }

    // MARK: - Codable helpers

    static func encode<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode<T: Decodable>(_ type: T.Type, from json: String?) -> T? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

extension Person: Identifiable {}
