import Foundation

/// Pure, deterministic identity-resolution logic for the participant directory (plan D5). Given the
/// current directory as value snapshots and one incoming attendee, `resolve` returns the single action
/// the single-writer `ParticipantDirectoryService` must apply. No SwiftData, no MainActor state, no
/// clock — every branch has one deterministic unit test.
///
/// Rules (plan D5, adjudication Part A #10-#12):
///  1. **Upsert by email.** An attendee with a known email folds a new spelling into the email person's
///     aliases and **never** clobbers its `displayName`.
///  2. **Provisional create.** A name-only attendee with no existing name match becomes a provisional
///     (email-less) person keyed by its normalized name.
///  3. **Single-unambiguous promotion.** A late email promotes the *one* name-matching provisional in
///     place; if the email is already owned, the one matching provisional is merged into that owner.
///  4. **Ambiguity ⇒ no auto action.** More than one candidate, or a name that already resolves to a
///     *different* email person, never triggers an auto merge/promote (recoverable via manual merge).
///  5. **Two distinct emails never auto-merge** (rule 4 covers it: a name-matching person that owns a
///     *different* email is not a promotion candidate).
///
/// Idempotent and order-independent: re-resolving an already-represented attendee yields `.none`, and
/// the `(name-only, then email)` and `(email, then name-only)` orders converge on one person.
enum PersonIdentity {
    /// A value snapshot of a stored `Person` — the resolver never touches the `@Model`.
    struct Snapshot: Equatable {
        var id: UUID
        var emailKey: String?
        var displayName: String
        var aliases: [String]
        /// Secondary emails recorded by a manual merge (plan D5 #11 / Part A #11). The resolver must see
        /// them so a merged-away email re-encountered during the every-launch backfill resolves to its
        /// surviving owner instead of resurrecting a fresh duplicate person.
        var altEmails: [String]

        init(id: UUID, emailKey: String?, displayName: String, aliases: [String] = [], altEmails: [String] = []) {
            self.id = id
            self.emailKey = emailKey
            self.displayName = displayName
            self.aliases = aliases
            self.altEmails = altEmails
        }
    }

    /// The normalized incoming attendee the resolver reasons about.
    struct Incoming: Equatable {
        /// Trimmed display label (case preserved). Non-empty when the incoming attendee is usable.
        var displayName: String
        /// Normalized (trimmed + lowercased) email, or `nil` for a name-only attendee.
        var emailKey: String?
    }

    /// The one action to apply. `addAliases` are already filtered to names not equal to the target's
    /// `displayName` and not already among its aliases, so the service applies them verbatim.
    enum Outcome: Equatable {
        /// Nothing to do — already represented, or an ambiguous name-only case (no safe action).
        case none
        /// Insert a brand-new person.
        case create(emailKey: String?, displayName: String)
        /// Mutate an existing person in place: optionally adopt an email (provisional → email), and add
        /// any new alias spellings. `adoptEmailKey == nil` leaves the email untouched.
        case update(id: UUID, adoptEmailKey: String?, addAliases: [String])
        /// Fold a provisional `loser` into an email-owning `winner` (plan D5 rule 3, merge variant):
        /// add the folded alias spellings to the winner, then delete the loser.
        case merge(loserID: UUID, winnerID: UUID, addAliases: [String])
    }

    // MARK: - Normalization

    /// Trim + lowercase an email into its comparison key; `nil` when empty/blank.
    static func normalizeEmail(_ email: String?) -> String? {
        guard let email else { return nil }
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    /// Trim a display name (case preserved); `nil` when empty/blank.
    static func normalizeDisplayName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The case-folded comparison key for a name.
    static func nameKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Build the normalized `Incoming` from a raw attendee name + email. Returns `nil` when neither a
    /// usable name nor an email is present (the resolver would have nothing to key on).
    static func incoming(name: String, email: String?) -> Incoming? {
        let emailKey = normalizeEmail(email)
        // A usable display label: the trimmed name, else the email itself (email-only attendee).
        let display = normalizeDisplayName(name) ?? emailKey
        guard let display else { return nil }
        return Incoming(displayName: display, emailKey: emailKey)
    }

    // MARK: - Resolution

    static func resolve(_ incoming: Incoming, existing: [Snapshot]) -> Outcome {
        let key = nameKey(incoming.displayName)

        // Does a snapshot carry `key` as its display name or any alias?
        func matchesName(_ snapshot: Snapshot) -> Bool {
            if nameKey(snapshot.displayName) == key { return true }
            return snapshot.aliases.contains { nameKey($0) == key }
        }

        // The alias spellings from `incoming` that a target does not already represent.
        func newAliases(for target: Snapshot) -> [String] {
            guard nameKey(target.displayName) != key,
                  !target.aliases.contains(where: { nameKey($0) == key }) else { return [] }
            return [incoming.displayName]
        }

        guard let emailKey = incoming.emailKey else {
            // Name-only (rule 2 / rule 4). Reuse a single existing match; create only when none exists;
            // do nothing when more than one matches (ambiguous ⇒ no auto action, no duplicate).
            let matches = existing.filter(matchesName)
            switch matches.count {
            case 0: return .create(emailKey: nil, displayName: incoming.displayName)
            default: return .none
            }
        }

        // Email present. Match a primary `emailKey` owner first; failing that, an owner that carries the
        // email as a merge-recorded secondary (`altEmails`) — otherwise the every-launch backfill would
        // re-encounter a merged-away email in historical `attendeesJSON`, find no owner, and `.create` a
        // duplicate, silently undoing the manual merge (plan Part A #11). Primary owner wins if both exist.
        if let owner = existing.first(where: { $0.emailKey == emailKey })
            ?? existing.first(where: { $0.altEmails.contains(emailKey) }) {
            // Rule 1: upsert by email. Rule 3 (merge variant): fold the single matching provisional in.
            // Exclude the owner itself: when the owner is matched via the `altEmails` fallback and is
            // itself provisional (`emailKey == nil`) — the state a legal manual `merge(emailPerson, into:
            // provisional)` produces — it would otherwise satisfy this name-only filter, yielding a
            // self-`.merge(loserID: W, winnerID: W)` that deletes the very person it just updated (data
            // loss on the every-launch backfill re-ingest). It is the winner, never a loser.
            let provisionalMatches = existing.filter { $0.id != owner.id && $0.emailKey == nil && matchesName($0) }
            if provisionalMatches.count == 1 {
                let loser = provisionalMatches[0]
                // Winner gains: the incoming spelling + the loser's names not already represented.
                var folded = newAliases(for: owner)
                for name in [loser.displayName] + loser.aliases {
                    let nk = nameKey(name)
                    guard nameKey(owner.displayName) != nk,
                          !owner.aliases.contains(where: { nameKey($0) == nk }),
                          !folded.contains(where: { nameKey($0) == nk }) else { continue }
                    folded.append(name)
                }
                return .merge(loserID: loser.id, winnerID: owner.id, addAliases: folded)
            }
            let aliases = newAliases(for: owner)
            return aliases.isEmpty ? .none : .update(id: owner.id, adoptEmailKey: nil, addAliases: aliases)
        }

        // Email is new. Rule 3 (promote variant): promote the *one* name-matching provisional, but only
        // when no name-matching person already owns a (necessarily different) email (rule 4/5).
        let nameMatches = existing.filter(matchesName)
        let provisionalMatches = nameMatches.filter { $0.emailKey == nil }
        let emailMatches = nameMatches.filter { $0.emailKey != nil }
        if provisionalMatches.count == 1, emailMatches.isEmpty {
            let promoted = provisionalMatches[0]
            return .update(id: promoted.id, adoptEmailKey: emailKey, addAliases: newAliases(for: promoted))
        }
        return .create(emailKey: emailKey, displayName: incoming.displayName)
    }
}
