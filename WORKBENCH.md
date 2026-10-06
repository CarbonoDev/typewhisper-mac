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

## Perf refactor — Phase 1 (stop the bleeding)
Ordered by impact ÷ implementation risk. Spec: docs/specs/2026-10-02-perf-refactor-plan.md (§3 findings, §5 phases).
- [x] Perf 1A: narrow MeetingsViewModel observation @diamond
  Impact high / risk low. Delete the unread `liveTranscript` mirror; move the 1 Hz elapsed tick into a tiny `CaptureClock` observed only by live band, banner, bottom bar, tray; equality-guard `clearTransientMessages` and the calendar mirrors; compare-before-assign + fingerprint gating in `MeetingOrganizationIndex`; `let` instead of `@ObservedObject` in method-only views.
  > 2026-10-02 diamond: landed on main as 31759321. Left observed on purpose: MeetingNotesPane (relies on the republish to show new notes), ParticipantsSection, SpeakerMappingView, MeetingLinkEventView, FinalRetranscriptionSettingsView. Scoped tests green (225 incl. 1B).
- [x] Perf 1B: cache per-render document/home facts, lazy Home timeline, leaf-local drafts @diamond
  Impact high / risk low. Duration / speaker count / has-content cached per (id, updatedAt) in `MeetingDocumentModel`; `documentPresentation` bound once; ask draft + transcript search as leaf `@State`, delete dead `noteDraft`; memoized transcript bubbles; `LazyVStack` timeline; memoized `homeBadgeFacts`; static formatters; `displayedMeetings` evaluated once per body.
  > 2026-10-02 diamond: landed on main as 355a177f. Not yet verified visually (lazy timeline look, row virtualization) nor re-profiled — needs a dev rebuild after the current live meeting ends. Follow-ups seen: `renderedOutputBody` re-parses markdown per body (Phase 2 RenderedOutput task), `duplicateMeetingIDs` parses every title per body, `relatedDocuments(for:)` still stats disk per note.
- [ ] Perf 1C: stop refetching all meetings on live append (`appendStableSegments`)
  Impact high / risk low-med. Keep `nextOrder` per live meeting instead of `segments.map(\.order).max()`; `save()` without `fetchMeetings()`; refetch only on insert / delete / sort-key change; `performBatch` deferral for Drive import and calendar sync. BLOCKED until the Google Phase 2 edits to `MeetingService.swift` are committed (same file).
- [ ] Perf 1C: precompiled regexes + per-title memo in `ImportedMeetingTitle`
  Impact medium / risk low. 160 of 281 meetings are imported; parse runs 2–3× per row per render with a fresh regex per suffix. BLOCKED on the same uncommitted `ImportedMeetingTitle.swift` edits.
- [ ] Perf 1C: static DateFormatters + memoized `actionFacts` in `HomeFeedViewModel`
  Impact medium / risk low. `setLocalizedDateFormatFromTemplate` per day group per render is 5 % of Home samples. BLOCKED on the uncommitted `HomeFeedViewModel.swift` edits.
- [ ] Perf: debounce search in `MainWindowCoordinator`; commit folder description on blur
  Impact medium / risk low. Search fans out per keystroke to every coordinator observer incl. per-row context menus; folder description JSON-encodes the whole UserDefaults map per keystroke (`MeetingFolderDetailView.swift:93-95`).
- [ ] Perf: move Phase 0 profiler scripts under scripts/perf/ and record a before/after `top`/`sample` baseline
  Impact low / risk none. Analyzers currently live only in the session scratchpad.

## Perf refactor — Phase 2 (structural)
- [ ] Perf: cached `RenderedOutput` for markdown (outcomes + pre-built AttributedStrings per output id/createdAt)
  Impact med-high / risk low-med. `MeetingOutputParser.parse` + `AttributedString(markdown:)` per block run on every document render (`MeetingDocumentBody.swift:121-136`, `MarkdownDocumentView.swift:21,302-307`).
- [ ] Perf: value-type `MeetingRowModel` + one `MeetingRowView`, list-local selection
  Impact high / risk medium. One list model recomputes rows only on input change; rows are Equatable and take a value + isSelected/isLive; replaces the duplicated `ArchiveRow` / `TimelineRowContent`; lifts selection off the singleton VM. Also collapse the per-row context-menu presenter stack into one list-level pending action.
- [ ] Perf: denormalise `segmentCount`, `lastSegmentEnd`, output kinds onto `Meeting` (optional columns, additive)
  Impact high / risk medium (schema, but additive-only). Maintained by `MeetingService` on append/replace/merge/import; replaces the per-fact caches (`transcriptFactCache`, `homeBadgeFacts`, `actionFacts`) and the `segments.isEmpty` probes that fault whole relationships.
- [ ] Perf: vault work off the main actor
  Impact high when used / risk medium. `ObsidianVaultService` enumerate/parse/rank as a `nonisolated` core run detached, cache parsed notes by mtime; `VaultContextPickerView` filters a cached snapshot instead of walking the vault in `body`; lazy async `SpaceViewModel.refresh` (no scan in init); Space tree indexed once per refresh; draft text local `@State`.
- [ ] Perf: Google calendar/Drive decode + mapping off main; debounced ledger writes
  Impact medium / risk low-med. `GoogleCalendarSyncEngine.swift:296-335`, `GoogleDriveTranscriptImporter.swift:183-215`, `GoogleDriveImportLedger.swift:396-412`. Wait for Google Phase 2 to land first.
- [ ] Perf: one calendar coordinator (EKEventStoreChanged instead of the 60 s poll, EventKit query off main, equality-gated publish)
  Impact medium / risk medium. Replaces the 60 s Timer, the brief-scheduler tick from the calendar sink, and the unconditional republish that re-runs twin collapse + start notifications.
- [ ] Refactor: split `MeetingsViewModel` by feature slice and drop the Combine mirrors
  Impact high / risk high (15–20 test files). Slices: Capture, Calendar, Library/Organization, Outputs, Vault/Export, Import, Related. Views take the slice they use; mirrors become computed forwards (or `@Observable`, macOS 14 floor). Removes the documented "authoritative vs mirrored" staleness workarounds.
- [ ] Refactor: `MeetingService` into repositories under one writer (meetings / outputs / templates)
  Impact medium / risk medium. 1,661 lines, six entity families; shrinks the republish blast radius. Mechanical split, own commit, no behaviour change.

## Perf refactor — Phase 3 (tidy)
- [ ] Refactor: store clean title + effective date at import instead of parsing on every render
  Impact medium / risk low-med. The "Clean up imported title" action already proves the normalisation can be persisted; additive optional columns.
- [ ] Refactor: collapse trivial single-conformer protocols to closures
  Impact low / risk low. `MeetingJobClock`, `MeetingBriefSchedulerStore`, `CalendarColorProviding`, `RelatedEmailsProviding`, the two `GoogleDriveTranscriptImporter` seams, `MeetingEventEmitting`; drop job-queue priority promotion (one caller). Keep seams with widely shared fakes.
- [ ] Refactor: one `TextNormalizer` and one date-bucket helper
  Impact low-med / risk low. ~17 `normalize*` helpers and five hand-rolled day-bucketing sites; share only the trim/case-fold core (person-name vs tag semantics differ).
- [ ] Perf: prune SwiftData persistent history; defer non-critical startup past the first frame
  Impact low-med / risk low-med. `ACHANGE` has 74k rows and nothing prunes it; launch logged a 2.8 s slow-HID response with ~10 store opens, a vault scan and plugin loading all synchronous before the first frame.
- [ ] Refactor: unify the organization/metadata stores behind one Library model
  Impact medium / risk med-high (user data migration from UserDefaults). `MeetingOrganizationIndex`, `MeetingFolderMetadataStore`, `MeetingChecklistStore`, `CalendarSelectionStore` + `SpaceTreeModel` mirror. Do last, after the VM split gives the slice a home.
