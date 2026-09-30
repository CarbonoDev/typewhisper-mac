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

1. TypeWhisper → Settings → Advanced → enable the **local API** (default `http://127.0.0.1:8978`).
2. `chrome://extensions` → enable **Developer mode** → **Load unpacked** → select this directory.
   Copy the **extension ID** Chrome shows under the loaded extension.
3. Back in Settings → Advanced → API Server → **Allowed Browser Extensions**: paste that ID, then
   press **Copy API Token**.
4. Open the extension's options, set the API URL, paste the token, and hit **Test connection**.
5. Join a Meet call. Captions are required for capture; by default the extension **turns them on
   for you** at call start (see Options below).

Steps 3 and 4 are not optional. Every extension in the browser shares the `chrome-extension://`
scheme, so the app trusts an *identity*, not a scheme: a request from an unlisted extension is
refused with `403`, and a listed one must present the API token on every call — the "Require API
Token" toggle governs loopback tools (CLI, Raycast) only and never exempts browser code. Getting
either wrong shows up as `403`/`401` in the extension's console.

The extension only ever talks to a loopback address; `config.js` hard-rejects any other host.

## Options

- **Capture captions on Google Meet** — master switch; off means nothing is observed or sent.
- **Turn on captions automatically when a call starts** (default on) — Meet makes captions per-call
  opt-in, so the extension clicks the CC button for you when a session starts without them. Strictly
  bounded: at most 3 attempts, ~5 s apart, only within the first ~30 s of the call — turning
  captions off yourself mid-call is never fought.
- **Hide Meet's caption overlay** (default on) — visually hides the caption band while still reading
  it. Implemented as `opacity: 0` + `pointer-events: none`, deliberately **not** `display: none` or
  `visibility: hidden`: for non-rendered elements `innerText` falls back to `textContent`, which
  loses the line structure the speaker/text parser depends on — captions would keep flowing while
  silently mis-attributing turns.
- **Caption language** (default "Leave as Meet has it") — for calls in mixed English/Spanish
  households: one **best-effort** attempt per call to steer Meet's caption-language picker to
  English or Spanish after captions come on. This is speculative DOM automation (open the
  caption-settings control, click the matching option, press Escape); when any step misses, it logs
  a `[tw-meet]` diagnostic dump of the picker's candidate options — like the caption ladder, it is
  designed to be repaired in `selectors.js` from one real call's console output — and gives up
  without touching capture.

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
- **`content.js`** — observation, port lifetime, and two bounded pieces of UI automation (the
  captions auto-enable click and the one-shot language steering, both fail-soft). It does no
  fetching: a content script runs in the page's origin and would be CORS-blocked, and it would also
  expose the API token to the page.
- **Noise filtering** — the lobby ("Ready to join?") shares the call's URL path, so capture waits for
  an in-call signal (the leave-call button, or a caption region found by a precise selector rung); a
  heuristic-found caption root must additionally *mutate* between two ticks before it is trusted.
  Block-level filters then drop UI chrome by its locale-independent tells: Material icon ligature
  text (`more_vert`, `frame_person`), keyboard-shortcut parentheticals ("(⌘ + d)"), emails in the
  speaker slot, and tiles that echo a participant's name. Covered by `test/selectors.test.js`.
- **`background.js`** — all networking. The meeting id and unsent buffer are mirrored to
  `chrome.storage.local` on every change, because MV3 evicts the worker aggressively. On wake it
  re-posts the same `session_key` and the app returns the same meeting.

## API surface it uses

| Endpoint | Purpose |
| --- | --- |
| `POST /v1/meetings/live` | Create or resume the meeting for a call. Idempotent on `session_key` (the Meet call code). |
| `POST /v1/meetings/live/{id}/segments` | Append a batch of caption turns. |
| `POST /v1/meetings/live/{id}/end` | Close the session. Deliberately does **not** trigger summarization. |
| `POST /v1/meetings/live/{id}/heartbeat` | Keep-alive, once a minute while someone else is in the call. Body: `{"participants": 3}` (omitted when the head count cannot be read). |

The heartbeat exists for the app's presence API (`GET /v1/meetings/now`): a caption session only
counts as "in a meeting" while the app has heard from it in the last five minutes — a caption batch
or a heartbeat. That is what carries a quiet call, and what lets the app notice a call whose `/end`
never arrived. No heartbeat is sent while you are alone in the room, so a Meet tab left open after
everyone has gone stops counting. The head count comes from the participant tiles
(`data-participant-id`), so in a large call it is a lower bound.

On create, the app tries to **match the call to a calendar event by title** (same scoring as import's
`match_calendar`): a calendar-created Meet call carries the event's name as the tab title, so a
confident title+date match links the meeting to the event and adopts its roster. When the tab title
is just the call code (an ad-hoc call), no match is attempted and the meeting is named from the
start time and the Google account the call was joined from (sent as `account`, read from the
account button's aria-label) — e.g. `Meet – Jan 5, 2026, 10:01 (marco@example.com)`.

Segments are stored with source `.liveCaptions`, kept distinct from `.liveCapture` so a later
re-transcription of your own audio can never delete the caption-derived speaker timeline.

## Tests

```bash
node --test chrome-extension/test/*.test.js
```

Covered: the stabilizer's revision/reset rules, the DOM-discovery ladder (over a small fake
`document` installed by the test), the language matcher, and the service worker's queueing rules —
buffering, retry backoff, and the retried `/end` — over a fake `chrome.storage`.

## Known limits

- **Captions must be on.** Meet resets this per call. Auto-enable (on by default) clicks the CC
  button for you, but it depends on the localized `aria-label` ladder finding the button — in an
  unlisted UI locale it logs a notice instead and you turn captions on by hand.
- **Single language.** Meet locks captions to one selected language; multilingual meetings lose
  labels on the off-language stretches. The caption-language option steers which single language
  that is (one best-effort attempt per call), but cannot make captions bilingual.
- **Overlapping speech collapses** to a single speaker — pyannote is genuinely better at crosstalk.
- **Display name only.** Captions carry no email. Matching names to `PersonIdentity` via the calendar
  event's attendees is not wired up yet.
- **Timestamps are estimates.** Captions trail speech by ~1–2s (`captionLagMs`, default 1200). This
  is fine because downstream speaker transfer is text-anchored, not time-anchored.

## Consent

Transcribing a call other people are on is a consent question before it is a technical one. Meet
shows participants an indicator for its *own* transcription but not for extension-side caption
reading. Two-party-consent jurisdictions require everyone's agreement. Tell the room.
