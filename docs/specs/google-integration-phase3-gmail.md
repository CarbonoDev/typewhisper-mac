# Google Integration Phase 3 — Gmail Context for Meetings

Status: **Design — authoritative target for Phase 3** (branch `feature/google-phase3-gmail` off
`feature/google-phase1-auth-calendar`, new worktree — see §10).
Phase 3 of three: Phase 1 auth + Calendar (built, spec
`docs/specs/google-integration-phase1-auth-calendar.md`) → Phase 2 Drive import/backfill (built **in
parallel** by another team) → Phase 3 Gmail context (this spec).

Decision IDs are `D-M1`…`D-M7`; code comments cite them the same way the codebase cites
`D-G2`/`D-A2`/`DB5`.

All file:line anchors below were verified against the Phase 1 branch
(`feature/google-phase1-auth-calendar`, worktree `typewhisper-wt-google-phase1`) — the base this
branch forks from. Line numbers will drift after the Phase 2 rebase (§10); symbol names are the
stable reference.

---

## 1. Goals / non-goals

### Goals

1. **Related emails as meeting context.** A `GmailContextService` retrieves emails related to a
   meeting (attendees, subject↔title terms, time window) via the Gmail API — **search-first, no
   local mail store** (D-M1) — and feeds them into:
   - the **pre-meeting brief** as a third context block beside prior meetings and vault passages
     (D-M3), and
   - **in-meeting Q&A** as a second escalation source beside `VAULT_SEARCH:` (D-M4).
2. **A "Related emails" list in the meeting UI** — on the briefing page (`scheduledEmptyBody`), in
   the rendered-output appendix, **and on the live capture page** (`liveNotesBody`, which today has
   no related-content surface) — with an account-correct "Open in Gmail" affordance (D-M6).
3. **Per-account Gmail enablement**: a toggle per connected Google account that requests the
   `gmail.readonly` scope incrementally via the Phase 1 seam
   `GoogleAuthService.reauthorize(accountID:additionalScopes:)`
   (`TypeWhisper/Services/Google/GoogleAuthService.swift:163`) — no re-adding accounts (D-M7).
4. **Privacy stance**: emails are retrieved on demand, cached **in memory only** with a short TTL,
   and **never persisted** to any store (D-M2). The only durable trace is derived content the user
   explicitly generates (a brief or Q&A answer that quotes an email — disclosed in the output).

### Non-goals (Phase 3)

- No local mail index/store, no message sync engine, no offline email search (D-M1).
- No email **sending**, labeling, or any Gmail write scope — `gmail.readonly` only.
- No LLM email-relevance judge in v1 — lexical-only ranking (D-M5; the `.emailsJudge`
  `MeetingModelPurpose` name is reserved for a follow-up, not added now).
- No new `MeetingJobKind` and **no `JobQueueService` changes** — brief email retrieval rides inside
  the existing `.brief` job; UI fetches are on-demand view-model calls (Phase 2 owns import job
  kinds this cycle, §10).
- No new SwiftData store, no `@Model` changes, no new `Meeting` columns.
- No changes to `GoogleAuthService`'s flow/taxonomy, `GoogleAccountStore`'s index format,
  `GoogleCalendarSyncEngine`, or any Phase-2-owned file (§10).
- No attachment content search (subject/body text only).
- No Gmail push notifications / watch — pull-on-demand only.

---

## 2. Architecture overview

```
GoogleAccountsSection ── per-account "Search Gmail…" toggle (D-M7)
        │  (missing scope ⇒ reauthorize(accountID:additionalScopes:[gmailScope]))
        ▼
GoogleAccountStore ── google.account.<sub>.gmailEnabled (dynamic key, single writer)
        │
        ▼
GmailContextService  (Services/Google/ — @MainActor, ObservableObject)
  │  isConnected · retrieve(for:query:limit:) async · candidates(for:)
  │  (scope — accounts/window/self-exclusion — computed INSIDE the service, D-M1)
  │  in-memory per-meeting TTL cache (D-M1) — never persisted
  │  GmailQueryBuilder (pure)  →  users.messages.list?q=…  ×2 clauses  (Gmail API)
  │  candidates (format=metadata + snippet) → LexicalRetriever.rank re-rank
  │  top-K → format=full → GmailBodyText (plain-part / HTML-strip) → EmailPassage
  │
  ├──► MeetingBriefService.relatedEmailsBlock(for:)   — third block (D-M3)
  ├──► MeetingLLMService pass-2 EMAIL_SEARCH escalation (D-M4)
  └──► MeetingsViewModel+RelatedEmails → MeetingRelatedEmailsSection (D-M6)
                                          (scheduledEmptyBody · liveNotesBody · appendix)
Row click → MeetingJoinLauncher.open(url:accountSub:)  — account-correct Gmail web URL
```

Everything new lives in **`TypeWhisper/Services/Google/`** (the D-G1 app-side family) plus one view,
one view-model extension, and additive edits to the three Phase-3-owned meetings services. All new
service objects are `@MainActor`; network work is awaited through the Phase 1 seams
(`GoogleHTTPTransport`, `GoogleAccessTokenProviding`) so nothing blocks the main thread.

Reused Phase 1 seams (verified):

| Seam | Anchor |
|---|---|
| `GoogleHTTPTransport` (fakeable network) | `Services/Google/GoogleHTTPTransport.swift:6` |
| `GoogleAccessTokenProviding` (scope-agnostic token) | `Services/Google/GoogleCalendarSyncEngine.swift:11` |
| `GoogleAuthService.reauthorize(accountID:additionalScopes:)` | `Services/Google/GoogleAuthService.swift:163` |
| `GoogleAuthError` open taxonomy (`.needsReauth` special-cased, unknown = transient) | `GoogleAuthService.swift:11-47,185-197` |
| `GoogleAccountStore` single writer + dynamic per-sub keys (`linkOpeningKey` precedent) | `Services/Google/GoogleAccountStore.swift:188-211` |
| `GoogleCalendarID.accountSub(fromNamespacedID:)` (meeting → owning account) | `Services/Google/GoogleCalendarMapper.swift:21-26` |
| `MeetingJoinLauncher.open(url:accountSub:)` (account-correct browser/Chrome-profile launch) | `Services/Google/MeetingJoinLauncher.swift:68` |
| `LexicalRetriever.rank(query:documents:limit:)` (pure re-ranking, reused as-is) | `Services/Meetings/LexicalRetriever.swift:50` |

---

## 3. Decision records

### D-M1 — Retrieval strategy: Gmail API search-first, metadata candidates, full-fetch top-K, in-memory TTL cache

**Options considered**

1. **API-search-first**: `users.messages.list` with a Gmail `q` built from the meeting's signals;
   no local mail store; `LexicalRetriever` re-ranks the fetched candidates.
2. Local index: periodically sync headers into a local store and search offline (a
   `GoogleCalendarSyncEngine`-shaped mail sync).
3. Hybrid: cache candidate metadata durably, fetch bodies on demand.

**Decision: option 1.** Gmail's server-side search operators (`from:`/`to:`, quoted subject terms,
`after:`/`before:`) already do the precision-filtering work that the vault path needs
`candidateNotes` + an LLM judge for — the candidate set arrives pre-scoped to the meeting. A local
mail store is a large privacy and engineering liability (sync engine, storage discipline, growth)
for zero v1 benefit; options 2–3 also violate the "never persisted" stance (D-M2). Latency is
handled by the cache below, not by local storage.

**Pipeline (normative):**

1. **Queries** — `GmailQueryBuilder.queries(attendeeEmails:excludedEmails:titleTerms:window:)`
   (pure, unit-tested) produces **two independent `q` strings** (either may be `nil`):
   - **Attendee query**: `(from:a@x OR to:a@x OR from:b@y OR to:b@y …)` over the attendee emails
     minus the excluded set (self-exclusion, D-M2), capped at the first **8** addresses; `nil`
     when no addresses remain.
   - **Subject query**: `subject:(term1 term2 …)` — content terms of the meeting title via
     `LexicalRetriever.tokenize` (`LexicalRetriever.swift:41` — lowercased, stop-worded), capped
     at the first **4** terms, **AND-scoped inside `subject:`** (Gmail treats space-separated
     terms inside the parens as AND); `nil` when no content terms.
   - Both queries carry the date window and noise filters:
     `after:YYYY/MM/DD before:YYYY/MM/DD -in:chats -in:drafts -category:promotions
     -category:social`. **Date serialization rule**: Gmail's `before:` is *exclusive* of the named
     day, so `after:` = the calendar day of the window start and `before:` = **the calendar day
     AFTER the window-end instant** — the window-end day itself (including a meeting day's
     mid-meeting arrivals) is always covered.
   - Both queries `nil` (no attendees with emails AND no title content terms) ⇒ retrieval returns
     `[]` without a network call.
2. **List — two-call merge (D-M1 flooding guard)** — per searched account, one
   `GET /gmail/v1/users/me/messages?q=…` per non-nil query: attendee query with
   `maxResults=25`, subject query with `maxResults=10`; results merged and deduped by `threadId`
   (attendee results win the dedupe). *Rationale (vs a single OR-joined query):* a single query
   fills its newest-first result window jointly, so a generic title ("weekly sync") could occupy
   all 25 slots with non-attendee noise and re-ranking cannot recover candidates that never
   arrived; per-clause caps guarantee attendee mail is never displaced, and `subject:(…)`
   AND-scoping keeps the title clause precise. No pagination in v1.
3. **Candidates** — per id, `GET …/messages/{id}?format=metadata&metadataHeaders=Subject&metadataHeaders=From&metadataHeaders=To&metadataHeaders=Date`
   (response also carries `snippet` and `threadId`), fetched **concurrently per account via a
   bounded `withThrowingTaskGroup` (width 6)** — normative: a sequential loop over ~35 gets costs
   3–6 s, unacceptable on the live surface; the bounded group lands at ~1–2 s.
   **Thread collapse**: keep only the newest message per `threadId` (D-M2 thread continuity — one
   row per conversation).
4. **Re-rank** — `LexicalRetriever.rank` over `Document(id: messageID, text: subject + " " + from
   + " " + snippet)` against the caller's query text (meeting title + attendee names for the
   list/brief; the model's search terms for Q&A escalation). Rank output is truncated to the
   caller's `limit`. When the lexical query has no content-term overlap (rank returns `[]`), fall
   back to date-descending candidate order — for emails, unlike vault notes, the server query
   already established relevance, so an empty lexical intersection must not blank the list.
5. **Bodies** — only for the passages actually fed to an LLM (brief block, Q&A escalation; limit 3):
   `format=full`, then `GmailBodyText.extract(payload:)` (pure): prefer the first `text/plain` MIME
   part (base64url-decoded), else tag-strip + entity-decode the first `text/html` part, else the
   snippet. Content capped at **2,000 chars** (mirrors `ObsidianVaultService.passageCharBudget`,
   `Services/Meetings/ObsidianVaultService.swift:102`). The UI list renders metadata + snippet only
   — no body fetch.

**Caching (normative).** The vault recomputes fresh on every call
(`ObsidianVaultService.retrieve`, `:183`) — viable for local disk, not for a network API feeding a
live surface (quota + 1–2 s latency per refresh). `GmailContextService` therefore holds an
**in-memory** cache: `[UUID /* meeting.id */: CacheEntry]` with
`CacheEntry {fetchedAt: Date, scopeFingerprint: String, candidates: [EmailCandidate]}`;
TTL **5 minutes** (injectable for tests). A call within TTL and with an unchanged scope
fingerprint is served from cache; `refresh(for:)` bypasses it. The **fingerprint** covers the
resolved account subs, the attendee-email set, and the **serialized date-granular window**
(`after:`/`before:` strings — never a raw `Date` instant, which would make every live fetch a
miss). The cache is invalidated wholesale on `GoogleAccountStore.objectWillChange` (received on
the main queue — `$accounts` alone would miss Gmail-toggle flips, which by D-M7 announce only via
`objectWillChange`); the fingerprint backstops correctness if an invalidation is ever missed.
**Nothing is ever written to disk** — the cache lives in the service (its single owner), so
single-writer discipline is trivially preserved, and quitting the app forgets every email.

**API shape (the deliberate deviations from the vault template):** the vault's
`retrieve(query:limit:scope:)` is synchronous and caller-scoped; Gmail's is `async throws` and
**meeting-centric** — callers hold no `GoogleAccountStore` access and cannot resolve accounts,
eligibility, or windows, and a meeting-keyed cache can only be hit by calls that carry the
meeting. The service computes the retrieval scope internally from the `Meeting` (D-M2:
owning-account resolution, self-exclusion set, date window from `startDate ?? createdAt`):

```swift
func retrieve(for meeting: Meeting, query: String, limit: Int) async throws -> [EmailPassage]  // bodies, for LLM blocks
func candidates(for meeting: Meeting) async throws -> [EmailCandidate]                          // metadata-only, for the UI list
func refresh(for meeting: Meeting) async throws -> [EmailCandidate]                             // cache-bypassing variant
```

`retrieve(for:query:limit:)` reuses the meeting's cached candidate set when fresh (the `query`
only drives the re-rank + which top-K bodies are fetched), so the brief, Q&A escalation, and the
UI list share one candidate fetch per meeting per TTL. All call sites (brief generation, Q&A
pass 2, view-model fetch) are already async contexts.

### D-M2 — Email relatedness, account resolution, privacy

**What makes an email "related" (normative):**

- **Attendee-based**: to/from any attendee email of the meeting (`Meeting.attendees`, self
  excluded) — the primary signal, expressed server-side in the attendee query.
  **Self-exclusion (normative)**: the excluded set = emails of attendees with `isSelf == true`
  **∪ the emails of ALL connected Google accounts** (`GoogleAccountStore.accounts` — the user may
  attend under one account while another is searched), compared case-insensitively.
- **Subject↔title**: title content terms matched in the message **subject** (`subject:(…)`,
  AND-scoped — D-M1 flooding guard) — the secondary signal, merged with the attendee query's
  results so either clause suffices but neither displaces the other.
- **Thread continuity**: candidates collapse to one row per `threadId` (newest message represents
  the conversation); the Gmail web URL opens the thread view so the whole conversation is one click
  away.
- **Time window**: `[reference − 14 days, reference + 1 day]` where `reference` = the meeting's
  `startDate ?? createdAt`, serialized at **date granularity** per the D-M1 rule (`before:` = the
  calendar day *after* the window-end instant, since Gmail's `before:` is exclusive). There is
  **no live special case**: for any meeting happening today the serialized window already covers
  all of today, so mid-meeting arrivals are reachable — the refresh button and the live 5-minute
  timer (D-M6) are the freshness mechanism, not a moving window end. (14 days ≈ the prep horizon
  of a recurring cadence; wider windows dilute the attendee clause and burn quota.)

**Which accounts are searched (normative):** the meeting's **owning account first** — parse
`GoogleCalendarID.accountSub(fromNamespacedID: meeting.calendarEventID)`
(`GoogleCalendarMapper.swift:21`); when that sub resolves to a Gmail-enabled account, search **only
it** (the invitations, replies, and prep threads live in the account that received the event). When
there is no sub (EventKit-linked, ad-hoc, imported meetings) or the sub's account is not
Gmail-enabled, search **all Gmail-enabled accounts** and merge candidates (re-rank across the
union; each candidate keeps its `accountSub` for the open-URL affordance). This bounds latency and
quota to one account in the common calendar case without blinding non-Google meetings.

**Privacy stance (normative):** emails are retrieved on demand and held only in the D-M1 in-memory
TTL cache. Nothing email-derived is written to `meetings.store` or any other store, no defaults
key ever contains message content, and no message ID is persisted. Two deliberate, disclosed
exceptions of *derived* content: (a) a generated **brief** whose "Related emails" section
summarizes/quotes retrieved emails is persisted as a normal `MeetingOutput` — that is the feature;
(b) a Q&A **answer** produced after an `EMAIL_SEARCH:` escalation is persisted as a normal
`MeetingQATurn`, prefixed with a localized disclosure that emails were consulted (D-M4). Log lines
never include subjects, senders, or bodies (message counts and lengths only; account subs logged
`.private`, matching the Phase 1 logging discipline).

### D-M3 — Brief integration: third context block + reserved budget slice

`MeetingBriefService.generateBrief` currently builds exactly two blocks —
`priorMeetingsBlock(for:)` (`Services/Meetings/MeetingBriefService.swift:131`) and
`knowledgeBaseBlock(for:)` (`:173`) — guards on both being empty (`:81`), and assembles with a
reserved KB slice in `assembleContext` (`:222`). The email block mirrors the KB block exactly:

- New `private func relatedEmailsBlock(for meeting: Meeting) async -> String`:
  `guard gmailService.isConnected(for: meeting)` (mirrors the `vaultService.isConnected` gate,
  `:174`); calls `gmailService.retrieve(for: meeting, query:, limit: 3)` (the meeting-centric
  seam, D-M1 — the service computes accounts/window/self-exclusion internally) with
  query = meeting title + attendee names (same `retrievalQuery(for:)` text, `:206`); renders
  passages as `"### <subject> — <from>, <date>\n<content>"` entries. **Degrades to `""` on any
  thrown error** (network, `.needsReauth`) — a Gmail outage must never fail a brief that prior
  meetings or the vault could still ground; the error is logged and surfaced only through the
  settings badge that `.needsReauth` already drives.
- The insufficiency guard becomes
  `!priorBlock.isEmpty || !kbBlock.isEmpty || emailBlockSufficient` — a meeting with rich email
  context but no prior meetings/vault can now get a brief. **Sole-grounding restriction
  (normative):** `emailBlockSufficient` = the block is non-empty **and the meeting has ≥1
  non-self attendee email** (i.e. the attendee query was non-nil) — title-term-only email matches
  may *augment* a brief but never solely ground a persisted one.
  *Documented approximation (M3 review, note-only):* the brief service's `hasNonSelfAttendeeEmail`
  checks `isSelf` only — it cannot see the connected-account emails the D-M2 self-exclusion also
  subtracts. In the narrow case where the sole non-self attendee email is one of the user's own
  connected accounts, the guard passes while the actual attendee clause was nil (a non-empty
  block is then title-anchored). Accepted: the block is still gated on a non-empty retrieval,
  and threading the account list into the brief service for this edge is not worth the coupling.
- `assembleContext(meeting:priorBlock:kbBlock:emailBlock:)`: the email block gets its own reserved
  slice, extending the existing reserve mechanics (`:240`) with one **explicit fix to the middle
  block's budget**: today the last section is given *all* remaining budget (`:250-256`), so a
  naively appended email section would be eaten by a large KB block. Normative budgets:
  `kbReserve = kbBlock.isEmpty ? 0 : charBudget / 4`;
  `emailReserve = emailBlock.isEmpty ? 0 : charBudget / 4`;
  prior block ≤ `charBudget − meta − kbReserve − emailReserve`;
  **KB block ≤ `charBudget − running − emailReserve`** (it must subtract the trailing email
  reserve, exactly as the prior block subtracts `kbReserve` today);
  email block gets the remainder (≥ its reserve). Section order **meta → prior meetings →
  knowledge base → related emails**, each carrying the existing truncation notice when cut; final
  whole-string bound unchanged (`:259`).
- **When it runs:** unchanged — inside brief generation, which `MeetingBriefScheduler.tick`
  (`Services/Meetings/MeetingBriefScheduler.swift:148`) already enqueues as a `.background`
  `.brief` job on the cap-1 `llm` lane ~20 min before start (`enqueueBrief`, `:229`). The email
  fetch adds 1–2 s inside that job — invisible pre-meeting. **No scheduler or job-queue change.**
- Injection: the service gains `gmailService: GmailContextRetrieving?` (a narrow protocol seam,
  §4), defaulted `nil` so every predating call site and test compiles unchanged and a nil service
  means "no email block" — the exact pattern of `folderMetadataStore`/`promptActionService`
  (`MeetingBriefService.swift:25-34`).

### D-M4 — Q&A escalation: second marker `EMAIL_SEARCH:`, one shared escalation round

**Options considered**

1. **Second marker + parallel block**: add `EMAIL_SEARCH:` beside `VAULT_SEARCH:`
   (`MeetingQAComposer.vaultSearchMarker`, `Services/Meetings/MeetingLLMService.swift:539`), keep
   `VaultPassage` untouched, add an email-passage parameter to `compose`.
2. **Generalize** `VaultPassage` into a source-tagged `KnowledgePassage` and one generic
   `SEARCH(source):` marker.

**Decision: option 1.** `VaultPassage` is threaded through `ObsidianVaultService`,
`MeetingQAComposer.compose` (`:575-582`), `MeetingBriefService`, and their test suites; renaming or
wrapping it is churn across files this phase otherwise leaves alone and buys no capability two
sources need (a third source someday can pay for the generalization). Option 1 is additive on
exactly the three Phase-3-owned files and keeps every existing test green. (These are fork-owned
meetings files — upstream divergence is not at stake either way; minimal diff wins.)

**Mechanics (normative):**

- `MeetingQAComposer` gains `static let emailSearchMarker = "EMAIL_SEARCH:"`,
  `emailSearchTerms(in:)` (same line-prefix detection contract as `vaultSearchTerms(in:)`, `:548`),
  and `strippingEscalationLines(from:)` which strips **both** marker forms (supersedes
  `strippingVaultSearchLines`, `:563`, which stays as a call-through for existing tests).
- `compose` gains `retrievedEmailPassages: [EmailPassage] = []`, rendered **last**, after the
  retrieved-vault block, under its own localized header with its own `charBudget / 4` slice, and —
  like both vault sections — withheld entirely when the transcript is empty (`:629-634` pattern).
  The prefix-keeping final bound (`:641-646`) thus drops email excerpts first under pressure;
  transcript primacy and the cross-meeting-leak ordering are untouched.
- **Invitations**: pass 1's system prompt appends the vault invitation only when
  `vaultService.isConnected` (`MeetingLLMService.swift:243-246`); identically, it appends a new
  `meetings.qa.systemPrompt.emailSearchInvitation` only when `gmailService.isConnected(for:
  meeting)`. Neither, one, or both may be extended.
- **One-round cap across BOTH sources (normative):** there is exactly **one escalation round per
  answer**, ever. Pass 1's reply is scanned for both markers; if **either or both** are present,
  the host runs the requested retrievals **within that single round** (vault retrieval at the
  existing escalation scope `:359`; email retrieval via `gmailService.retrieve(for: meeting,
  query: terms, limit: 3)` with the marker's terms — falling back to the question text for a bare
  marker — the service's D-M2 window already covers the meeting day), composes one
  pass 2 with every non-empty retrieved block, and re-asks once. If **all** requested retrievals
  come back empty, degrade to the existing localized "not covered" answer (`:275-281` pattern). Any
  marker in the pass-2 reply is stripped, never honored (`:303` loop-guard pattern, now stripping
  both forms); an all-marker pass-2 reply degrades to "not covered".
- **Disclosure**: the pass-2 answer prefix reflects what was actually consulted — existing
  `meetings.qa.answer.vaultConsultedPrefix` (vault only), new
  `meetings.qa.answer.emailsConsultedPrefix` (emails only), new
  `meetings.qa.answer.vaultAndEmailsConsultedPrefix` (both).
- Progress state: `searchingVaultMeetingIDs` (`:47`) is joined by
  `searchingEmailsMeetingIDs: Set<UUID>` with identical lifecycle (inserted before the email
  retrieval, cleared in the existing `defer`, `:188-191`); same "no view consumes this yet"
  posture as the vault set.
- Gmail retrieval failure during escalation degrades to "emails contributed nothing" (empty
  block), never fails the answer.
- Injection: `MeetingLLMService` gains `gmailService: GmailContextRetrieving?`, defaulted `nil`
  (same seam as D-M3).

### D-M5 — Relevance judging: lexical-only in v1; no new `MeetingModelPurpose`

**Options:** (a) a new `MeetingModelPurpose` case (`.emailsJudge`-style,
`isTemplateOverridable = false`) plus a judge input/parse contract mirroring
`MeetingRelatedDocsService.parseJudgeReply`'s fail-closed NONE/int-list grammar
(`Services/Meetings/MeetingRelatedDocsService.swift:219`); (b) **lexical-only ranking, no LLM
judge**.

**Decision: (b) for v1.** The vault needs a judge because its candidate generator is a blind
whole-vault lexical sweep (`candidateNotes`, `ObsidianVaultService.swift:229`) — high recall, junk
included. Gmail candidates arrive **pre-filtered by structured server-side operators** (attendee
addresses, title terms, a date window): the precision problem the judge solves is largely solved
before ranking. A judge would add one LLM call + seconds of latency to every brief and — worse —
to the live surface's refresh path, plus a settings row, defaults keys, and a purpose case, for
marginal precision on an already-scoped set. Ship lexical; observe. **Follow-up trigger:** if QA
shows noisy email sections in briefs, add the judge behind the brief path only (never the live
list), as purpose case `.emailsJudge` with `isTemplateOverridable = false`, keys
`meetings.models.emailsJudge.providerId/.model` (the naming pattern of
`App/UserDefaultsKeys.swift:225-227`), and the DB3 parse contract — the name and shape are
reserved here so the follow-up is mechanical. **Phase 3 therefore touches neither
`MeetingModelRouter.swift` nor the model-settings UI.**

### D-M6 — UI: `MeetingRelatedEmailsSection` in all three body modes; open-in-Gmail via the join launcher

**Placement.** A new `Views/Meetings/MeetingRelatedEmailsSection.swift` modeled directly on
`MeetingRelatedDocsSection` (`Views/Meetings/MeetingRelatedDocsSection.swift` — header +
gated body + row list), rendered:

1. **Briefing page** — appended in `scheduledEmptyBody`
   (`Views/Meetings/MeetingDocumentBody.swift:38-46`) below `MeetingRelatedDocsSection`.
2. **Live capture page** — in `liveNotesBody` (`:92-104`, today agenda + notes only): a
   **collapsed-by-default `DisclosureGroup`** ("Related emails (N)") below `MeetingNotesPane`, so
   the capture page stays notes-first and the transcript pane keeps its primacy; expanding reveals
   the same row list plus the refresh affordance.
3. **Appendix** — a `MeetingAppendixRow` in `appendix` (`:222-274`) beside the related-documents
   row (`:266-273`), summary = row count, gated like the docs row on
   connected-or-nonempty.

**Gating**: the section renders its rows only when `viewModel.isGmailConnected` (mirror of
`isVaultConnected`, `ViewModels/MeetingsViewModel.swift:80`). **Recompute trigger (normative)**:
the mirror subscribes to `GoogleAccountStore.objectWillChange` with a main-queue hop — the
`vaultPath` re-check pattern (`MeetingsViewModel.swift:368-374`) — because Gmail-toggle flips
announce only via `objectWillChange`, never through `$accounts` (D-M7). When not connected, a
one-line inert hint ("Enable Gmail for a Google account…") — mirroring
`meetingdoc.related.notConnected` (`MeetingRelatedDocsSection.swift:26-29`); **except** when the
last fetch error for the meeting was `.needsReauth`, in which case the section shows a reconnect
hint instead ("Reconnect %@ in Settings…") — an owning account in `.needsReauth` must not
masquerade as "Gmail not enabled". When no account exists at all the section renders nothing
(the briefing page must not advertise plumbing the user never configured).

**Data flow**: new `ViewModels/MeetingsViewModel+RelatedEmails.swift` (the
`+RelatedDocs.swift` pattern): `relatedEmails(for:) -> [EmailRow]` served from a published
`[UUID: [EmailRow]]`, `fetchRelatedEmails(for:)` / `refreshRelatedEmails(for:)` async methods
calling the service (`candidates(for:)` / `refresh(for:)`), `isFetchingRelatedEmails(for:)`,
`lastEmailFetchError(for:)` — fed both by thrown fetch errors and by the service's per-meeting
`lastPartialError(for:)`, which surfaces a partially failed multi-account fetch that would
otherwise hide behind the merged remainder (§4, M1 review adjudication). The section triggers
`fetchRelatedEmails` from `.task(id: meeting.id)`
— served from the D-M1 cache when fresh, so re-navigation costs nothing.

**Refresh cadence (normative)**: fetch on appear + a manual refresh button (progress spinner while
in flight, `MeetingRelatedDocsSection.findButton` pattern) in **all** modes; in the **live** mode
only, the section additionally auto-refreshes on a timer equal to the cache TTL (5 min), so
mid-meeting arrivals surface without interaction but the API is never polled per-minute. A caption
shows "Updated at %@".

**Row** = subject (bold, 1 line) · sender display name · relative date · snippet (2 lines,
secondary) · account email caption when >1 account was searched. Row click / "Open in Gmail":

- **URL form (normative)**: `https://mail.google.com/mail/?authuser=<accountEmail>#all/<messageID>`
  — `authuser` by email pins the correct Google session in the browser (index-based `/u/N/` is
  ordering-fragile), `#all/<messageID>` deep-links the thread view containing the message.
  Built by a pure `GmailWebURL.messageURL(messageID:accountEmail:)` helper (unit-tested,
  percent-escaping the email).
- **Launch**: `MeetingJoinLauncher.open(url: url, accountSub: candidate.accountSub)`
  (`MeetingJoinLauncher.swift:68`). The launcher is join-*named* but its contract is exactly what
  this needs — http(s)-only guard, per-account Chrome-profile preference, system-browser fallback —
  so v1 **reuses it as-is** (one added doc-comment line noting the second caller) rather than
  renaming a Phase-1 file mid-parallel-cycle. So the account is honored twice: the right Chrome
  profile (or system browser) *and* the right Google session via `authuser`. A generalizing rename
  (`AccountLinkLauncher`) is an explicit non-goal this cycle.

### D-M7 — Per-account Gmail toggle in `GoogleAccountsSection`

Mirrors the Phase 1 §9 pattern (the same one Phase 2 uses for Drive):

- **UI**: in each `accountRow(_)` (`Views/Meetings/GoogleAccountsSection.swift:141-173`), below the
  `linkOpeningPicker`, a `Toggle` "Search Gmail for meeting context" + one caption line. Disabled
  while `authService.isAuthorizing` (the M2 gating precedent, `:162`).
- **Turning on**: if `account.grantedScopes` already contains the Gmail scope ⇒ just set the flag.
  Otherwise run `reauthorize(accountID: account.id, additionalScopes:
  [GmailContextService.gmailScope])` through the section's existing `runAuthFlow` driver
  (`:350-359`, inline error via `GoogleConnectErrorPresenter`); set the flag **only after** the
  flow succeeds (scope union lands via `GoogleAccountStore.upsert`,
  `GoogleAccountStore.swift:146-161`). A cancelled consent leaves the toggle off.
- **Turning off**: clear the flag. No token revocation — the grant stays on the account (revoking
  would kill Calendar too, since Google revokes the whole token); the caption says searches stop
  immediately.
- **Scope constant**: `GmailContextService.gmailScope =
  "https://www.googleapis.com/auth/gmail.readonly"` — deliberately **not** on `GoogleAuthService`,
  whose Phase 1 comment (`GoogleAuthService.swift:58-59`) directs later phases to pass scopes
  through `reauthorize` instead of adding constants there. This also removes `GoogleAuthService`
  from the shared-conflict surface entirely (§6/§10).
- **Storage**: dynamic per-sub defaults key `google.account.<sub>.gmailEnabled` (Bool), read/written
  **only** by `GoogleAccountStore` via `isGmailEnabled(for accountID:)` /
  `setGmailEnabled(_:for:)` — the exact `linkOpeningKey` pattern (`GoogleAccountStore.swift:
  188-211`), including `objectWillChange.send()` on set (the flag is not account identity; do not
  republish the index and ripple the calendar sync trigger) and explicit key removal in
  `remove(accountID:)` (`:166-171`).
- **Effective enablement (the `isConnected` rule, normative)**:
  `account.status == .connected && account.grantedScopes.contains(gmailScope) &&
  store.isGmailEnabled(for: account.id)`. Pure helper
  `GmailAccountEligibility.isEnabled(account:flagged:)` so it is testable without the store.
  `GmailContextService.isConnected` = ≥1 account passes; `isConnected(for meeting:)` additionally
  applies the D-M2 owning-account resolution (a meeting owned by a Gmail-disabled account with no
  other enabled accounts ⇒ not connected for that meeting).

---

## 4. Data model & type changes (nothing persisted — flagged)

**No SwiftData changes.** No `@Model` edits, no new stores, no new columns. Flagged persistent
side-effects: brief `MeetingOutput`s / Q&A `MeetingQATurn`s may *contain* email-derived prose
(D-M2, disclosed); the per-account `google.account.<sub>.gmailEnabled` Bool in UserDefaults
(D-M7); nothing else.

New value types (in `Services/Google/`):

```swift
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

/// A metadata-only candidate for the UI list (no body fetch). Same fields as EmailPassage minus
/// `content`, plus `messageID: String` — the raw Gmail message id carried beside the namespaced
/// `id` so the body fetch and GmailWebURL never re-parse it (M1 review).
struct EmailCandidate: Sendable, Equatable, Identifiable { /* see above */ }

/// SERVICE-computed retrieval scope (D-M1 — unlike the vault template's caller-computed scope,
/// because scope resolution needs GoogleAccountStore access the meetings services rightly lack).
/// Internal to GmailContextService + GmailQueryBuilder; also the cache-fingerprint input.
struct EmailRetrievalScope: Equatable, Sendable {
    var accountSubs: [String]         // resolved per D-M2 (owning account first)
    var attendeeEmails: [String]      // self-exclusion set already subtracted (D-M2)
    var titleTerms: String            // the meeting title (builder tokenizes)
    var afterDay: String              // serialized date-granular window (D-M1 rule) —
    var beforeDay: String             //   fingerprint-stable across fetches within a day
}
```

New protocol seam (in `Services/Google/GmailContextService.swift`, consumed by the two meetings
services so tests inject a stub that never touches the network — the `MeetingBriefGenerating`
precedent, `MeetingBriefScheduler.swift:31`):

```swift
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
```

`GmailContextService` itself: `@MainActor final class`, `ObservableObject`; init
`(store: GoogleAccountStore, tokenProvider: GoogleAccessTokenProviding, transport:
GoogleHTTPTransport = URLSessionGoogleTransport(), now: @escaping () -> Date = Date.init,
cacheTTL: TimeInterval = 300)`; `@Published private(set) var isFetching`; constructed in
`ServiceContainer` beside the calendar engine and handed to `MeetingBriefService` /
`MeetingLLMService` / the VM extension. Multi-account fetch failures isolate per account (one
account's error never drops another's candidates — the `performSync` per-account pattern,
`GoogleCalendarSyncEngine.swift:168-194`); `.needsReauth` is never retried (the auth service
already flipped the badge). A **partial** multi-account failure (some accounts failed while the
others' candidates were merged and cached) is surfaced per meeting via `lastPartialError(for:)`
(`@Published lastPartialErrors: [UUID: String]`, cleared on a fully clean fetch) so the D-M6
fetchFailed line can show partial loss — only a total failure throws (M1 review adjudication;
the `firstError` precedent). Candidate fetches are single-flight per meeting: concurrent
same-meeting callers await one network pass, and `isFetching` derives from the in-flight map
(M1 review).

---

## 5. Milestones

Each milestone leaves the app building and the full test suite green. New Swift files are added to
`TypeWhisper.xcodeproj` using **pbxproj IDs `GGF/GGB…0100-0199` only** (§10). No SDK/package
changes anywhere. **Every user-facing string in every milestone ships EN + DE in the same
milestone** (CLAUDE.md localization rule — the "EN strings" lists below name the keys; DE is not
optional or deferred). Strings that embed machine markers must embed them **verbatim in both
languages**: the DE variant of the D-M4 escalation invitation carries the literal `EMAIL_SEARCH:`
token exactly as the vault invitation's DE string carries `VAULT_SEARCH:` (the precedent
documented at `MeetingLLMService.swift:536-539`).

### M1 — Gmail API client + query builder + `GmailContextService` (no UI, no consumers)

**Create** (`TypeWhisper/Services/Google/`):

- `GmailAPI.swift` — Codable models (`GmailMessageList {messages: [{id, threadId}]?,
  resultSizeEstimate?}`, `GmailMessage {id, threadId, snippet?, internalDate?, payload?}`,
  `GmailPayload {mimeType?, headers? [{name, value}], body? {data?}, parts? [GmailPayload]}`) +
  request builders `listRequest(token:query:maxResults:)`,
  `messageMetadataRequest(token:id:)`, `messageFullRequest(token:id:)` + its own
  `RequestFailed(statusCode:)` error (the `GoogleCalendarAPI` shape).
- `GmailQueryBuilder.swift` — pure D-M1 two-query assembly + the D-M2 window helper
  `window(reference:)` and the date-granular serializer (`before:` = day after the end instant).
- `GmailBodyText.swift` — pure: base64url decode, plain-part-first traversal, HTML tag-strip +
  entity decode, 2,000-char cap.
- `GmailContextService.swift` — D-M1/D-M2 pipeline, TTL cache, account resolution,
  `GmailContextRetrieving`, `GmailAccountEligibility`, `gmailScope` constant, `EmailPassage` /
  `EmailCandidate` / `EmailRetrievalScope`, `GmailWebURL`.

**Modify:** `GoogleAccountStore.swift` — `isGmailEnabled(for:)` / `setGmailEnabled(_:for:)` +
key cleanup in `remove(accountID:)` (D-M7 storage only; the toggle UI is M2).
`ServiceContainer.swift` — construct `gmailContextService` (no consumers yet).

**Tests:** `GmailQueryBuilderTests` (two-query split with per-clause caps, `subject:(…)`
AND-scoping, 8-address / 4-term caps, nil-query guards, **self-exclusion**: `isSelf` attendees ∪
all connected-account emails, case-insensitive; **date serialization**: `before:` = calendar day
after the window-end instant, window-end day's mail always in range); `GmailBodyTextTests`
(base64url, plain-over-html precedence, tag-strip, cap); `GmailContextServiceTests` (fake
transport + fake token provider + fake clock: two-call merge + threadId dedupe with attendee
precedence, bounded-concurrency metadata fetch, thread collapse, re-rank with date-order
fallback, cache TTL hit/expiry, **fingerprint stability across same-day fetches** and miss on
account/attendee/window change, invalidation on store `objectWillChange`, refresh bypass,
per-account error isolation, `.needsReauth` skip, owning-account vs all-accounts resolution);
`GmailAccountEligibilityTests`; `GoogleAccountStoreGmailFlagTests` (flag round-trip, cleared on
remove); `GmailWebURLTests`.

**EN strings:** none (no UI).

### M2 — Per-account Gmail toggle in settings

**Modify:** `Views/Meetings/GoogleAccountsSection.swift` — the D-M7 toggle + caption per account
row, reauthorize-on-missing-scope through `runAuthFlow`, flag set only on success. Every ON path
routes through the tested `GmailToggleState.enable` seam, which **re-checks the granted scopes
after the flow** (granular consent: an unticked Gmail checkbox on Google's consent screen lets
the flow succeed without the scope — the toggle then stays off, silently, like a cancel).

**Tests:** `GmailToggleStateTests` — pure mapping `(GoogleAccount, flag) → (isOn, needsReauthFlow)`
extracted as a static helper so the view stays logic-free (the `GoogleAccountRowState` precedent),
plus the `enable` ordering seam (consent-first, flag untouched on throw, granular-consent
no-grant ⇒ flag off, no consent when the scope is already granted).

**EN strings (dev adds DE):**
`google.gmail.toggle` "Search Gmail for meeting context";
`google.gmail.toggleCaption` "Finds emails related to your meetings for briefs, Q&A, and the Related emails list. Read-only; turning this off stops searches immediately." (the trailing sentence carries D-M7's stops-immediately note);
`google.gmail.consentHint` "Google will ask you to allow read-only Gmail access.".

### M3 — Brief integration (D-M3)

**Modify:** `Services/Meetings/MeetingBriefService.swift` — `gmailService:
GmailContextRetrieving?` (nil-defaulted), `relatedEmailsBlock(for:)`, relaxed insufficiency guard,
`assembleContext` email reserve + section; `ServiceContainer.swift` — pass the service.

**Tests:** `MeetingBriefServiceEmailBlockTests` (stub retriever): email-only context passes the
guard **when the meeting has a non-self attendee email**, and is rejected as sole grounding when
title-only (D-M3 sole-grounding restriction); block rendering; thrown retrieval degrades to empty
block and the brief still generates; **budget: huge prior block + huge KB block → the email slice
still survives at ≥ its reserve** (the KB-subtracts-emailReserve fix), plus emails-survive-huge-
prior alone; section ordering; nil service ⇒ byte-identical context to today (regression).

**EN strings:** `meetings.brief.context.emailsHeader` "Related emails:".

### M4 — Q&A escalation (D-M4)

**Modify:** `Services/Meetings/MeetingLLMService.swift` — `gmailService` seam,
`searchingEmailsMeetingIDs`, dual-marker scan, single shared escalation round, disclosure-prefix
selection; `MeetingQAComposer` — `emailSearchMarker`, `emailSearchTerms(in:)`,
`strippingEscalationLines(from:)`, `retrievedEmailPassages` block.

**Tests:** `MeetingQAComposerEmailTests` (marker detect/strip both forms, mid-sentence immunity,
email block rendered last + withheld without transcript, budget slice);
`MeetingLLMServiceEmailEscalationTests` (stub processor + stub retriever): vault-only, email-only,
both-markers-one-round, pass-2 marker stripped never honored, all-empty ⇒ not-covered, retriever
throw ⇒ vault-only pass 2, correct disclosure prefix per combination, invitation appended only
when Gmail connected.

**EN strings:** `meetings.qa.systemPrompt.emailSearchInvitation` (instructs the single-line
`EMAIL_SEARCH: <terms>` reply — the literal marker embedded verbatim in **both** the EN and DE
variants, per the §5 preamble / `MeetingLLMService.swift:536-539` precedent);
`meetings.qa.context.emailsHeader` "Related emails (secondary to the transcript):";
`meetings.qa.answer.emailsConsultedPrefix` "I also checked your email for this.";
`meetings.qa.answer.vaultAndEmailsConsultedPrefix` "I also checked your notes and email for this.".

### M5 — Related-emails UI (D-M6)

**Create:** `Views/Meetings/MeetingRelatedEmailsSection.swift` (styles: `.standard` /
`.live`-collapsed); `ViewModels/MeetingsViewModel+RelatedEmails.swift`.

**Modify:** `Views/Meetings/MeetingDocumentBody.swift` — section in `scheduledEmptyBody` (:38),
collapsed group in `liveNotesBody` (:92), appendix row (:222); `MeetingsViewModel.swift` —
`isGmailConnected` mirror (the `isVaultConnected` pattern, :80), recomputed on
`GoogleAccountStore.objectWillChange` with a main-queue hop (the vault-path re-check pattern,
:368-374 — `$accounts` alone would miss Gmail-toggle flips, D-M6).

**Tests:** `EmailRowPresentationTests` (pure candidate → row mapping: sender display, relative
date, account caption only when >1 account searched); `RelatedEmailsFetchStateTests` (VM extension
with stub service: fetch populates rows, error captured, refresh bypasses cache, per-meeting
isolation).

**EN strings:** `meetingdoc.emails.title` "Related emails";
`meetingdoc.emails.notConnected` "Enable Gmail for a Google account in Settings to see related emails.";
`meetingdoc.emails.empty` "No related emails found.";
`meetingdoc.emails.refresh` "Refresh";
`meetingdoc.emails.updatedAt` "Updated %@";
`meetingdoc.emails.open` "Open in Gmail";
`meetingdoc.emails.liveTitle` "Related emails (%lld)";
`meetingdoc.emails.fetchFailed` "Couldn't search Gmail: %@";
`meetingdoc.emails.needsReauth` "Reconnect %@ in Settings to search Gmail." (the D-M6
needs-reauth empty-state variant, keyed off the last fetch error).

### M6 — Rebase onto Phase 2 + integration + QA

Phase 2 merges first (§10). Then:

1. Rebase `feature/google-phase3-gmail` onto the post-Phase-2 trunk; resolve the expected conflicts
   (`GoogleAccountsSection.swift` — Drive toggle beside the Gmail toggle;
   `Localizable.xcstrings`; `project.pbxproj`; possibly `ServiceContainer.swift` /
   `GoogleAccountStore.swift` — all additive by construction on both sides).
2. Full suite: `xcodebuild test … -parallel-testing-enabled NO` + `scripts/pr-preflight.sh`.
3. Manual QA script (§7) on a dev build with real accounts.
4. Verify Drive + Gmail toggles coexist per account row and neither reauthorize path clobbers the
   other's scope (scope union, `GoogleAccountStore.upsert`).

---

## 6. Upstream-shared files touched

Target: **zero SDK/package files** — met (no change under `TypeWhisperPluginSDK/`).

| File | Change |
|---|---|
| `TypeWhisper/App/ServiceContainer.swift` | one wiring block (service + two init args) |
| `TypeWhisper/Resources/Localizable.xcstrings` | added keys only |
| `TypeWhisper.xcodeproj/project.pbxproj` | new file refs, IDs `…0100-0199` only |

`GoogleAuthService.swift` is deliberately **not** touched (scope constant lives on
`GmailContextService`, D-M7). Everything else modified is fork-owned meetings/Google surface.
`Views/SettingsView.swift`, `UserDefaultsKeys.swift` (the Gmail flag is a dynamic store-owned
key), `MeetingModelRouter.swift`, and `JobQueueService`/`MeetingJob.swift` are untouched.

---

## 7. Test plan

**Unit** (per milestone, §5) — pure logic over fakeable seams: `GoogleHTTPTransport`,
`GoogleAccessTokenProviding`, `GmailContextRetrieving`, stub `PromptProcessing`, injected clocks,
ephemeral `UserDefaults` suites. No test touches the network, the Keychain, or a real mailbox.
Run scoped: `xcodebuild test … -only-testing:TypeWhisperTests/GmailContextServiceTests` etc.

**Manual QA script** (requires the §9 runbook completed, `CodeSigning.local.xcconfig` present, ≥1
account with real meeting-related mail):

1. `scripts/build-dev-local.sh`; Settings → Meetings → Google Accounts: each account row shows the
   Gmail toggle off; meeting documents show the "enable Gmail" hint in the Related-emails section
   only when ≥1 account exists.
2. Toggle Gmail ON for an account lacking the scope → browser consent lists "Read your email
   messages and settings" (read-only) → approve → toggle lands ON. (Testing-mode consent: the
   account must be a listed test user; expect the unverified-app interstitial.)
3. Toggle OFF → related-email sections go inert immediately. Toggle ON again → no consent prompt
   (scope already granted), flag flips instantly.
4. Open a calendar meeting (Google-owned, with attendees you've mailed): briefing page shows
   Related emails rows — subjects/senders plausible, one row per thread, newest first-ish; Refresh
   spins and completes; "Updated %@" advances.
5. Click a row → correct browser/Chrome profile opens (the account's link-opening preference), and
   the correct Google session shows the thread (authuser routing).
6. Generate a brief → it contains a Related-emails-informed section; with Wi-Fi off, regenerate →
   brief still generates from prior meetings/vault (email block silently absent).
7. Q&A: ask something answerable only from a related email ("what did X say about the contract in
   email?") → answer arrives with the emails-consulted disclosure prefix; verify no
   `EMAIL_SEARCH:`/`VAULT_SEARCH:` token ever renders in the UI. Ask something in neither
   transcript, vault, nor email → "not covered" answer.
8. Live: start capture on a meeting; the Related emails disclosure sits collapsed under notes;
   send yourself an email from an attendee's account mid-meeting; after Refresh (or ≤5 min) it
   appears. Q&A mid-capture with an email escalation works.
9. Multi-account: meeting owned by account A (Gmail on) → rows come from A only; ad-hoc meeting →
   rows merge from every enabled account with account captions.
10. `.needsReauth` (revoke at myaccount.google.com/permissions): section shows the fetch-failed
    line; settings badge flips; briefs still generate without emails. Reconnect heals both
    (Calendar + Gmail — one grant).
11. Privacy spot-check: quit the app, relaunch → related-email lists are empty until refetched
    (nothing persisted); `defaults read` shows only the `gmailEnabled` bool; no email content in
    Console logs.
12. Disconnect the account entirely → toggle state and rows disappear; Keychain swept (Phase 1
    behavior); reconnect re-adds with Calendar-only scope (Gmail toggle off again — the flag was
    cleared on remove).

---

## 8. Risks & open questions

- **Restricted scope in Testing mode (decided — do not re-litigate):** the consent screen stays in
  **Testing**; `gmail.readonly` (restricted) works for listed test users; **all** refresh tokens —
  including Calendar's — expire weekly, flipping accounts to "Needs attention" until reconnected.
  Accepted cost; the §9 runbook and QA step 10 cover the symptom. Verification is a later decision.
- **Quota/latency:** one refresh ≈ 2 `list`s + ≤35 metadata `get`s (+≤3 full `get`s on LLM paths)
  per searched account — trivial against Gmail's default per-user quota; the 5-min TTL and the
  no-auto-poll-except-live rule keep the live surface bounded. Latency: **~1–2 s** with the
  normative bounded-concurrency metadata fetch (D-M1, task-group width 6); a sequential loop
  would be 3–6 s, which is why concurrency is normative, not an optimization. 403/429 surfaces as
  a fetch error and is retried on next refresh; no backoff scaffold in v1.
- **Lexical-only precision (D-M5):** promotions/newsletters from an attendee's domain can slip
  through despite the category filters. Mitigation: filters + thread collapse + snippet-visible
  rows (junk is recognizable at a glance). Trigger for the reserved `.emailsJudge` follow-up is
  documented in D-M5.
- **HTML fidelity:** `GmailBodyText`'s tag-strip is deliberately naive; heavily-templated mail may
  yield noisy passages. Bounded at 2,000 chars; brief/Q&A prompts already tolerate messy context.
- **`authuser` routing** relies on the target session being signed in inside the opened
  browser/profile; if not, Gmail shows an account chooser — degraded, not broken.
- **Prompt-injection surface:** email bodies are attacker-authored text entering LLM context. Same
  standing risk as vault notes/transcripts; blocks are labeled as quoted context and rendered last.
  No new mitigation in v1 — noted for a cross-cutting hardening pass.
- **Attendee-less meetings** (ad-hoc, solo) degrade to title-terms-only queries — weaker recall by
  construction; the empty state copes.
- **Open for Marco:** (a) is the 14-day lookback right, or should it be a setting? (b) should the
  brief's email block be excludable per meeting (like `noVaultContext`) in a follow-up? (c) live
  auto-refresh at TTL cadence — keep, or manual-only?

---

## 9. Runbook delta (Google Cloud console — extends Phase 1 Appendix A)

1. **Enable the API**: *APIs & Services → Library* → **Gmail API** → Enable (same project).
2. **Consent screen**: *Google Auth Platform → Data access (Scopes)* → add
   `https://www.googleapis.com/auth/gmail.readonly`. This is a **restricted** scope.
3. **Publishing status — decided:** the app is in **Testing** mode. Ensure every Google account
   you will toggle Gmail on for is listed under **Audience → Test users**. Expected consequences:
   the unverified/testing interstitial at consent, and **7-day refresh-token expiry for the whole
   grant (Calendar included)** — weekly "Needs attention" → Reconnect is the accepted routine.
   Do **not** publish to production: unverified production apps are blocked outright for
   restricted scopes.
4. In-app: Settings → Meetings → Google Accounts → toggle **Search Gmail for meeting context** on
   the account → complete the consent flow. No client ID/secret changes — same Desktop-app client.

---

## 10. Parallel-run coordination (binding — Phase 2 builds concurrently)

- **Branch/worktree:** dev creates worktree **`/Users/marco/Projects/typewhisper-wt-google-phase3`**
  on branch **`feature/google-phase3-gmail`**, forked from **`feature/google-phase1-auth-calendar`**
  (NOT from Phase 2's branch). **Phase 2 merges first**; M6 rebases this branch onto the
  post-Phase-2 trunk before QA/PR.
- **pbxproj ID ranges:** Phase 3 uses **`GGF…/GGB…` suffixes 0100–0199 exclusively** (e.g.
  `GGF0000000000000000100`). Phase 2 owns 0040–0099; Phase 1 consumed up to ~0034. Never mint
  outside the reserved range.
- **Phase-2-owned files — Phase 3 must NOT touch:** `TranscriptFileParser.swift`,
  `MeetingImportService.swift`, `JobQueueService.swift`/`MeetingJob.swift` (import job kinds),
  any WatchFolder-style poller, and Phase 2's own `Services/Google/GoogleDrive*` files.
  (This spec adds no job kinds and no pollers — verified against §1 non-goals.)
- **Shared files — expect rebase conflicts, keep edits minimal/additive:**
  `GoogleAccountsSection.swift` (one toggle block per phase; place Gmail's below the link-opening
  picker and merge Drive's beside it at rebase), `GoogleAccountStore.swift` (each phase adds its
  own dynamic-key accessor pair + one `remove` cleanup line), `ServiceContainer.swift`,
  `MeetingsViewModel.swift` (M5 adds the `isGmailConnected` mirror to the VM body; Phase 2 may
  touch the VM too — keep the addition to one self-contained block),
  `Localizable.xcstrings` (distinct key prefixes: `google.gmail.*` / `meetingdoc.emails.*` /
  `meetings.qa.*emails*` — no key collisions possible), `project.pbxproj` (disjoint ID ranges).
  `GoogleAuthService.swift` is not edited by Phase 3 at all (D-M7).
- **Phase-3-owned this cycle (Phase 2 won't touch):** `MeetingBriefService.swift`,
  `MeetingLLMService.swift` (incl. `MeetingQAComposer`), `MeetingRelatedDocsService.swift`
  (unchanged in v1 but reserved), `MeetingDocumentBody.swift`.
- **PR:** squash-merge to the trunk after Phase 2; template Summary + Test Plan with the exact
  `-only-testing` commands from §7; do not bump any `TypeWhisperPluginSDK/Package.swift` pins.
