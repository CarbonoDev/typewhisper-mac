#!/usr/bin/env bash
# Run the perf benchmark suite at the pre-refactor commit and at the current checkout, then print
# a before/after table. See scripts/perf/README.md.
#
#   scripts/perf/run-before-after.sh [runs]        # default: 3 runs per side
#
# Env: BEFORE_REF (default 772f3535), WORK_DIR (default: a fresh mktemp dir; removed on exit
# together with the exported tree and both DerivedData folders, ~3 GB each).
set -euo pipefail

RUNS="${1:-3}"
BEFORE_REF="${BEFORE_REF:-772f3535}"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
WORK_DIR="${WORK_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/typewhisper-perf.XXXXXX")}"
BEFORE_TREE="$WORK_DIR/before"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "work dir: $WORK_DIR"

# 1. Export the old commit (a plain export, not a worktree) and graft the suite onto it.
mkdir -p "$BEFORE_TREE"
git -C "$REPO" archive "$BEFORE_REF" | tar -x -C "$BEFORE_TREE"
cp "$REPO/TypeWhisperTests/PerfBenchmarkTests.swift" "$REPO/TypeWhisperTests/PerfBenchmarkFixtures.swift" \
   "$BEFORE_TREE/TypeWhisperTests/"
cp "$REPO/scripts/perf/PerfBenchmarkShim.before.swift" "$BEFORE_TREE/TypeWhisperTests/PerfBenchmarkShim.swift"
python3 "$REPO/scripts/perf/register_test_files.py" "$BEFORE_TREE/TypeWhisper.xcodeproj/project.pbxproj"

run_suite() { # <tree> <derived-data> <log>
  TEST_RUNNER_TYPEWHISPER_PERF=1 xcodebuild test \
    -project "$1/TypeWhisper.xcodeproj" -scheme TypeWhisper \
    -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO \
    -derivedDataPath "$2" \
    CODE_SIGN_IDENTITY='-' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
    -only-testing:TypeWhisperTests/PerfBenchmarkTests > "$3" 2>&1 \
    || { echo "suite failed, see $3" >&2; grep -E "error:|failed \(" "$3" >&2 || true; exit 1; }
}

BEFORE_LOGS=(); AFTER_LOGS=()
for run in $(seq 1 "$RUNS"); do
  echo "run $run/$RUNS: before ($BEFORE_REF)"
  run_suite "$BEFORE_TREE" "$WORK_DIR/dd-before" "$WORK_DIR/before-$run.log"
  BEFORE_LOGS+=("$WORK_DIR/before-$run.log")
  echo "run $run/$RUNS: after (working tree)"
  run_suite "$REPO" "$WORK_DIR/dd-after" "$WORK_DIR/after-$run.log"
  AFTER_LOGS+=("$WORK_DIR/after-$run.log")
done

python3 "$REPO/scripts/perf/summarize.py" "${BEFORE_LOGS[@]}" -- "${AFTER_LOGS[@]}"
