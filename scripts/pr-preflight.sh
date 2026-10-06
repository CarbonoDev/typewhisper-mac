#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
base_ref="${1:-origin/main}"

log() {
  printf '[pr-preflight] %s\n' "$*"
}

run_if_exists() {
  local script_path="$1"
  shift

  if [[ -x "$script_path" ]]; then
    "$script_path" "$@"
  else
    bash "$script_path" "$@"
  fi
}

cd "$repo_root"

if ! git rev-parse --verify "$base_ref" >/dev/null 2>&1; then
  log "error: base ref '$base_ref' was not found"
  log "hint: fetch the base branch first, or pass an existing ref explicitly"
  exit 2
fi

log "checking whitespace and conflict markers against $base_ref"
git diff --check "$base_ref"...HEAD

log "checking shell scripts parse"
while IFS= read -r script_file; do
  [[ -n "$script_file" ]] || continue
  bash -n "$script_file"
done < <(git ls-files 'scripts/*.sh')

log "checking the Meet Bridge extension version"
if ! git diff --quiet "$base_ref"...HEAD -- chrome-extension/src chrome-extension/manifest.json; then
  manifest_version() {
    python3 -c 'import json, sys; print(json.load(sys.stdin)["version"])'
  }
  base_version="$(git show "$base_ref":chrome-extension/manifest.json 2>/dev/null | manifest_version 2>/dev/null || true)"
  head_version="$(manifest_version < chrome-extension/manifest.json)"
  if [[ -n "$base_version" && "$base_version" == "$head_version" ]]; then
    log "error: chrome-extension/ changed but manifest.json is still at version $head_version"
    log "hint: bump \"version\" in chrome-extension/manifest.json and MeetBridgeVersion.shipped together"
    exit 1
  fi
  log "extension version $base_version -> $head_version"
fi
if command -v node >/dev/null 2>&1; then
  log "running Meet Bridge extension tests"
  node --test chrome-extension/test/*.test.js >/dev/null
fi

log "running Python script tests"
python3 scripts/test_assemble_community_plugin_registry.py
python3 scripts/test_plugin_registry_metadata.py
python3 scripts/test_import_gemini_meeting_notes.py

log "checking release instrumentation helper"
run_if_exists scripts/check_release_binary_instrumentation.sh --self-test

log "running Plugin SDK tests"
swift test --package-path TypeWhisperPluginSDK

log "preflight complete"
