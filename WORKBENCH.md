## Next
- [~] Meeting state for the habit tracker: API request #dd660ccd
  # Meeting state for the habit tracker: API request
  **To the agent working on the meeting app.** This describes what another local
  app needs from yours. It is a request, not a finished design. Please:
  1. **Look at what the app's local API already does first**: its endpoints,
  port, auth, response conventions, and what meeting state it already tracks
  internally.
  2. **Come back with a proposal tailored to your app** before building
  anything. If existing endpoints already cover part of this, say so and we
  will use them as they are. If a field is expensive or unavailable, leave it
  out and tell us. If a different shape fits your API better, propose it.
  ## Who is asking, and why
  `local-habit-tracker` is a personal macOS menu bar app on the same Mac. It
  detects habits (nail biting, vaping) from the webcam and records each event
  with context, to find patterns such as "more alerts while listening in group
  meetings". It also softens its alerts during meetings.
  Today it guesses "in a meeting" from whether any app is using a microphone.
  That misses meetings where the user only listens, and knows nothing about the
  meeting itself. Your app knows the real thing.
  ## What the tracker needs, in order of value
  1. **Whether a meeting is in progress**, and when it started.
  2. **Whether the user is speaking or listening** right now (or speaking
  segments, if that is what you have).
  3. **The meeting's shape**: platform, participant count (1:1 vs group),
  scheduled vs ad hoc.
  4. **A stable meeting ID**, so events can be grouped per meeting. A title is
  optional and only if the user is comfortable with a second app storing it.
  5. **Camera on/off and screen sharing**, which decide how discreet an alert
  must be.
  **Not wanted:** transcript text, audio, summaries, or participant names. The
  tracker should not hold meeting content.
  ## Suggested shape (adapt it to your conventions)
  Two read-only endpoints on the existing local API.
  ### Current state: `GET /meeting/now`
  Polled by the tracker every 2 to 5 seconds, so it must be cheap.
  ```json
  {
  "schema": 1,
  "in_meeting": true,
  "meeting_id": "abc123",
  "started_at": "2026-09-30T10:00:00-06:00",
  "platform": "meet",
  "participants": 4,
  "scheduled": true,
  "speaking": false,
  "camera_on": true,
  "screen_sharing": false,
  "title": null
  }
  ```
  When no meeting is in progress: `{"schema": 1, "in_meeting": false}`.
  | Field | Type | Required | Notes |
  |---|---|---|---|
  | `schema` | integer | yes | Bump on breaking changes. |
  | `in_meeting` | boolean | yes | True from join to leave, including listen-only. |
  | `meeting_id` | string | when in a meeting | Stable for the whole meeting; opaque to the tracker. |
  | `started_at` | ISO 8601 with offset | when in a meeting | When the user joined. |
  | `platform` | string | optional | For example `meet`, `zoom`, `teams`. |
  | `participants` | integer | optional | Including the user. |
  | `scheduled` | boolean | optional | From a calendar event vs ad hoc. |
  | `speaking` | boolean | optional | The user is talking right now. |
  | `camera_on` | boolean | optional | |
  | `screen_sharing` | boolean | optional | The user is sharing. |
  | `title` | string or null | optional | Omit or null by default. |
  Omit any optional field you can't provide. Don't send placeholders.
  ### Recent meetings: `GET /meeting/history?since=<ISO 8601>`
  Used to attach meetings to events the tracker recorded while it couldn't
  reach the API, and for exposure ("hours in meetings") in its insights.
  ```json
  {
  "schema": 1,
  "meetings": [
  {
  "meeting_id": "abc123",
  "started_at": "2026-09-30T10:00:00-06:00",
  "ended_at": "2026-09-30T10:45:12-06:00",
  "platform": "meet",
  "participants": 4,
  "scheduled": true,
  "speaking_seconds": 310,
  "speaking_segments": [["2026-09-30T10:03:10-06:00", "2026-09-30T10:04:02-06:00"]]
  }
  ]
  }
  ```
  `ended_at` is null for a meeting still in progress. `speaking_segments` is
  optional and only worth adding if you already have the data; `speaking_seconds`
  alone is useful.
  This endpoint is lower priority than `/meeting/now`. If history is awkward for
  your app, propose `/meeting/now` only.
  ## Behaviour the tracker relies on
  - **Loopback only.** Bind to `127.0.0.1`, as your API presumably already does.
  - **Auth:** whatever the existing API uses. Tell us how a second local app
  should obtain and present the credential. If the API has no auth today,
  please validate the `Host` header so web pages in a browser can't read it.
  - **Discovery:** tell us the port, and whether it is fixed or written somewhere
  the tracker can read (a file, a default).
  - **Cheap and side-effect free.** `/meeting/now` is called every few seconds.
  - **Failure is fine.** If your app isn't running or the call fails, the tracker
  falls back to its microphone check. No need to keep the API up at all costs.
  - **Timestamps** in ISO 8601 with a UTC offset.
  - **Stable IDs:** the same `meeting_id` in `/meeting/now` and
  `/meeting/history`.
  ## What to send back
  A short proposal covering:
  1. What your API already exposes that matches, and what you would add.
  2. The final endpoints, fields, and an example response for each.
  3. Port and auth details for a local client.
  4. Anything above you would drop or change, and why.
  5. Any extra signal your app has that might matter for habit tracking (for
  example, meeting type, or how long the user has been silent).
  The tracker side will be built against whatever you propose.
  [edit] detail os:marco ⧗2026-09-30T00:13:40-06:00 #1622bbe0
  [edit] state os:marco in_progress ⧗2026-10-02T12:20:29-06:00 #aba9060e

## live-writes (jade)
- [x] Perf 1C: stop refetching all meetings on live append (`appendStableSegments`) @live-writes
  Impact high / risk low-med. Keep `nextOrder` per live meeting instead of `segments.map(\.order).max()`; `save()` without `fetchMeetings()`; refetch only on insert / delete / sort-key change; `performBatch` deferral for Drive import and calendar sync.
  > 2026-10-06 diamond: dispatched, isolated worktree forked from main 772f3535 (Google Phase 2 edits now committed, so no longer blocked).
  > 2026-10-06 diamond: worker done on its branch (f4e80c91 move tags/folders + related notes into extensions, 952ac5e2 in-place writes save without refetch + nextOrder cache, 43907520 performBatch; 586 + 194 tests green). NOT merged — review found `mergeImport` renumbers segments without invalidating the nextOrder cache (append → Drive merge → append yields duplicate orders). Sent back for a structural fix + regression tests.
  > 2026-10-06 diamond: fix reviewed, merged to main as 622219d4 (move), 5500f687 (in-place writes save without refetch/republish; nextOrder cache), eb4cc058 (performBatch; Drive create path uses it), ca0b4748 (order cache invalidated structurally in insertSegment/deleteSegment/renumber; 4 sequence tests). Worker: 49 classes / 588 tests green. Not verified live: that every view still updates on in-place writes now that the list no longer republishes (relies on SwiftData observation) — the first thing to check in a dev build during a live caption session.
- [x] Perf: denormalise `segmentCount`, `lastSegmentEnd`, output kinds onto `Meeting` (optional columns, additive) @live-writes
  Impact high / risk medium (schema, but additive-only). Maintained by `MeetingService` on append/replace/merge/import; replaces the per-fact caches (`transcriptFactCache`, `homeBadgeFacts`, `actionFacts`) and the `segments.isEmpty` probes that fault whole relationships.
  > 2026-10-06 diamond: reviewed + merged to main (17907303 frozen-V1 schema additivity test, 66b04ce0 four optional fact columns on Meeting + maintenance on the choke points + reconcile, 1bfc7417 deferred post-launch backfill, 961471d3 document readers, 07eaa677 HTTP meeting list, 16514919 language setters moved out; MeetingService.swift now 1,287 lines). Worker: 800 scoped tests green. Schema change is additive (4 optional columns). Not verified live: the backfill over the real 281-meeting store.
- [x] Perf: Home-side readers onto the fact columns (HomeFeedViewModel.hasTranscript, homeBadgeFacts, HomeFeedView) @live-writes
- [x] Perf: first-launch facts backfill budgeted by work, not meeting count @live-writes
- [x] Perf: one save per write (stale-facts recompute + autosave vs explicit saves, finding 17b) @live-writes
  > 2026-10-06 diamond: reviewed + merged to main: Home readers on the fact columns with their caches deleted (HomeFeedViewModel.hasTranscript, homeBadgeFacts, HomeFeedView attention rows); backfill budgeted at 400 rows / 4 ms per main-actor turn using paged fetches of `end` + `speakerLabel` only, with a live-append interleave pinned by test; stale-facts recompute folded into the write's own save (one transaction per write; autosave kept — nothing relies on it and it adds no transaction). Worker: 826 scoped tests green. Depends on SwiftData flagging pending deletes `isDeleted` and reflecting pending inserts in the relationship before save — pinned by MeetingServiceTransactionTests / MeetingFactsTests on this OS. Not verified live: the first-launch backfill over the real store.
- [x] Perf: actionFacts asks the output-kinds column before faulting `outputs` (the unmoved 214 ms Home first-paint phase) @live-writes
  > 2026-10-06 diamond: dispatched to live-writes from the benchmark result.
  > 2026-10-06 diamond: merged to main as b6d666a3 (actionItems checks outputKinds first), a90a0749 (archive state facets on the facts), 4db4b02c (speaker-plan inputs on the stored label set). The phase did NOT move (200 → 199 ms): the worker's probe shows it is `MeetingOutputParser.parse` over the 100 summaries (170 ms, ~1.7 ms each in Debug), not relationship faults (15 ms) — my hypothesis was wrong. In the app only realized rows pay it (20-row window first paint: 17 ms).

## titles-home (amber)
- [x] Perf 1C: precompiled regexes + per-title memo in `ImportedMeetingTitle` @titles-home
  Impact medium / risk low. 160 of 281 meetings are imported; parse runs 2–3× per row per render with a fresh regex per suffix.
- [x] Perf 1C: static DateFormatters + memoized `actionFacts` in `HomeFeedViewModel` @titles-home
  Impact medium / risk low. `setLocalizedDateFormatFromTemplate` per day group per render is 5 % of Home samples.
- [x] Perf: debounce search in `MainWindowCoordinator`; commit folder description on blur @titles-home
  Impact medium / risk low. Search fans out per keystroke to every coordinator observer incl. per-row context menus; folder description JSON-encodes the whole UserDefaults map per keystroke (`MeetingFolderDetailView.swift:93-95`).
- [x] Perf: move Phase 0 profiler scripts under scripts/perf/ and record a before/after `top`/`sample` baseline @titles-home
  Impact low / risk none. Analyzers currently live only in the session scratchpad.
- [x] Perf: compute `duplicateMeetingIDs` once per input change (1B follow-up) @titles-home
  > 2026-10-06 diamond: reviewed + merged to main as 3d6be5ff (scripts/perf), 0d08abaf (ImportedMeetingTitle precompiled regexes + lock-guarded memo), 560953db (Home header formatters + actionFacts keyed on updatedAt), c6565d9b (250 ms search debounce; field binds to the instant `searchFieldText`), 408ff669 (folder description commits on blur/submit/1 s pause/disappear), 5136e7cc (MeetingDuplicateIndex). Worker: 18 classes / 125 tests green. Not profiled live. Before/after baseline still to record once a dev build is allowed.
- [x] Perf: value-type `MeetingRowModel` + one `MeetingRowView`, list-local selection @titles-home
  Impact high / risk medium. One list model recomputes rows only on input change; rows are Equatable and take a value + isSelected/isLive; replaces the duplicated `ArchiveRow` / `TimelineRowContent`; lifts selection off the singleton VM. Also collapse the per-row context-menu presenter stack into one list-level pending action.
  > 2026-10-06 diamond: reviewed + merged to main as 27051dda (MeetingRowModel + updatedAt-keyed store), 0b5e662c (one MeetingRowView for archive + timeline), 54357374 (selection on MeetingSelectionModel, off the VM), 4c62fc00 (row dialogs presented once per list from a pending action). Worker: 20 classes / 139 tests green. NOT verified in the app — needs eyes in a dev build: pixel parity of both row styles, right-click menu single vs bulk, rename / delete / merge / new-folder / link-event dialogs actually firing, selection surviving open-and-back.
- [x] Perf: list filter/search/sort pipeline — cached search haystack per (id, updatedAt), memoized filter+sort shared by list and folder detail (finding 5 remainder) @titles-home
  > 2026-10-06 diamond: dispatched to titles-home after its second merge.
  > 2026-10-06 diamond: worker done on its branch (3f75a088 MeetingListPipeline + parity tests, 8720fb7e archive + folder detail use it; 96 tests green). NOT merged — it derives `hasTranscript` / output kinds for every meeting eagerly, and the row store merged earlier (27051dda) builds row models for the whole displayed array in the list body: first paint now faults `segments` + `outputs` for all ~280 meetings instead of the visible ~15. Sent back to make both lazy, pin it with a test, and add object identity to the memo key.
  > 2026-10-06 diamond: fix reviewed, merged to main as e8a155b7 + ad0c7a66 (MeetingListPipeline: cached search fields, memoized filter+sort shared by archive and folder detail, parity tests against the old predicate), 93a56db1 (transcript / output-kind facts derived only while a state facet needs them; memo keyed on object identity), ff576e83 (row models built per realized row via MeetingRowCell). Worker: 17 classes / 104 tests green. The first-paint regression from 27051dda is closed by ff576e83.
- [x] Perf: swap the MeetingRelationshipFacts seam onto the denormalised fact columns @titles-home
  > 2026-10-06 diamond: dispatched to titles-home after its third merge.
  > 2026-10-06 diamond: reviewed + merged to main (list facts read `meeting.hasTranscript` / `meeting.outputKinds`). Worker caught that fact columns are healed in place without an `updatedAt` bump, so the row store, the pipeline's per-fact caches and its result memo now also key on a column stamp; drift/heal tests added. 11 classes / 72 tests green. Full suite on main before this merge: 2,621 tests, 0 failures.

## render-cache (onyx)
- [x] Perf: cached `RenderedOutput` for markdown (outcomes + pre-built AttributedStrings per output id/createdAt) @render-cache
  Impact med-high / risk low-med. `MeetingOutputParser.parse` + `AttributedString(markdown:)` per block run on every document render (`MeetingDocumentBody.swift:121-136`, `MarkdownDocumentView.swift:21,302-307`).
- [x] Perf: `relatedDocuments(for:)` once per input change, not a disk stat per body (1B follow-up) @render-cache
  > 2026-10-06 diamond: reviewed + merged to main as 060fa4dd (RenderedMarkdown pre-render, Space note once per load), e2280c11 (RenderedOutputCache LRU for body/brief/agenda), 946d98ed (RelatedDocumentsMemo). 71 scoped tests green per worker. Not yet verified in a dev build. Note: show-as-missing for a related note now lags a vault rename by up to 30 s.
- [x] Perf: one calendar coordinator (EKEventStoreChanged instead of the 60 s poll, EventKit query off main, equality-gated publish) @render-cache
  Impact medium / risk medium. Replaces the 60 s Timer, the brief-scheduler tick from the calendar sink, and the unconditional republish that re-runs twin collapse + start notifications.
  > 2026-10-06 diamond: reviewed + merged to main as 4c753cfb (EventKit query off main via its own store), 5e63d4ac (CalendarRefreshCoordinator: EKEventStoreChanged / wake / day-rollover / clock triggers + one wake timer from CalendarWakePlanner; equality-gated publish; provider query reaches 1 h past the look-ahead so a refetch is due hourly, not every minute). Worker: 17 classes / 158 tests green, 20 new. Not verified live: start notifications and auto-briefs firing at the right moment in a dev build.
- [x] Perf: drop the main-queue hops in the MeetingsViewModel Combine mirrors + dead staleness workarounds (finding 12, narrow — not the VM split) @render-cache
  > 2026-10-06 diamond: reviewed + merged to main (synchronous compare-before-assign mirrors via `Publisher.mirror(to:)`; three hops kept as load-bearing with comments — Google account store, `$upcomingEvents` consumers, `$vaultPath`; capture double-start guards now read the synchronous mirrors, pinned by tests that fail on the old hopped code; the Rules `objectWillChange` pokes kept). Worker: 18 classes / 177 tests green.
- [x] Audit + fix: state that was only refreshed by the now-removed republishes (non-observed sources read in bodies, Meeting fields read outside bodies, caches keyed only on updatedAt) @render-cache
  > 2026-10-06 diamond: reviewed + merged to main, 7 fixes (…865939d2, 93d59733). Ranked by visibility: (1) Home next-meeting card, Settings in-progress/ended badges, status-bar entry, idle tray title and Today/Yesterday headers froze at event start/end — caused by the calendar coordinator publishing only on change; fixed with a CalendarClock ticked at every wake/refetch plus a wake for the tray's 60-min window. (2) Upcoming not re-filtered after a meeting delete/merge or a placeholder's capture start. (3) Sidebar folder tree stale for configured folders with no meetings. (4) Tray kept an outdated upcoming meeting after recording stopped. (5) Auto-brief settings change did not re-plan the wake. (6) Related-emails badge in the document appendix. (7) Language Detect spinner stuck after a failed detection. Worker: 142 scoped tests green, 7 new; tray / auto-brief / document-view fixes have no unit test. Report-only: timeline rows tracked inside a lazy ForEach closure (already covered on main by MeetingRowCell, ff576e83); pre-existing low-visibility items (tray label after renaming the active meeting; related emails not refetched when participants change; MeetingRelatedEmailsSection reads hasGoogleAccounts unobserved; stale comment in +Rules.swift).

## vault-offmain (topaz)
- [x] Perf: vault work off the main actor @vault-offmain
  Impact high when used / risk medium. `ObsidianVaultService` enumerate/parse/rank as a `nonisolated` core run detached, cache parsed notes by mtime; `VaultContextPickerView` filters a cached snapshot instead of walking the vault in `body`; lazy async `SpaceViewModel.refresh` (no scan in init); Space tree indexed once per refresh; draft text local `@State`.
  > 2026-10-06 diamond: reviewed + merged to main as 98c7a799 (SpaceTreeIndex once per snapshot), 67f40604 (VaultIndexer actor: walk/parse/rank off main, parse cache keyed on mtime+size+inode; picker filters a snapshot; Space lazy async refresh, no scan in init), 3445e0b5 (draft text view-local). Worker: 24 classes / 252 tests green. Not yet verified in a dev build (Space, context picker, brief/Q&A vault retrieval).
- [x] Perf: prune SwiftData persistent history; defer non-critical startup past the first frame @vault-offmain
  Impact low-med / risk low-med. `ACHANGE` has 74k rows and nothing prunes it; launch logged a 2.8 s slow-HID response with ~10 store opens, a vault scan and plugin loading all synchronous before the first frame.
  > 2026-10-06 diamond: reviewed + merged to main as 2f8b63e0 (LaunchMetrics: milestones + per-store open time, log category "Launch"), c4d01b98 (Google sync start + participant backfill after first frame), bf8222a7 (prune persistent history >24 h, off main, macOS 15+). Worker: 12 classes / 203 tests green. NOT measured: no launch timed, prune not run against the real store. Worker's finding: most launch cost is ~10 store opens + ~70 services built synchronously in ServiceContainer (upstream structure) — parked until the dev build's per-store timings exist. Parked follow-ups: lazy store opens, usage-statistics backfill + history retention purge after first frame, VACUUM, PromptActionService opens its store outside the factory.
- [x] Perf: Google calendar/Drive decode + mapping off main; debounced ledger writes @vault-offmain
  Impact medium / risk low-med. `GoogleCalendarSyncEngine.swift:296-335`, `GoogleDriveTranscriptImporter.swift:183-215`, `GoogleDriveImportLedger.swift:396-412`. Wait for Google Phase 2 to land first.
  > 2026-10-06 diamond: reviewed + merged to main (Google calendar page decode + mapping off main, equality-gated lastSyncError; Drive export decode + summary-gate parse off main; ledger writes coalesced to one per 2 s with flush on backfill end / cycle end / terminate, first watermark seed and forget written through). Worker: 13 classes / 195 tests green. Trade accepted: a crash inside the 2 s window re-discovers the file and re-imports it as a deduped merge into the meeting it already created — same exposure the write-through ledger had, wider window.
- [x] Perf: Drive import parses the export once, off main (segments handed to MeetingImportService) @vault-offmain
- [x] Perf: before/after benchmark suite over a synthetic store, run at 772f3535 and at main @vault-offmain
  > 2026-10-06 diamond: reviewed + merged to main as da5471fd (Drive export parsed once off main; segment-taking overloads on MeetingImportService) and 4921b770 (PerfBenchmarkTests + scripts/perf/run-before-after.sh; results table in scripts/perf/README.md). Measured 772f3535 vs the branch point ad632918+2, Debug build, synthetic 300-meeting / 50k-segment store and 2,000-note vault, 3 interleaved runs: live append 264 → 21.5 ms and 1 → 0 list republishes per append; imported titles repeat render 98 → 0.4 ms; Home rows repeat 127 → 9 ms, after a write 147 → 10 ms, FIRST PAINT only 539 → 409 ms; markdown repeat 3.7 → 0.004 ms (first render unmoved, 5.2 ms); vault retrieve main stall 600 → 0 ms (wall time unchanged); Space init 290 → 0.4 ms, folder visits 247 → 0.06 ms; calendar refresh unchanged-list 0.27 → 0.56 ms but 2 → 0 publishes; list search unmoved (0.99×) because the pipeline had not merged yet. Not a measurement of the real app.
- [x] Perf: benchmark follows the current code paths (pipeline, row cells, facts); live-append breakdown @vault-offmain
- [x] Perf: full before/after re-run once the in-flight changes have merged @vault-offmain
  > 2026-10-06 diamond: merged to main as 5ae9198a (list pipeline / row model / live-append breakdown benchmarks), 38d4c4dd (before-shim corrected: 772f3535 filtered once per body, not 7×), 29eccc18 (results in scripts/perf/README.md). 772f3535 vs main d6f0692a, Debug, synthetic 300 meetings / ~50k segments / 2,000-note vault, 3 interleaved runs: live append 279 → 23 ms, 1 → 0 republishes; Home rows first paint 567 → 226 ms (scalar 131 → 8.7, segments 221 → 2.6, OUTPUTS 214 → 215 unmoved), repeat 134 → 12.6, after write 159 → 12.1; list search per changed keystroke 63.8 → 2.8 ms, unchanged re-render 64 → 0.38; archive rows 20-row window first paint 60 → 19 ms, repeat 5.5 → 0.28; whole list first paint 532 → 227; imported titles first 105 → 10, repeat 101 → 0.4; markdown repeat 3.9 → 0.004 (first render unmoved 5.5); vault retrieve main stall 614 → 0.5 ms (wall unchanged), Space init 308 → 0.4, refresh 308 → 137 (stall 310 → 0.5), folder visits 266 → 0.06; calendar refresh unchanged-list 0.30 → 0.39 ms, 2 → 0 publishes. Live append on a 1,726-segment meeting = save 12.4 ms + relationship assignment 8.8 ms, both O(existing segments). These supersede the first table (whose list-search baseline was overstated). Not a measurement of the real app.

## drive-title (coral)
- [x] Bug: Drive-imported meetings keep the date in the title and miss their calendar meeting @drive-title
  Reported 2026-10-06: Gemini "Notas" exports arrive as `<Title> - 2026/07/22 11:59 CST`; the parser only knew the `YYYY-MM-DD HH-MM-SS` shape, so the title stayed raw, the matcher scored it against the clean event title below 0.6, and a duplicate was created next to the calendar meeting.
  > 2026-10-06 diamond: merged to main as d99c2aa2 (ImportedMeetingTitle recognizes three trailing-date shapes: stamp, slash-dated, "22 Jul 2026 at 11:59"; impossible days rejected; WIB/WITA/WIT offsets), 1fffd38a (DriveTranscriptMatcher cleans both sides before scoring), 6cab16ec + 5e5cc8dc (tests: slash-dated title displays clean in the row model, list date, GoogleDriveAPITests), 04b16c66 (Drive doc names whose date shape is still unrecognized are logged once per session at .info, name private), 762f29e3 (Home attention rows + Settings meetings list show the clean display title; attention-row logic lifted to a testable static). Full suite 2,875 / 0 failures. Not auto-fixed: duplicates already in the store — the bulk "Merge N meetings" action handles them by hand; a batch-suggest pass was offered, not started. Not verified live.

## Backlog — Perf refactor Phase 1 (stop the bleeding)
Ordered by impact ÷ implementation risk. Spec: docs/specs/2026-10-02-perf-refactor-plan.md (§3 findings, §5 phases).
- [x] Perf 1A: narrow MeetingsViewModel observation @diamond
  Impact high / risk low. Delete the unread `liveTranscript` mirror; move the 1 Hz elapsed tick into a tiny `CaptureClock` observed only by live band, banner, bottom bar, tray; equality-guard `clearTransientMessages` and the calendar mirrors; compare-before-assign + fingerprint gating in `MeetingOrganizationIndex`; `let` instead of `@ObservedObject` in method-only views.
  > 2026-10-02 diamond: landed on main as 31759321. Left observed on purpose: MeetingNotesPane (relies on the republish to show new notes), ParticipantsSection, SpeakerMappingView, MeetingLinkEventView, FinalRetranscriptionSettingsView. Scoped tests green (225 incl. 1B).
- [x] Perf 1B: cache per-render document/home facts, lazy Home timeline, leaf-local drafts @diamond
  Impact high / risk low. Duration / speaker count / has-content cached per (id, updatedAt) in `MeetingDocumentModel`; `documentPresentation` bound once; ask draft + transcript search as leaf `@State`, delete dead `noteDraft`; memoized transcript bubbles; `LazyVStack` timeline; memoized `homeBadgeFacts`; static formatters; `displayedMeetings` evaluated once per body.
  > 2026-10-02 diamond: landed on main as 355a177f. Not yet verified visually (lazy timeline look, row virtualization) nor re-profiled — needs a dev rebuild after the current live meeting ends. Follow-ups seen: `renderedOutputBody` re-parses markdown per body (Phase 2 RenderedOutput task), `duplicateMeetingIDs` parses every title per body, `relatedDocuments(for:)` still stats disk per note.

## Backlog — found during the refactor
- [ ] Perf: store parsed action-item counts per output (optional column on MeetingOutput or a cache keyed by output id) so first paint of a row with a summary does not parse its markdown
  Impact low-med / risk low-med. ~1.7 ms per summary in a Debug build, paid once per realized row per launch. Outputs are immutable after write.
- [ ] Perf: live append cost grows with meeting length (save 12.4 ms + `segment.meeting = meeting` 8.8 ms on a 1,726-segment meeting, Debug)
  Impact low / risk unknown. 23 ms every ~4 s; both are SwiftData internals.
- [ ] Fix: `plannedSpeakerSource(for:)` writes diarization status during `SpeakerSection`'s body (pre-existing; found by the VM split)
- [ ] Fix: tray recording label keeps the old title after renaming the active meeting (pre-existing)
- [ ] Fix: related emails are not refetched when a meeting's participants change or an event is linked (pre-existing)
- [ ] Fix: `MeetingRelatedEmailsSection` reads `hasGoogleAccounts` without observing the account store (pre-existing)
- [ ] Verify in a dev build: everything merged on 2026-10-06 (see each worker section's "not verified" notes) — live caption session, list rows + context-menu dialogs, calendar clock at event start/end, first-launch facts backfill and history prune on the real store, launch log (`category == "Launch"`)

## Backlog — Perf refactor Phase 2 (structural)
- [x] Refactor: split `MeetingsViewModel` by feature slice and drop the Combine mirrors
  Impact high / risk high (15–20 test files). Slices: Capture, Calendar, Library/Organization, Outputs, Vault/Export, Import, Related. Views take the slice they use; mirrors become computed forwards (or `@Observable`, macOS 14 floor). Removes the documented "authoritative vs mirrored" staleness workarounds.
  > 2026-10-06 diamond: done by vm-split (garnet), merged to main as d36dc97c (inventory, docs/specs/2026-10-06-meetings-vm-split.md), 579762af (MeetingsCaptureModel), 244d3177 (MeetingsCalendarModel), 54c5dead (MeetingsOutputsModel), b903ebe0 (stop note). Old property names forwarded as computed properties; every reader re-pointed at its slice (tables in the commit messages, cross-checked by grep at each merge). Library (`meetings`) deliberately not split — reasoning in the spec. Worker: 43 classes / 392 tests green; not verified in the app (the running dev build predates it).
- [ ] Refactor: `MeetingService` into repositories under one writer (meetings / outputs / templates)
  Impact medium / risk medium. 1,661 lines, six entity families; shrinks the republish blast radius. Mechanical split, own commit, no behaviour change.

## Backlog — Perf refactor Phase 3 (tidy)
- [ ] Refactor: store clean title + effective date at import instead of parsing on every render
  Impact medium / risk low-med. The "Clean up imported title" action already proves the normalisation can be persisted; additive optional columns.
- [ ] Refactor: collapse trivial single-conformer protocols to closures
  Impact low / risk low. `MeetingJobClock`, `MeetingBriefSchedulerStore`, `CalendarColorProviding`, `RelatedEmailsProviding`, the two `GoogleDriveTranscriptImporter` seams, `MeetingEventEmitting`; drop job-queue priority promotion (one caller). Keep seams with widely shared fakes.
- [ ] Refactor: one `TextNormalizer` and one date-bucket helper
  Impact low-med / risk low. ~17 `normalize*` helpers and five hand-rolled day-bucketing sites; share only the trim/case-fold core (person-name vs tag semantics differ).
- [ ] Refactor: unify the organization/metadata stores behind one Library model
  Impact medium / risk med-high (user data migration from UserDefaults). `MeetingOrganizationIndex`, `MeetingFolderMetadataStore`, `MeetingChecklistStore`, `CalendarSelectionStore` + `SpaceTreeModel` mirror. Do last, after the VM split gives the slice a home.
