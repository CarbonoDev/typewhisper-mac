# NORTH-STAR.md

**Project type:** Code

What is worth building in this repo. `CLAUDE.md` says how to build; this says what to build and
what to turn down. It is for whoever turns a goal into tasks — a worker handed a brief does not
re-scope it on the strength of this file.

## 1. What this is for

Turning a meeting into durable, grounded knowledge on the user's own Mac: a transcript with
trustworthy speaker names, plus briefs, summaries, and Q&A that are grounded in the meeting itself
and in material the user already owns (Obsidian vault, calendar, Drive transcripts, related email).

## 2. Who it is for

- **One person who sits in a lot of calls and keeps their knowledge in an Obsidian vault** — today
  that is the maintainer. Multi-account Google (work + personal), Google Meet, and bilingual
  meetings (the UI ships EN + DE; transcripts and LLM output parsing also handle ES) are first-class
  because that is the real daily setup.
- **Anyone who builds the fork from source.** Every feature is unlocked; there is no paid tier.
- **Not** teams or organisations: no shared workspaces, no server, no accounts of our own, no admin
  surface. A request that only makes sense for a team is out of scope.
- **Not** upstream TypeWhisper's dictation audience as such. Dictation, file transcription,
  workflows, and the plugin system stay working because we inherit them, but their roadmap is
  upstream's. Fixes that are upstream-worthy go back through the preview-PR flow instead of growing
  here.

## 3. What good looks like

A piece of work is worth doing when it serves at least one of these and breaks none:

- **The transcript is never lost.** Live text is persisted incrementally; an import or merge must
  never delete or overwrite a recording in progress; a store change must never reset user data
  (additive-only schema).
- **The most trustworthy source wins, and the user can tell which one it was.** Speaker labels
  follow the strict ladder (provider/caption labels > two-person channel split > local pyannote);
  model choice resolves per call (one-shot > template > purpose > app default) and is recorded as
  provenance.
- **Answers are grounded in the meeting first.** Vault and email are escalations the model has to
  ask for, not context stuffed into every prompt.
- **The user's files are theirs.** Vault writes are never-clobber; external sources (calendar,
  Drive, Gmail) are read-only; failures in one account or calendar degrade to stale data, never to
  an empty list or a thrown error.
- **It runs locally and degrades gracefully.** Cloud providers are optional plugins. The local HTTP
  API stays loopback-only and off by default.
- **Upstream stays mergeable.** Meetings work lives in the fork's own files; edits to shared
  upstream files are minimal and additive.

## 4. What this is not

- Not a meeting bot. Nothing joins the call as a participant or records on a server; capture is the
  local mic + system audio, or Meet's own captions via the Chrome extension.
- Not a SaaS or a sync service. No backend, no cross-device sync, no telemetry pipeline.
- Not a monetised product. No license keys, supporter prompts, or feature gating — and upstream
  commits that reintroduce them are never re-adopted.
- Not a calendar, mail, or Drive client. We read those to give a meeting context; we do not write
  events, send or label mail, or manage files.
- Not a note-taking app or an Obsidian replacement. Space is a browser over the vault; the vault
  stays the source of truth and Obsidian stays the editor of record.
- Not a rewrite of upstream. Dictation, workflows, plugins, the HTTP API, and the CLI are carried,
  not redesigned.
- Not a Mac App Store app, and not cross-platform. macOS 14+, direct build.

## 5. What we have already rejected, and why

- 2026-07-07 — Paid tier / license keys / supporter prompts: removed outright (`165f683`,
  `042d868`); a personal fork has no one to sell to and the gates only cost maintenance.
- 2026-07-08 — An LLM relevance judge inside Space: the judge is a meeting-scoped concern; Space
  stays a plain vault browser with no second scanner (Track E spec).
- 2026-07-18 — Upstream's premium iPhone/Mac sync (`f8dfdbb`): out of scope for a delicensed,
  single-machine fork; revisit only if the fork ever adopts a sync story.
- 2026-07-18 — Upstream's settings restyle series (#948/#950/#951) as clean picks: collides with
  the meetings-first settings structure; adapt deliberately or skip.
- 2026-08-10 — Google auth as a plugin-SDK feature (D-G1): it would widen the upstream-shared SDK
  for a fork-only need; Google lives app-side in `Services/Google/`.
- 2026-08-10 — An automatic cross-provider calendar dedupe engine (D-G6): too easy to collapse two
  real events; twins are collapsed on a narrow `iCalUID` key and the manual merge is the fallback.
- 2026-08-10 — Calendar write access: read-only everywhere, matching the EventKit posture.
- 2026-08-11 — Drive `changes.list` / push / watch channels (D-D3): a polled listing window is
  enough for one user and needs no public endpoint.
- 2026-08-11 — The `drive.file` scope: it only sees files opened through a Google picker, which
  kills auto-discovery of transcripts.
- 2026-08-11 — The Meet REST API (`conferenceRecords`) as a transcript source: extra scopes, and it
  does not cover the Gemini notes docs; Drive is the single source.
- 2026-08-11 — A Workspace-Internal OAuth app: org-locked, so it excludes personal Gmail accounts;
  the consent screen stays in Testing mode and weekly reconnects are accepted until verification.
- 2026-08-11 — A local mail index / sync engine / offline email search (D-M1): email is fetched on
  demand into an in-memory TTL cache and never persisted.
- 2026-08-11 — Auto-merging a Drive transcript into a near-miss meeting (score < 0.6): create a new
  meeting instead; a wrong merge destroys data, a duplicate is one manual merge away.
- 2026-09-18 — *Reversal, kept as a warning:* "discover only Gemini notes docs, not transcript
  docs" was a Phase 2 non-goal built on a single sample export, and it was the bug. A non-goal that
  narrows what we ingest needs more than one sample behind it.

## 6. Current focus

As of 2026-09-30:

- **Google integration, Phase 2 (Drive transcript auto-import + backfill)** — in progress on the
  working tree; Phase 1 (auth + Calendar) is merged, Phase 3 (Gmail context) is code-complete.
  Specs: `docs/specs/google-integration-phase{1,2,3}-*.md`.
- **Meet caption bridge** (`chrome-extension/`) hardening — real speaker names, live, merged in
  PR #13.
- **Around the edges:** the landing page (`site/`) and the Home Assistant Wyoming bridge
  (`tools/wyoming-bridge/`), both still untracked.
- **Open and undecided:** the product name ("MeetingWhisper" is a working title; the upstream
  trademark requires a rename before any redistribution), a release process for the fork, and
  Google OAuth verification.
