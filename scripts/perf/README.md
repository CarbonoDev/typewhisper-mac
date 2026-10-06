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

`772f3535` vs main at `d6f0692a` (list pipeline, row models, fact columns, Home readers on the
columns, one save per write), 3 interleaved runs per side, Debug build, Apple silicon. Median of
per-run medians; spread is the min–max of the per-run medians.

| Benchmark | Before ms (spread) | After ms (spread) | After/Before | Before extra | After extra |
|---|---|---|---|---|---|
| liveAppend.perAppend | 279.358 (278.791–279.852) | 23.119 (23.064–23.284) | 0.08× | listPublishes/append=1.00 objectWillChange/append=1.00 maxMainStall=291.0ms | listPublishes/append=0.00 objectWillChange/append=0.00 maxMainStall=23.6ms |
| importedTitles.firstRender | 104.949 (104.475–105.056) | 10.178 (10.112–10.587) | 0.10× | rows=300 | rows=300 |
| importedTitles.repeatRender | 100.746 (100.552–100.855) | 0.408 (0.394–0.420) | 0.00× | rows=300 | rows=300 |
| homeRows.firstPaint | 566.655 (561.631–566.853) | 225.538 (224.568–228.246) | 0.40× | rows=300 | rows=300 |
| homeRows.firstPaint.scalar | 130.902 (130.537–131.304) | 8.676 (8.326–9.657) | 0.07× | groups+headers+titles | groups+headers+titles |
| homeRows.firstPaint.outputs | 213.996 (213.172–214.328) | 214.584 (212.295–216.892) | 1.00× | badges+actionFacts relationshipReads=300 | badges+actionFacts relationshipReads=300 |
| homeRows.firstPaint.segments | 221.023 (216.733–223.143) | 2.628 (2.616–2.679) | 0.01× | hasTranscript relationshipReads=300 | hasTranscript relationshipReads=300 |
| homeRows.repeat | 133.966 (133.766–135.055) | 12.601 (12.076–12.641) | 0.09× |  |  |
| homeRows.afterWrite | 159.044 (158.442–159.997) | 12.103 (11.963–12.448) | 0.08× |  |  |
| listSearch.changedKeystroke | 63.830 (63.804–64.160) | 2.770 (2.738–3.019) | 0.04× | rows=300 | rows=300 |
| listSearch.unchangedRerender | 63.967 (63.902–64.017) | 0.381 (0.380–0.385) | 0.01× | rows=300 | rows=300 |
| markdown.firstRender | 5.477 (5.337–5.539) | 5.640 (5.484–6.230) | 1.03× | chars=3934 | chars=3934 |
| markdown.repeatRender | 3.858 (3.837–3.905) | 0.004 (0.004–0.004) | 0.00× |  |  |
| vault.retrieve.first | 614.621 (611.852–640.247) | 624.900 (621.609–625.559) | 1.02× | hits=3 maxMainStall=613.5ms | hits=3 maxMainStall=0.5ms |
| vault.retrieve.repeat | 602.188 (601.719–606.061) | 486.708 (482.697–511.429) | 0.81× | maxMainStall=636.0ms | maxMainStall=0.1ms |
| space.init | 308.375 (301.518–314.512) | 0.391 (0.370–0.503) | 0.00× |  |  |
| space.refresh | 307.747 (307.058–310.863) | 136.782 (136.339–136.909) | 0.44× | entries=2000 maxMainStall=310.1ms | entries=2000 maxMainStall=0.5ms |
| space.visitAllFolders | 266.482 (262.325–267.399) | 0.063 (0.062–0.064) | 0.00× | folders=26 | folders=26 |
| calendar.refreshUnchanged | 0.303 (0.300–0.304) | 0.390 (0.337–0.412) | 1.29× | publishes/refresh=2.00 maxMainStall=0.3ms | publishes/refresh=0.00 maxMainStall=0.3ms |
| archiveRows.window20.firstPaint | 60.102 (59.479–60.216) | 18.931 (18.316–19.269) | 0.31× | rows=20 | rows=20 |
| archiveRows.window20.repeat | 5.511 (5.508–5.526) | 0.275 (0.274–0.275) | 0.05× | rows=20 | rows=20 |
| archiveRows.wholeList.firstPaint | 532.221 (531.407–539.165) | 227.367 (226.643–227.645) | 0.43× | rows=300 | rows=300 |
| archiveRows.wholeList.repeat | 89.103 (88.888–89.128) | 4.463 (4.387–4.559) | 0.05× | rows=300 | rows=300 |

Live-append breakdown on the same tree (`PerfLiveAppendBreakdownTests`, one run of 20 appends of 3
segments; median ms). The replay repeats the service's SwiftData steps on a second context:

| Step | 1,726-segment meeting | 150-segment meeting |
|---|---|---|
| `appendStableSegments`, whole | 22.97 | — |
| replay, sum of steps | 22.70 | 3.99 |
| `ModelContext.save()` | 12.37 | 2.64 |
| `segment.meeting = meeting` (relationship assignment) | 8.75 | 1.03 |
| `context.insert` | 1.49 | 0.19 |
| segment mapping | 0.06 | 0.04 |
| `updatedAt` bump | 0.003 | 0.002 |
| `isInFetchOrder` over 300 meetings | 0.64 | — |

Save and relationship assignment both grow with the meeting's existing segment count (about 5 µs
per existing segment each, per append); mapping and the order scan are noise.
