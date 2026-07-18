# TypeWhisper Meetings (working title)

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
[![macOS](https://img.shields.io/badge/macOS-14.0%2B-black.svg)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-6-orange.svg)](https://swift.org)

A macOS menu bar app for **calendar-aware meeting capture** on top of the speech-to-text and AI
text-processing foundation it inherits from [TypeWhisper](https://github.com/TypeWhisper/typewhisper-mac).
Record a meeting from the microphone and system audio, get a durable live transcript with reliable
post-call speaker labels, and turn it into pre-meeting briefs, summaries, extended analysis, and
grounded Q&A — with an optional Obsidian vault as the knowledge base.

The original app's dictation, file transcription, workflows, and plugin system are all still here and
still work the same way. This fork adds the entire Meetings surface on top and unlocks every feature
for everyone.

> **This is a fork.** It is based on the original TypeWhisper and keeps its architecture and most of
> its features. See [A note on this fork](#a-note-on-this-fork) for credit, naming, and licensing.

## A note on this fork

This project is a fork of **[TypeWhisper](https://github.com/TypeWhisper/typewhisper-mac)** by the
TypeWhisper project. Enormous credit and thanks go to the original authors: the dictation pipeline,
the "everything is a plugin" architecture, the transcription engines, the workflow system, the HTTP
API, and the CLI are all their work. This fork stands on that foundation and adds a meetings-focused
layer.

A few things to be aware of:

- **Name is a working title.** "TypeWhisper Meetings" is a placeholder pending a naming decision.
  The upstream [TRADEMARK.md](TRADEMARK.md) states that "TypeWhisper" and its logo/app icon are
  trademarks and that forks must be renamed and remove those trademarks before redistribution. If
  this fork is ever distributed, a distinct name (and icon) avoids trademark friction. Until then the
  app still builds as `TypeWhisper` internally.
- **All features are unlocked.** Upstream ships a dual-license model with a supporter/commercial tier
  gating some features. This fork removes that machinery: `LicenseService` reports every feature as
  available, and there are no purchase, license-key, supporter, or reminder prompts.
- **License files are untouched.** The code remains under **GPLv3** ([LICENSE](LICENSE)), and the
  upstream [LICENSE-COMMERCIAL.md](LICENSE-COMMERCIAL.md) and [TRADEMARK.md](TRADEMARK.md) are left
  in place as inherited from upstream. Removing paid feature-gates in code does not change your
  GPLv3 obligations.

## Meetings

Meetings are the headline of this fork. Open the app from the menu bar (**Open TypeWhisper**) and you
land in a meetings-first main window with a Home feed, a Meetings list, first-party Folders and Tags,
and a Space vault browser in the sidebar.

### Calendar-aware capture

- **EventKit calendar integration** — TypeWhisper reads your calendars (with permission) to surface
  upcoming meetings, link a recording to the event it belongs to, and drive pre-meeting briefs.
- **Mic + system audio, separate tracks** — Live capture records the microphone and system audio and
  keeps them as separate tracks, which the speaker pass can later split deterministically by channel.
- **Durable live transcript** — Stabilized transcript text is persisted incrementally as the meeting
  runs, so nothing is lost if the app is interrupted; on stop, the full buffer is re-transcribed to
  timestamped segments.
- **Ad-hoc or scheduled** — Start a recording straight from the menu bar for an unscheduled call, or
  let an upcoming calendar meeting prompt you.

### Reliable speaker labeling

Speaker labels are resolved **after** the call through a strict precedence ladder, so the most
trustworthy source wins:

1. **Cloud provider labels** — if the transcription engine already produced diarized labels tied to
   the real audio timeline, they are adopted directly.
2. **Two-person channel split** — a two-person call recorded as genuinely separate mic/system tracks
   is labeled deterministically by channel, with no detection model at all.
3. **Local pyannote** — general local diarization via a bundled Python `pyannote.audio` sidecar,
   hinted with the known participant count when available.

Diarization settings (enable/disable, speaker count, Python path, Hugging Face token for gated
pyannote models) live in **Settings → Meetings → Diarization**. Detected speakers can be mapped to
named participants from the meeting's roster.

### Briefs, summaries, and analysis

- **Pre-meeting briefs** — Before a meeting, TypeWhisper assembles a brief from summaries of prior
  related meetings (shared attendees or the same recurring series) plus relevant passages from your
  Obsidian vault, and makes one LLM call to draft it. Briefs can be generated automatically ahead of
  time (**Settings → Meetings → auto-brief**) or on demand. It degrades gracefully: no vault uses
  prior meetings only, no prior meetings uses vault passages only.
- **Summaries and extended analysis** — Generate structured outputs from the transcript using
  editable templates. Summary and Extended Analysis ship as presets; templates are editable prompt
  actions in the unified prompt/template library.
- **In-meeting Q&A** — Ask questions grounded on the meeting transcript-so-far. When the meeting
  material doesn't cover a question and an Obsidian vault is connected, the model can escalate to a
  single vault knowledge-base search round, with the answer disclosing that your notes were consulted.

### Organization and knowledge base

- **Participants directory** — A directory of the people across your meetings, backfilled from
  meeting rosters, used for attendee mapping and for finding related meetings.
- **Folders and tags** — First-party folders and tags organize the in-app meetings list. They work
  with no vault connected and are backed by the meeting store, not the vault.
- **Related documents** — Per-meeting agentic discovery ranks candidate vault notes with a
  single-turn LLM judge and surfaces the most relevant documents for a meeting.
- **Obsidian export** — Export meetings as Markdown notes into an Obsidian vault, with frontmatter
  (including a `typewhisper-meeting` backlink) and a uniform, never-overwrite folder layout.
- **Space — the vault browser** — A read-write browser for the connected Obsidian vault in the
  sidebar: open notes, and compose atomic, never-clobber **quick notes**. Space is a projection of
  the vault on disk; it is gated on a connected vault while Folders/Tags keep working without one.

### Import existing meetings

- **Audio or transcript** — Import existing recordings (audio) or transcripts as meetings.
- **Bulk archives via CLI / HTTP API** — Import a whole archive of old transcripts through the CLI
  (`typewhisper meetings import-transcript`) or the local HTTP API, optionally driven by an external
  agent, so historical meetings feed prior-meeting briefs. Supported transcript formats include
  Google Meet exports, `Speaker:` turns, timestamped lines, and plain text (`.txt`, `.md`).
- **Calendar matching** — On import, optionally match a transcript to a historical calendar event by
  date and link it automatically when confidence is high enough.

### Under the hood

- **Per-purpose model settings** — Summaries/analysis, briefs, Q&A, language detection, and the
  related-docs judge each have an independent provider/model setting, resolved per call with
  `template > purpose > app default` precedence.
- **Background job queue** — Long-running per-meeting work (summaries, briefs, final transcription,
  diarization, discovery, export, imports) runs through a lane-based job queue so LLM, transcription,
  and I/O work never contend across categories.
- **Menu bar meeting indicators** — The menu bar surfaces an in-progress recording (with elapsed
  time) or the soonest upcoming calendar meeting (with a countdown), each of which opens and focuses
  the meeting in the main window.

## Inherited features (from upstream TypeWhisper)

Everything below comes from the original TypeWhisper and is preserved in this fork. Where the fork
changed behavior it is called out.

### Transcription

- **Multiple engines** — WhisperKit (99+ languages, streaming, translation), Parakeet TDT v3 (25
  European languages, extremely fast), Apple SpeechAnalyzer (macOS 26+, no model download needed),
  Granite Speech (MLX-based), Qwen3 ASR (MLX-based), Voxtral (local Voxtral Mini 4B, MLX-based), Groq
  Whisper, OpenAI Whisper, Smallest Pulse, xAI/Grok STT, and OpenAI Compatible (any OpenAI-compatible
  API), plus registry engines such as AssemblyAI and ElevenLabs.
- **On-device or cloud** — All processing happens locally on your Mac, or use cloud APIs for faster
  processing.
- **Streaming preview** — See partial transcription in real-time while speaking (WhisperKit).
- **File transcription** — Batch-process multiple audio/video files with drag & drop; Dictionary
  Corrections apply to file transcriptions.
- **Subtitle export** — Export transcriptions as SRT or WebVTT with timestamps.

### Dictation

- **System-wide** — Push-to-talk, toggle, or hybrid mode via global hotkey, auto-pastes into any app.
- **Modifier-key hotkeys** — Use a single modifier key (Command, Shift, Option, Control) as your hotkey.
- **Indicator styles** — Choose Notch, Overlay, or Minimal, with optional live transcript preview.
- **Sound feedback** — Audio cues for recording start, transcription success, and errors.
- **Microphone selection** — Choose a specific input device, with a microphone priority list and
  recovery after route changes (including clamshell failover).

### AI processing

- **Workflows** — Build reusable transformations for translation, rewriting, extraction, formatting,
  and app-specific automation. Workflows run automatically by app, website, or app + website, from a
  dedicated hotkey, as a global fallback, or manually from the Workflow Palette.
- **Global LLM fallback list** — Order Apple Intelligence (macOS 26+), Groq, OpenAI / ChatGPT,
  xAI/Grok, Gemini, OpenAI Compatible, and local providers in one global provider/model list. Prompts
  and workflows inherit that order by default; a workflow with an explicit provider stays on that one.
- **Speech providers** — System voices, xAI/Grok TTS, and experimental local Supertonic TTS.
- **Local prompt processing** — Gemma 4 via MLX runs on-device on Apple Silicon (verified path:
  the E2B/E4B 4-bit models).
- **Translation** — Translate transcriptions on-device using Apple Translate.

### Personalization

- **Dictionary** — Terms improve cloud recognition accuracy; corrections fix common mistakes
  automatically, with auto-learning of high-confidence single-word manual corrections, grouped
  correction variants, search, and safe reset actions. Includes importable term packs.
- **Snippets** — Text shortcuts with placeholders like `{{DATE}}`, `{{TIME}}`, and `{{CLIPBOARD}}`.
- **History** — Searchable transcription history with inline editing, correction detection, app
  context tracking, timeline grouping, filters, bulk delete, multi-select export, and auto-retention.

### Integration & extensibility

- **Plugin system** — Extend TypeWhisper with custom LLM providers, transcription engines, TTS
  providers, post-processors, and action plugins. Bundled engines and integrations are reference
  implementations of the same SDK. See
  [TypeWhisperPluginSDK/Plugins/README.md](TypeWhisperPluginSDK/Plugins/README.md).
- **HTTP API** — Local REST API for integration with external tools and scripts (see below).
- **CLI tool** — Shell-friendly transcription and meeting import via the command line (see below).
- **Backup & Restore** — Export and restore settings, including meeting data.

### General

- **Universal binary** — Runs natively on Apple Silicon and Intel Macs.
- **Widgets** — Desktop widgets for usage stats, last transcription, activity chart, and history.
- **Multilingual UI** — English and German.
- **Launch at Login** — Start automatically with macOS, windowless on login launches.
- **Settings layout** — Settings are grouped as **Dictation**, **Meetings**, **Library**, **Tools**,
  and **Application**. The former "Recording" tab is now **Dictation**; the Meetings group holds the
  Meetings and Diarization tabs. With paid gating removed, formerly premium controls (target-app
  correction learning, cloud folder sync) live in the Application group and are available to everyone.

## Screenshots

The screenshots below cover the inherited dictation surfaces and predate the fork's settings
regroup — in particular, the Premium and License pages shown have been replaced by the delicensed
settings (see [A note on this fork](#a-note-on-this-fork)). Screenshots of the Meetings window,
Space vault browser, briefs, and speaker mapping are not yet captured.

<!-- readme-screenshots:start -->

<p align="center">
  <a href=".github/screenshots/home.png"><img src=".github/screenshots/home.png" width="270" alt="Home Dashboard"></a>
  <a href=".github/screenshots/recording.png"><img src=".github/screenshots/recording.png" width="270" alt="Recording"></a>
  <a href=".github/screenshots/recovery.png"><img src=".github/screenshots/recovery.png" width="270" alt="Recovery"></a>
</p>

<p align="center">
  <a href=".github/screenshots/hotkeys.png"><img src=".github/screenshots/hotkeys.png" width="270" alt="Hotkeys"></a>
  <a href=".github/screenshots/workflows.png"><img src=".github/screenshots/workflows.png" width="270" alt="Workflows"></a>
  <a href=".github/screenshots/file-transcription.png"><img src=".github/screenshots/file-transcription.png" width="270" alt="File Transcription"></a>
</p>

<p align="center">
  <a href=".github/screenshots/recorder.png"><img src=".github/screenshots/recorder.png" width="270" alt="Recorder API"></a>
  <a href=".github/screenshots/history.png"><img src=".github/screenshots/history.png" width="270" alt="History"></a>
  <a href=".github/screenshots/dictionary.png"><img src=".github/screenshots/dictionary.png" width="270" alt="Dictionary"></a>
</p>

<p align="center">
  <a href=".github/screenshots/dictionary-term-packs.png"><img src=".github/screenshots/dictionary-term-packs.png" width="270" alt="Dictionary Term Packs"></a>
  <a href=".github/screenshots/snippets.png"><img src=".github/screenshots/snippets.png" width="270" alt="Snippets"></a>
  <a href=".github/screenshots/plugins.png"><img src=".github/screenshots/plugins.png" width="270" alt="Installed Integrations"></a>
</p>

<p align="center">
  <a href=".github/screenshots/integrations-available.png"><img src=".github/screenshots/integrations-available.png" width="270" alt="Integration Marketplace"></a>
  <a href=".github/screenshots/premium.png"><img src=".github/screenshots/premium.png" width="270" alt="Premium"></a>
  <a href=".github/screenshots/license.png"><img src=".github/screenshots/license.png" width="270" alt="License"></a>
</p>

<p align="center">
  <a href=".github/screenshots/general.png"><img src=".github/screenshots/general.png" width="270" alt="General Settings"></a>
  <a href=".github/screenshots/advanced.png"><img src=".github/screenshots/advanced.png" width="270" alt="Advanced Settings"></a>
  <a href=".github/screenshots/about.png"><img src=".github/screenshots/about.png" width="270" alt="About"></a>
</p>

<!-- readme-screenshots:end -->

## Install

This fork is not published to Homebrew or as a signed release. Build it from source (see
[Build](#build)). To install the original, upstream app instead, see
[TypeWhisper releases](https://github.com/TypeWhisper/typewhisper-mac/releases/latest).

## Quick Start

1. Build and launch the app (see [Build](#build)), or run `scripts/build-dev-local.sh` for a local
   dev build.
2. Open Settings and grant Microphone plus Accessibility access (and Calendar access for Meetings).
3. Pick an engine and, if needed, download a local model.
4. Trigger the global hotkey to dictate, or start a meeting recording from the menu bar.

## System Requirements

- macOS 14.0 (Sonoma) or later
- Apple Silicon (M1 or later) recommended
- 8 GB RAM minimum, 16 GB+ recommended for larger models
- Some features (Apple Translate, improved Settings UI) require macOS 15+. Apple Intelligence and
  SpeechAnalyzer require macOS 26+.
- Local pyannote diarization requires a Python 3 environment with `pyannote.audio` installed and a
  Hugging Face token for the gated models. Cloud engines that diarize, or two-person separate-track
  calls, do not need it.

## Gemma 4 Support

TypeWhisper includes a bundled local Gemma 4 plugin powered by MLX for on-device prompt processing on
Apple Silicon. In the current verified path, Gemma 4 support is limited to the dense `E2B 4-bit` and
`E4B 4-bit` variants; larger or unverified variants stay visible in the UI but remain disabled.

## Model Recommendations

| RAM | Recommended Models |
|-----|-------------------|
| < 8 GB | Whisper Tiny, Whisper Base |
| 8-16 GB | Whisper Small, Whisper Large v3 Turbo, Parakeet TDT v3, Voxtral Mini 4B |
| > 16 GB | Whisper Large v3 |

## Build

1. Clone the repository:
   ```bash
   git clone https://github.com/CarbonoDev/typewhisper-mac.git
   cd typewhisper-mac
   ```

2. Open in Xcode 16+:
   ```bash
   open TypeWhisper.xcodeproj
   ```

3. Select the TypeWhisper scheme and build (Cmd+B). Swift Package dependencies (WhisperKit,
   FluidAudio, Sparkle, TypeWhisperPluginSDK) resolve automatically. Building requires no signing
   setup (ad-hoc signing).

4. Run the app. It appears as a menu bar icon — open it to reach the Meetings window, or open
   Settings to download a model.

5. Run the automated checks before shipping changes:
   ```bash
   xcodebuild test -project TypeWhisper.xcodeproj -scheme TypeWhisper -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO CODE_SIGN_IDENTITY='-' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
   swift test --package-path TypeWhisperPluginSDK
   ```

## HTTP API

The HTTP API is an advanced local automation surface. It binds to `127.0.0.1` only, is disabled by
default, and is intended for local tools and scripts.

Enable the API server in Settings > Advanced (default port: `8978`).

### Check Status

```bash
curl http://localhost:8978/v1/status
```

```json
{
  "status": "ready",
  "engine": "whisper",
  "model": "openai_whisper-large-v3_turbo",
  "supports_streaming": true,
  "supports_translation": true
}
```

### Transcribe Audio

```bash
curl -X POST http://localhost:8978/v1/transcribe \
  -F "file=@recording.wav" \
  -F "language=en"

curl -X POST http://localhost:8978/v1/transcribe \
  -F "file=@recording.wav" \
  -F "language_hint=de" \
  -F "language_hint=en"
```

```json
{
  "text": "Hello, world!",
  "language": "en",
  "duration": 2.5,
  "processing_time": 0.8,
  "engine": "whisper",
  "model": "openai_whisper-large-v3_turbo"
}
```

Optional parameters:
- `language` - ISO 639-1 code (e.g., `en`, `de`). Omit for full auto-detection.
- `language_hint` - Repeatable, ordered language hint for restricted auto-detection. Hint-aware engines receive the full list; other engines use the first hint as the requested language. Do not combine with `language`.
- `task` - `transcribe` (default) or `translate` (translates to English, WhisperKit only).
- `target_language` - ISO 639-1 code for translation target language (e.g., `es`, `fr`). Uses Apple Translate.
- `apply_corrections` - Boolean, default `true`. Set to `false` to return raw transcription text without Dictionary Corrections. For raw body uploads, send `x-apply-corrections: false`.

Uploads to `/v1/transcribe` are limited to 256 MiB, including stdin uploads from the CLI. Requests above that size return `413 Payload Too Large`. Local CLI file paths use a direct handoff to the running TypeWhisper app instead of uploading the file bytes.

### List Models

```bash
curl http://localhost:8978/v1/models
```

```json
{
  "models": [
    {
      "id": "openai_whisper-large-v3_turbo",
      "engine": "whisper",
      "ready": true
    }
  ]
}
```

### History

```bash
# Search history
curl "http://localhost:8978/v1/history?q=meeting&limit=10&offset=0"

# Delete entry
curl -X DELETE "http://localhost:8978/v1/history?id=<uuid>"
```

### Dictionary

```bash
# List recognition terms
curl http://localhost:8978/v1/dictionary/terms

# Merge terms, or set replace=true to replace all terms
curl -X PUT http://localhost:8978/v1/dictionary/terms \
  -H "Content-Type: application/json" \
  -d '{"terms":["TypeWhisper","WhisperKit"],"replace":false}'

# Delete one term
curl -X DELETE http://localhost:8978/v1/dictionary/terms \
  -H "Content-Type: application/json" \
  -d '{"term":"TypeWhisper"}'

# List post-transcription corrections
curl http://localhost:8978/v1/dictionary/corrections

# Add or update one correction by original text
curl -X PUT http://localhost:8978/v1/dictionary/corrections \
  -H "Content-Type: application/json" \
  -d '{"original":"teh","replacement":"the","caseSensitive":false}'

# Delete one correction
curl -X DELETE http://localhost:8978/v1/dictionary/corrections \
  -H "Content-Type: application/json" \
  -d '{"original":"teh"}'
```

### Workflows

```bash
# List all workflow-backed rules
curl http://localhost:8978/v1/rules

# Toggle a workflow-backed rule on/off
curl -X PUT "http://localhost:8978/v1/rules/toggle?id=<uuid>"
```

### Dictation Control

```bash
# Start dictation (returns session id)
curl -X POST http://localhost:8978/v1/dictation/start

# Stop dictation (returns same session id)
curl -X POST http://localhost:8978/v1/dictation/stop

# Check whether dictation is currently recording
curl http://localhost:8978/v1/dictation/status

# Fetch status/result for a specific dictation session
curl "http://localhost:8978/v1/dictation/transcription?id=<uuid>"
```

Dictation control records microphone audio for system-wide insertion. A completed dictation session returns text that TypeWhisper can paste back into the active app.

### Recorder Control

Recorder control uses the same recorder path as the TypeWhisper UI, including microphone capture, optional system audio capture, mixing, finalization, and final transcription. Use it for automations that need a saved recording file or meeting/system-audio transcription without auto-pasting into another app.

```bash
# Start recorder with microphone and system audio
curl -X POST "http://localhost:8978/v1/recorder/start?mic=true&system_audio=true"

# Stop the active API recorder session
curl -X POST http://localhost:8978/v1/recorder/stop

# Check whether the recorder is currently recording
curl http://localhost:8978/v1/recorder/status

# Fetch status/result for a specific recorder session
curl "http://localhost:8978/v1/recorder/session?id=<uuid>"
```

`POST /v1/recorder/start` accepts optional query flags:
- `mic` - `true`, `false`, `1`, or `0`. If omitted, TypeWhisper uses the current recorder microphone setting.
- `system_audio` - `true`, `false`, `1`, or `0`. If omitted, TypeWhisper uses the current recorder system-audio setting.

At least one source must be enabled. If both resolved sources are disabled, the API returns `400 Bad Request`.

Start response:

```json
{
  "id": "8F8C1F45-6D03-44D2-A38C-0C4DE4F7E5F7",
  "status": "recording"
}
```

Stop response:

```json
{
  "id": "8F8C1F45-6D03-44D2-A38C-0C4DE4F7E5F7",
  "status": "finalizing"
}
```

Status response:

```json
{
  "recording": true
}
```

Session response:

```json
{
  "id": "8F8C1F45-6D03-44D2-A38C-0C4DE4F7E5F7",
  "status": "completed",
  "text": "Meeting notes from the recording.",
  "output_file": "/Users/alex/Documents/TypeWhisper Recordings/Recording 2026-05-20 14-30-00.m4a"
}
```

Recorder sessions move through `recording -> finalizing -> completed` or `failed`. If recorder transcription is disabled or produces no transcript, `text` is omitted and `output_file` still points to the finalized recording when available. Failed sessions include an `error` field.

Conflict and lookup behavior:
- Starting while the recorder is already recording or finalizing returns `409 Conflict`.
- Stopping without an active API recorder session returns `409 Conflict`.
- Polling with a missing or invalid `id` returns `400 Bad Request`.
- Polling a valid but unknown session id returns `404 Not Found`.

### Meetings

Import an archive of existing transcripts as meetings and list them. Useful for bulk-importing old
meeting transcripts (optionally driven by an external agent) so they feed prior-meeting briefs.

```bash
# Import a transcript file by local path (direct handoff, no bytes uploaded)
curl -X POST http://localhost:8978/v1/meetings/import-transcript \
  -H "Content-Type: application/json" \
  -d '{"path":"/Users/alex/archive/2026-01-05-sync.txt","date":"2026-01-05","folder":"Clients/Acme","tags":["sales"],"language":"en","match_calendar":true}'

# Import raw transcript text (options via query parameters)
curl -X POST "http://localhost:8978/v1/meetings/import-transcript?title=Kickoff&date=2026-01-05" \
  -H "Content-Type: text/plain" \
  --data-binary @sync.txt

# List meetings with optional filters
curl "http://localhost:8978/v1/meetings?folder=Clients/Acme&tag=sales&from=2026-01-01&to=2026-03-31&limit=50&offset=0"

# Fetch one meeting, optionally including the transcript text
curl "http://localhost:8978/v1/meetings/<uuid>?include=transcript"
```

`POST /v1/meetings/import-transcript` accepts either a JSON body with a `path` (a local transcript
file handed to the app directly) or a `text` field, or a raw text body with options as query
parameters. Optional fields: `title`, `date` (ISO 8601), `folder`, `tags[]`, `language`,
`match_calendar`. Supported transcript formats are `.txt`, `.text`, `.md`, and `.markdown` (Google
Meet exports, `Speaker:` turns, timestamped lines, and plain text).

When `match_calendar` is `true` and a `date` is present, TypeWhisper searches historical calendar
events near that date and, if the best candidate clears a confidence threshold, links the meeting to
it automatically. The response reports the matched event or `null`:

```json
{
  "id": "8F8C1F45-6D03-44D2-A38C-0C4DE4F7E5F7",
  "title": "Acme sync",
  "date": "2026-01-05T10:00:00Z",
  "matched_event": {
    "id": "event-id#1767607200.0",
    "title": "Acme sync",
    "date": "2026-01-05T10:00:00Z",
    "confidence": 0.87
  }
}
```

List rows are compact:

```json
{
  "meetings": [
    {
      "id": "8F8C1F45-6D03-44D2-A38C-0C4DE4F7E5F7",
      "title": "Acme sync",
      "date": "2026-01-05T10:00:00Z",
      "folder": "Clients/Acme",
      "tags": ["sales"],
      "language": "en",
      "has_transcript": true,
      "has_summary": false,
      "calendar_linked": true
    }
  ],
  "total": 1,
  "limit": 50,
  "offset": 0
}
```

Behavior:
- `GET /v1/meetings` filters: `folder` (matches the folder and its subfolders), `tag`, `from`/`to`
  (ISO 8601), `limit` (default 50, max 200), `offset`.
- `GET /v1/meetings/{id}` returns full detail; add `?include=transcript` for the rendered transcript
  text. A missing or invalid id returns `400 Bad Request`; an unknown id returns `404 Not Found`.
- An unsupported/empty transcript or an invalid `date` returns `400 Bad Request`.

## CLI Tool

TypeWhisper includes a command-line tool for shell-friendly transcription and meeting import. It is
part of the advanced automation surface and connects to the running local API server.

### Installation

Install via Settings > Advanced > CLI Tool > Install. This places the `typewhisper` binary in `/usr/local/bin`.

### Commands

```bash
typewhisper status              # Show server status
typewhisper models              # List available models
typewhisper transcribe file.wav # Transcribe an audio file
typewhisper meetings import-transcript notes.txt  # Import a transcript as a meeting
typewhisper meetings list       # List meetings
```

### Options

| Option | Description |
|--------|-------------|
| `--port <N>` | Server port (default: auto-detect) |
| `--json` | Output as JSON |
| `--language <code>` | Source language (e.g. `en`, `de`) |
| `--language-hint <code>` | Repeatable, ordered language hint for restricted auto-detection; engines without hint support use the first hint |
| `--task <task>` | `transcribe` (default) or `translate` |
| `--translate-to <code>` | Target language for translation |
| `--no-corrections` | Return raw transcription text without Dictionary Corrections |

Meeting options for `meetings import-transcript`: `--title`, `--date <iso8601>`, `--folder`,
`--tags a,b,c`, `--language`, `--match-calendar`. Filters for `meetings list`: `--folder`, `--tag`,
`--from <iso8601>`, `--to <iso8601>`.

### Examples

```bash
# Transcribe with language and JSON output
typewhisper transcribe recording.wav --language de --json

# Restrict auto-detection to a shortlist
typewhisper transcribe recording.wav --language-hint de --language-hint en

# Pipe audio from stdin
cat audio.wav | typewhisper transcribe -

# Use in a script
typewhisper transcribe meeting.m4a --json | jq -r '.text'

# Import an old transcript and auto-link a matching calendar event
typewhisper meetings import-transcript 2026-01-05-sync.txt --date 2026-01-05 --match-calendar

# Import into a folder with tags, then list that folder
typewhisper meetings import-transcript call.txt --folder Clients/Acme --tags sales,q1
typewhisper meetings list --folder Clients/Acme --json
```

The CLI requires the API server to be running (Settings > Advanced).

Local file paths are handed to the running TypeWhisper app directly, so large files do not need to
fit inside an HTTP upload body. Stdin usage (`typewhisper transcribe -`) still uses the regular
`/v1/transcribe` upload endpoint and is limited to 256 MiB.

## Plugins

TypeWhisper supports plugins for adding custom LLM providers, transcription engines, TTS providers,
post-processors, and action plugins. Plugins are macOS `.bundle` files placed in
`~/Library/Application Support/TypeWhisper/Plugins/`.

Bundled engines and integrations (WhisperKit, Parakeet, SpeechAnalyzer, Granite, Qwen3, Voxtral,
Supertonic, Groq, OpenAI, xAI/Grok, OpenAI Compatible, Gemini, Linear, Webhook, and more) are
implemented as plugins and serve as reference implementations.

See [TypeWhisperPluginSDK/Plugins/README.md](TypeWhisperPluginSDK/Plugins/README.md) for the full
plugin development guide, including the event bus, host services API, and manifest format.

## Architecture

```
TypeWhisper/
├── typewhisper-cli/           # Command-line tool (status, models, transcribe, meetings)
├── PluginRegistry/            # Source registry entries for community plugin feeds
├── TypeWhisperPluginSDK/      # Plugin SDK + first-party plugin sources (Swift package)
├── TypeWhisperWidgetExtension/ # WidgetKit widgets (stats, activity, history)
├── App/                       # App entry point, ServiceContainer dependency injection
├── Models/                    # Data models (TranscriptionResult, Meeting, MeetingTemplate, ...)
├── Services/
│   ├── Meetings/              # MeetingService, MeetingCaptureService, CalendarService,
│   │                          #   MeetingBriefService, MeetingLLMService, MeetingModelRouter,
│   │                          #   MeetingImportService, ObsidianVaultService, VaultNoteWriter,
│   │                          #   MeetingObsidianExporter, ParticipantDirectoryService,
│   │                          #   MeetingRelatedDocsService, MeetingJob (job queue), ...
│   ├── DiarizationProvider / PyannoteDiarizationProvider / LocalDiarizationService
│   ├── HTTPServer/            # Local REST API (HTTPServer, APIRouter, APIHandlers)
│   ├── ModelManagerService    # Transcription dispatch (delegates to plugins)
│   ├── HotkeyService / AudioRecordingService / TextInsertionService
│   ├── WorkflowService / HistoryService / DictionaryService / SnippetService
│   ├── PluginManager / PluginRegistryService / PostProcessingPipeline / EventBus
│   └── TranslationService / SubtitleExporter / SoundService
├── ViewModels/                # MVVM view models with Combine (incl. MeetingsViewModel+*)
├── Views/
│   ├── MainWindow/            # Meetings-first main window, sidebar, routes
│   ├── Meetings/              # Meeting document, brief, Q&A, import, speaker mapping, ...
│   └── Space/                 # Obsidian vault browser + quick notes
├── Resources/                 # Info.plist, entitlements, localization, sounds
└── diarize_sidecar.py         # pyannote diarization sidecar (copied into app resources at build)
```

**Patterns:** MVVM with `ServiceContainer` singleton for dependency injection. ViewModels use a
static `_shared` pattern. Localization via `String(localized:)` with `Localizable.xcstrings`.

## License

GPLv3 - see [LICENSE](LICENSE) for details. This fork removes upstream's paid feature-gates in code
but leaves the inherited [LICENSE-COMMERCIAL.md](LICENSE-COMMERCIAL.md) and [TRADEMARK.md](TRADEMARK.md)
in place. See [A note on this fork](#a-note-on-this-fork).
