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
