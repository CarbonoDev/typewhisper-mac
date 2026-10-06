# Perf profiling scripts

Phase 0 tooling from the perf refactor (`docs/specs/2026-10-02-perf-refactor-plan.md`).
They capture a `top` + `sample` baseline of the **running** dev build
(`MeetingWhisper-Dev.app`, process name `TypeWhisper`) and rank where the main
thread spends its time. Nothing here builds or relaunches the app.

Captures contain meeting titles and symbols from live data — write them to a
scratch directory, never into the repo.

## Capture

The drive scripts default to `pgrep -x TypeWhisper`; set `PID=<pid>` when more
than one build is running.

```bash
OUT=$(mktemp -d)

# Idle / steady-state baseline (10 s, 1 ms interval)
sample $(pgrep -x TypeWhisper) 10 -file $OUT/idle.txt

# Navigation under load: open URLs 2.5 s apart while sampling for 10 s
# (also writes top-<label>.txt with CPU/mem/threads every 2 s, and
#  nav-<label>.times with the moment each URL was opened)
scripts/perf/drive2.sh $OUT 2 typewhisper://home typewhisper://meetings \
  typewhisper://meeting/<meeting-uuid> typewhisper://screenshot/nav2

# Open two (large) meetings back to back, then screenshot
scripts/perf/drive1.sh $OUT <meeting-uuid-1> <meeting-uuid-2>
```

## Analyze

All three read a `sample` text report; thread 0 is the main thread.

```bash
# Busy vs idle on a thread, app-frame inclusive counts >= MIN, top self frames
python3 scripts/perf/analyze.py $OUT/nav-2.txt <MIN> [thread-index]

# Inclusive counts for every frame whose symbol contains any |-separated pattern
python3 scripts/perf/incl.py $OUT/nav-2.txt 'ImportedMeetingTitle|DateFormatter'

# Breakdown beneath one exact symbol (inclusive top-N, then self)
python3 scripts/perf/sub.py $OUT/nav-2.txt 'MeetingDocumentBody.body.getter' [thread-index] [N]
```

Compare counts between a baseline and an after-change capture taken with the
same drive script and the same data set.

## Benchmark suite (no app)

An XCTest suite that times the perf refactor's hot paths (`docs/specs/2026-10-02-perf-refactor-plan.md`
§3) without launching the app. It uses a synthetic on-disk meetings store shaped like the real one
(300 meetings, 160 with imported-style titles, 4 with 1,600 segments, ~50k segments, 100 long
summary outputs, attendees on every meeting) and a synthetic 2,000-note vault in a temp directory.

| Benchmark | Finding | What one sample is |
|---|---|---|
| `liveAppend.perAppend` | 2 | one 3-segment `appendStableSegments` into a 1,600-segment meeting; counts list republishes and `objectWillChange` per append |
| `importedTitles.firstRender` / `.repeatRender` | 9 | `ImportedMeetingTitle.parse` + `displayTitle` over all 300 titles |
| `homeRows.firstPaint` / `.repeat` / `.afterWrite` | 3–5 | Home timeline pass: day groups, group titles, badges, action facts, transcript fact, display title per row; `afterWrite` follows a live append |
| `homeRows.firstPaint.scalar` / `.outputs` / `.segments` | 3–5 | the first paint split by phase: grouping + headers + titles, then the reads that fault each row's `outputs` (badges, action facts), then its `segments` (transcript fact). SwiftData has no cheap fault counter, so the phases are timed |
| `listSearch.changedKeystroke` / `.unchangedRerender` | 5 | one archive body's filter + sort when the query changed, and when the list re-renders with the same query (before: `filteredMeetings` + the effective-date sort once per body, unmemoized; after: one memoized `MeetingListPipeline` call) |
| `archiveRows.window20.*` / `.wholeList.*` | 4–5 | the archive's per-row body work for the first 20 rows vs all 300, first paint (fresh context and caches) and repeat (before: what `ArchiveRow` read from the live `Meeting`; after: `MeetingRowModelStore`) |
| `markdown.firstRender` / `.repeatRender` | 6 | one body pass of a ~4 KB summary: outcome extraction, block split, inline attributes |
| `vault.retrieve.first` / `.repeat` | 10 | one `retrieve` over the 2,000-note vault |
| `space.init` / `.refresh` / `.visitAllFolders` | 10 | Space view model construction, one snapshot refresh, then every folder index's children lookup |
| `calendar.refreshUnchanged` | 11 | one calendar refresh with an unchanged 60-event list; counts section republishes |

`PerfLiveAppendBreakdownTests` (current code only, not grafted onto the old commit) splits one live
append into its parts: the whole `appendStableSegments`, the `isInFetchOrder` scan, and a replay of
the same SwiftData steps on a second context over the same store — segment mapping, relationship
assignment, insert, `updatedAt`, `save()` — into the 1,600-segment meeting and into a 150-segment
one, which shows which steps grow with the meeting.

Each result prints one line, `PERF|<before|after>|<name>|median_ms|min_ms|max_ms|n|<extra>`.
`maxMainStall` in the extra column is the longest single main-thread block during the timed
iterations, measured by a background timer pinging the main queue every 2 ms. It is what the user
feels: off-main work can take as long as before in wall time and still stall the main thread for 0 ms.

Numbers come from a Debug test build (`-Onone`), so absolute values run high; compare sides, not
against production.

### Run it on the current tree

The suite is skipped unless `TYPEWHISPER_PERF=1` reaches the test runner (the `TEST_RUNNER_` prefix
forwards it). It takes about 25 s, most of it seeding the store.

```bash
TEST_RUNNER_TYPEWHISPER_PERF=1 xcodebuild test -project TypeWhisper.xcodeproj -scheme TypeWhisper \
  -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO \
  CODE_SIGN_IDENTITY='-' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  -only-testing:TypeWhisperTests/PerfBenchmarkTests \
  -only-testing:TypeWhisperTests/PerfLiveAppendBreakdownTests | grep '^PERF|'
```

### Before / after

```bash
scripts/perf/run-before-after.sh [runs]   # default 3 runs per side
```

The script:

1. exports the pre-refactor commit (`BEFORE_REF`, default `772f3535`) with `git archive` into a temp
   directory — a plain export, not a `git worktree`;
2. copies `PerfBenchmarkTests.swift` and `PerfBenchmarkFixtures.swift` in unchanged, and
   `PerfBenchmarkShim.before.swift` in as `PerfBenchmarkShim.swift`, then registers the three files in
   that tree's test target (`register_test_files.py`);
3. runs the suite alternately on the old tree and the current tree, each with its own DerivedData;
4. prints a markdown table (`summarize.py`): per benchmark the median of the per-run medians, with
   the min–max of those medians as the run-to-run spread;
5. deletes the export and both DerivedData folders (~3 GB each) on exit, success or not.

Two cold builds dominate the runtime: plan on 15–25 minutes.

### The shim

The benchmark and fixture files use only API that exists at both commits. The four calls whose API
the refactor changed go through `PerfShim`:

| Call | Before (`PerfBenchmarkShim.before.swift`) | After (`TypeWhisperTests/PerfBenchmarkShim.swift`) |
|---|---|---|
| `retrieve` | synchronous `ObsidianVaultService.retrieve` | `await retrieve` (off the main actor, parse cache) |
| `refresh` | synchronous `SpaceViewModel.refresh` | `await refresh` (off the main actor, per-refresh index) |
| `calendarRefresh` | synchronous `CalendarService.refresh` (the 60 s poll) | `refreshInBackground` (the event-driven path) |
| `makeRenderer` | outcome parse + block split + inline attributes on every pass | `RenderedOutputCache` (build once, then look up) |

When a later change alters one of these APIs again, update the after shim; the before shim stays
pinned to `772f3535`.

### Results, 2026-10-06

These "after" numbers predate main's list pipeline, row models and fact columns; `listSearch` and
the Home rows were re-measured on the current tree after that and need a fresh before/after run.

`772f3535` vs main at `3a449793`, 3 interleaved runs per side, Debug build, Apple silicon. Median of per-run medians; spread is the min–max of the per-run medians.

| Benchmark | Before ms (spread) | After ms (spread) | After/Before | Before extra | After extra |
|---|---|---|---|---|---|
| liveAppend.perAppend | 263.708 (263.565–263.849) | 21.546 (21.429–21.615) | 0.08× | listPublishes/append=1.00 objectWillChange/append=1.00 maxMainStall=269.0ms | listPublishes/append=0.00 objectWillChange/append=0.00 maxMainStall=31.1ms |
| importedTitles.firstRender | 101.116 (100.759–102.528) | 9.963 (9.911–10.205) | 0.10× | rows=300 | rows=300 |
| importedTitles.repeatRender | 98.276 (97.670–98.361) | 0.395 (0.392–0.413) | 0.00× | rows=300 | rows=300 |
| homeRows.firstPaint | 538.627 (535.277–545.562) | 409.120 (407.468–412.993) | 0.76× | rows=300 | rows=300 |
| homeRows.repeat | 127.323 (126.690–127.697) | 9.195 (9.138–9.383) | 0.07× |  |  |
| homeRows.afterWrite | 147.248 (146.574–148.680) | 10.117 (10.010–10.254) | 0.07× |  |  |
| listSearch.perKeystroke | 32.593 (32.410–32.640) | 32.233 (32.065–32.502) | 0.99× | rows=300 passes/keystroke=7 | rows=300 passes/keystroke=7 |
| markdown.firstRender | 5.209 (5.205–5.280) | 5.244 (5.242–5.315) | 1.01× | chars=3934 | chars=3934 |
| markdown.repeatRender | 3.699 (3.671–3.723) | 0.004 (0.004–0.004) | 0.00× |  |  |
| vault.retrieve.first | 597.621 (581.677–640.703) | 599.674 (589.107–620.013) | 1.00× | hits=3 maxMainStall=583.3ms | hits=3 maxMainStall=0.6ms |
| vault.retrieve.repeat | 575.706 (571.862–624.536) | 469.897 (465.581–471.984) | 0.82× | maxMainStall=602.8ms | maxMainStall=0.0ms |
| space.init | 290.453 (286.543–291.758) | 0.362 (0.361–0.481) | 0.00× |  |  |
| space.refresh | 284.736 (284.661–284.885) | 131.530 (130.914–135.089) | 0.46× | entries=2000 maxMainStall=286.7ms | entries=2000 maxMainStall=0.5ms |
| space.visitAllFolders | 247.175 (246.663–247.631) | 0.063 (0.062–0.065) | 0.00× | folders=26 | folders=26 |
| calendar.refreshUnchanged | 0.272 (0.261–0.280) | 0.556 (0.536–0.568) | 2.04× | publishes/refresh=2.00 maxMainStall=0.3ms | publishes/refresh=0.00 maxMainStall=0.4ms |
