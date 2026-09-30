# Meeting presence for local clients — API proposal

Status: **Built (2026-09-30), not yet exercised against a real call.** Answers the
`local-habit-tracker` request in `WORKBENCH.md`. The decisions in §6 are settled; this is the
contract the tracker's side builds against.

## 1. What the app can and cannot know

The app is a recorder, not a conferencing client. It knows a meeting is in progress in exactly two
cases:

| Case | How it starts | Covers listen-only? |
| --- | --- | --- |
| **Local capture** | The user presses record (menu bar / meeting page); mic + system audio are recorded as separate tracks. | Yes, as long as the user is recording. |
| **Meet caption bridge** | The Chrome extension sees the user in a Google Meet call and opens a live session (`POST /v1/meetings/live`). | Yes — no microphone involved. Google Meet in Chrome only. |

A Zoom or Teams call the user joins **without recording it** is invisible to the app. For that case
the tracker's existing microphone check remains the only signal, so keep it as the fallback rather
than replacing it.

## 2. What already exists

- **Transport**: HTTP on `127.0.0.1` only (the listener is bound to IPv4 loopback). **Off by
  default** — Settings › Advanced › API Server. Each request is one connection (no keep-alive).
- **Port**: `8978` by default, user-configurable.
- **Discovery**: while the server runs, the app writes
  `~/Library/Application Support/MeetingWhisper/api-discovery.json` (`{"port": 8978, "token": "…"}`,
  mode `0600`) and removes it when the server stops. Dev builds use `MeetingWhisper-Dev/`. The
  bundled CLI discovers the API the same way.
- **Auth**: `Authorization: Bearer <token>` or `X-TypeWhisper-API-Token: <token>`. The token is
  only *enforced* for plain local callers when "Require API Token" is on (off by default);
  `GET /v1/status` is always public. Browser-extension origins must be allowlisted and always need
  the token. Web pages get no CORS headers. There is no `Host` header check today.
- **Conventions**: `/v1/…` paths, snake_case JSON, dates as ISO 8601 in UTC (`2026-09-30T16:00:00Z`),
  errors as `{"error": {"code": "not_found", "message": "…"}}`.
- **Meeting endpoints today**: `GET /v1/meetings?from=&to=&limit=&offset=` and
  `GET /v1/meetings/{id}`. They could technically answer "recent meetings", but the list row always
  carries the **title** and has no state or end time, and the detail carries **attendee names and
  emails**. That is exactly the content the tracker said it does not want to hold, so neither is a
  fit. Two new read-only endpoints are warranted.

## 3. Endpoints

### `GET /v1/meetings/now`

Reads in-memory state only (the capture service's published state and the already-loaded meeting
list); no store fetch, no side effects. Fine at a 2–5 s poll.

```json
{
  "schema": 1,
  "in_meeting": true,
  "meeting_id": "6F1C2B7E-3A55-4D0B-9C0E-2E1B7C0A9D11",
  "started_at": "2026-09-30T16:00:00Z",
  "detected_by": "capture",
  "platform": "meet",
  "participants": 4,
  "scheduled": true,
  "recurring": true,
  "speaking": false,
  "seconds_since_spoke": 212,
  "calendar_event_now": true
}
```

No meeting: `{"schema": 1, "in_meeting": false, "calendar_event_now": false}`.

| Field | When present | Source in the app |
| --- | --- | --- |
| `schema` | always | Constant `1`. |
| `in_meeting` | always | A local capture is running, or a caption-bridge meeting is `live` and was heard from in the last 5 minutes (§6.2). |
| `meeting_id` | in a meeting | `Meeting.id` (UUID). Same id as `/v1/meetings/{id}`. |
| `started_at` | in a meeting | `Meeting.startDate`. For local capture this is when **recording** started, not when the call was joined. |
| `detected_by` | in a meeting | `"capture"` or `"captions"` — tells the tracker which fields to expect. |
| `platform` | when known | `meet` for caption sessions; otherwise from the linked calendar event's join URL host: `meet`, `zoom`, `teams`, `webex`. Omitted for an ad-hoc recording with no calendar link. |
| `participants` | when known | For a caption session, the extension's count of people actually in the call (a lower bound in a large call). Otherwise the attendee count from the calendar event (*invited*, not *present*), or `2` when the meeting is flagged as a two-person call. Omitted otherwise. |
| `scheduled` | in a meeting | Linked to a calendar event or not. |
| `recurring` | when scheduled | The event belongs to a series. |
| `speaking` | `detected_by: capture` only | New: microphone level above a threshold, with a short hangover. See §4. |
| `seconds_since_spoke` | `detected_by: capture` only | New, from the same tracker. Omitted until the user has spoken once. |
| `calendar_event_now` | always | A timed calendar event with a join link is running right now. A weak hint, independent of `in_meeting`: it says a meeting is *scheduled*, not that the user joined it. |

### `GET /v1/meetings/sessions?since=<ISO 8601>[&until=<ISO 8601>][&limit=<n>]`

Named `sessions` because `/v1/history` is already the dictation history. `since` is required;
a meeting is returned when it overlaps the window, ordered by `started_at`, `limit` default 100 and
max 200. Only meetings the user was in are listed: ones the app recorded, and caption-bridge
sessions. Imported files, Drive transcripts, and scheduled meetings that never started are excluded.

```json
{
  "schema": 1,
  "sessions": [
    {
      "meeting_id": "6F1C2B7E-3A55-4D0B-9C0E-2E1B7C0A9D11",
      "started_at": "2026-09-30T16:00:00Z",
      "ended_at": "2026-09-30T16:45:12Z",
      "detected_by": "capture",
      "platform": "meet",
      "participants": 4,
      "scheduled": true,
      "recurring": true,
      "speaking_seconds": 310
    }
  ]
}
```

`ended_at` is `null` while the meeting is in progress. A caption session whose end message never
arrived is reported as ended at its last caption. `speaking_seconds` is present only when the app
knows which speaker is the user (§4).

### `POST /v1/meetings/live/{id}/heartbeat` (caption bridge only)

Body `{"participants": 3}`, or `{}` when the extension cannot read a head count. Sent once a minute
while someone else is in the call; see §6.2.

## 4. Speaking vs listening — what is real and what is not

- **Live, during local capture**: the recorder already measures microphone and system-audio levels
  separately. A small tracker on top of those gives `speaking` and `seconds_since_spoke`. It does
  not exist yet; it is the only genuinely new logic in this proposal. Known weakness: without
  headphones the mic hears the other participants, so the rule has to be "mic clearly louder than
  system audio", and it will still be wrong sometimes.
- **Live, caption sessions**: captions arrive batched and seconds late, and the extension does not
  mark which speaker is the user. No `speaking` field in v1.
- **After the meeting**: `speaking_seconds` is summed from transcript segments attributed to the
  user. That attribution exists for two-person calls recorded locally (the mic channel is the user)
  and for meetings where a speaker was mapped to the attendee marked as self. For everything else
  the field is omitted.

## 5. Dropped or changed from the request

- **`camera_on`, `screen_sharing`**: dropped. The app has no such signal. The Meet extension could
  read both from the call toolbar later, for Meet only — a separate piece of work.
- **`title`**: dropped, not nulled. A client that wants it can call `GET /v1/meetings/{id}` with the
  same id; the presence endpoints stay content-free by construction.
- **`speaking_segments`**: dropped from v1. Live-transcript segment times are coarse until a final
  re-transcription has run, so the intervals would look more precise than they are.
- **Paths**: `/v1/meetings/now` and `/v1/meetings/sessions` instead of `/meeting/now` and
  `/meeting/history`, to match the existing API.
- **Timestamps**: UTC with `Z`, as everywhere else in this API, rather than a local offset.
- **`meeting_id` stability**: stable for the life of the meeting, with one caveat — if the user
  later merges two meetings, the absorbed one's id disappears from `sessions`. The tracker should
  treat an unknown id as "meeting no longer exists", not as an error.

## 6. Decisions

1. **Auth.** `GET /v1/meetings/now` and `GET /v1/meetings/sessions` always require the token, even
   when "Require API Token" is off — the same stance the router already takes for browser
   extensions. The tracker reads `api-discovery.json` and sends `Authorization: Bearer <token>`.
   The router gained a per-route `requiresToken` flag for this; no `Host` header check was added.
2. **Stale caption sessions.** A caption session counts as in progress only if the app heard from
   it in the last **5 minutes** — a caption batch or a heartbeat. The extension sends a heartbeat
   every minute while the call is open **and more than one person is in it**; alone in the room it
   sends none, so a Meet tab left open after everyone has gone stops counting within 5 minutes.
   When the extension cannot read the head count it still sends the heartbeat (the call is open;
   a broken probe must not end it). The last-heard-from times live in memory only: after an app
   relaunch a running call re-registers on its next heartbeat or caption, within a minute.
3. **The API is off by default.** The tracker only works once the user has enabled the API server
   (Settings › Advanced › API Server). Its setup should say so.
4. **Calendar as a third signal.** Exposed as `calendar_event_now` on `/v1/meetings/now`.

## 7. Where it lives

- `Services/Meetings/MeetingPresence.swift` — the pure logic: response types, the projector, the
  speaking tracker, the caption-session liveness registry. Covered by `MeetingPresenceTests`.
- `Services/Meetings/MeetingPresenceService.swift` — main-actor glue over the capture service, the
  meeting list, the recorder's level meters and the calendar. Writes to no store.
- `Services/HTTPServer/APIHandlers+MeetingPresence.swift` — the three routes. `APIRouter` carries the
  `requiresToken` flag (`APIRouterRequiredTokenTests`).
- `chrome-extension/` — `readParticipantCount()` in `selectors.js`, the heartbeat in `content.js`
  and `background.js`.

## 8. Not yet verified

- **The participant count against a live Meet call.** It counts distinct `data-participant-id`
  tiles, which is how Meet has marked tiles for a long time, but it has only been tested against a
  fake DOM. If the probe finds nothing, heartbeats are still sent (without a count), so the
  failure mode is "a tab left open alone keeps counting", not "meetings go missing".
- **The speaking thresholds** (`SpeakingActivityTracker`): mic level ≥ 0.06 and at least half the
  system-audio level, with a 3 s hangover. Reasoned from how the recorder scales its levels, not
  tuned on recordings.
