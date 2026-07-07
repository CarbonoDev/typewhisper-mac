# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

TypeWhisper is a macOS menu bar app for speech-to-text and AI text processing (system-wide dictation, file transcription, workflows). Swift 6 with strict concurrency, SwiftUI, macOS 14.0+ deployment target, Xcode 16+.

## Commands

```bash
# Full app test suite (also the pre-ship check from CONTRIBUTING.md)
xcodebuild test -project TypeWhisper.xcodeproj -scheme TypeWhisper -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO CODE_SIGN_IDENTITY='-' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

# Single test class (append -only-testing to the command above)
... -only-testing:TypeWhisperTests/WorkflowServiceTests

# Plugin SDK + first-party plugin tests (fast, no Xcode project build)
swift test --package-path TypeWhisperPluginSDK

# PR preflight: whitespace/conflict checks, shell script parsing,
# Python registry-script tests, plugin SDK tests
scripts/pr-preflight.sh [base-ref]   # default base: origin/main

# Build, install, and launch a local dev build (TypeWhisper-Dev.app)
scripts/build-dev-local.sh
```

Building requires no signing setup (ad-hoc signing). To use a real identity: `echo 'DEVELOPMENT_TEAM = YOUR_TEAM_ID' > CodeSigning.local.xcconfig`.

Debug builds use a separate data directory (`TypeWhisper-Dev`) and keychain prefix, so they don't interfere with an installed release build.

## Architecture

### Two build units

1. **`TypeWhisper.xcodeproj`** — the app (`TypeWhisper/`), tests (`TypeWhisperTests/`), widgets (`TypeWhisperWidgetExtension/` + `TypeWhisperWidgetShared/`), and CLI (`typewhisper-cli/`).
2. **`TypeWhisperPluginSDK/`** — a Swift package containing the plugin SDK *and* all first-party plugin sources under `TypeWhisperPluginSDK/Plugins/` (40+ plugins: WhisperKit, Parakeet, Groq, OpenAI, Gemini, xAI/Grok, Linear, Webhook, MLX-based local models, etc.). The app depends on this package; plugins ship as macOS `.bundle` files loaded from `~/Library/Application Support/TypeWhisper/Plugins/`.

### Everything is a plugin

Transcription engines, LLM providers, TTS providers, post-processors, and actions are implemented as plugins — the bundled engines are reference implementations of the same SDK external plugins use. Key protocols: `TranscriptionEnginePlugin`, `LLMProviderPlugin`, `TTSProviderPlugin`, `PostProcessorPlugin`, `ActionPlugin`. Each plugin has a `manifest.json` (id, version, `principalClass`, `sdkCompatibilityVersion`) and receives a `HostServices` object (keychain, scoped UserDefaults, data directory, event bus).

Host-side plumbing in `TypeWhisper/Services/`:
- `PluginManager` — discovery, loading, lifecycle
- `PluginRegistryService` — community plugin marketplace (feeds defined in `PluginRegistry/`)
- `ModelManagerService` — transcription dispatch; delegates to engine plugins
- `HostServicesImpl` — the host side of the plugin API
- `EventBus` — typed publish/subscribe (recordingStarted, transcriptionCompleted, textInserted, ...); plugins observe the pipeline through it
- `PostProcessingPipeline` — priority-ordered text-processing chain

### App patterns

- **MVVM + `ServiceContainer`**: `ServiceContainer.shared` (`TypeWhisper/App/ServiceContainer.swift`) is the DI root — it constructs all services and view models. ViewModels expose a static `_shared` that ServiceContainer assigns at startup.
- **Persistence**: SwiftData (HistoryService, PromptActionService, etc.); Combine for reactive updates.
- **Localization**: all user-facing strings via `String(localized:)` backed by `Localizable.xcstrings`; UI is localized in English and German (plugins carry their own `.xcstrings`).
- **Dictation flow**: HotkeyService → AudioRecordingService → ModelManagerService (engine plugin) → PostProcessingPipeline / DictionaryService / WorkflowTextProcessingService → TextInsertionService, with WorkflowService matching the active app/browser URL to decide language, engine, and prompt behavior.
- **Local automation surface**: `Services/HTTPServer/` (HTTPServer, APIRouter, APIHandlers) exposes a localhost-only REST API (default port 8978, disabled by default); the CLI (`typewhisper-cli/`) is a thin client of it.

## Pull Requests

- PRs are squash-merged into `main`; keep one feature/fix per PR and fill out the template (Summary + Test Plan).
- When a PR fixes or implements a GitHub issue (from AGENTS.md): include the issue context in the PR body, an auto-close reference like `Closes #123`, and a short test plan with the exact verification command(s).
