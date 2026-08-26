# Upstream Sync Playbook

How this fork tracks the upstream TypeWhisper project, pulls fixes forward, and offers changes
back. Read this before starting any sync.

## Fork model

- **`origin`** — `git@github.com:CarbonoDev/typewhisper-mac.git`. This fork. All product work lives
  here.
- **`upstream`** — `https://github.com/TypeWhisper/typewhisper-mac.git`. The public project we
  forked from. Fetch-only in practice; we never push product branches to it.
- **`main`** — sits at the fork point plus fork-local scaffolding (e.g. `Add CLAUDE.md`). It is the
  shared ancestor with upstream, not the development trunk.
- **`feature/meetings`** — the product branch. This is where the fork's work ships: the meetings
  suite, the Space vault browser (Track E), the perf-hardened capture path, and every adopted
  upstream commit. Treat it as the effective trunk.
- **`origin/upstream`** — a mirror branch on `origin` that mirrors `upstream/main`. It exists so
  reverse-direction PRs (fork → upstream) can be previewed on `origin` without touching the real
  upstream. Keep it in step with `upstream/main` (currently both at `cbf684c`).

## Running a sync (upstream → fork)

1. **Fetch.** `git fetch upstream`. New work lands on `upstream/main`.
2. **Build an adoption ledger.** Walk the new commits (`git log <last-synced-sha>..upstream/main`)
   and classify every one:
   - **ADOPT-CLEAN** — cherry-picks with no conflict, wanted as-is.
   - **ADOPT-ADAPT** — wanted, but needs rework to fit the meetings-first shell, the delicensed
     build, or the perf-hardened capture path.
   - **DEFER** — potentially wanted later; parked with a reason (see "Deferred items" below).
   - **SKIP** — not wanted (UI that collides with the fork's structure, premium/monetization,
     upstream-only release plumbing, and merge commits that are tree-identical to their adopted
     constituents).
3. **Stage cherry-picks.** Work on a dedicated `upstream-integration` branch, cherry-pick with
   `-x` (records the source SHA in the message), in small batches ordered to minimize conflicts.
4. **Gate each batch.** Run the full suites before moving on:
   ```bash
   xcodebuild test -project TypeWhisper.xcodeproj -scheme TypeWhisper -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO CODE_SIGN_IDENTITY='-' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
   swift test --package-path TypeWhisperPluginSDK
   ```
5. **Close out with `-s ours`.** Once the wanted commits are in, record a closure merge that ties
   the fork history to the synced upstream tip without taking any of its tree:
   ```bash
   git merge -s ours upstream/main
   ```
   Write the excluded SHAs into the commit body (skipped and deferred, with reasons) so the next
   sync's `git log <closure>..upstream/main` surfaces only genuinely new commits. The example to
   follow is **`6afb356`** ("Close out upstream sync at 2d29456 (-s ours)"), which recorded the
   adoption of upstream PRs #816–#954: 49 commits cherry-picked (some adapted), the rest listed as
   skipped or deferred by SHA.

## Invariants any sync must preserve

These are the reasons commits get adapted or skipped. A sync that breaks one of them is wrong even
if the suite is green.

- **The dependency revision pins in `TypeWhisperPluginSDK/Package.swift`.** Upstream bumps to these
  must be reviewed, not auto-adopted. Current pins:
  - FluidAudio — `revision: 300165b240c45375add402265f62410b6df33cf1`
  - mlx-audio-swift — `revision: 2685c640d4079641a01ef3489cacb684c34109fd`
  - mlx-swift — `exact: 0.31.3`

  (For context, the exact/from pins alongside them: swift-huggingface `exact: 0.9.0`,
  onnxruntime-swift-package-manager `from: 1.24.2`.)
- **The delicensing.** The fork removed monetization and unlocked all paid features
  (`165f683` open-source all paid features, `042d868` unlock paid features / remove monetization,
  `e448c31` remove inert Polar/supporter dead code). Never re-adopt upstream commits that reintroduce
  money-asks, supporter prompts, or feature gating.
- **The meetings-first settings and menu-bar structure** (`ed7a38e`, "Track D: settings regroup +
  menu-bar slim"). Upstream settings/menu restyles that assume the original layout collide with
  this and are adapted or skipped.
- **The perf-hardened capture path** — bounded streaming finalization (`793e1b8`, #914), scroll-lag
  fix while a Recorder session is active (`83ee86f`, #934), and the mic-teardown / mic-priority
  hardening from the B4 pass (`ffe99da`, `5276023`). Preserve these when adapting upstream capture
  or recorder changes.

## Reverse direction (fork → upstream)

When a fork fix is genuinely upstream-worthy, offer it back as an atomic branch:

- Branch each contribution off the **`origin/upstream` mirror branch** (which tracks
  `upstream/main`), one self-contained fix per branch.
- Open a **preview PR against `origin/upstream`** so it can be reviewed in the fork before anything
  is proposed to the real upstream.
- Existing preview PRs (all open against base `upstream` on `origin`):
  - **#1** — Dev build script: honor `CodeSigning.local.xcconfig` so keychain/TCC grants survive
    rebuilds.
  - **#2** — StreamingHandler: reject length-mismatched snapshots before the LCS pass.
  - **#3** — Settings: restore Prompts and Rules panes (deep links dead-ending on Workflows).
  - **#4** — ClaudePlugin: fetch model list from `/v1/models` with 24h cache, skip sampling params
    for models that reject them.

## Deferred items (parked for a future sync)

Recorded as DEFER in `6afb356`; revisit on the next sync.

- **Soniox live engine** (`7450349`, #818) — new live WebSocket transcription engine; deferred
  pending a decision on carrying another live engine alongside the fork's capture path.
- **Settings restyle series** (`34019fb` #948 form-based pages, `42b63cc` #950 tool/workspace pages,
  `e2daaaa` #951 complex pages) — broad settings-page unification; deferred because it collides with
  the meetings-first settings structure and needs adaptation, not a clean pick.
- **Premium iPhone/Mac sync** (`f8dfdbb`, #929) — skipped in the last sync as out of scope for the
  delicensed fork; parked, revisit only if the fork adopts a sync story.
- **Release-pipeline commits** — `80667c2` (#896, verify public appcast publication), `6bd1a51`
  (#917, show canonical release tags in About), `5c34d45` (#824, localized screenshot automation);
  deferred because they assume the upstream release process, which the fork has not yet defined.

Other deferred commits from the same closure: `06d6545` (make recording cancel confirmation
optional), `80ee8ea` (#852, Gemma 4 4-bit MLX loading fix), `35ba373` (#879, guided microphone
correction trainer).
