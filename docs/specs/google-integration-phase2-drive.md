# Google Integration Phase 2 — Drive Transcript Auto-Import + Historical Backfill

Status: **Design — authoritative target for Phase 2** (branch off
`feature/google-phase1-auth-calendar`, which carries the fully built Phase 1 auth + Calendar
layer; see `docs/specs/google-integration-phase1-auth-calendar.md`).
Phase 2 of three: Phase 1 auth + Calendar (built) → **Phase 2 Drive import/backfill (this
spec)** → Phase 3 Gmail context.

Decision IDs are `D-D1`…`D-D8`; code comments cite them the same way the codebase cites
`D-A2`/`D-G2`/`M11`. All `file:line` anchors below were verified against the Phase 1 worktree
(`feature/google-phase1-auth-calendar`), which supersedes the recon document where they disagree.

---

## 1. Goals / non-goals

### Goals

1. **Auto-import Gemini meeting transcripts from Google Drive.** The Gemini "Notes by Gemini" /
   "Notas de Gemini" Google Docs that Meet drops into Drive are discovered as they appear (per
   connected, Drive-enabled account), exported as markdown, parsed through the existing
   `TranscriptFileParser` Gemini rung, and **attached to the right meeting**: merged into an
   existing meeting when a confident match exists (including the flagship collision — a meeting
   already carrying live captions), else created as a new `.importedTranscript` meeting dated
   from the export filename.
2. **Historical backfill with user control.** A per-account "Import past transcripts" flow scans
   the account's Drive for old Gemini notes docs, previews them (clean title, real date, matched
   meeting), and batch-imports the selection with progress, cancellation, and rate limiting.
3. **Per-account enablement.** Drive import is opt-in per Google account (a toggle in the
   existing accounts section); enabling it triggers the incremental-scope reauthorize built in
   Phase 1 (`GoogleAuthService.reauthorize(accountID:additionalScopes:)`,
   `TypeWhisper/Services/Google/GoogleAuthService.swift:163`).
4. **Idempotency.** A file is never imported twice; a doc that Gemini keeps editing after the
   meeting is re-merged into the same meeting, not duplicated.
5. **Testing-mode consent strategy** (D-D1, user-decided): the Phase 1 consent screen moves back
   to Testing so the restricted Drive scope works without verification; the weekly
   refresh-token expiry this brings is absorbed by a hardened one-click reconnect UX (D-D8).
   The Phase 1 runbook delta is Appendix A.

### Non-goals (Phase 2)

- **No Gmail** (Phase 3). The reconnect/scope machinery this phase generalizes is Phase 3's seam.
- **No Meet REST API** (`conferenceRecords.transcripts`): it needs its own scopes and only covers
  Meet's raw transcription artifacts, not Gemini notes docs. Drive is the one source of truth here.
- **No Drive `changes.list` / push notifications / watch channels** (rejected in D-D3).
- **No Meet "… - Transcript" doc format**: v1 discovers Gemini notes names only
  (`ImportedMeetingTitle.notesSuffixes`, `Services/Meetings/ImportedMeetingTitle.swift:20-24`).
  The parser would handle more; the *query* stays narrow. Future widening is a follow-up.
- **No SwiftData schema changes of any kind** — import identity lives in a side ledger (D-D5),
  matching the additive-only store discipline by not touching stores at all.
- **No review inbox for near-miss matches**: below the auto-merge threshold a new meeting is
  created; the existing manual merge (`MeetingMergePlanner`) remains the fold-later recovery.
- **No cross-account doc dedupe engine** (the matcher makes the common case converge — §D-D4).
- **No plugin-SDK changes** (Phase 1 D-G1 placement holds: everything lands in
  `TypeWhisper/Services/Google/`).

---

## 2. Architecture overview

```
GoogleAccountsSection ── per-account "Drive import" toggle ──► GoogleAuthService.reauthorize
        │  (backfill sheet, sync status, reconnect)                (+ drive.readonly, D-D2)
        ▼
GoogleDriveSyncEngine  (app-lifetime, 15-min cadence — the GoogleCalendarSyncEngine shape)
        │   files.list per Drive-enabled account (watermark query, D-D3)
        │   decides per file: unseen / edited / retry / skip   (ledger reads, D-D5)
        ▼
JobQueueService  ──.driveImport / .driveBackfill jobs (io lane, D-D6)──►
        ▼
GoogleDriveTranscriptImporter
        │   files.export (text/markdown) → TranscriptFileParser (Gemini rung)
        │   DriveTranscriptMatcher (D-D4): merge into matched meeting | create + auto-link
        ▼
MeetingImportService.mergeTranscriptText / importTranscriptText ──► MeetingService (single writer)
        │
        └──► GoogleDriveImportLedger (google-drive-imports.json — imported/failed/watermarks, D-D5)
```

New code lives in **`TypeWhisper/Services/Google/`** plus one settings sheet. The importer is the
only writer of the ledger; `MeetingService` stays the single writer of `meetings.store`; the
engine never touches either directly. All new objects are `@MainActor` with network work awaited
inside `async` calls (the Phase 1 discipline); every seam is fakeable (`GoogleHTTPTransport`,
`GoogleAccessTokenProviding`, injected clocks, in-memory ledger).

**Error taxonomy contract** (from Phase 1, `GoogleAuthService.swift:185-187,205-208`): consumers
special-case `GoogleAuthError.needsReauth` (terminal until reconnect) and treat every unknown
error — `CancellationError`, `URLError`, HTTP failures — as transient. The Drive engine follows
`GoogleCalendarSyncEngine.performSync` exactly (`GoogleCalendarSyncEngine.swift:161-210`):
needsReauth skips the account without retry; transient failures surface via `lastSyncError` and
retry next tick.

---

## 3. Decision records

### D-D1 — Consent strategy: Testing mode now, Google verification later — **user-decided (Marco, 2026-08-11)**

`drive.readonly` (and every Drive alternative that can see Gemini docs — see D-D2) is a
**restricted** scope. Google blocks restricted-scope consent entirely for unverified apps
published "In production" — the mode Phase 1 chose (Phase 1 spec §8 anticipated this fork).

**Options researched** (2026 policy, for the record):

| # | Option | Verdict |
|---|---|---|
| a | **Same project/client, consent screen back to Testing** — restricted scopes work for ≤100 listed test users behind a one-click "unverified" interstitial; **all** refresh tokens expire after 7 days | **CHOSEN** (user-decided; expiry accepted as temporary, mitigated in D-D8) |
| b | Second Google Cloud project/client in Testing, used only for Drive-scoped accounts (keeps Calendar tokens long-lived) | Rejected — requires a per-account OAuth-client registry (account↔client binding, per-client secrets, connect-time picker); real complexity Phase 1 deliberately avoided |
| c | Workspace **Internal** app (no verification, no expiry, restricted scopes fine) for accounts on Marco's Workspace orgs | Rejected for now — Internal apps are org-locked (one project per org; personal @gmail excluded), which forces the same multi-client registry as (b) |
| d | `drive.file` (non-restricted) | Rejected — only sees files the user explicitly opens via a Google picker (a web surface); kills auto-discovery, and even manual backfill would need a picker flow the app has nowhere to host |
| e | Full Google verification now (brand + scope justification + CASA Tier 2 assessment) | Deferred — Marco will submit later; Appendix A carries the "path to verification" checklist so nothing here forecloses it |

**Consequences (normative):**

- The **entire consent screen** rides Testing: Phase 1's `calendar.readonly` tokens **also**
  expire every 7 days while in Testing. Accepted (user-decided) as temporary until verification.
  The weekly symptom is every connected account flipping to "Needs attention" (`invalid_grant` →
  `.needsReauth`, `GoogleAuthService.swift:257-263`); D-D8 makes recovery one click and visible.
- **No code path may depend on verification status.** Testing vs verified production differ only
  in console configuration (Appendix A); the app's flow, scopes, and error handling are
  identical. When Marco later verifies the app, nothing ships — tokens simply stop expiring.
- **Simplification recorded:** the per-account scope-strategy split and multi-client support that
  options (b)/(c) would have required are **dropped**. One OAuth client (Phase 1's
  `GoogleAccountStore.clientID`/`clientSecret`), one consent screen, every account on it. The
  per-account **Drive enable toggle survives for UX reasons** (D-D7): not every connected account
  has Meet transcripts, and an off toggle avoids pointless polling and consent prompts.

### D-D2 — Drive scope: `drive.readonly`; `drive.meet.readonly` flagged as a tightening candidate

**Options:** (a) `https://www.googleapis.com/auth/drive.readonly`; (b) `drive.metadata.readonly`
(+ nothing — cannot export content, dead end); (c) `drive.meet.readonly` (July 2024, "Drive files
created or edited by Google Meet" — exactly the Gemini-notes universe).

**Decision: (a) `drive.readonly`,** defined once as `GoogleDriveAPI.readonlyScope`. All three are
equally *restricted*, so under D-D1 there is no consent-policy difference — the choice is
semantics and reliability. (c) is the better citizen (least privilege, and a stronger story for
the later verification submission) but has a reported history of `files.list`/file-endpoint
breakage under the scope (Google issue tracker #365706547) that cannot be verified without
trying. QA step 11 (§7) runs the experiment: if `files.list` + `files.export` behave under
`drive.meet.readonly`, switching is a **one-constant change** plus a consent-screen scope swap —
the code is scope-agnostic by construction. Until then, `drive.readonly` guarantees the
discovery-query and export semantics this spec depends on.

### D-D3 — Discovery: periodic `files.list` watermark query; export as `text/markdown`

**Options:** (a) Drive `changes.list` with a persisted per-account `pageToken`
(`changes.getStartPageToken` bootstrap); (b) periodic `files.list` with a name/MIME query and a
persisted `modifiedTime` watermark.

**Decision: (b).** `changes.list` streams *every* Drive mutation (noisy for a Drive in active
use), needs pageToken lifecycle management (expiry ⇒ full re-bootstrap), behaves unpredictably
under a future narrowed scope (D-D2), and — decisive — **backfill needs the `files.list` query
anyway** (§D-D7: the same query minus the time bound). One code path serves both. The
fingerprint-store durability precedent (`WatchFolderService`,
`Services/WatchFolderService.swift:439-449` — JSON under `AppConstants.appSupportDirectory`)
is followed for the watermark + ledger (D-D5), not the FS-watch mechanism.

**Query (normative,** built by `GoogleDriveAPI.filesListRequest`**):**

```
q = mimeType='application/vnd.google-apps.document'
    and (name contains 'Notes by Gemini' or name contains 'Notas de Gemini'
         or name contains 'Gemini Notes')
    and trashed = false
    [and modifiedTime > '<watermark RFC3339>']        ← omitted for backfill scans
fields = nextPageToken, files(id, name, mimeType, createdTime, modifiedTime)
orderBy = modifiedTime            pageSize = 100      (+ pageToken pagination, maxPages guard)
```

The three name markers are **derived from one canonical list**, not mirrored:
`ImportedMeetingTitle.notesSuffixes` (`ImportedMeetingTitle.swift:20-24`) holds the bare marker
phrases ("notas de gemini", "notes by gemini", "gemini notes") and is today `private static` —
M1 widens it to `static` (internal; the file is fork-owned and Phase 2 owns this change, §4).
The two consumers *derive* differently from the same list: `ImportedMeetingTitle` wraps each
phrase in its dash-separator suffix regex for title cleaning (:44), while
`GoogleDriveAPI.filesListRequest` emits one `name contains '<phrase>'` term per phrase verbatim
(Drive matches case-insensitively). A unit test asserts the query terms are generated from
`notesSuffixes` — one list, two derivations, impossible to drift.
`corpora`/`driveId` are left at defaults (user corpus) for v1; shared-drive widening is a noted
follow-up. RFC3339 formatting reuses the `GoogleCalendarAPI.rfc3339String` helper
(`Services/Google/GoogleCalendarAPI.swift:137`) — hoist it somewhere both can call rather than
duplicating.

**Content fetch: `files.export` with `mimeType=text/markdown`.** Verified against a real export
in hand (`Seguimiento Fase 2 IA - … - Notas de Gemini.md`): Google's Docs→markdown converter
(the same one behind Docs "Download → Markdown", available to `files.export` since July 2024)
produces exactly the shape `TranscriptFileParser.parseGeminiNotes` was built on
(`Services/Meetings/TranscriptFileParser.swift:169-235`): `## **<Title> \- Transcripción**`
title heading, `### **HH:MM:SS**` section headers, `**Speaker:** utterance` turns,
backslash-escaped punctuation (handled by `unescapeMarkdown`, :332), closing
"finalizó después de / Transcript ended" line. This is **load-bearing**: `text/plain` export
drops the heading/bold markup, so the Gemini rung would never fire.

**Fallback rungs (defense in depth):** (1) if the markdown export parses to zero segments, the
parser cascade itself already falls through to the generic rungs (`TranscriptFileParser.parse`,
:36-105), so a format drift degrades to `Speaker:`-line or plain-paragraph parsing rather than
failing; (2) if the export request itself fails with an unsupported-MIME error (HTTP 400/403),
the importer retries once with `text/plain` — degraded timing/speakers, but content lands. Both
paths are unit-tested; no new parser rung is written unless QA shows real drift.

### D-D4 — Attach-to-meeting: score existing meetings with the Phase-1-proven link scoring; merge on confidence, else create + auto-link

There is no auto-matching anywhere today (`MeetingImportService.mergeTranscriptFile` takes an
explicitly chosen meeting, `Services/Meetings/MeetingImportService.swift:203`). Phase 2 builds
it as a pure resolver, `DriveTranscriptMatcher`:

**Inputs:** the file's identity — `ImportedMeetingTitle.parse` on the filename
(`ImportedMeetingTitle.swift:26` — clean title + embedded `yyyy_MM_dd HH_mm TZ` date; matches
Drive names verbatim), falling back to the doc `createdTime` when the filename carries no date —
plus a value snapshot of candidate meetings
`[(id, title, startDate, calendarEventID, segmentCount)]` taken from `MeetingService.meetings`.

**Scoring:** reuse `CalendarService`'s pure statics unchanged — `titleSimilarity`
(`Services/Meetings/CalendarService.swift:374`, token Jaccard), `dateProximity` (:385) and the
0.65/0.35 `linkScore` blend (:395) — over candidates whose `startDate` lies within
`CalendarService.defaultAutoLinkWindow` (±24 h, :441; deliberately narrow so a weekly recurring
title can never hit the wrong occurrence). Threshold: `defaultAutoLinkConfidence` (0.6, :446).
Ranking among qualifying candidates (score ≥ threshold) is **score-dominant with a near-tie
band** (review ruling, 2026-08-11): a score gap wider than **0.05**
(`DriveTranscriptMatcher.affinityTieBand`) is decided by score alone — account affinity must
never redirect a transcript away from a clearly better match (back-to-back recurring
occurrences: yesterday's same-account meeting at ~0.66 would otherwise beat today's unlinked
meeting at ~1.0, silently corrupting the wrong occurrence and breaking cross-account
convergence). Within the band, prefer a meeting whose `calendarEventID` is namespaced to the
**same account** (`GoogleCalendarID.accountSub(fromNamespacedID:)`,
`Services/Google/GoogleCalendarMapper.swift:21-26` — the transcript and the calendar event came
from the same Google account), then higher score, then more segments (the `ranksBefore` spirit,
`MeetingMergePlan.swift`).

**Dispositions (normative):**

1. **Match (score ≥ 0.6)** → merge via the new `MeetingImportService.mergeTranscriptText(_:into:)`
   (M1) — the text twin of `mergeTranscriptFile`: parse, then
   `MeetingService.mergeImport(into:segments:source:)` (`Services/Meetings/MeetingService.swift:657`).
   `ImportOverlapPlan` semantics apply automatically (`Services/Meetings/ImportOverlapPlan.swift:43`;
   policy comment at `MeetingService.swift:650-656`): the timed Gemini import **owns its covered
   span** — overlapped `.liveCapture`/`.liveCaptions` rows are dropped, everything else survives.
   This is THE flagship collision (a meeting captured live via captions whose Gemini notes doc
   lands 10 minutes later) and it is already the tested behavior of the merge path.
2. **No match** → create via `MeetingImportService.importTranscriptText(_:title:startDate:)`
   (`MeetingImportService.swift:141`; gains an additive `startDate:` parameter in M1 —
   `createFromImport` already accepts one, `MeetingService.swift:522`), titled with the clean
   title and dated from the filename — historical meetings land on their real dates. Then a
   best-effort **calendar auto-link**: `CalendarService.bestAutoLinkCandidate(title:date:)`
   (`CalendarService.swift:452`, the bulk-import precedent) and, on a hit,
   `MeetingService.linkToCalendarEvent` (:187) — giving the new meeting event identity and
   attendees. (Historical backfill dates usually fall outside the Google snapshot window, so old
   meetings simply stay unlinked — fine.)
3. **Near-miss (0 < score < 0.6)** → treated as no-match: create, never auto-merge below
   threshold. A wrong merge silently corrupts a meeting; a duplicate is visible and foldable
   with the existing user-triggered `MeetingMergePlanner` flow. Documented non-goal (§1).

**Atomicity (normative):** the importer completes the export **before** resolving the
disposition, then takes the candidate snapshot, runs the matcher, and performs the
`MeetingService` write in **one synchronous main-actor stretch — no `await` between snapshot
and write**. Two imports can therefore never interleave between "saw no matching meeting" and
"created one": whichever runs first has fully written its meeting before the other takes its
snapshot.

Cross-account convergence follows structurally: when two connected accounts both receive the
same meeting's notes doc, the second import's snapshot necessarily contains the meeting the
first one created, scores ≥ 0.6, and merges (`TranscriptMerger` dedupes identical rows) instead
of duplicating. A two-file importer test (same doc under two subs, interleaved processing)
asserts exactly one meeting results.

### D-D5 — Idempotency: side JSON ledger (`GoogleDriveImportLedger`), not a `Meeting` column

**Options:** (a) new optional `Meeting.driveFileID` column (additive schema is allowed);
(b) side JSON store à la `WatchFolderService`'s fingerprints
(`WatchFolderService.swift:439-449`).

**Decision: (b).** Import identity must **outlive the meeting row**: a merged import has no
dedicated meeting of its own (which meeting would carry the column? — merges append to an
existing one), and a deleted meeting must not resurrect its doc on the next poll. A `Meeting`
column can express neither. The JobQueue cannot help either — its dedupe keys on
`(kind, meetingID)` and a `nil` meetingID is never deduped (`MeetingJobDedupeKey`,
`Services/Meetings/MeetingJob.swift:76`; `JobQueueService.enqueue`,
`Services/Meetings/JobQueueService.swift:57`) — so per-file dedupe lives here, in the importer's
own store, exactly as the recon predicted.

**`google-drive-imports.json`** under `AppConstants.appSupportDirectory` (per-build-flavor, like
`watch-folder-processed.json`), atomic write, Codable:

```swift
struct GoogleDriveImportLedger.Entry: Codable {
    var fileID: String            // namespaced: google:<sub>:<driveFileID> (Phase 1 §9 convention)
    var docModifiedTime: Date     // Drive modifiedTime at last successful import
    var importedAt: Date          // first successful import (fixes the re-merge horizon)
    var meetingID: UUID?          // merge/create target; nil once known-deleted
    var disposition: String       // "merged" | "created" — backfill preview + debugging
}
// plus: watermarks: [String: Date]        (sub → last successful sync-cycle start, D-D3)
//       failures:   [String: Int]         (namespaced fileID → attempt count, capped)
```

`@MainActor final class GoogleDriveImportLedger` — **single writer:**
`GoogleDriveTranscriptImporter` (success/failure records) and the engine (watermarks only);
read by the engine's per-file decision and the backfill planner. In-memory `pendingFileIDs` set
guards the enqueue-to-completion window so one file is never enqueued twice concurrently.

**Doc-edited-after-import (Gemini finishes writing late):** on discovery of a ledgered file
whose `modifiedTime` exceeds the stored `docModifiedTime` (> 1 s tolerance):

- within the **re-merge horizon** (14 days after `importedAt`) and `meetingID` resolves →
  re-export and `mergeTranscriptText` into the *same* meeting. Idempotent by construction:
  `TranscriptMerger.mergeAuthoritativeImport` dedupes identical rows and the overlap plan
  re-applies (`MeetingService.swift:657-700`); update `docModifiedTime`.
- beyond the horizon, or `meetingID` no longer exists → update `docModifiedTime` only (touch)
  so an ancient doc edit never churns meetings. A meeting deleted on purpose stays deleted
  (limitation noted in §8).

**Write order (normative — crash-safe):** the importer writes the **meeting first, the ledger
second**, always. A crash between the two self-heals: the file re-surfaces next cycle (no
ledger entry ⇒ unseen, and the D-D6 watermark rule guarantees re-discovery), the matcher scores
the just-created/just-merged meeting at ~1.0 (identical title + date), the disposition is
merge, and `TranscriptMerger` dedupes the identical rows to a no-op. The reversed order would
record "imported" for a transcript that never landed — a **permanent** loss. An importer test
asserts the order and the self-healing replay (import, drop the ledger write, re-run, assert
one meeting with no duplicated rows).

**Failure retry:** an import job that *ran and failed* records `failures[fileID] += 1`; the
engine re-enqueues ledgered failures with `attempts < 3` each cycle regardless of watermark,
then abandons (the record stays — surfaced in logs and as a selectable backfill row, D-D7).
This keeps transient export errors from blocking the watermark indefinitely: a failed file has
left the pending set, so the D-D6 rule no longer holds the watermark for it — the failure
record, not the watermark, is what brings it back. **The re-merge path is gated by the same
cap** (review fix, 2026-08-11): a ledgered doc whose re-merges keep failing is skipped once
`attempts ≥ 3` — UNLESS the doc was edited again *after* the last failed attempt
(`modifiedTime > lastAttemptAt`), which **resets the attempt budget** before re-merging: an
edit plausibly fixes a parse failure. (Failure records therefore carry `lastAttemptAt`
alongside the attempt count — needed for this rule and for pruning.) **Pruning:** failure records past the retry
cap are pruned 30 days after their last attempt (the backfill sheet remains the recovery);
imported entries are kept indefinitely — bounded by the number of real docs, declared
acceptable (§8).

### D-D6 — Scheduler & jobs: `GoogleDriveSyncEngine` (15-min app-lifetime cadence) enqueuing `.driveImport`/`.driveBackfill` on the `io` lane

**Engine shape = `GoogleCalendarSyncEngine`, deliberately** (the proven Phase 1 scheduler,
`Services/Google/GoogleCalendarSyncEngine.swift`): app-lifetime task loop started from
`ServiceContainer.initialize()` (`App/ServiceContainer.swift:581-584` precedent — never the
UI-visibility-scoped poll), `syncNow()` with in-flight coalescing + `resyncRequested` re-loop
(:139-159), per-account failure isolation and needsReauth skip (:161-210), published
`lastSyncAt`/`lastSyncError` for the settings row. Differences: **15-minute** cadence
(transcripts are not time-critical; quota is a non-issue), only accounts that are `.connected`
**and Drive-enabled** (D-D7) are polled, and the trigger set is: cadence tick, account/status
change (same `store.$accounts` sink), Drive toggle flip, and manual "Check now".

**Per cycle, per account:** token → `files.list` with `watermark(sub) − 5 min` overlap margin
(first-ever cycle for an account: **seed the watermark to now and import nothing** — history is
backfill's job, user-controlled) → for each file, the D-D5 decision (unseen → import; edited →
re-merge; failed+retryable → retry; else skip) → cap **25 enqueues per cycle** (burst bound;
the remainder lands next cycle via the watermark overlap).

**Watermark advance (normative — crash-safe):** on a fully successful list pass,
`watermark := min(cycleStart, earliest modifiedTime of any enqueued-but-not-yet-ledgered file
− 1 s)`. The `pendingFileIDs` guard entries carry each file's `modifiedTime` for exactly this
computation. Rationale: `.driveImport` jobs live in the in-memory io lane (`JobQueueService`
persists nothing) — if the watermark jumped straight to `cycleStart` and the app quit before an
enqueued job ran, that file would have no ledger entry, an empty (relaunched) pending set, and a
`modifiedTime` below the watermark: silently lost forever (the 5-min overlap only survives
sub-5-min gaps). Holding the watermark at the earliest unfinished discovery makes every
discovered-but-unimported file **re-surface next cycle**; re-discoveries of files that did
complete are no-ops via the ledger, and re-discoveries of still-pending files are blocked by the
pending guard. Once all of a cycle's jobs have ledgered, the next clean pass advances the
watermark fully.

**JobQueue integration** (`MeetingJobKind`, `Services/Meetings/MeetingJob.swift:5-34`):

- `case driveImport` → lane `.io` (network fetch + parse + main-actor store writes; no LLM or
  transcription contention — the lane table's own rationale, :21-34). One job per file,
  `meetingID: nil` (no meeting yet / not known), `priority: .background`, dedupe `nil` —
  per-file dedupe is the ledger's `pendingFileIDs` (D-D5), since the queue cannot key external
  IDs. `progressLabel` carries the doc's clean title so the activity popover reads
  "Drive transcript import — Weekly sync".
- `case driveBackfill` → lane `.io`, one job for the whole selected batch (§D-D7),
  `priority: .userInitiated`, cancellable (the operation checks `Task.isCancelled` between
  files). `MeetingJobPresentation.canCancel` needs no change (only `.export` and queued
  `.finalTranscription` are special-cased, `MeetingJob.swift:169-174`).
- Both cases extend the `displayName` switch (`MeetingJob.swift:105-121`; EN+DE keys in §5).

The job operations close over `GoogleDriveTranscriptImporter.processFile(…)` — export, parse,
match, merge/create, ledger record — and report the outcome back so ledger failure counts stay
accurate. Jobs run their awaits off the main actor inside the transport; all store writes hop
back (`@MainActor` services), matching every existing job kind.

### D-D7 — Backfill UX: per-account sheet with preview, select-all, batch import

**Entry point:** an "Import past transcripts…" button on the account row in
`GoogleAccountsSection` (`Views/Meetings/GoogleAccountsSection.swift:141` — the row builder),
visible when the account is `.connected` with Drive enabled.

**Sheet (`GoogleDriveBackfillSheet`) flow:**

1. **Scan** — `files.list` full query (no watermark bound), paged to completion, progress
   spinner. Each hit becomes a preview row via the pure planner `GoogleDriveBackfillPlanner`:
   `ImportedMeetingTitle.parse` for title/date, ledger lookup for "already imported",
   `DriveTranscriptMatcher` for the disposition label.
2. **Preview list** — rows show *clean title · real date · disposition*: "Merge into '<meeting>'"
   / "New meeting" / "Already imported" (pre-unchecked, disabled). Select-all toggle; footer
   count ("Import N transcripts").
3. **Import** — one `.driveBackfill` job; the operation walks the selection **serially** with a
   250 ms inter-file pause (rate limiting; also keeps the main actor breathing), publishing
   `(current, total)` progress into the sheet and the job's `progressLabel`. **Per file, at
   execution time, the ledger and pending set are re-checked** — the auto-import engine keeps
   ticking during preview and batch, so a preview disposition may be stale; a file imported or
   in flight by the time the batch reaches it is skipped and counted in the summary. Cancel
   stops after the in-flight file; completed files stay imported (ledgered).
4. **Summary** — imported / merged-into-existing / skipped / failed counts.

Retry-abandoned failures (D-D5) appear in the scan as normal selectable rows (their disposition
recomputed by the matcher), so the backfill sheet doubles as the recovery surface for files
auto-import gave up on; a successful backfill import clears the failure record.

Backfill writes the same ledger entries as auto-import, so the two paths can never double-import
each other's files, and it does **not** move the auto-import watermark (the watermark tracks the
poll cycle only; ledger entries are what dedupe).

Duplicate historical meetings that already exist (e.g. from a manual file import last month whose
Drive doc is now selected) resolve through the matcher: score ≥ 0.6 → merged, not duplicated;
worse → the documented near-miss policy (create + manual fold).

### D-D8 — Per-account Drive toggle + reconnect that re-carries feature scopes + a needs-reauth nudge

**Toggle storage:** dynamic per-account defaults key `google.account.<sub>.driveImport`
("1"/absent), written **only** by `GoogleAccountStore` — the exact precedent of the
`google.account.<sub>.chromeProfile` key (`Services/Google/GoogleAccountStore.swift:188-211`):
accessors `isDriveImportEnabled(for:)` / `setDriveImportEnabled(_:for:)` (announcing via
`objectWillChange`, not the accounts index), and `remove(accountID:)` clears the key alongside
the chromeProfile one (:166-171).

**Enable flow:** toggle ON → if `account.grantedScopes` lacks `GoogleDriveAPI.readonlyScope`,
run `GoogleAuthService.reauthorize(accountID:additionalScopes:[GoogleDriveAPI.readonlyScope])`
(`GoogleAuthService.swift:163` — `login_hint` + `include_granted_scopes=true`; the store unions
scopes on upsert, `GoogleAccountStore.swift:146-161`). On success → set the key, `syncNow()`.
On failure/cancel/scope-not-granted (check the returned `grantedScopes`) → revert the toggle
with an inline explanation. Toggle OFF → clear the key; the engine skips the account next
cycle; no token changes (scope stays granted — harmless).

**Reconnect carries feature scopes (Testing-mode hardening, D-D1):** after a weekly expiry the
refresh token is dead and Reconnect mints a *new* grant. `include_granted_scopes=true` asks
Google to merge prior grants, but the spec does not lean on that alone: the settings row's
Reconnect action (and any programmatic reauthorize) composes `additionalScopes` from the
account's **enabled features** — a small pure helper
`GoogleFeatureScopes.additionalScopes(for account: GoogleAccount, store:) -> [String]`
(Drive scope iff the Drive toggle is on; Phase 3 appends Gmail). One click restores calendar
**and** Drive in a single consent pass.

**Needs-reauth nudge:** today `.needsReauth` is visible only inside Settings
(`GoogleAccountRowState`, `GoogleAccountsSection.swift:373-399`) and as a sync-error line —
under D-D1 it now fires **weekly for every account**, so it must be visible where the user
lives. A compact banner (`GoogleReauthNudge`) renders at the top of the Home feed whenever
≥1 account is `.needsReauth`: *"Google account needs reconnecting — <email> stopped syncing."*
with an inline **Reconnect** button that runs the same reauthorize (feature scopes included)
without a settings round-trip; a second button routes to Settings. Pure visibility rule
(`[GoogleAccount] -> nudge state`) is unit-tested; the view is logic-free. The Drive engine's
`lastSyncError` mentions reconnecting on needsReauth skips, mirroring the calendar engine's
message discipline (`GoogleCalendarSyncEngine.swift:302-311`).

---

## 4. Data model changes

**SwiftData: none.** No `Meeting` columns, no new stores, no `MeetingSource` cases — a
Drive-imported meeting is a normal `.importedTranscript` meeting; a merged import is invisible
at the schema level (segments carry `.importedTranscript` provenance as today).

Additive value-type / signature changes only:

- `MeetingImportService.importTranscriptText(_:title:startDate:)` — new optional `startDate`
  parameter, `nil`-defaulted (`MeetingImportService.swift:141`; threads into the existing
  `createFromImport(startDate:)`, `MeetingService.swift:522`). Existing call sites compile
  unchanged.
- `MeetingImportService.mergeTranscriptText(_:into:) -> Int` — new method, the text twin of
  `mergeTranscriptFile(at:into:)` (:203): parse → `mergeImport`, returns dropped-overlap count.
- `ImportedMeetingTitle.notesSuffixes` — visibility widens from `private static` to `static`
  (internal), becoming the canonical marker list the Drive query derives from (D-D3/F3). No
  behavior change; the file is fork-owned.
- `MeetingJobKind`: `+ .driveImport`, `+ .driveBackfill` (+ lane mapping + `displayName`).
- `GoogleAccountStore`: Drive-toggle accessors (D-D8), no stored-shape change
  (`GoogleAccount` is untouched — enabled-ness is a defaults key, not account identity, same
  reasoning as the link-opening preference).
- New value types confined to `Services/Google/`: `GoogleDriveAPI` request builders + Codable
  models (`GDriveFile`, `GDriveFileListPage`), `GoogleDriveImportLedger.Entry`,
  `DriveTranscriptMatcher.Candidate`/`.Disposition`, `GoogleDriveBackfillPlanner.Row`.
- `GoogleDriveAPI.fileID(sub:raw:)` namespacing (`google:<sub>:<fileID>`) — the Phase 1 §9
  convention, same shape as `GoogleCalendarID` (`GoogleCalendarMapper.swift:6-27`).

---

## 5. Milestones

Each milestone leaves the app building and the full test suite green
(`xcodebuild test … -only-testing:` scoped while iterating; `scripts/pr-preflight.sh` before
PR). New Swift files must be added to `TypeWhisper.xcodeproj`. Branch:
`feature/google-phase2-drive` off `feature/google-phase1-auth-calendar`. No SDK/package changes.

**pbxproj identifier reservation (parallel-phase hygiene, lands in M1's first commit):** new
`project.pbxproj` object IDs minted by Phase 2 use the `GG` marker with suffixes
**0040–0099**; Phase 3 (Gmail) owns **0100–0199**. This keeps the two phases' project-file
diffs mechanically conflict-free if they proceed in parallel worktrees.

### M1 — Drive API client, import ledger, matcher, text-merge seams (no UI, no engine)

**Create** (`TypeWhisper/Services/Google/`):

- `GoogleDriveAPI.swift` — `readonlyScope` constant; `fileID(sub:raw:)` namespacing; Codable
  `GDriveFile` {id, name, mimeType, createdTime, modifiedTime}, `GDriveFileListPage`
  {files, nextPageToken}; request builders `filesListRequest(token:watermark:pageToken:)`
  (the D-D3 query — single-quote escaping in name literals, RFC3339 watermark) and
  `exportRequest(fileID:mimeType:token:)`; `RequestFailed` mirroring
  `GoogleCalendarAPI.RequestFailed` (`GoogleCalendarAPI.swift:159`).
- `GoogleDriveImportLedger.swift` — the D-D5 store: entries/watermarks/failures, load/save
  (atomic JSON at `AppConstants.appSupportDirectory/google-drive-imports.json`), `pendingFileIDs`,
  decision helpers `action(for file:sub:now:) -> LedgerAction` (`importNew`/`remerge(meetingID:)`
  /`retry`/`skip`) so the engine's per-file branch is pure and testable.
- `DriveTranscriptMatcher.swift` — pure D-D4 resolver over `Candidate` snapshots; reuses
  `CalendarService.titleSimilarity/dateProximity/linkScore` statics; emits
  `.merge(meetingID:score:)` / `.create(title:startDate:)`.

**Modify:** `Services/Meetings/MeetingImportService.swift` — the two §4 additions
(`startDate:` param, `mergeTranscriptText`); `Services/Meetings/ImportedMeetingTitle.swift` —
the §4 visibility widening of `notesSuffixes` (F3).

**Tests:** `GoogleDriveAPITests` (query assembly incl. escaping + watermark formatting + the
assertion that the `name contains` terms are **derived from** `ImportedMeetingTitle.notesSuffixes`,
D-D3/F3; export URL + MIME);
`GoogleDriveImportLedgerTests` (round-trip, unseen/edited/horizon/touch/retry-cap decisions,
pending guard, watermark per sub); `DriveTranscriptMatcherTests` (threshold, ±24 h window,
same-account tie-break, near-miss creates, no-date fallback to createdTime);
`MeetingImportServiceTests` additions (text merge drops overlapped live rows via the real
merger; `startDate` lands on the created meeting).

**EN strings:** none.

### M2 — Sync engine, importer, job kinds, wiring (auto-import end-to-end, still toggle-gated off)

**Create** (`TypeWhisper/Services/Google/`):

- `GoogleDriveTranscriptImporter.swift` — `@MainActor`; `processFile(_ file:sub:) async ->
  Outcome`: export markdown (plain-text fallback, D-D3) → `TranscriptFileParser` via the
  matcher's disposition → `mergeTranscriptText` / `importTranscriptText` + best-effort
  `bestAutoLinkCandidate` link (D-D4) → ledger record. Sole ledger entry/failure writer (D-D5).
  Injected: transport, token seam (`GoogleAccessTokenProviding`,
  `GoogleCalendarSyncEngine.swift:11`), `MeetingImportService`, `MeetingService` (candidates +
  link), `CalendarService` (auto-link), ledger, clock.
- `GoogleDriveSyncEngine.swift` — the D-D6 loop (Calendar engine shape: `start()`, coalescing
  `syncNow()`, published `lastSyncAt`/`lastSyncError`, per-account isolation, needsReauth skip);
  enqueues `.driveImport` jobs through `JobQueueService` with the 25/cycle cap; watermark
  advance on clean list pass.

**Modify:** `Services/Meetings/MeetingJob.swift` — the two kinds + lane map + `displayName`;
`App/ServiceContainer.swift` — construct ledger/importer/engine after the Phase 1 Google block
(:192-216), `googleDriveSyncEngine.start()` beside the calendar engine's start (:581-584);
`Services/Google/GoogleAccountStore.swift` — D-D8 toggle accessors + `remove` sweep (no UI
yet: default-off keeps the engine idle, so this milestone is reviewable with zero behavior
change for existing users).

**Tests:** `GoogleDriveSyncEngineTests` (fake transport/token/ledger/queue/clock: watermark
seed-on-first-cycle imports nothing; overlap margin; only connected+enabled accounts queried;
unseen→enqueue, edited→re-merge enqueue, retry re-enqueue, cap respected; needsReauth skip +
error surfacing; account isolation; **crash re-discovery (D-D6/F1)**: enqueue a file, complete
nothing, rebuild the engine against the same ledger — fresh pending set — and assert the file
is re-discovered and re-enqueued because the watermark held below its `modifiedTime`);
`GoogleDriveTranscriptImporterTests` (fixture markdown → merge vs create vs near-miss;
plain-text fallback; failure recorded; auto-link attempted with in-window event;
**write-order self-heal (D-D5/F2)**: meeting written, ledger write dropped, replay imports into
the same meeting with zero duplicated rows; **atomicity (D-D4/F6)**: the same doc under two
subs, processed interleaved, yields exactly one meeting); `MeetingJobPresentationTests`
additions (new kinds' sections/cancelability).

**EN strings (dev adds DE):**
`meetings.jobs.kind.driveImport` "Drive transcript import";
`meetings.jobs.kind.driveBackfill` "Past Drive transcripts import".

### M3 — Settings UI: Drive toggle, sync status, reconnect-with-feature-scopes, reauth nudge

**Create:** `Services/Google/GoogleFeatureScopes.swift` (pure, D-D8);
`Views/MainWindow/GoogleReauthNudge.swift` (banner + pure visibility rule; dev locates the Home
feed insertion point beside the existing live banner).

**Modify:** `Views/Meetings/GoogleAccountsSection.swift` — per-account Drive toggle (reauthorize
flow, revert-on-denial, inline error), Drive sync status line ("Transcripts checked %@" /
error + "Check now"), Reconnect composing scopes via `GoogleFeatureScopes`;
`GoogleAccountRowState` (:373) grows the toggle/backfill visibility flags (pure, tested).

**Tests:** `GoogleFeatureScopesTests` (drive on/off composition; unknown features ignored);
`GoogleAccountRowStateTests` additions; `GoogleReauthNudgeRuleTests` (none/needsReauth-only/
mixed accounts).

**EN strings:**
`google.drive.enableToggle` "Import Meet transcripts from Drive";
`google.drive.toggleHelp` "Automatically imports this account's Gemini meeting notes (\"Notes by Gemini\") from Google Drive and attaches them to the matching meeting.";
`google.drive.scopeDenied` "Google didn't grant Drive access, so the toggle was turned off. Try again and approve the Drive permission.";
`google.drive.lastSync` "Transcripts checked %@";
`google.drive.checkNow` "Check now";
`google.drive.syncError` "Drive transcript sync failed: %@";
`google.reauth.nudgeTitle` "Google account needs reconnecting";
`google.reauth.nudgeMessage` "%@ stopped syncing. Reconnect to resume calendar and transcript updates.";
`google.reauth.nudgeReconnect` "Reconnect";
`google.reauth.nudgeSettings` "Open Settings".

### M4 — Historical backfill: planner, sheet, batch job

**Create:** `Services/Google/GoogleDriveBackfillPlanner.swift` (pure rows from scan results ×
ledger × matcher, D-D7); `Views/Meetings/GoogleDriveBackfillSheet.swift` (scan → preview →
serial batch under one `.driveBackfill` job with progress + cancel → summary).

**Modify:** `GoogleAccountsSection.swift` — "Import past transcripts…" row button presenting
the sheet.

**Tests:** `GoogleDriveBackfillPlannerTests` (dispositions incl. already-imported disabled rows
and retry-abandoned failures surfacing as selectable rows (D-D7/F7), selection counts, ordering
by date desc); importer batch test (serial, cancellation between files, summary tally, pause
injected via clock, and **execution-time re-check (D-D7/F4)**: a file ledgered mid-batch by a
concurrent auto-import is skipped and counted as skipped in the summary).

**EN strings:**
`google.drive.backfillButton` "Import past transcripts…";
`google.drive.backfill.title` "Import past transcripts";
`google.drive.backfill.scanning` "Looking for Gemini transcripts in Drive…";
`google.drive.backfill.empty` "No Gemini transcripts were found in this account's Drive.";
`google.drive.backfill.selectAll` "Select all";
`google.drive.backfill.mergeInto` "Merge into \"%@\"";
`google.drive.backfill.newMeeting` "New meeting";
`google.drive.backfill.alreadyImported` "Already imported";
`google.drive.backfill.importCount` "Import %lld transcripts";
`google.drive.backfill.progress` "Importing %lld of %lld…";
`google.drive.backfill.summary` "Imported %lld transcripts — %lld merged into existing meetings, %lld skipped, %lld failed.";
`google.drive.backfill.cancel` "Cancel".

---

## 6. Upstream-shared files touched

Target unchanged from Phase 1: **zero SDK/package files**.

| File | Change |
|---|---|
| `TypeWhisper/App/ServiceContainer.swift` | one wiring block (ledger/importer/engine + `start()`) |
| `TypeWhisper/Resources/Localizable.xcstrings` | added keys only |
| `TypeWhisper.xcodeproj/project.pbxproj` | new file references — object IDs use the `GG` marker, suffixes **0040–0099** (Phase 3 reserves 0100–0199; §5 preamble) |

No `UserDefaultsKeys.swift` change (the Drive toggle is a dynamic per-`sub` key owned by
`GoogleAccountStore`, D-D8; the watermark lives in the ledger JSON, D-D5). Everything else is
fork-owned surface (`Services/Google/`, `Services/Meetings/MeetingImportService.swift`,
`Services/Meetings/MeetingJob.swift`, `Views/Meetings/`, `Views/MainWindow/`).

---

## 7. Test plan

**Unit** (per milestone above; scoped runs via
`-only-testing:TypeWhisperTests/<Class>`). Style unchanged from Phase 1: pure logic over
fakeable seams — fake `GoogleHTTPTransport`, fake `GoogleAccessTokenProviding`, in-memory
ledger, canned meeting snapshots, injected clocks. No test touches the network, Keychain,
Drive, or the plugin graph. Fixture set: the real Gemini markdown sample (ES), an EN synthetic
twin, a no-date filename, a plain-text degraded export.

**Manual QA script** (real account; Appendix A completed; `CodeSigning.local.xcconfig` present):

1. `scripts/build-dev-local.sh`. Settings → Meetings → Google Accounts: account rows now show
   the Drive toggle (off) and no backfill button until enabled. With **all** toggles off, the
   Drive engine issues **zero** Drive requests: no "Transcripts checked" timestamp ever
   appears, no Drive job shows in the activity popover, and Console (filter
   `GoogleDriveSyncEngine`) logs no fetch activity across a full 15-min cycle.
2. Enable the toggle → browser consent shows the **Drive read-only (restricted)** scope with the
   Testing-mode unverified interstitial → approve → toggle stays on;
   `account.grantedScopes` now contains `drive.readonly` (visible in a debugger or by the
   backfill button appearing).
3. Deny the consent instead (second account): toggle reverts with the inline
   `google.drive.scopeDenied` message.
4. Have a meeting with Gemini notes ("Take notes with Gemini") → after the doc lands in Drive,
   within ≤15 min (or **Check now**) a "Drive transcript import" job appears and the transcript
   attaches to the calendar meeting created for that event — verify speakers, timestamps, and
   that the meeting was **merged, not duplicated**. This step also validates that the lowercase
   `name contains` terms (derived from `ImportedMeetingTitle.notesSuffixes`) match Google's
   title-case doc names — Drive matching is documented case-insensitive; if discovery fails
   here, the fallback is emitting display-case variants derived from the same canonical list.
5. **Flagship collision:** run a meeting captured with live captions, then let its Gemini doc
   import — verify overlapped live rows were replaced by the Gemini transcript
   (`ImportOverlapPlan`) and non-overlapped content survived.
6. Edit the Gemini doc in Docs (append a line) → next cycle re-merges into the same meeting; no
   duplicate meeting, no duplicated rows.
7. Ad-hoc transcript with no matching meeting → new `.importedTranscript` meeting titled/dated
   from the filename; if the event is in the calendar snapshot window, verify it auto-linked.
8. **Backfill:** "Import past transcripts…" → scan lists historical docs with clean titles +
   real dates; already-imported rows disabled; select a batch of **≥ 20 docs** → progress
   advances serially with the rate-limit pause visible; cancel mid-run keeps completed
   imports; summary counts match; re-open the sheet — imported rows now show "Already
   imported".
9. Restart the app → nothing re-imports (ledger + watermark survive).
10. **Weekly-expiry drill (D-D1/D-D8):** revoke the app at myaccount.google.com/permissions →
    next sync flips the account to "Needs attention", the Home nudge appears; click
    **Reconnect** on the nudge → one consent pass restores **both** calendar and Drive scopes;
    events and transcript polling resume.
11. **Scope-narrowing experiment (D-D2, record the result in the PR):** on a scratch account,
    swap the constant to `drive.meet.readonly`, reconnect, and check whether `files.list` and
    `files.export` still behave. Either outcome is fine; it decides a follow-up, not this PR.
12. Debug/Release separation: dev build wrote only `…mac.dev.apikey.google.…` keychain items and
    its own `google-drive-imports.json` under the `MeetingWhisper-Dev` data directory.

---

## 8. Risks & open questions

- **Markdown-export fidelity** is assumed identical between the Docs UI download and
  `files.export?mimeType=text/markdown` (same converter; verified sample is a UI download). QA
  step 4 is the empirical gate; the D-D3 fallback rungs bound the damage if Google drifts.
- **Name-based discovery misses renamed docs** (a user retitling the doc breaks the
  `name contains` markers). Accepted for v1; the fallback is manual file import (existing UI).
  A "Meet Recordings folder" query or `drive.meet.readonly` visibility (D-D2) could widen this
  later.
- **Weekly consent friction (D-D1)** now applies to *all* accounts and *all* scopes; the nudge
  (D-D8) makes it one click but it is still weekly. This is the accepted cost of Testing mode
  until Marco submits for verification (Appendix A path-to-verification).
- **Deleted meetings stay deleted**: the ledger keeps the doc marked imported, and backfill
  shows "Already imported" with no re-import affordance in v1 — deliberate (respect deletion),
  but users who *wanted* a re-import must clear it manually (delete the ledger file or a future
  "re-import" affordance). Open question for a polish pass.
- **Near-miss duplicates** (score just under 0.6 — e.g. Gemini titling drift vs the calendar
  title) create a second meeting by design; the manual `MeetingMergePlanner` flow is the fold.
  If this proves common, a Phase 2.1 could surface a "possible duplicate" hint on the meeting.
- **Two accounts, same doc**: converges via the matcher — and the D-D4 atomicity rule (export
  first, then snapshot→match→write in one synchronous main-actor stretch) makes the
  duplicate-creation race structurally impossible rather than merely rare.
- **Ledger growth**: imported entries are kept indefinitely — bounded by the number of real
  Gemini docs (a few per meeting-day), declared acceptable; failure records are pruned per
  D-D5 (past retry cap + 30 days).
- **Quota**: `files.list` every 15 min per enabled account + occasional exports is orders of
  magnitude under Drive API defaults; HTTP 403/429 are treated as transient sync errors
  (surfaced, retried next tick) — no dedicated backoff scaffold, same posture as Phase 1.
- **Testing-mode caps**: 100 test users is irrelevant at N≈3 accounts; every connecting account
  **must be listed as a test user** or consent fails outright (Appendix A).

---

## 9. Forward compatibility — Phase 3 (Gmail)

- **Scope pattern generalizes**: `GoogleFeatureScopes` (D-D8) gains the Gmail scope behind a
  per-account `google.account.<sub>.gmailContext` toggle — same reauthorize flow, same
  reconnect composition, same Testing-mode consent screen (gmail.readonly is also restricted;
  D-D1 covers it unchanged).
- **Engine + ledger shapes are the template**: a `GmailContextService` takes
  `GoogleAccessTokenProviding` + `GoogleHTTPTransport` exactly like the two sync engines; the
  `google:<sub>:<id>` namespacing extends to message IDs (Phase 1 §9).
- **Nudge is shared**: `GoogleReauthNudge` keys off `.needsReauth` regardless of which feature's
  sync tripped it — Phase 3 inherits it for free.
- **Join-link guard**: `MeetingJoinLauncher` opens http(s) URLs only
  (`Services/Google/MeetingJoinLauncher.swift:56-70`). Phase 2 adds no `conferencingURL`
  producers (Drive meetings get theirs only via the D-D4 auto-link → event projection path,
  which is already guarded); Phase 3 email context must keep any extracted links behind the
  same launcher.
- **Verification submission** (Appendix A) should be filed with the final Phase 3 scope set so
  the CASA assessment covers Calendar + Drive + Gmail in one pass.

---

## Appendix A — Google Cloud console runbook delta (Phase 1 Appendix A remains the base)

Changes to the existing project/client (no new project, no new client — D-D1):

1. **Enable the API**: *APIs & Services → Library* → **Google Drive API** → Enable.
2. **Add the scope**: *Google Auth Platform → Data access* (older consoles: OAuth consent
   screen → Scopes) → *Add or remove scopes* → add
   `https://www.googleapis.com/auth/drive.readonly` (listed under Google Drive API after
   step 1) → Save.
3. **Switch the consent screen to Testing** (D-D1, reversing Phase 1 step 4): *Google Auth
   Platform → Audience* → set **Publishing status: Testing**. This is what permits the
   restricted Drive scope without verification.
4. **Test users**: in the same Audience screen, ensure **every** Google account that will
   connect (personal + each Workspace account) is listed as a test user. An unlisted account
   gets a hard "access_denied" at consent.
5. **Expected behavior while in Testing** (accepted, D-D1): consent shows the unverified-app
   interstitial each (re)connect; **refresh tokens for every scope — including Phase 1's
   calendar — expire after 7 days**, flipping accounts to "Needs attention" weekly. The in-app
   nudge + one-click Reconnect (D-D8) is the designed remedy. Workspace accounts note: a
   Workspace admin can additionally restrict third-party app access — if consent fails for a
   Workspace test user, check *admin.google.com → Security → API controls*.
6. **Path to verification** (later, per Marco — not a blocker for anything in this spec):
   brand verification (app homepage + privacy policy URL on a domain Marco owns, verified in
   Search Console); scope justification for each restricted scope + a demo video showing the
   consent flow and the Drive usage; **CASA Tier 2 security assessment** (third-party, paid,
   re-certified annually) required for restricted scopes; typical end-to-end timeline is
   several weeks. After approval: flip Audience back to **In production** — token expiry
   stops; **no app change is required** (D-D1's identical-code-path rule).
