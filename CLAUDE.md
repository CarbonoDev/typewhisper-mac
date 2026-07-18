# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a **meetings-focused fork** of upstream TypeWhisper (a macOS menu bar app for speech-to-text and AI text processing). It keeps the full upstream base — system-wide dictation, file transcription, workflows — and adds a Meetings feature on top:

- **Calendar-aware capture**: read-only EventKit integration surfaces current/upcoming events and projects a chosen event into a `Meeting`.
- **Live transcript** captured through a dedicated meeting recorder that never touches the standalone dictation Recorder's state.
- **LLM outputs**: pre-meeting briefs, summaries / extended analysis, and in-meeting Q&A over the transcript plus vault knowledge.
- **Participants** directory with dedupe/promote/merge, and **speaker labeling** (cloud labels, deterministic two-person channel path, or local pyannote diarization).
- **Obsidian export** and a **Space** vault browser (folders + notes) built on a shared never-clobber write discipline.

Swift 6 with strict concurrency, SwiftUI, macOS 14.0+ deployment target, Xcode 16+.

The fork stays close to upstream (dictation/workflows/plugins are largely upstream code); the Meetings feature is the fork's own surface and is where most divergence lives. When touching shared upstream files, prefer minimal, additive changes to keep upstream syncs clean.

## Commands

```bash
# Full app test suite (also the pre-ship check from CONTRIBUTING.md)
xcodebuild test -project TypeWhisper.xcodeproj -scheme TypeWhisper -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO CODE_SIGN_IDENTITY='-' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

# Single test class (append -only-testing to the command above)
... -only-testing:TypeWhisperTests/WorkflowServiceTests

# Plugin SDK + first-party plugin tests (fast, no Xcode project build; ~29 test targets: SDK core + per-plugin suites)
swift test --package-path TypeWhisperPluginSDK

# PR preflight: whitespace/conflict checks, shell script parsing,
# Python registry-script tests, plugin SDK tests
scripts/pr-preflight.sh [base-ref]   # default base: origin/main

# Build, install, and launch a local dev build (TypeWhisper-Dev.app)
scripts/build-dev-local.sh
```

Building requires no signing setup (ad-hoc signing). To use a real identity: `echo 'DEVELOPMENT_TEAM = YOUR_TEAM_ID' > CodeSigning.local.xcconfig`.

`build-dev-local.sh` **auto-signs when `CodeSigning.local.xcconfig` is present**: it builds with the developer identity so keychain items and TCC grants (mic, calendar, accessibility) survive rebuilds. Without it, it falls back to ad-hoc signing and those grants reset every rebuild — a real pain when iterating on meetings/calendar permissions, so keep the xcconfig around for meetings work.

Debug builds use a separate data directory (`TypeWhisper-Dev`) and keychain prefix, so they don't interfere with an installed release build.

The meetings feature has extensive unit coverage in `TypeWhisperTests/` (e.g. `MeetingModelRouterTests`, `JobQueueServiceTests`, `MeetingDiarizationEnricherTests`, `CalendarServiceTests`, `MeetingLLMServiceTests`, `MeetingBriefServiceTests`, `ParticipantDirectory*Tests`). Most are pure-logic tests over fakeable seams (the diarization/import/rule-matching protocols), so they run without the plugin graph — scope to one class with `-only-testing:TypeWhisperTests/<Class>` when iterating.

## Architecture

### Two build units

1. **`TypeWhisper.xcodeproj`** — the app (`TypeWhisper/`), tests (`TypeWhisperTests/`), widgets (`TypeWhisperWidgetExtension/` + `TypeWhisperWidgetShared/`), and CLI (`typewhisper-cli/`).
2. **`TypeWhisperPluginSDK/`** — a Swift package with the plugin SDK *and* all first-party plugin sources under `TypeWhisperPluginSDK/Plugins/` (WhisperKit, Parakeet, Groq, OpenAI, Gemini, xAI/Grok, AssemblyAI, Linear, Webhook, MLX-based local models, etc.). The app depends on this package; plugins ship as macOS `.bundle` files loaded from `~/Library/Application Support/TypeWhisper/Plugins/`.

Bundled `.bundle` plugins each build via their own Xcode scheme (`GeminiPlugin`, `GroqPlugin`, `OpenAIPlugin`, `WebhookPlugin`, `XAIPlugin`, …); `swift test --package-path TypeWhisperPluginSDK` exercises the SDK and per-plugin test targets together.

### Everything is a plugin

Transcription engines, LLM providers, TTS providers, post-processors, and actions are plugins — the bundled engines are reference implementations of the same SDK external plugins use. Key protocols: `TranscriptionEnginePlugin`, `LLMProviderPlugin`, `TTSProviderPlugin`, `PostProcessorPlugin`, `ActionPlugin`. Each plugin has a `manifest.json` (id, version, `principalClass`, `sdkCompatibilityVersion`) and receives a `HostServices` object (keychain, scoped UserDefaults, data directory, event bus).

Host-side plumbing in `TypeWhisper/Services/`:
- `PluginManager` — discovery, loading, lifecycle
- `PluginRegistryService` — community plugin marketplace (feeds defined in `PluginRegistry/`)
- `ModelManagerService` — transcription dispatch; delegates to engine plugins
- `HostServicesImpl` — the host side of the plugin API
- `EventBus` — typed publish/subscribe (recordingStarted, transcriptionCompleted, textInserted, …); plugins observe the pipeline through it
- `PostProcessingPipeline` — priority-ordered text-processing chain

### Meetings services — `TypeWhisper/Services/Meetings/`

42 source files. Each store-owning service is the **single writer** of its own isolated SwiftData store.

- **`MeetingService`** — sole writer of the `meetings.store` aggregate (`Meeting`, `MeetingSegment`, `MeetingNote`, `MeetingOutput`, `MeetingQATurn`, `MeetingTemplate`); owns its `ModelContainer`/`ModelContext`.
- **`CalendarService`** — read-only EventKit integration behind `CalendarEventProviding`; rolling window of events, projects an event into a `.calendar`-sourced meeting.
- **`MeetingCaptureService`** — drives live capture; wraps `AudioRecorderService` with its own `StreamingHandler`, isolated from the standalone Recorder and the EventBus.
- **`MeetingLLMService`** (+ `MeetingQAComposer` enum, in-file) — summaries/analysis and meeting-first in-meeting Q&A: pass 1 grounds only on the meeting's own material; a second pass runs only when the model requests a vault search (`VAULT_SEARCH:` escalation, at most one round).
- **`MeetingBriefService`** (+ `MeetingBriefScheduler`) — pre-meeting briefs from prior related meetings and vault passages.
- **Diarization / speaker labeling**: `SpeakerSourcePlan` is a pure precedence resolver with a strict ladder **cloud labels > two-person channel path > local pyannote** (+ `.none`) — cloud labels are adopted only when the "prefer provider speaker labels" preference is on. `MeetingDiarizationEnricher` runs the local pyannote diarization provider over stored audio; `SpeakerTimingAligner` is the pure timing-transfer aligner for the keep-live timing re-pass; `MeetingSegmentMapper` and `TranscriptMerger` support the pipeline.
- **`ObsidianVaultService`** + **`VaultNoteWriter`** — vault retrieval and the shared never-clobber write discipline (sanitize filename / unique path / atomic write), reused by both the meeting exporter and Space.
- **`MeetingObsidianExporter`** — exports selectable sections (`brief`/`summary`/`extended`/`transcript`/`notes`) to the vault.
- **Importers**: `MeetingImportService` (+ `ImportedMeetingTitle`) — audio import transcribes through `ModelManagerService.transcribe`; `TranscriptFileParser` handles transcript files.
- **`JobQueueService`** — in-memory lane-based serial drivers. Lanes: `llm` and `transcription` (cap 1), `io` (unbounded). Job kinds map to lanes (e.g. summary/brief/languageDetection→llm, finalTranscription/audioImport/diarization→transcription, export/participantBackfill→io). Dedupe by `(kind, meetingID)` drops a second enqueue while one is in flight, with priority promotion on a dedupe hit. Nothing is persisted.
- **`ParticipantDirectoryService`** — single writer of `participants.store`; every attendee write funnels through `ingest(_:)`; pure dedupe/promote/merge logic (`PersonIdentity`).
- **`MeetingModelRouter`** — per-purpose LLM provider/model selection, resolved **per call** (never snapshotted) with precedence **one-shot > template > purpose > app default**. Purposes: `.summariesAnalysis`, `.briefs`, `.qa`, `.languageDetection`, `.relatedDocsJudge` (only summaries/briefs carry a template rung). Two resolver flavors: a call-time override (`one-shot ?? template ?? purpose`, `nil` = inherit the app default at the `process(providerOverride:)` seam) and an effective-value flavor (`one-shot ?? template ?? purpose ?? appDefault`) used for provenance recording and settings display. Provider and model dimensions resolve independently.
- **`MeetingContextRuleService`** — single writer of `meeting-rules.store`; evaluates capture-context rules behind `MeetingContextRuleMatching`.
- **Templates & output**: `MeetingTemplatePresets` is the curated starter set (migrated into `.meeting`-surface `PromptAction` rows, names/prompts localized EN+DE); `MeetingOutputParser` parses LLM output into stored `MeetingOutput`s; `MeetingLanguageDirective`/`MeetingLanguageService` handle spoken-language detection (a routed `.languageDetection` purpose).
- **`MeetingRelatedDocsService`** — related-documents discovery with an LLM relevance judge; `LexicalRetriever` + `TranscriptContextBuilder` assemble retrieval context.
- Supporting: `MeetingOrganizationIndex`, `MeetingFolderMetadataStore`, `MeetingChecklistStore`, `MeetingEventBus`/`MeetingEventEmitter`, `MeetingStartNotificationService`/`MeetingEndReminderService`, `JobQueueService`'s `MeetingJob`/`MeetingJobClock`.

SwiftData `@Model` types for meetings live in `TypeWhisper/Models/` (`Meeting`, `MeetingSegment`, `MeetingNote`, `MeetingOutput`, `MeetingQATurn`, `MeetingTemplate`, `MeetingContextRule`).

### Main window & views

- **`TypeWhisper/Views/MainWindow/`** — meetings-first main window. `MainWindowCoordinator` is the singleton navigation channel (frozen API: callers use `openMeeting(id:)` / `show(_:)`, never edit it). `MainWindowRoute` is the route enum; its `spaceFolder(String)` / `spaceNote(String)` cases are **additive on an otherwise-frozen contract** — the Space routes for the vault browser.
- **`TypeWhisper/Views/Space/`** — the Space vault browser (`SpaceFolderView`, `SpaceNoteView`, `SpaceTreeModel`, `SpaceSidebarSection`, `SpaceDraft`, `SpaceSelection`, `SpaceReveal`) driven by `SpaceViewModel`.
- **`TypeWhisper/Views/Meetings/`** — meeting detail / list UI. Home surfaces (`HomeFeedView`, `ComingUpCard`, `HomeLiveBanner`, `LiveRecordingBand`, `MeetingsListView`, `MeetingTimeline`) live under `MainWindow/`.
- The menu bar entry point (`MenuBarView`) and tray/activity indicators (`MeetingTrayIndicator`, `MeetingActivityIndicator`/`MeetingActivityPopover`) start and reflect capture; all cross-navigation routes through `MainWindowCoordinator`.

### App patterns

- **MVVM + `ServiceContainer`**: `ServiceContainer.shared` (`TypeWhisper/App/ServiceContainer.swift`) is the DI root; ViewModels expose a static `_shared` assigned at startup.
- **Isolated SwiftData stores**: every store-owning service builds its own container via `SwiftDataStoreFactory.create(for:storeName:in:)` (`TypeWhisper/App/AppConstants.swift`), one `.store` file per domain (`meetings`, `participants`, `meeting-rules`, plus upstream's `history`, `workflows`, `dictionary`, `snippets`, `profiles`, `usage-statistics`, …). **Additive-only schema discipline**: the factory resets (deletes) a store on an incompatible schema, so a non-additive `@Model` change is destructive data loss — only add optional/defaulted properties, never remove or retype existing ones.
- **Persistence & reactivity**: SwiftData for durable state (per-store, above); `@Published` / Combine for reactive UI. Meeting services publish their model arrays and refetch on write.
- **Concurrency**: Swift 6 strict concurrency. Meeting services and their view models are `@MainActor`; heavy work (transcription, diarization, LLM calls) is awaited from the main actor but runs off it inside the plugins/executors, so the queue drivers never block the main thread. `MeetingEventBus`/`MeetingEventEmitter` is a meetings-local channel kept separate from the app-wide plugin `EventBus`.
- **Localization**: all user-facing strings via `String(localized:)` backed by `TypeWhisper/Resources/Localizable.xcstrings`; **UI is localized in English and German** (plugins carry their own `.xcstrings`). New user-facing strings must ship EN + DE.
- **Dictation flow** (upstream): HotkeyService → AudioRecordingService → ModelManagerService (engine plugin) → PostProcessingPipeline / DictionaryService / WorkflowTextProcessingService → TextInsertionService, with WorkflowService matching the active app/browser URL.
- **Local automation surface**: `Services/HTTPServer/` exposes a localhost-only REST API (default port 8978, disabled by default); the CLI (`typewhisper-cli/`) is a thin client of it.
- **Data & permissions**: meeting audio is written under `meetings-audio/` in Application Support (per build flavor); the `.store` SwiftData files sit alongside. Meetings require TCC grants (microphone, calendar/EventKit, and accessibility for insertion) — hence the auto-signing note above so grants persist across dev rebuilds.

## Fork conventions

- **Remotes**: `origin` → `CarbonoDev/typewhisper-mac` (this fork), `upstream` → `TypeWhisper/typewhisper-mac`. `main` sits at the fork point plus fork-local scaffolding; **`feature/meetings` is the effective trunk** where feature work lands.
- **Upstream sync**: pull upstream changes as **staged cherry-picks** of the commits we want, then record a **closure commit with `git merge -s ours`** that marks the upstream range as reconciled without importing its tree (see e.g. `6afb356 Close out upstream sync at 2d29456 (-s ours)`). This keeps the trunk's history linear and the fork's own commits authoritative while still letting `git` know what has been integrated. The full runbook is `docs/upstream-sync.md`.
- **Dependency pins**: the `FluidAudio` and `mlx-audio-swift` (and `mlx-swift`) pins in `TypeWhisperPluginSDK/Package.swift` are pinned to exact revisions/versions. **Do not bump them casually** — they gate on-device diarization/audio-model behavior and are a common source of upstream-merge conflicts; change only deliberately, with a test pass.
- **Preview-PR flow** (fork → upstream): the `origin/upstream` branch mirrors `upstream/main`; upstream-worthy fixes branch off it and are opened as preview PRs against it on `origin`, so they can be reviewed in the fork before being proposed to the real upstream.
- **Design specs**: `docs/specs/` holds the design + implementation plans referenced by commit messages and code comments (e.g. the Space "Track E" spec, workflows design/plan). When code comments cite a plan/decision id (e.g. `D-A2`, `M5`, `AD7`), the corresponding spec is the source of truth.

## Pull Requests

- PRs are squash-merged into `main`; keep one feature/fix per PR and fill out the template (Summary + Test Plan).
- When a PR fixes or implements a GitHub issue (from AGENTS.md): include the issue context in the PR body, an auto-close reference like `Closes #123`, and a short test plan with the exact verification command(s).
