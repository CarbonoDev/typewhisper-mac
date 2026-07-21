# TypeWhisper Meet Bridge

A Chrome MV3 extension that reads Google Meet's live captions and streams them into the TypeWhisper
meetings app as **speaker-attributed transcript segments**.

## Why captions

Meet's caption DOM carries the speaker's *display name* alongside each turn, live, at no cost. That
makes it a free realtime diarizer that returns real names — something neither local pyannote
(`SPEAKER_00`) nor a paid cloud provider (`Speaker A`) gives you:

| Source | Cost | Latency | Labels |
| --- | --- | --- | --- |
| Local pyannote | CPU, offline pass | post-meeting | `SPEAKER_00` |
| Cloud provider labels | per-minute billing | post-meeting | `Speaker A` |
| **Meet captions** | free | realtime | **real names** |

Segments arrive already labeled, so `SpeakerSourcePlan` resolves to its `.cloud` rung
(`isProviderOriginatedLabel` accepts any non-empty, non-`SPEAKER_`-prefixed label) and local
diarization is skipped entirely. No change to the ladder was needed.

## Install

1. TypeWhisper → Settings → enable the **local API** (default `http://127.0.0.1:8978`). Note the
   API token if you set one.
2. `chrome://extensions` → enable **Developer mode** → **Load unpacked** → select this directory.
3. Open the extension's options and set the API URL and token, then hit **Test connection**.
4. Join a Meet call and **turn captions on** (the CC button). Nothing is captured without them.

The extension only ever talks to a loopback address; `config.js` hard-rejects any other host.

## How it works

```
Meet DOM ──▶ content.js ──port──▶ background.js ──HTTP──▶ TypeWhisper
           (observe only)      (all networking)
```

- **`selectors.js`** — DOM discovery ladder: `jsname` attributes → localized `aria-label` regions →
  legacy class names → a structural heuristic. Meet's class names rotate, so no single rung is
  load-bearing. When every rung fails, `describeCandidates()` dumps the caption-shaped subtrees to
  the console so the ladder can be repaired from one real call. **This is the file that needs
  editing when Meet changes.**
- **`stabilizer.js`** — Meet captions are a rolling revision buffer, not finished lines: text grows,
  the tail gets rewritten, blocks get evicted. The stabilizer exploits the fact that revisions only
  touch the tail — it emits a settled *prefix* once enough text accumulates (never cutting inside a
  ~90-character guard, preferring sentence boundaries), and finalizes a block when it goes idle or
  leaves the DOM. Covered by `test/stabilizer.test.js`.
- **`content.js`** — observation and port lifetime only. It does no fetching: a content script runs
  in the page's origin and would be CORS-blocked, and it would also expose the API token to the page.
- **`background.js`** — all networking. The meeting id and unsent buffer are mirrored to
  `chrome.storage.local` on every change, because MV3 evicts the worker aggressively. On wake it
  re-posts the same `session_key` and the app returns the same meeting.

## API surface it uses

| Endpoint | Purpose |
| --- | --- |
| `POST /v1/meetings/live` | Create or resume the meeting for a call. Idempotent on `session_key` (the Meet call code). |
| `POST /v1/meetings/live/{id}/segments` | Append a batch of caption turns. |
| `POST /v1/meetings/live/{id}/end` | Close the session. Deliberately does **not** trigger summarization. |

Segments are stored with source `.liveCaptions`, kept distinct from `.liveCapture` so a later
re-transcription of your own audio can never delete the caption-derived speaker timeline.

## Tests

```bash
node --test chrome-extension/test/stabilizer.test.js
```

## Known limits

- **Captions must be on.** Meet resets this per call. The extension detects their absence and logs a
  notice rather than clicking the CC button for you (the button's label is localized and clicking
  blind is fragile).
- **Single language.** Meet locks captions to one selected language; multilingual meetings lose
  labels on the off-language stretches.
- **Overlapping speech collapses** to a single speaker — pyannote is genuinely better at crosstalk.
- **Display name only.** Captions carry no email. Matching names to `PersonIdentity` via the calendar
  event's attendees is not wired up yet.
- **Timestamps are estimates.** Captions trail speech by ~1–2s (`captionLagMs`, default 1200). This
  is fine because downstream speaker transfer is text-anchored, not time-anchored.

## Consent

Transcribing a call other people are on is a consent question before it is a technical one. Meet
shows participants an indicator for its *own* transcription but not for extension-side caption
reading. Two-party-consent jurisdictions require everyone's agreement. Tell the room.
