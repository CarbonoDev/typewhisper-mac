# TypeWhisper Meet Bridge

A Chrome MV3 extension that reads Google Meet's live captions and streams them into the TypeWhisper
meetings app as **speaker-attributed transcript segments**. It also lets the app show a **floating
mute button** for the call on your Mac (see [Call controls](#call-controls)).

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
4. Open the extension's options (they show this copy's ID), set the API URL, paste the token, and
   hit **Test connection** — it posts as the extension does, so it reports a missing allowlist
   entry or a wrong token rather than a false "connected".
5. Join a Meet call. Captions are required for capture; by default the extension **turns them on
   for you** at call start (see Options below).

Steps 3 and 4 are not optional. Every extension in the browser shares the `chrome-extension://`
scheme, so the app trusts an *identity*, not a scheme: a request from an unlisted extension is
refused with `403`, and a listed one must present the API token on every call — the "Require API
Token" toggle governs loopback tools (CLI, Raycast) only and never exempts browser code. Getting
either wrong shows up as `403`/`401` in the extension's console.

The extension only ever talks to a loopback address; `config.js` hard-rejects any other host.

## Which version is running

Chrome runs the extension from whatever folder it was loaded from, and **Reload** re-reads that
folder — so reloading after a change made in another checkout or worktree runs the old code again.
To make that visible, the bridge carries a version and says it everywhere:

- the popup and the options page show `Meet Bridge v<version>`;
- the first `[tw-meet]` line in a Meet tab's console names the build running in that tab, and the
  popup's **Copy diagnostics** text starts with it;
- the app shows the connected version under Settings → Advanced → API Server, and flags a bridge
  that is older than the one the app was built with (or one so old it does not report a version).

`chrome://extensions` → **Details** shows the folder the extension is loaded from ("Source").

A Meet tab that was already open when the extension was (re)loaded keeps running the *old* content
script — or none at all. The popup says so ("Nothing from Meet Bridge in this tab … reload the
tab") instead of staying blank.

## What it is doing — the popup

Click the toolbar icon on a Meet tab. The popup reads the status that tab's content script reports
(no DevTools needed) and says, in plain words:

- **what is happening** — "Not on a call page", "Waiting in the lobby — not joined yet", "On a Meet
  call page, but not detected as in the call", "In the call — creating the meeting in the app…",
  "In the call, but the app has not taken the meeting", or "In the call — meeting linked in the app";
- **why** — which in-call signal matched (or, when none did, every signal it looked for and what it
  found: "leave button not found (labels tried: …); no hang-up icon; no caption region; mic toggle
  not readable"), whether captions are being read and how many segments went out, whether the mic
  toggle is readable (the floating mute button depends on it), what is queued, and whether the app
  answered lately (or the last error it gave).

**Copy diagnostics** puts that status, the worker's view of the session and the app, and the last
100 `[tw]` / `[tw-meet]` log lines on the clipboard — paste it into a bug report. Log lines are
written on state *transitions* only (entered the call page, in-call signal matched/lost and by which
rung, session started/ended, meeting created/resumed, app unreachable/back, caption region
found/lost, mic toggle readable/unreadable), so 100 lines cover a lot of history. Caption text is
never copied: the per-segment lines stay in the tab's own console. The diagnostics do include the
call code and the in-page diagnostic dumps, which can name participants.

The status and the log ring buffer live in `chrome.storage.session` — per browser session, never
synced — so they survive the worker's evictions but not a browser restart.

**Every change to the extension bumps `version` in `manifest.json`**, together with
`MeetBridgeVersion.shipped` in the app (a unit test fails when the two differ, and
`scripts/pr-preflight.sh` fails when `chrome-extension/` changed without a bump).

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

- **Let TypeWhisper mute and unmute me** (default on) — reports whether your own microphone and
  camera are on and lets the app click those two toggles. Off means no state leaves the page and no
  command is honored; the floating button disappears.
- **Join with the microphone off** / **Join with the camera off** (both default on) — on Meet's
  joining screen ("Ready to join?" / "¿Todo listo para unirte?") the extension turns your mic and
  camera off once, so you walk into the call muted. Turning one back on there is respected: it is
  never clicked again on that visit, and nothing is touched once you are in the call.

## Call controls

While you are in a call that the app counts as a meeting (someone else is there — the same rule as
its presence API), the app shows a small floating button on your Mac — red when your
microphone is muted, green when it is live — above every app and every Space, not just inside the
browser. Click it to toggle the microphone; hover for the camera toggle and a "return to call"
button that brings the Meet tab back to the front; drag it anywhere (the position is remembered,
relative to the screen). Under Settings → Advanced → API Server the app also offers a **size**
(automatic makes it larger on an iPad used as a Sidecar display) and **follow the active screen**,
which keeps it on whichever display you are working on. Turn it off there with **Floating call
controls for Google Meet**, or here with the option above.

Meet has no API for this, so the extension reads the state from Meet's own mic/camera buttons
(their `data-is-muted` attribute) and clicks those same buttons. The app cannot push to an
extension, so commands travel as the answer to a **long-poll**: the worker keeps one request to the
app open for the life of the call, the app answers it the moment you click, and the worker asks
again. Commands name a target state ("microphone: muted") rather than "toggle", so one that arrives
late or twice never flips the wrong way.

## How it works

```
Meet DOM ──▶ content.js ──port──▶ background.js ──HTTP──▶ TypeWhisper
           (observe only)      (all networking)
```

- **`selectors.js`** — DOM discovery ladder: `jsname` attributes → localized `aria-label` regions →
  legacy class names → a structural heuristic. Meet's class names rotate, so no single rung is
  load-bearing. When every rung fails, `describeCandidates()` dumps the caption-shaped subtrees to
  the console so the ladder can be repaired from one real call. **This is the file that needs
  editing when Meet changes.** Once a region is found, `findTurnBlocks()` locates the level whose
  children are the speaker turns: Meet can nest them inside a scroll wrapper, and a wrapper read
  as a turn attributes the whole call to whoever spoke first. The console line
  `reading N caption turn(s), D level(s) below the caption region` says what it settled on.
- **`stabilizer.js`** — Meet captions are a rolling revision buffer, not finished lines: text grows,
  the tail gets rewritten, blocks get evicted. The stabilizer exploits the fact that revisions only
  touch the tail — it emits a settled *prefix* once enough text accumulates (never cutting inside a
  ~90-character guard, preferring sentence boundaries), and finalizes a block when it goes idle or
  leaves the DOM. Covered by `test/stabilizer.test.js`.
- **`content.js`** — observation, port lifetime, two bounded pieces of UI automation (the
  captions auto-enable click and the one-shot language steering, both fail-soft), and the call
  controls: it reports mic/camera state on change and clicks those toggles on command. It does no
  fetching: a content script runs in the page's origin and would be CORS-blocked, and it would also
  expose the API token to the page.
- **`presence.js`** — the "are we in the call yet" ladder. The lobby ("Ready to join?") and the knock
  screen share the call's URL path, so a session — and the app's meeting — starts only on an in-call
  signal, and **any one** of these is enough:
  1. the leave button by its localized label ("Leave call", "Leave meeting", "Salir de la llamada",
     "Abandonar la llamada", "Salir de la reunión", …);
  2. a caption container found by a precise selector, or 3. a captions *region* found by label;
  4. the leave button by Meet's `jsname`; 5. a button carrying the `call_end` hang-up icon ligature
     (locale-free); 6. two or more of the call's side-panel buttons (details / people / chat /
     activities); 7. the user's own mic toggle with a readable `data-is-muted`.

  Rungs 4–7 are **vetoed while any lobby tell is visible**: a join button by text, label or
  `jsname` ("Join now", "Ask to join", "Unirse ahora", "Pedir unirse", …) or a lobby/knock/"you left"
  text ("Ready to join?", "Asking to be let in"). That veto matters because the mic and camera
  toggles exist in the lobby too — counting them there is how pre-join junk meetings used to be
  created. The signal must also hold for two ticks before a session starts. The session starts at
  join **whether or not captions are on**: the meeting, the heartbeat (presence) and the mic/camera
  report (the floating mute button) all work without captions; captions only add the transcript.
  A meeting the app could not create at join (app closed) is retried every few seconds, with
  backoff, while the tab is connected — not only when a caption needs delivering.
- **`lobby.js`** — join muted. While a lobby tell is visible, the in-call ladder says not joined and
  no session exists, it reads the user's own mic and camera toggles (`findCallControl`) and clicks
  each one that reads live **once per lobby visit** — a visit is the call code, re-armed when the
  code changes or when the lobby shows again after a session ended — then re-reads it after the
  same 150 ms settle the call controls use. A toggle already off is left alone; one that stays
  missing, unreadable or disabled for 10 ticks is given up on with one `lobby:` diagnostic line.
  What it did lands in the status (`lobbyMuted`) and the popup's lobby headline ("Microphone and
  camera turned off for you."). Covered by `test/lobby.test.js`.
- **`status.js`** — the content script's status object and its transition log; the worker stores
  each tab's status for the popup (`diagnostics.js`).
- **Noise filtering** — a heuristic-found caption root must *mutate* between two ticks before it is
  trusted.
  Block-level filters then drop UI chrome by its locale-independent tells: Material icon ligature
  text (`more_vert`, `frame_person`), keyboard-shortcut parentheticals ("(⌘ + d)"), emails in the
  speaker slot, and tiles that echo a participant's name. Covered by `test/selectors.test.js`.
- **`background.js`** — all networking. The meeting id and unsent buffer are mirrored to
  `chrome.storage.local` on every change, because MV3 evicts the worker aggressively. On wake it
  re-posts the same `session_key` and the app returns the same meeting. It also runs the call's
  command long-poll (one loop per call, in memory only) and hands each command to the page.

## API surface it uses

| Endpoint | Purpose |
| --- | --- |
| `POST /v1/meetings/live` | Create or resume the meeting for a call. Idempotent on `session_key` (the Meet call code). |
| `POST /v1/meetings/live/{id}/segments` | Append a batch of caption turns. |
| `POST /v1/meetings/live/{id}/end` | Close the session. Deliberately does **not** trigger summarization. |
| `POST /v1/meetings/live/{id}/heartbeat` | Keep-alive, once a minute while someone else is in the call. Body: `{"participants": 3}` (omitted when the head count cannot be read). |
| `POST /v1/meetings/live/{id}/controls` | Your mic/camera state changed. Body: `{"mic_muted": true, "camera_off": false}` (`camera_off` omitted when unreadable; an empty body withdraws the call from control). |
| `POST /v1/meetings/live/{id}/commands/poll` | Long-poll for the floating controls' commands. Body: `{"wait_seconds": 20, "mic_muted": …, "camera_off": …}`; answers `{"commands": [{"id": "…", "action": "set_mic", "muted": true}]}` — actions `set_mic`, `set_camera`, `focus` — or an empty list when the wait runs out. |
| `POST /v1/bridge/hello` | Says which build this is, on every connect and from **Test connection**. Body: `{"version": "0.3.0"}`; answers `{"expected_version": "…"}`, the version the app ships with. |

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

Covered: the stabilizer's revision/reset rules, the DOM-discovery ladder and the in-call ladder (over
a small fake `document`, `test/fake-dom.js`) including the mic/camera toggles and the lobby veto, the
language matcher, the status tracker's transition log, the popup's plain-words rendering and the
diagnostics ring buffer, and the service worker's queueing rules — buffering, retry backoff, the
retried `/end`, the call-control report and poll, and a call joined with captions off creating its
meeting and sending heartbeats and controls — over a fake `chrome.storage`.

## Known limits

- **The call page is recognised by its URL.** A call lives at `meet.google.com/abc-defg-hij` or,
  in the newer Meet UI, at `meet.google.com/meet/abc-defg-hij`; both are the same call. Any other
  path (`/landing`, `/new`, a `/meet/` page without a code) is "Not on a call page".
- **In-call detection is DOM-reading.** No single signal is load-bearing, but every one of them is
  Meet's markup. If Meet changes all of them at once the bridge does nothing — and the popup says
  so, listing what it looked for. The leave-button and join-button `jsname`s are best-known values,
  not verified against today's Meet. In a UI locale none of the lobby lists covers, the mic-toggle
  rung could fire in the lobby; the two-tick hold narrows that, and a join-button `jsname` match
  vetoes it in any language.
- **Captions must be on for a transcript** (not for the meeting itself). Meet resets this per call. Auto-enable (on by default) clicks the CC
  button for you, but it depends on the localized `aria-label` ladder finding the button — in an
  unlisted UI locale it logs a notice instead and you turn captions on by hand.
- **Single language.** Meet locks captions to one selected language; multilingual meetings lose
  labels on the off-language stretches. The caption-language option steers which single language
  that is (one best-effort attempt per call), but cannot make captions bilingual.
- **Overlapping speech collapses** to a single speaker — pyannote is genuinely better at crosstalk.
- **Display name only.** Captions carry no email. Matching names to `PersonIdentity` via the calendar
  event's attendees is not wired up yet.
- **Call controls depend on Meet's toolbar.** The mic/camera toggles are found by `jsname`, then by
  localized label, then by their keyboard-shortcut hint, and their state is read from
  `data-is-muted`. When none of that matches, the floating button simply never appears and the
  console gets a `[tw-meet]` dump of the candidate controls to repair `CALL_CONTROLS` from. With
  two calls open, the button follows the one joined last.
- **Joining muted depends on recognising the lobby.** The lobby tells (join button, "Ready to
  join?" text) are DOM-reading, like the rest of the presence ladder. In a UI locale none of the
  lobby lists covers — and without a join-button `jsname` match — the lobby is not recognised and
  nothing is clicked: you join with whatever Meet had on. After a call ends, a long wait on the
  "you left" screen can use up the 10-tick budget before a rejoin, so that rejoin is not muted.
- **Timestamps are estimates.** Captions trail speech by ~1–2s (`captionLagMs`, default 1200). This
  is fine because downstream speaker transfer is text-anchored, not time-anchored.

## Consent

Transcribing a call other people are on is a consent question before it is a technical one. Meet
shows participants an indicator for its *own* transcription but not for extension-side caption
reading. Two-party-consent jurisdictions require everyone's agreement. Tell the room.
