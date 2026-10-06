# Performance refactor: findings and phased plan

Date: 2026-10-02. Status: Phase 0 (investigation) complete; Phase 1 in progress.

Six parallel audits (live profiling of the running dev build, state propagation,
view layer, persistence, background/startup work, simplification) converged on
one root cause and a short list of amplifiers. This document is the single place
for the ranked findings, the phased plan, and what is deliberately left alone.

## 1. Root cause in one paragraph

A single `MeetingsViewModel.shared` (44 `@Published` properties, observed at 52
sites across 38 view files, including per-row views and the window root)
republishes everything that changes anywhere. `MeetingService` saves and then
refetches **all** meetings and replaces its published array after **every**
write (52 call sites), including each live-caption append, which arrives every
4 s from the Chrome extension. Each republish re-runs the `body` of every
observer, and those bodies redo expensive work: faulting SwiftData relationships
one SQL round-trip per object, parsing titles with freshly compiled regexes,
parsing markdown, allocating `DateFormatter`s, and scanning disk. With a
1,700-segment meeting open, one caption append costs roughly 0.3–0.5 s of main
thread; the profiler saw 1 s bursts at ~30 % CPU every 4 s with no user input,
90 %+ main-thread occupancy during navigation, and a spindump "spin".

## 2. Evidence (from the live dev build, pid 3042, read-only)

| Measure | Value |
|---|---|
| Meetings / segments / outputs | 281 / 50,172 / 121 |
| Largest meeting | 1,711 segments; several over 950 |
| Imported meetings (title parse on slow path) | 160 of 281 |
| Meetings without `startDate` (regex in sort comparator) | 2 of 281 |
| Idle CPU, no live session | 0 % |
| Idle CPU, live caption session | 1 s bursts at 28–33 % every 4 s |
| Main thread during navigation | 90–92 % busy over 10 s; spindump spin |
| Launch | 2.8 s "slow hid response"; peak 697 MB |
| CoreData / SwiftData warnings in log | 0 |

Main-thread hot spots by sample share:

1. `MeetingDocumentBody` transcript duration + speaker count: 30 % of navigation
   samples, 52 % of busy time with a big meeting open. Three full walks over
   `meeting.segments` per body; each segment access is a SQL fetch.
2. `MeetingService.appendStableSegments` `segments.map(\.order).max()`: 29 % of
   busy time steady-state during capture, O(n) per 4 s append, then
   `save()` + full `fetchMeetings()` + republish.
3. Home timeline non-lazy `VStack` over all meetings: 34 % of Home samples.
4. `DateFormatter` + `setLocalizedDateFormatFromTemplate` per day group per
   render: 5 %.
5. `homeBadgeFacts` faulting every output per row: 6 %.
6. `ImportedMeetingTitle.parse` regex compiled per suffix per call, 2× per row:
   4 %.

SwiftData objects re-fault after each `save()` + refetch, so "loaded once"
caching inside model objects does not help; derived values must be memoized
outside the models, keyed by `(id, updatedAt)`.

## 3. Ranked findings

Impact is the expected effect on interactive latency; effort is S/M/L.

| # | Finding | Where | Impact | Effort |
|---|---|---|---|---|
| 1 | Whole-window invalidation from the singleton VM: 1 Hz elapsed tick, ~3 Hz `liveTranscript` mirror with **zero readers**, selection, transient messages | `MeetingsViewModel.swift` 83, 414-431, 469-480; 52 observer sites | High | S→M |
| 2 | Refetch-all + republish after every write; live append refetches 281 rows every 4 s | `MeetingService.swift` 470-491, 1615-1631 | High | S→M |
| 3 | Document body faults all segments 3× per render; header duplicates it; `documentPresentation` computed 4× | `MeetingDocumentBody.swift` 208-225, `MeetingDocumentHeader.swift` 99, `MeetingDocumentView.swift` 16-18 | High | S |
| 4 | Home timeline eager over the whole archive; badge/action facts fault outputs per row; formatter per group | `MeetingTimeline.swift` 59-76, `MeetingsViewModel+Home.swift` 105, 188, `HomeFeedViewModel.swift` 120-128, 217-232 | High | M |
| 5 | List filter+sort computed 7× per body; search decodes attendees JSON per keystroke; selection lives on the singleton | `MeetingsListView.swift` 31-56, 68-70, 108; `MeetingsViewModel+Organization.swift` 226-289 | High | S→M |
| 6 | Typing in Ask / transcript search re-renders the whole document incl. markdown parse; `noteDraft` dead | `MeetingDocumentView.swift` 117-126, `MeetingDocumentBody.swift` 121-136, `MarkdownDocumentView.swift` 21, 302-307 | High | S |
| 7 | Transcript bubbles built twice per body, sorted each time | `MeetingTranscriptPanel.swift` 16-27, 109, 115 | High (long meetings) | S |
| 8 | Org index rebuild on every publish: JSON-decode tags ×281, O(F²) tree, 3 unconditional publishes | `MeetingOrganizationIndex.swift` 150-166 | Medium | S |
| 9 | Imported-title regexes compiled per call; `exportSuffixes` rebuilt per access | `ImportedMeetingTitle.swift` 55, 158-165 | Medium | S |
| 10 | Vault scans on the main actor: retrieval reads ≤2000 notes synchronously; picker enumerates the vault inside a view body per keystroke; Space tree O(N²) in body and on each draft keystroke; `SpaceViewModel.init` scans at launch | `ObsidianVaultService.swift` 72, 183-450; `VaultContextPickerView.swift` 24-27; `SpaceFolderView.swift` 54, 74; `SpaceTreeModel.swift` 62-88; `SpaceViewModel.swift` 48-50 | High when used | M |
| 11 | Calendar: synchronous EventKit query on main every 60 s; unconditional republish re-runs twin collapse, start notifications, brief scheduler | `CalendarService.swift` 128-145, 511-514; `MeetingsViewModel.swift` 361-391, 1951-1958 | Medium | M |
| 12 | ~20 Combine mirrors with a `receive(on: .main)` hop between two `@MainActor` objects: double render pass, documented staleness workarounds and manual `objectWillChange` pokes | `MeetingsViewModel.swift` 280-460; `+Rules.swift` 124-150 | Medium | M |
| 13 | Google calendar/Drive decode + mapping + import in synchronous main-actor stretches | `GoogleCalendarSyncEngine.swift` 296-335; `GoogleDriveTranscriptImporter.swift` 183-215 | Medium (bursty) | S→M |
| 14 | Folder description writes whole UserDefaults map per keystroke | `MeetingFolderDetailView.swift` 93-95 | Medium | S |
| 15 | Per-row context-menu modifier with 3 observed objects, 7 `@State`, 5 presenters | `MeetingRowContextMenu.swift` 15-83 | Medium | M |
| 16 | Startup: ~70 services, ~10 stores, vault scan and plugin loading synchronous before first frame | `ServiceContainer.swift` 638-720, `PluginManager.swift` 427-467 | Medium (launch) | M→L |
| 17 | Persistent history (`ACHANGE`, 74k rows) never pruned; `autosaveEnabled` plus explicit saves | `AppConstants.swift` 167, 188 | Low | S |

## 4. Overengineering inventory (ranked by payoff of simplifying)

1. **`MeetingsViewModel` as a forwarding facade.** ~3,450 lines across 10 files,
   21-parameter init, 107 methods in the main file, roughly half one-line
   pass-throughs to 20 services plus ~20 Combine mirrors. The nine `+Concern`
   extensions split lines, not coupling. It exists so views can observe one
   object; that is exactly finding 1.
2. **Mirror state layers that document their own races.** Five "authoritative
   synchronous vs Combine-mirrored" caveats and manual `objectWillChange` pokes
   compensate for the async hop in the mirrors.
3. **`HomeFeedViewModel`**: an `ObservableObject` with zero `@Published`,
   observed in ~8 places including per row; two caches written during `body`.
4. **Organization state in four places**: `MeetingOrganizationIndex`,
   `MeetingFolderMetadataStore` (UserDefaults JSON), `MeetingChecklistStore`,
   `CalendarSelectionStore`, plus `+Organization`; `SpaceTreeModel` mirrors the
   index again.
5. **Two meeting-row implementations** (`ArchiveRow`, `TimelineRowContent`)
   duplicating gutter, title parse, facts, hover.
6. **Display title parsed on every render** instead of normalised once at
   import (the "Clean up imported title" action proves it can be stored).
7. **Five signalling mechanisms** for overlapping facts (app `EventBus`,
   `MeetingEventBus`/`Emitter`, `NotificationCenter` for the Google snapshot,
   Combine mirrors, `JobQueueService.shared` observed by 10 views).
8. **Three schedulers** that could be one calendar coordinator driven by
   `EKEventStoreChanged` plus the Google snapshot.
9. **17 single-conformer protocols** (of 21 in scope). Keep the ones with widely
   shared fakes (`PromptProcessing`, `GoogleHTTPTransport`,
   `CalendarEventProviding`); collapse `MeetingJobClock`,
   `MeetingBriefSchedulerStore`, `CalendarColorProviding`,
   `RelatedEmailsProviding`, and the two importer seams into closures.
10. **~17 `normalize*` helpers** and five hand-rolled date-bucketing sites.
11. **`JobQueueService` generality**: priority promotion and the clock seam have
    one caller each; keep the serial lanes.

Deliberately **not** on the list, because NORTH-STAR or a spec justifies them:
the speaker ladder (`SpeakerSourcePlan`), per-call model routing with
provenance, `VAULT_SEARCH` single-round escalation, never-clobber
`VaultNoteWriter`, separate isolated stores with additive-only schema and a
single writer each, `MeetingEventBus` isolation from the dictation bus (AD4),
Google app-side (D-G1), narrow twin collapse (D-G6), polled Drive (D-D3),
in-memory mail only (D-M1), and the per-flush save in `appendStableSegments`
("the transcript is never lost": keep the save, drop the refetch).

## 5. Phased plan

Each phase is independently shippable and measurable. Measure with `top -pid`
during a live caption session (bursts every 4 s) and `sample` during navigation
before and after; the scratch analyzers from Phase 0 live in the session
scratchpad and should be moved under `scripts/perf/` when Phase 1 lands.

### Phase 1: stop the bleeding (S changes, no schema, no single-writer impact)

1A, view-model side (branch `perf/phase1a`):
- Delete the unread `liveTranscript` mirror.
- Move the elapsed clock into a tiny `CaptureClock` observed only by the live
  band, banner, bottom bar, and tray.
- Guard `clearTransientMessages` and the calendar mirrors with equality.
- Compare-before-assign and fingerprint gating in `MeetingOrganizationIndex`.
- `let` instead of `@ObservedObject` in method-only views.

1B, render side (branch `perf/phase1b`):
- Cache duration / speaker count / has-content per `(id, updatedAt)` in
  `MeetingDocumentModel`; bind `documentPresentation` once.
- Ask draft and transcript search become leaf `@State`; delete `noteDraft`.
- Memoize transcript bubbles; bind once per body.
- `LazyVStack` for the Home timeline; memoize badge facts; static formatters.
- Evaluate `displayedMeetings` once per body.

1C, service side (blocked until the Google Phase 2 working-tree changes to
`MeetingService.swift`, `ImportedMeetingTitle.swift`, `HomeFeedViewModel.swift`
are committed):
- `appendStableSegments`: keep `nextOrder` per live meeting; `save()` without
  `fetchMeetings()`; publish a per-meeting change instead of the array.
- Refetch only on insert / delete / sort-key change; add a `performBatch`
  deferral for importers and sync.
- Precompiled static regexes and a per-title memo in `ImportedMeetingTitle`.
- Static `DateFormatter`s in `HomeFeedViewModel`; memoize `actionFacts`.
- Debounce search in `MainWindowCoordinator`; commit folder description on blur.

### Phase 2: structural (M/L, touches 15–20 test files)

- Value-type row models: one `MeetingRowView(MeetingRowModel)` fed by a list
  model that recomputes only on input change; selection list-local.
- Split `MeetingsViewModel` by feature slice (Capture, Calendar, Library,
  Outputs, Vault/Export, Import, Related); views take the slice they use; drop
  the Combine mirrors (computed forwards, or `@Observable`, macOS 14 is the
  floor).
- Denormalise `segmentCount`, `lastSegmentEnd`, output kinds onto `Meeting` as
  optional columns (additive), maintained by `MeetingService`; retire the
  per-fact caches they replace.
- Move vault enumeration / tokenising off the main actor (`nonisolated`
  core + `Task.detached`), cache parsed notes by mtime; lazy Space refresh;
  index the Space tree once per refresh.
- Calendar: one coordinator, `EKEventStoreChanged` instead of a 60 s poll,
  EventKit query off main, equality-gated publish.
- Google decode/mapping off main; debounced ledger writes.
- `MeetingService` into repositories under one writer; cached `RenderedOutput`
  for markdown.

### Phase 3: tidy (S each, cognitive wins)

- Collapse trivial single-conformer protocols to closures; drop the emitter
  protocol; drop job-queue priority promotion.
- One `TextNormalizer`, one date-bucket helper; merge the two row views.
- Store the clean title / effective date at import.
- Prune persistent history; defer non-critical startup past the first frame.
- Unify the organization/metadata stores behind one Library model.

## 6. Constraints the refactor must respect

- Single writer per store; additive-only schema (optional/defaulted columns
  only).
- Swift 6 strict concurrency; services and view models stay `@MainActor`.
- Upstream-inherited files are not split or reformatted; fork additions to
  them go in sibling files.
- New files ≤500 lines, registered by hand in `project.pbxproj`; files over
  800 lines do not grow.
- `MainWindowCoordinator` API is frozen; routes are additive.
- EN + DE for any new user-facing string.
- Never run `scripts/build-dev-local.sh` while a test run or a live meeting
  is in progress.
