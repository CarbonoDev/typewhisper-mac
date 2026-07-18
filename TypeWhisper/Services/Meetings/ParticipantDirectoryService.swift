import Foundation
import SwiftData
import Combine
import os.log

private let participantLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper",
    category: "ParticipantDirectoryService"
)

/// Owns the isolated `participants.store` and is the **single writer** of the participant directory
/// (plan D4/D5/D7). Every attendee write in the app funnels through `ingest(_:)` (wired from
/// `MeetingService`'s attendee choke points); all dedupe/promote/merge logic lives in the pure
/// `PersonIdentity` resolver, so this type only applies the resolved outcome and persists it.
///
/// Mirrors `MeetingContextRuleService` exactly: `SwiftDataStoreFactory.create`, an
/// `init(appSupportDirectory:)` seam for unit tests, and a destructive reset on incompatibility (the
/// directory is fully re-derivable by `backfill`, so a reset is non-catastrophic).
///
/// `emailKey` uniqueness is enforced here on the MainActor (never by a SwiftData constraint — plan
/// Part A #10). `meetingCount`/`lastSeen` are **derived** by `derivedStats` at read time, never stored
/// (plan D9).
@MainActor
final class ParticipantDirectoryService: ObservableObject {
    /// Above this many meetings the startup backfill is offloaded to the `io` lane rather than run
    /// inline (plan D7). Comfortably above any hand-managed directory; a bulk archive import trips it.
    static let largeArchiveThreshold = 250

    @Published private(set) var persons: [Person] = []

    private let modelContainer: ModelContainer
    private let modelContext: ModelContext

    init(appSupportDirectory: URL = AppConstants.appSupportDirectory) {
        do {
            let (container, context) = try SwiftDataStoreFactory.create(
                for: [Person.self],
                storeName: "participants",
                in: appSupportDirectory
            )
            modelContainer = container
            modelContext = context
        } catch {
            fatalError("Failed to initialize participants store: \(error)")
        }
        fetchPersons()
    }

    // MARK: - Ingestion (single choke point)

    /// Fold a meeting write's attendees into the directory (plan D7). Applies the pure resolver to each
    /// attendee in turn against the current directory state; idempotent (re-ingesting the same roster is
    /// a no-op) and order-independent. Called from `MeetingService`'s attendee choke points via a
    /// closure seam wired in `ServiceContainer`.
    func ingest(_ attendees: [Attendee]) {
        guard !attendees.isEmpty else { return }
        // Resolve each attendee against a live working set that `apply` mutates in lock-step with the
        // model context, NOT against `persons` (which only refreshes after the loop). Otherwise every
        // attendee in one batch resolves against the same stale snapshot, so a colliding roster like
        // `[Alex, Alex+email]` or two same-key name-only `[Alex, alex]` would create duplicate persons in
        // a single call — permanent duplicates that can never auto-converge (plan D5 idempotence).
        var working = snapshots()
        var created: [Person] = []
        var didChange = false
        for attendee in attendees {
            guard let incoming = PersonIdentity.incoming(name: attendee.name, email: attendee.email) else {
                continue
            }
            let outcome = PersonIdentity.resolve(incoming, existing: working)
            if apply(outcome, working: &working, created: &created) { didChange = true }
        }
        guard didChange else { return }
        save()
        fetchPersons()
    }

    /// Ingest a single attendee (convenience used by `MeetingService.addAttendee`'s seam).
    func ingest(_ attendee: Attendee) {
        ingest([attendee])
    }

    // MARK: - Startup backfill (plan D7 — idempotent)

    /// One-time startup pass folding every existing meeting's roster into the directory (plan D7,
    /// pattern `recoverInterruptedMeetings`). Idempotent: because `ingest` is a no-op for already-known
    /// identities, re-running over the same archive changes nothing. Enqueued on the `io` lane by
    /// `ServiceContainer` when the archive is large; run inline otherwise.
    func backfill(from meetings: [Meeting]) async {
        for meeting in meetings {
            ingest(meeting.attendees)
            // Cooperative yield: a large-archive backfill runs on the MainActor (the store and `persons`
            // are MainActor-isolated), so yielding between meetings keeps the UI responsive instead of
            // freezing for the whole >250-meeting pass (roughly quadratic in directory size).
            await Task.yield()
        }
    }

    // MARK: - Manual directory management (plan D5 #11 — merge/split/delete)

    /// Manually merge `loser` into `winner` (plan D5 #11 / Part A #11). Records the loser's primary and
    /// secondary emails in the winner's `altEmails` (the **only** path that writes `altEmails`, so
    /// matching signal from a merged-away person survives), folds its names into the winner's aliases,
    /// then deletes the loser. No-op when they are the same person.
    func merge(_ loser: Person, into winner: Person) {
        guard loser.id != winner.id else { return }

        var alt = winner.altEmails
        for email in ([loser.emailKey].compactMap { $0 } + loser.altEmails) {
            let key = PersonIdentity.normalizeEmail(email)
            guard let key, key != winner.emailKey, !alt.contains(key) else { continue }
            alt.append(key)
        }
        winner.altEmails = alt

        var aliases = winner.aliases
        let winnerNameKey = PersonIdentity.nameKey(winner.displayName)
        for name in ([loser.displayName] + loser.aliases) {
            let nk = PersonIdentity.nameKey(name)
            guard nk != winnerNameKey, !aliases.contains(where: { PersonIdentity.nameKey($0) == nk }) else { continue }
            aliases.append(name)
        }
        winner.aliases = aliases

        winner.updatedAt = Date()
        modelContext.delete(loser)
        save()
        fetchPersons()
    }

    /// Split a secondary email back out of `person` into its own new person (plan D8 escape hatch — the
    /// recovery for a wrong auto-adopt or an over-eager manual merge). Removes `email` from the person's
    /// `altEmails` and creates a fresh email person for it. Returns the new person, or `nil` when the
    /// email is not one of the person's secondaries.
    @discardableResult
    func split(email: String, from person: Person) -> Person? {
        guard let key = PersonIdentity.normalizeEmail(email), person.altEmails.contains(key) else { return nil }
        // Never mint a second primary owner of an email the service already guarantees is unique
        // (plan Part A #10). If some other person already owns `key` as its primary `emailKey`, there is
        // nothing to split out — return nil and leave the secondary in place.
        guard !persons.contains(where: { $0.id != person.id && $0.emailKey == key }) else { return nil }
        person.altEmails = person.altEmails.filter { $0 != key }
        person.updatedAt = Date()
        let created = Person(emailKey: key, displayName: key)
        modelContext.insert(created)
        save()
        fetchPersons()
        return created
    }

    /// Delete a person from the directory (settings action, plan Part F #6 — never triggered by
    /// removing an attendee from a meeting).
    func delete(_ person: Person) {
        modelContext.delete(person)
        save()
        fetchPersons()
    }

    /// Restore participants from a settings backup (fork adaptation of #932). Additive by `id`: a
    /// person whose id already exists in `participants.store` is skipped, never overwritten, so an
    /// import never clobbers the local directory. Single-writer on the MainActor. Returns the number
    /// of persons inserted.
    @discardableResult
    func importPersons(_ dtos: [SettingsBackupExporter.PersonDTO]) -> Int {
        let existingIDs = Set(persons.map(\.id))
        var imported = 0
        for dto in dtos where !existingIDs.contains(dto.id) {
            let person = Person(
                id: dto.id,
                emailKey: dto.emailKey,
                displayName: dto.displayName,
                createdAt: dto.createdAt,
                updatedAt: dto.updatedAt
            )
            // `aliases`/`altEmails` are stored as JSON columns; carry them verbatim.
            person.aliasesJSON = dto.aliasesJSON
            person.altEmailsJSON = dto.altEmailsJSON
            modelContext.insert(person)
            imported += 1
        }
        if imported > 0 {
            save()
            fetchPersons()
        }
        return imported
    }

    /// Rename a person's current display label (plan D6 — the label is the *current* name, resolved by
    /// email at display time; historical `attendeesJSON` is **never** rewritten). The previous label is
    /// folded into `aliases` so a name-only attendee that carried the old spelling still resolves to this
    /// person (and therefore now renders the new name). No-op for a blank or unchanged name.
    func rename(_ person: Person, to newName: String) {
        guard let trimmed = PersonIdentity.normalizeDisplayName(newName),
              PersonIdentity.nameKey(trimmed) != PersonIdentity.nameKey(person.displayName) || trimmed != person.displayName else {
            return
        }
        let oldName = person.displayName
        let oldKey = PersonIdentity.nameKey(oldName)
        if PersonIdentity.nameKey(trimmed) != oldKey,
           !person.aliases.contains(where: { PersonIdentity.nameKey($0) == oldKey }) {
            person.aliases = person.aliases + [oldName]
        }
        person.displayName = trimmed
        person.updatedAt = Date()
        save()
        fetchPersons()
    }

    // MARK: - Read-time identity resolution (plan D6/D8 — display + prior-matching)

    /// The set of directory Person ids a roster resolves to (plan D8 — the additive prior-meeting
    /// matching union). Instance wrapper over the pure static so `MeetingService.priorMeetings` can
    /// resolve two meetings' rosters against the live directory. See `resolvePersonIDs(for:persons:)`.
    func resolvePersonIDs(for attendees: [Attendee]) -> Set<UUID> {
        Self.resolvePersonIDs(for: attendees, persons: persons)
    }

    /// A resolver closure that shares a single prebuilt resolution index over the current directory
    /// snapshot (M4 — M3 review minor). `MeetingService.priorMeetings(matching:)` calls this once per
    /// query and reuses the returned closure for the target and every candidate roster, so the index is
    /// built once (O(persons)) instead of once per candidate (was O(meetings × persons) on the
    /// MainActor). Resolution semantics are identical to `resolvePersonIDs(for:)`.
    func makePersonIDResolver() -> ([Attendee]) -> Set<UUID> {
        let index = Self.resolutionIndex(for: persons)
        return { attendees in
            var ids = Set<UUID>()
            for attendee in attendees {
                if let id = Self.personID(for: attendee, index: index) { ids.insert(id) }
            }
            return ids
        }
    }

    /// The current display name for an attendee, resolved by the directory (plan D6 — rename felt at
    /// display time). Instance wrapper over the pure static; falls back to the attendee's own name.
    func currentDisplayName(for attendee: Attendee) -> String {
        Self.resolveDisplayName(name: attendee.name, email: attendee.email, persons: persons)
    }

    /// Directory Person ids a roster resolves to (plan D8). Email attendees resolve by primary or
    /// merge-recorded secondary email; a name-only attendee resolves **only** when exactly one person
    /// carries the name (common-name conservatism, plan D8) — otherwise it contributes nothing. Pure so
    /// the prior-matching union is unit-testable without a store.
    static func resolvePersonIDs(for attendees: [Attendee], persons: [Person]) -> Set<UUID> {
        let index = resolutionIndex(for: persons)
        var ids = Set<UUID>()
        for attendee in attendees {
            if let id = personID(for: attendee, index: index) { ids.insert(id) }
        }
        return ids
    }

    /// The current display name for `name`/`email` resolved against a persons snapshot (plan D6). Pure
    /// so the "rename felt at display time" behavior is testable without a store. Returns the matched
    /// person's `displayName`; falls back to the trimmed input name when nothing resolves.
    static func resolveDisplayName(name: String, email: String?, persons: [Person]) -> String {
        let fallback = PersonIdentity.normalizeDisplayName(name) ?? name
        let index = resolutionIndex(for: persons)
        let attendee = Attendee(name: name, email: email)
        guard let id = personID(for: attendee, index: index),
              let person = persons.first(where: { $0.id == id }) else {
            return fallback
        }
        return person.displayName
    }

    /// Resolution indexes over a persons snapshot: primary + secondary email → person id, and name key →
    /// person ids (a name may be shared). Built once and shared by `derivedStats`, `resolvePersonIDs`,
    /// and `resolveDisplayName` so the three never disagree on how an attendee maps to a person.
    static func resolutionIndex(for persons: [Person]) -> (byEmail: [String: UUID], byName: [String: [UUID]]) {
        var byEmail: [String: UUID] = [:]
        var byName: [String: [UUID]] = [:]
        for person in persons {
            if let key = person.emailKey { byEmail[key] = person.id }
            for alt in person.altEmails { byEmail[alt] = person.id }
            for name in [person.displayName] + person.aliases {
                byName[PersonIdentity.nameKey(name), default: []].append(person.id)
            }
        }
        return (byEmail, byName)
    }

    /// Resolve one attendee to a person id via a prebuilt index (plan D8). Email wins (primary or
    /// secondary); a name-only attendee resolves only when unambiguous. `nil` when nothing/ambiguous.
    static func personID(
        for attendee: Attendee,
        index: (byEmail: [String: UUID], byName: [String: [UUID]])
    ) -> UUID? {
        if let key = PersonIdentity.normalizeEmail(attendee.email) {
            return index.byEmail[key]
        }
        let ids = index.byName[PersonIdentity.nameKey(attendee.name)] ?? []
        return ids.count == 1 ? ids.first : nil
    }

    // MARK: - Derived stats (plan D9 — never stored)

    /// Per-person meeting count and last-seen date, derived from a meetings snapshot (plan D9). A
    /// meeting counts once per person even if the person appears as two attendees; `lastSeen` is the
    /// latest of the matching meetings' effective dates (`startDate ?? createdAt`). Pure over its
    /// inputs so it is unit-testable without any store.
    static func derivedStats(persons: [Person], meetings: [Meeting]) -> [UUID: PersonStats] {
        // Shared resolution indexes (primary + secondary email → id; name key → [id]) — the same map
        // `resolvePersonIDs`/`resolveDisplayName` use, so counting and matching never disagree.
        let index = resolutionIndex(for: persons)

        var stats: [UUID: PersonStats] = [:]
        for meeting in meetings {
            let date = meeting.startDate ?? meeting.createdAt
            var countedThisMeeting = Set<UUID>()
            for attendee in meeting.attendees {
                // Name-only attendees resolve only when unambiguous (one person carries the name).
                guard let personID = personID(for: attendee, index: index),
                      countedThisMeeting.insert(personID).inserted else { continue }
                var entry = stats[personID] ?? PersonStats(meetingCount: 0, lastSeen: nil)
                entry.meetingCount += 1
                if let last = entry.lastSeen {
                    entry.lastSeen = max(last, date)
                } else {
                    entry.lastSeen = date
                }
                stats[personID] = entry
            }
        }
        return stats
    }

    // MARK: - Apply / store plumbing

    private func snapshots() -> [PersonIdentity.Snapshot] {
        persons.map { snapshot(of: $0) }
    }

    private func snapshot(of person: Person) -> PersonIdentity.Snapshot {
        PersonIdentity.Snapshot(
            id: person.id,
            emailKey: person.emailKey,
            displayName: person.displayName,
            aliases: person.aliases,
            altEmails: person.altEmails
        )
    }

    /// Apply one resolved outcome to the context, keeping the `working` snapshot set and the `created`
    /// list of this-batch inserts in sync so the next attendee in the same batch resolves against
    /// up-to-date state. Returns whether anything actually changed (so a batch of `.none` outcomes skips
    /// the save + refetch).
    private func apply(
        _ outcome: PersonIdentity.Outcome,
        working: inout [PersonIdentity.Snapshot],
        created: inout [Person]
    ) -> Bool {
        // A person mutated by an update/merge may have been inserted earlier in this same batch, so it is
        // not yet in `persons` — look through the batch-local `created` list too.
        func person(for id: UUID) -> Person? {
            persons.first(where: { $0.id == id }) ?? created.first(where: { $0.id == id })
        }
        func mutateSnapshot(id: UUID, _ mutate: (inout PersonIdentity.Snapshot) -> Void) {
            guard let index = working.firstIndex(where: { $0.id == id }) else { return }
            mutate(&working[index])
        }

        switch outcome {
        case .none:
            return false
        case let .create(emailKey, displayName):
            let person = Person(emailKey: emailKey, displayName: displayName)
            modelContext.insert(person)
            created.append(person)
            working.append(snapshot(of: person))
            return true
        case let .update(id, adoptEmailKey, addAliases):
            guard let person = person(for: id) else { return false }
            if let adoptEmailKey { person.emailKey = adoptEmailKey }
            if !addAliases.isEmpty { person.aliases += addAliases }
            person.updatedAt = Date()
            mutateSnapshot(id: id) { snapshot in
                if let adoptEmailKey { snapshot.emailKey = adoptEmailKey }
                snapshot.aliases += addAliases
            }
            return true
        case let .merge(loserID, winnerID, addAliases):
            // Belt-and-suspenders: a self-merge (loser == winner) would delete the winner it just
            // updated. The resolver never emits one, but guard here so no future resolver regression can
            // destroy a person. Treat as `.none` — nothing to fold, nothing to delete.
            guard loserID != winnerID else { return false }
            guard let winner = person(for: winnerID) else { return false }
            if !addAliases.isEmpty { winner.aliases += addAliases }
            winner.updatedAt = Date()
            if let loser = person(for: loserID) {
                modelContext.delete(loser)
                created.removeAll { $0.id == loserID }
            }
            mutateSnapshot(id: winnerID) { snapshot in snapshot.aliases += addAliases }
            working.removeAll { $0.id == loserID }
            return true
        }
    }

    private func fetchPersons() {
        let descriptor = FetchDescriptor<Person>(
            sortBy: [SortDescriptor(\.displayName), SortDescriptor(\.createdAt, order: .forward)]
        )
        do {
            persons = try modelContext.fetch(descriptor)
        } catch {
            participantLogger.error("Fetch failed: \(error.localizedDescription)")
            persons = []
        }
    }

    private func save() {
        do {
            try modelContext.save()
        } catch {
            participantLogger.error("Save failed: \(error.localizedDescription)")
        }
    }
}

/// Derived per-person aggregation (plan D9). Never persisted on `Person`; computed at read time from
/// the meetings snapshot by `ParticipantDirectoryService.derivedStats`.
struct PersonStats: Equatable, Sendable {
    var meetingCount: Int
    var lastSeen: Date?
}
