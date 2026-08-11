import Foundation
import Combine
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "GmailContextService")

// MARK: - Value types (spec §4 — never persisted, D-M2)

/// A retrieved email, bounded and ready for an LLM block. Never persisted (D-M2).
struct EmailPassage: Sendable, Equatable {
    let id: String            // google:<sub>:<messageID> (GoogleCalendarID convention, Phase 1 §9)
    let accountSub: String
    let accountEmail: String
    let threadID: String
    let subject: String
    let from: String          // display form: "Name <addr>" or bare address
    let date: Date
    let snippet: String
    let content: String       // body text, ≤2000 chars (D-M1)
}

/// A metadata-only candidate for the UI list (no body fetch). Carries the raw `messageID` beside
/// the namespaced `id` so the body fetch (D-M1 step 5) and `GmailWebURL` (D-M6) never re-parse it.
struct EmailCandidate: Sendable, Equatable, Identifiable {
    let id: String            // google:<sub>:<messageID>
    let messageID: String     // raw Gmail message id
    let accountSub: String
    let accountEmail: String
    let threadID: String
    let subject: String
    let from: String
    let date: Date
    let snippet: String
}

/// SERVICE-computed retrieval scope (D-M1 — unlike the vault template's caller-computed scope,
/// because scope resolution needs `GoogleAccountStore` access the meetings services rightly lack).
/// Internal to `GmailContextService` + `GmailQueryBuilder`; also the cache-fingerprint input.
struct EmailRetrievalScope: Equatable, Sendable {
    var accountSubs: [String]         // resolved per D-M2 (owning account first)
    var attendeeEmails: [String]      // self-exclusion set already subtracted (D-M2)
    var titleTerms: String            // the meeting title (builder tokenizes)
    var afterDay: String              // serialized date-granular window (D-M1 rule) —
    var beforeDay: String             //   fingerprint-stable across fetches within a day

    /// Covers exactly the D-M1 normative set: resolved subs, the attendee-email set (order- and
    /// case-insensitive), and the serialized window — never a raw `Date` instant.
    var fingerprint: String {
        let emails = attendeeEmails.map { $0.lowercased() }.sorted().joined(separator: ",")
        return "\(accountSubs.joined(separator: ","))|\(emails)|\(afterDay)|\(beforeDay)"
    }
}

// MARK: - Eligibility (D-M7)

/// The effective-enablement rule (D-M7, normative), pure so it is testable without the store:
/// connected + scope granted + per-account flag on.
enum GmailAccountEligibility {
    static func isEnabled(account: GoogleAccount, flagged: Bool) -> Bool {
        account.status == .connected
            && account.grantedScopes.contains(GmailContextService.gmailScope)
            && flagged
    }
}

// MARK: - Web URL (D-M6)

/// Pure builder of the account-correct Gmail web URL: `authuser` by email pins the right Google
/// session (index-based `/u/N/` is ordering-fragile), `#all/<messageID>` deep-links the thread
/// view containing the message.
enum GmailWebURL {
    static func messageURL(messageID: String, accountEmail: String) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard
            let email = accountEmail.addingPercentEncoding(withAllowedCharacters: allowed),
            let id = messageID.addingPercentEncoding(withAllowedCharacters: allowed),
            !messageID.isEmpty, !accountEmail.isEmpty
        else { return nil }
        return URL(string: "https://mail.google.com/mail/?authuser=\(email)#all/\(id)")
    }
}

// MARK: - Retrieval seam (spec §4)

/// The narrow protocol the meetings services consume (M3/M4) so tests inject a stub that never
/// touches the network — the `MeetingBriefGenerating` precedent.
@MainActor
protocol GmailContextRetrieving: AnyObject {
    var isConnected: Bool { get }
    func isConnected(for meeting: Meeting) -> Bool
    /// Meeting-centric (D-M1): the service resolves accounts, self-exclusion, and the date window
    /// from the meeting internally, and keys its TTL cache by `meeting.id` — so brief, Q&A, and
    /// the UI list share one candidate fetch. Callers never build a scope.
    func retrieve(for meeting: Meeting, query: String, limit: Int) async throws -> [EmailPassage]
}

extension GmailContextService: GmailContextRetrieving {}

// MARK: - Service

/// Related-email retrieval for meetings ([Google Phase 3 · M1], D-M1/D-M2): Gmail API
/// search-first, no local mail store. Two-call merge per searched account (attendee query
/// `maxResults=25`, subject query `maxResults=10`, dedupe by `threadId` with attendee
/// precedence), bounded-concurrency metadata fetch, `LexicalRetriever` re-rank, and a
/// `format=full` body fetch only for the top-K passages actually fed to an LLM.
///
/// Caching (D-M1, normative): an **in-memory** per-meeting TTL cache (5 min, injectable), keyed by
/// `meeting.id` and fingerprinted over the resolved scope. Invalidated wholesale on
/// `GoogleAccountStore.objectWillChange` (main-queue hop — `$accounts` alone would miss
/// Gmail-toggle flips, which by D-M7 announce only via `objectWillChange`); the fingerprint
/// backstops correctness if an invalidation is ever missed. Nothing is ever written to disk —
/// quitting the app forgets every email (D-M2).
@MainActor
final class GmailContextService: ObservableObject {
    /// Phase 3's data scope (D-M7) — deliberately NOT on `GoogleAuthService`, whose Phase 1
    /// comment directs later phases to pass scopes through `reauthorize` instead of adding
    /// constants there.
    nonisolated static let gmailScope = "https://www.googleapis.com/auth/gmail.readonly"
    /// D-M1 cache TTL.
    nonisolated static let defaultCacheTTL: TimeInterval = 5 * 60
    /// D-M1 normative bounded-concurrency width for the per-account metadata fetches (~35
    /// sequential gets would cost 3–6 s; the bounded group lands at ~1–2 s).
    nonisolated static let metadataFetchWidth = 6

    struct CacheEntry {
        let fetchedAt: Date
        let scopeFingerprint: String
        let candidates: [EmailCandidate]
    }

    /// True while ≥1 candidate fetch is in flight (M5's refresh spinner observes this). Derived
    /// from the single-flight map, so one meeting's early completion can never clear the flag
    /// while another meeting's fetch still runs (review finding, M1).
    @Published private(set) var isFetching = false

    /// The most recent fetch's *partial* failure per meeting — some accounts failed while the
    /// others' candidates were merged and cached, which per-account isolation would otherwise
    /// hide for a whole TTL (review adjudication; the `performSync` `firstError` precedent).
    /// Cleared on a fully clean fetch; a totally failed fetch throws instead of recording here.
    /// The detail is a debug-facing English string inside whatever localized frame the UI adds
    /// (the M5 VM reads it for the D-M6 fetchFailed line).
    @Published private(set) var lastPartialErrors: [UUID: String] = [:]

    /// Convenience accessor for the D-M6 surface.
    func lastPartialError(for meeting: Meeting) -> String? {
        lastPartialErrors[meeting.id]
    }

    private let store: GoogleAccountStore
    private let tokenProvider: GoogleAccessTokenProviding
    private let transport: GoogleHTTPTransport
    /// Injected clock so TTL tests are time-deterministic (§7).
    private let now: () -> Date
    private let cacheTTL: TimeInterval
    /// In-memory only — never persisted (D-M2).
    private var cache: [UUID: CacheEntry] = [:]
    /// Single-flight per meeting (the `GoogleAuthService.refreshTasks` precedent): concurrent
    /// same-meeting callers await one network pass instead of double-fetching and
    /// last-writer-winning the cache. Only the installing call clears its entry (joiners return
    /// via `.value` without installing anything), so no successor can install at the key before
    /// the owner's unconditional clear runs — generation IDs are unnecessary here.
    private var inFlightFetches: [UUID: Task<[EmailCandidate], Error>] = [:]
    private var cancellables: Set<AnyCancellable> = []

    init(
        store: GoogleAccountStore,
        tokenProvider: GoogleAccessTokenProviding,
        transport: GoogleHTTPTransport = URLSessionGoogleTransport(),
        now: @escaping () -> Date = Date.init,
        cacheTTL: TimeInterval = GmailContextService.defaultCacheTTL
    ) {
        self.store = store
        self.tokenProvider = tokenProvider
        self.transport = transport
        self.now = now
        self.cacheTTL = cacheTTL
        // Wholesale invalidation on any account-state change (D-M1): account add/remove/status
        // AND Gmail-toggle flips, which announce only via `objectWillChange` (D-M7).
        store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.cache.removeAll()
            }
            .store(in: &cancellables)
    }

    // MARK: - Connectivity (D-M7)

    /// ≥1 account passes the D-M7 effective-enablement rule.
    var isConnected: Bool {
        !enabledAccounts().isEmpty
    }

    /// Additionally applies the D-M2 owning-account resolution: a meeting owned by a
    /// Gmail-disabled account with no other enabled accounts ⇒ not connected for that meeting.
    /// (An owning account that IS enabled is searched exclusively, so any enabled account —
    /// owner or not — makes the meeting connected.)
    func isConnected(for meeting: Meeting) -> Bool {
        !searchAccounts(for: meeting).isEmpty
    }

    // MARK: - Retrieval (D-M1)

    /// Metadata-only candidates for the UI list — served from the TTL cache when fresh and the
    /// scope fingerprint is unchanged.
    func candidates(for meeting: Meeting) async throws -> [EmailCandidate] {
        let scope = retrievalScope(for: meeting)
        if let entry = cache[meeting.id],
           entry.scopeFingerprint == scope.fingerprint,
           now().timeIntervalSince(entry.fetchedAt) < cacheTTL {
            return entry.candidates
        }
        return try await fetchAndCache(meetingID: meeting.id, scope: scope)
    }

    /// Cache-bypassing variant (the refresh button / live timer, D-M6).
    func refresh(for meeting: Meeting) async throws -> [EmailCandidate] {
        try await fetchAndCache(meetingID: meeting.id, scope: retrievalScope(for: meeting))
    }

    /// Bodied passages for LLM blocks (D-M1 step 5). Reuses the meeting's cached candidate set
    /// when fresh — `query` only drives the re-rank and which top-K bodies are fetched. A body
    /// fetch failure degrades that passage to its snippet (an outage must never fail a brief the
    /// candidates could still ground); only the candidate fetch itself can throw.
    func retrieve(for meeting: Meeting, query: String, limit: Int) async throws -> [EmailPassage] {
        guard limit > 0 else { return [] }
        let candidates = try await candidates(for: meeting)
        let ranked = rank(candidates: candidates, query: query, limit: limit)
        var passages: [EmailPassage] = []
        var tokens: [String: String] = [:]
        for candidate in ranked {
            var content = candidate.snippet
            do {
                let token: String
                if let cached = tokens[candidate.accountSub] {
                    token = cached
                } else {
                    token = try await tokenProvider.accessToken(for: candidate.accountSub)
                    tokens[candidate.accountSub] = token
                }
                let message: GmailAPI.GmailMessage = try await send(
                    GmailAPI.messageFullRequest(token: token, id: candidate.messageID)
                )
                content = GmailBodyText.extract(payload: message.payload, snippet: candidate.snippet)
            } catch {
                logger.warning("Body fetch failed for a message in account \(candidate.accountSub, privacy: .private); degrading to snippet: \(error.localizedDescription)")
            }
            passages.append(EmailPassage(
                id: candidate.id,
                accountSub: candidate.accountSub,
                accountEmail: candidate.accountEmail,
                threadID: candidate.threadID,
                subject: candidate.subject,
                from: candidate.from,
                date: candidate.date,
                snippet: candidate.snippet,
                content: String(content.prefix(GmailBodyText.contentCharCap))
            ))
        }
        return passages
    }

    // MARK: - Scope resolution (D-M2)

    /// The service-computed retrieval scope: searched accounts (owning account first), the
    /// self-excluded attendee-email list, and the serialized date window from
    /// `startDate ?? createdAt`.
    func retrievalScope(for meeting: Meeting) -> EmailRetrievalScope {
        let accounts = searchAccounts(for: meeting)
        let attendeeEmails = GmailQueryBuilder.includedAddresses(
            attendeeEmails: meeting.attendees.compactMap(\.email),
            excludedEmails: excludedEmails(for: meeting)
        )
        let window = GmailQueryBuilder.window(reference: meeting.startDate ?? meeting.createdAt)
        return EmailRetrievalScope(
            accountSubs: accounts.map(\.id),
            attendeeEmails: attendeeEmails,
            titleTerms: meeting.title,
            afterDay: window.afterDay,
            beforeDay: window.beforeDay
        )
    }

    // MARK: - Private: accounts

    private func enabledAccounts() -> [GoogleAccount] {
        store.accounts.filter {
            GmailAccountEligibility.isEnabled(account: $0, flagged: store.isGmailEnabled(for: $0.id))
        }
    }

    /// D-M2 (normative): the meeting's owning account when it resolves to a Gmail-enabled account
    /// — search only it; otherwise (no sub, or owner not enabled) all Gmail-enabled accounts.
    private func searchAccounts(for meeting: Meeting) -> [GoogleAccount] {
        let enabled = enabledAccounts()
        if let eventID = meeting.calendarEventID,
           let sub = GoogleCalendarID.accountSub(fromNamespacedID: eventID),
           let owner = enabled.first(where: { $0.id == sub }) {
            return [owner]
        }
        return enabled
    }

    /// D-M2 self-exclusion: emails of `isSelf == true` attendees ∪ the emails of ALL connected
    /// Google accounts (the user may attend under one account while another is searched).
    /// Case-insensitivity is applied by `GmailQueryBuilder.includedAddresses`.
    private func excludedEmails(for meeting: Meeting) -> [String] {
        store.accounts.map(\.email)
            + meeting.attendees.filter { $0.isSelf == true }.compactMap(\.email)
    }

    // MARK: - Private: fetch pipeline

    /// Single-flight wrapper: a call landing while this meeting's fetch runs awaits the same
    /// network pass. A joiner's scope may lag the running fetch's by one mutation — acceptable,
    /// because the fingerprint check on the next call refetches (the cache backstop).
    private func fetchAndCache(meetingID: UUID, scope: EmailRetrievalScope) async throws -> [EmailCandidate] {
        if let inFlight = inFlightFetches[meetingID] {
            return try await inFlight.value
        }
        let task = Task { [weak self] () throws -> [EmailCandidate] in
            guard let self else { return [] }
            return try await self.performFetch(meetingID: meetingID, scope: scope)
        }
        inFlightFetches[meetingID] = task
        isFetching = true
        defer {
            inFlightFetches[meetingID] = nil
            isFetching = !inFlightFetches.isEmpty
        }
        return try await task.value
    }

    private func performFetch(meetingID: UUID, scope: EmailRetrievalScope) async throws -> [EmailCandidate] {
        let window = GmailQueryBuilder.Window(afterDay: scope.afterDay, beforeDay: scope.beforeDay)
        // Exclusion already applied in the scope (D-M2) — the builder receives the final list.
        let queries = GmailQueryBuilder.queries(
            attendeeEmails: scope.attendeeEmails,
            excludedEmails: [],
            titleTerms: scope.titleTerms,
            window: window
        )
        // No signals (or no searchable account) ⇒ [] without a network call (D-M1 step 1).
        guard !queries.isEmpty, !scope.accountSubs.isEmpty else {
            lastPartialErrors[meetingID] = nil
            cache[meetingID] = CacheEntry(fetchedAt: now(), scopeFingerprint: scope.fingerprint, candidates: [])
            return []
        }

        // Per-account isolation (the `performSync` pattern): one account's error never drops
        // another's candidates; only a total failure throws.
        var merged: [EmailCandidate] = []
        var firstError: String?
        var succeededAnyAccount = false
        var totalFailure: Error?
        for sub in scope.accountSubs {
            guard let account = store.account(id: sub) else { continue }
            do {
                merged.append(contentsOf: try await fetchAccountCandidates(account: account, queries: queries))
                succeededAnyAccount = true
            } catch {
                logger.warning("Gmail fetch failed for account \(sub, privacy: .private): \(error.localizedDescription)")
                if firstError == nil {
                    firstError = "\(account.email): \(error.localizedDescription)"
                    totalFailure = error
                }
            }
        }
        if !succeededAnyAccount, let totalFailure {
            throw totalFailure
        }
        // Surface a partial multi-account failure instead of hiding it behind the merged
        // remainder for a whole TTL; `nil` on a fully clean pass.
        lastPartialErrors[meetingID] = firstError

        merged.sort { $0.date > $1.date }
        cache[meetingID] = CacheEntry(fetchedAt: now(), scopeFingerprint: scope.fingerprint, candidates: merged)
        return merged
    }

    /// One account's two-call merge (D-M1 step 2) + bounded-concurrency metadata fetch (step 3).
    /// Dedupe and thread collapse happen together at the ref stage: within each list response
    /// Gmail orders newest-first, so first-occurrence-wins per `threadId` keeps the newest
    /// message per conversation, and processing the attendee list first gives it precedence.
    private func fetchAccountCandidates(
        account: GoogleAccount,
        queries: GmailQueryBuilder.Queries
    ) async throws -> [EmailCandidate] {
        let token = try await tokenProvider.accessToken(for: account.id)

        var refs: [GmailAPI.GmailMessageRef] = []
        var seenThreads = Set<String>()
        if let query = queries.attendee {
            let list: GmailAPI.GmailMessageList = try await send(
                GmailAPI.listRequest(token: token, query: query, maxResults: GmailQueryBuilder.attendeeMaxResults)
            )
            for ref in list.messages ?? [] where seenThreads.insert(ref.threadId).inserted {
                refs.append(ref)
            }
        }
        if let query = queries.subject {
            let list: GmailAPI.GmailMessageList = try await send(
                GmailAPI.listRequest(token: token, query: query, maxResults: GmailQueryBuilder.subjectMaxResults)
            )
            for ref in list.messages ?? [] where seenThreads.insert(ref.threadId).inserted {
                refs.append(ref)
            }
        }
        guard !refs.isEmpty else { return [] }

        let messages = try await fetchMetadataBounded(refs: refs, token: token)
        return messages.map { message in
            candidate(from: message, account: account)
        }
    }

    /// D-M1 normative: metadata gets run concurrently through a bounded `withThrowingTaskGroup`
    /// (width 6). Completion order is irrelevant — the merged list is date-sorted afterwards.
    private func fetchMetadataBounded(
        refs: [GmailAPI.GmailMessageRef],
        token: String
    ) async throws -> [GmailAPI.GmailMessage] {
        let transport = self.transport
        return try await withThrowingTaskGroup(of: GmailAPI.GmailMessage.self) { group in
            var results: [GmailAPI.GmailMessage] = []
            results.reserveCapacity(refs.count)
            var iterator = refs.makeIterator()
            var inFlight = 0
            while inFlight < Self.metadataFetchWidth, let ref = iterator.next() {
                group.addTask {
                    try await Self.fetchMessage(transport: transport, request: GmailAPI.messageMetadataRequest(token: token, id: ref.id))
                }
                inFlight += 1
            }
            while let message = try await group.next() {
                results.append(message)
                if let ref = iterator.next() {
                    group.addTask {
                        try await Self.fetchMessage(transport: transport, request: GmailAPI.messageMetadataRequest(token: token, id: ref.id))
                    }
                }
            }
            return results
        }
    }

    private nonisolated static func fetchMessage(
        transport: GoogleHTTPTransport,
        request: URLRequest
    ) async throws -> GmailAPI.GmailMessage {
        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200 else {
            throw GmailAPI.RequestFailed(statusCode: response.statusCode)
        }
        return try JSONDecoder().decode(GmailAPI.GmailMessage.self, from: data)
    }

    private func candidate(from message: GmailAPI.GmailMessage, account: GoogleAccount) -> EmailCandidate {
        EmailCandidate(
            // The D-G3 `google:<sub>:<raw>` convention (spec §4); message IDs never collide with
            // event IDs because these ids are never fed to calendar code.
            id: "google:\(account.id):\(message.id)",
            messageID: message.id,
            accountSub: account.id,
            accountEmail: account.email,
            threadID: message.threadId,
            subject: header("Subject", in: message) ?? "",
            from: header("From", in: message) ?? "",
            date: date(from: message),
            snippet: message.snippet ?? ""
        )
    }

    private func header(_ name: String, in message: GmailAPI.GmailMessage) -> String? {
        message.payload?.headers?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// `internalDate` (epoch millis) is authoritative; a missing/garbled one sorts the message to
    /// the very back rather than dropping it.
    private func date(from message: GmailAPI.GmailMessage) -> Date {
        guard let raw = message.internalDate, let millis = Double(raw) else { return .distantPast }
        return Date(timeIntervalSince1970: millis / 1000)
    }

    /// D-M1 step 4: `LexicalRetriever.rank` over subject + from + snippet, truncated to `limit`.
    /// An empty rank (no content-term overlap) falls back to date-descending candidate order —
    /// the server query already established relevance, so an empty lexical intersection must not
    /// blank the list.
    private func rank(candidates: [EmailCandidate], query: String, limit: Int) -> [EmailCandidate] {
        let documents = candidates.map {
            LexicalRetriever.Document(id: $0.id, text: "\($0.subject) \($0.from) \($0.snippet)")
        }
        let results = LexicalRetriever.rank(query: query, documents: documents, limit: limit)
        guard !results.isEmpty else {
            // Candidates are stored date-descending (fetchAndCache sorts).
            return Array(candidates.prefix(limit))
        }
        let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        return results.compactMap { byID[$0.id] }
    }

    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200 else {
            throw GmailAPI.RequestFailed(statusCode: response.statusCode)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}
