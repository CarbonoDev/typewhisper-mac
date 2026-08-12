import Foundation

/// The narrow seam `RelatedEmailsModel` consumes ([Google Phase 3 · M5], D-M6) — the concrete
/// `GmailContextService` surface the UI needs (candidates/refresh/partial error), so the fetch
/// state machine is testable with a stub that never touches the network
/// (`RelatedEmailsFetchStateTests`).
@MainActor
protocol RelatedEmailsProviding: AnyObject {
    func isConnected(for meeting: Meeting) -> Bool
    func candidates(for meeting: Meeting) async throws -> [EmailCandidate]
    func refresh(for meeting: Meeting) async throws -> [EmailCandidate]
    func lastPartialError(for meeting: Meeting) -> String?
}

extension GmailContextService: RelatedEmailsProviding {}

/// Per-meeting related-emails fetch state ([Google Phase 3 · M5], D-M6). Owned by
/// `MeetingsViewModel` (constructed in its init, observed directly by
/// `MeetingRelatedEmailsSection`); the VM's `+RelatedEmails` pass-throughs are the spec-named API.
/// A dedicated `ObservableObject` rather than VM-stored dictionaries because extension files
/// cannot add stored state and the full VM cannot be constructed in unit tests — this keeps the
/// state machine testable against a stub provider. Rows are in-memory only (D-M2) and per-meeting
/// (a fetch for meeting A never touches meeting B's rows). The in-flight signal here is the
/// section's spinner source — NOT `MeetingLLMService.searchingEmailsMeetingIDs`, which stays set
/// through the whole Q&A pass 2 (M4 review note).
@MainActor
final class RelatedEmailsModel: ObservableObject {
    @Published private(set) var candidatesByMeeting: [UUID: [EmailCandidate]] = [:]
    @Published private(set) var fetchingMeetingIDs: Set<UUID> = []
    /// Thrown-fetch errors per meeting; cleared by the next successful fetch. `lastFetchError`
    /// also surfaces the service's `lastPartialError` (some accounts failed, remainder cached).
    @Published private(set) var fetchErrors: [UUID: String] = [:]
    @Published private(set) var updatedAtByMeeting: [UUID: Date] = [:]

    private let provider: RelatedEmailsProviding?
    /// Injected clock so row date labels and "Updated %@" are deterministic under test.
    private let now: () -> Date

    init(provider: RelatedEmailsProviding?, now: @escaping () -> Date = Date.init) {
        self.provider = provider
        self.now = now
    }

    func rows(for meeting: Meeting) -> [MeetingsViewModel.EmailRow] {
        MeetingsViewModel.emailRows(from: candidatesByMeeting[meeting.id] ?? [], now: now())
    }

    func isFetching(for meeting: Meeting) -> Bool {
        fetchingMeetingIDs.contains(meeting.id)
    }

    /// The line the section's failure caption renders: a thrown fetch's description, else the
    /// service's per-meeting partial-failure detail (D-M6 — partial loss must not hide behind the
    /// merged remainder), else `nil`.
    func lastFetchError(for meeting: Meeting) -> String? {
        fetchErrors[meeting.id] ?? provider?.lastPartialError(for: meeting)
    }

    func updatedAt(for meeting: Meeting) -> Date? {
        updatedAtByMeeting[meeting.id]
    }

    /// Cache-honoring fetch (`.task(id: meeting.id)` on appear — re-navigation within the TTL
    /// costs nothing, D-M1).
    func fetch(for meeting: Meeting) async {
        await load(for: meeting, bypassCache: false)
    }

    /// Cache-bypassing fetch (the manual refresh button + the live 5-minute timer, D-M6).
    func refresh(for meeting: Meeting) async {
        await load(for: meeting, bypassCache: true)
    }

    private func load(for meeting: Meeting, bypassCache: Bool) async {
        guard let provider, provider.isConnected(for: meeting) else { return }
        // Per-meeting spinner sanity: a second call while one is in flight joins the service's
        // single-flight anyway; skip it here so the spinner state never double-toggles.
        guard !fetchingMeetingIDs.contains(meeting.id) else { return }
        fetchingMeetingIDs.insert(meeting.id)
        defer { fetchingMeetingIDs.remove(meeting.id) }
        do {
            let candidates = bypassCache
                ? try await provider.refresh(for: meeting)
                : try await provider.candidates(for: meeting)
            candidatesByMeeting[meeting.id] = candidates
            updatedAtByMeeting[meeting.id] = now()
            fetchErrors[meeting.id] = nil
        } catch {
            fetchErrors[meeting.id] = error.localizedDescription
        }
    }
}

/// Spec-named related-emails API ([Google Phase 3 · M5], D-M6): thin MainActor pass-throughs to
/// the VM-owned `RelatedEmailsModel`, plus the pure candidate → row presentation mapping
/// (`EmailRowPresentationTests`). Extension-file discipline: no stored state here.
@MainActor
extension MeetingsViewModel {
    /// One row of the Related emails list (D-M6): presentation-ready fields plus what the
    /// open-in-Gmail affordance needs (raw `messageID` + `accountEmail` for `GmailWebURL`,
    /// `accountSub` for the launcher — no id parsing, per the M1 `EmailCandidate` contract).
    struct EmailRow: Identifiable, Equatable {
        let id: String
        let messageID: String
        let accountSub: String
        let accountEmail: String
        let subject: String
        let sender: String
        let dateLabel: String
        let snippet: String
        /// The account email caption — only when >1 account contributed candidates (D-M6).
        let accountCaption: String?
    }

    /// Pure candidate → row mapping. The account caption renders only when the candidate set
    /// spans more than one account (ad-hoc meetings merge every enabled account, D-M2).
    nonisolated static func emailRows(from candidates: [EmailCandidate], now: Date) -> [EmailRow] {
        let multiAccount = Set(candidates.map(\.accountSub)).count > 1
        return candidates.map { candidate in
            EmailRow(
                id: candidate.id,
                messageID: candidate.messageID,
                accountSub: candidate.accountSub,
                accountEmail: candidate.accountEmail,
                subject: candidate.subject,
                sender: senderDisplayName(from: candidate.from),
                dateLabel: relativeDateLabel(for: candidate.date, now: now),
                snippet: candidate.snippet,
                accountCaption: multiAccount ? candidate.accountEmail : nil
            )
        }
    }

    /// `"Ada Lovelace <ada@x.com>"` → `"Ada Lovelace"`; a bare address (or an empty display
    /// name) falls back to the address itself.
    nonisolated static func senderDisplayName(from: String) -> String {
        let trimmed = from.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let bracket = trimmed.firstIndex(of: "<") else { return trimmed }
        let name = trimmed[..<bracket]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        if !name.isEmpty { return name }
        return trimmed
            .dropFirst(trimmed.distance(from: trimmed.startIndex, to: bracket) + 1)
            .trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
    }

    /// Relative date for the row ("2 hr. ago"); same-minute dates render as "now"-ish per the
    /// system formatter. Injected `now` keeps it deterministic under test.
    nonisolated static func relativeDateLabel(for date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }

    // MARK: - Pass-throughs (the spec-named surface)

    func relatedEmails(for meeting: Meeting) -> [EmailRow] {
        relatedEmailsModel.rows(for: meeting)
    }

    func fetchRelatedEmails(for meeting: Meeting) async {
        await relatedEmailsModel.fetch(for: meeting)
    }

    func refreshRelatedEmails(for meeting: Meeting) async {
        await relatedEmailsModel.refresh(for: meeting)
    }

    func isFetchingRelatedEmails(for meeting: Meeting) -> Bool {
        relatedEmailsModel.isFetching(for: meeting)
    }

    func lastEmailFetchError(for meeting: Meeting) -> String? {
        relatedEmailsModel.lastFetchError(for: meeting)
    }

    func relatedEmailsUpdatedAt(for meeting: Meeting) -> Date? {
        relatedEmailsModel.updatedAt(for: meeting)
    }
}
