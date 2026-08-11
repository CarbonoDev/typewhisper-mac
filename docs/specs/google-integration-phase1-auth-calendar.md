# Google Integration Phase 1 — Auth Foundation + Google Calendar

Status: **Design — authoritative target for Phase 1** (branch off `feature/meet-caption-bridge`).
Phase 1 of three: Phase 1 auth + Calendar (this spec) → Phase 2 Drive import/backfill → Phase 3
Gmail context. The auth layer built here is the foundation the later phases extend with scopes
only (see §9).

Decision IDs in this document are `D-G1`…`D-G8`; code comments should cite them the same way the
codebase cites `D-A2`/`M11`/`AD7`.

---

## 1. Goals / non-goals

### Goals

1. **Google OAuth foundation, multi-account.** N Google accounts, each with its own refresh token
   (Keychain, Debug/Release prefix discipline), display name/email, per-account connect/disconnect
   UI, automatic access-token refresh, and revocation/expiry error surfacing. Built for
   **incremental scopes**: Phase 1 requests only Calendar read; Phases 2–3 request Drive/Gmail
   readonly later against the *same* connected accounts without re-adding them.
2. **Google Calendar as a second calendar source** beside EventKit: a `GoogleCalendarProvider`
   behind the existing `CalendarEventProviding` seam
   (`TypeWhisper/Services/Meetings/CalendarEventProviding.swift:89-101`), multi-provider fan-in in
   `CalendarService`, provider/account-namespaced calendar and event IDs, per-account calendar
   selection, and visible account attribution ("split by account") in the calendars UI.
3. **Richer event detail, additive-only**: event description/notes, conferencing URL, and richer
   attendees (organizer flag, RSVP status) — threaded DTO → projection → new optional `Meeting`
   columns. `ParticipantDirectoryService.ingest` continues to consume name+email unchanged.
4. **Duplicate-source mitigation** for the case where the same Google account is also synced into
   macOS Calendar via CalDAV (same events from two providers) — see D-G6.
5. A **Google Cloud console runbook** (Appendix A); the app receives the OAuth client ID/secret via
   settings — never hardcoded.

### Non-goals (Phase 1)

- No Drive, no Gmail (Phases 2–3). The auth layer only *prepares* for their scopes.
- No write access to calendars anywhere (read-only, matching the EventKit provider's posture).
- No new `MeetingSource` case and no per-provider `Meeting` source changes beyond the additive
  columns in §4 — a Google-calendar meeting is a normal `.calendar` meeting.
- No changes to `MeetingMergeService`/`MeetingMergePlanner` (the post-hoc merge remains the manual
  fallback for duplicates that slip through D-G6).
- No plugin-SDK changes of any kind (see D-G1).
- No event-level cross-provider dedupe engine (deliberately rejected in D-G6 for Phase 1).

---

## 2. Architecture overview

```
Settings (MeetingsSettingsView)                 Google Cloud
 └─ GoogleAccountsSection ──────────┐            (accounts.google.com / oauth2.googleapis.com
                                    ▼             / www.googleapis.com/calendar/v3)
                         GoogleAuthService ──────────────► OAuth endpoints
                          │   (loopback server, PKCE,
                          │    token refresh, revoke)
                          ▼
                    GoogleAccountStore  ──► UserDefaults (account index, client ID)
                          │             ──► Keychain (refresh tokens, client secret)
                          ▼
                GoogleCalendarSyncEngine ────────────────► Calendar API (calendarList, events)
                          │  (periodic fetch → in-memory snapshot)
                          ▼
                  GoogleCalendarProvider  (CalendarEventProviding — reads the snapshot
                          │                synchronously; namespaced IDs, D-G3)
                          ▼
   CalendarService (fan-in: EventKitCalendarProvider primary + secondaries, D-G4)
                          │  republish() choke point — selection filter unchanged
                          ▼
   upcomingEvents / earlierEvents → MeetingsViewModel.createMeeting(from:) → MeetingService
```

Everything new lives in **`TypeWhisper/Services/Google/`** (app-side, fork-owned — D-G1) plus one
settings section view. `CalendarService` keeps its single filtering choke point (`republish()`,
`CalendarService.swift:117-143`) and its projection seam (`meetingProjection(for:)`,
`CalendarService.swift:278-289`); Google events flow through the exact same pipeline as EventKit
events once they leave the provider.

All new store/service objects are `@MainActor` (matching every meetings service) except the
loopback listener, which may stay queue-confined per its precedent (M1); network work happens inside
`async` calls on `URLSession` so nothing blocks the main thread (same discipline as the LLM/
transcription paths, CLAUDE.md "Concurrency").

---

## 3. Decision records

### D-G1 — Placement: app-side `TypeWhisper/Services/Google/`, not a plugin

**Options considered**

1. *SDK plugin* (matches the "everything is a plugin" precedent: OpenAI/Gemini/Groq etc. under
   `TypeWhisperPluginSDK/Plugins/`).
2. *App-side service family* under `TypeWhisper/Services/Google/`.
3. Hybrid: auth as a plugin, calendar provider app-side.

**Decision: option 2 — app-side.**

**Rationale**

- **Reachability.** Every consumer is an app-side, fork-owned meetings service: `CalendarService`
  fan-in now (`CalendarService.swift:39,53-65`), `MeetingImportService` (Phase 2) and
  `MeetingBriefService`/`MeetingLLMService` (Phase 3) later. The plugin protocol surface
  (`TranscriptionEnginePlugin`, `LLMProviderPlugin`, `TTSProviderPlugin`, `PostProcessorPlugin`,
  `ActionPlugin`) has **no calendar/mail/file-source concept**; a plugin would need a brand-new
  host-visible protocol plus host plumbing in `PluginManager`/`HostServicesImpl` — strictly more
  new surface than option 2, all of it in the **upstream-shared** SDK the fork deliberately keeps
  minimally diverged (CLAUDE.md "Fork conventions").
- **Upstream divergence.** Option 2 touches zero SDK files. Option 1 would put a large,
  fork-specific protocol into the shared package and make every upstream sync harder.
- **Multi-account.** `HostServicesImpl.storeSecret/loadSecret` scopes secrets per-plugin, not
  per-account; the app-side `KeychainService` (`TypeWhisper/Services/Cloud/KeychainService.swift`)
  takes arbitrary service names, so the per-account scheme in D-G5 is trivial app-side.
- **Settings fit.** Google accounts are a meetings-feature concern; a section inside the existing
  Meetings pane (`MeetingsSettingsView.swift:6`, registered at `SettingsView.swift:248`) is the
  natural home. Plugin placement would strand the UI in the Integrations tab away from calendar
  selection.
- The "integrations are plugins" precedent is about *pipeline* integrations (engines, LLMs,
  actions) that plug into dispatch seams. Google here is a *data source for the fork's own
  meetings surface* — closer kin to `ObsidianVaultService` (also app-side, also an external system)
  than to the Groq plugin. Comment the family with a `D-G1` citation so the exception is legible.

### D-G2 — OAuth flow: Google "Desktop app" client + loopback redirect + PKCE (S256)

**Options considered**

1. **Desktop app client type, loopback `http://127.0.0.1:{port}` redirect**, browser via
   `NSWorkspace.open`, local `NWListener` catching the redirect — the in-repo precedent
   (`TypeWhisperPluginSDK/Plugins/OpenAIPlugin/OpenAIPlugin.swift`: loopback server class :149,
   PKCE :379, browser open :1945, redirect URI config :66).
2. iOS client type + reversed-client-ID custom scheme + `ASWebAuthenticationSession`.

**Decision: option 1.** Current Google policy is decisive: **custom URI schemes are deprecated
("no longer supported due to the risk of app impersonation")** and the loopback flow, while being
retired for iOS/Android/Chrome client types, **continues to be supported for Desktop app
clients** ([Google loopback migration guide](https://developers.google.com/identity/protocols/oauth2/resources/loopback-migration),
[OAuth 2.0 for iOS & Desktop Apps](https://developers.google.com/identity/protocols/oauth2/native-app)).
`ASWebAuthenticationSession` cannot capture a loopback redirect, so option 2 would ride a
deprecated mechanism. The app is unsandboxed with `network.client` (recon §D;
`Resources/TypeWhisper.entitlements`), so a loopback listener needs no entitlement work.

**Flow specifics (normative):**

- **Client type:** "Desktop app" in Google Cloud console. Desktop clients need **no registered
  redirect URI**; any `http://127.0.0.1:{port}` is accepted, so the listener binds an **ephemeral
  port** (bind port 0, read the assigned port, build the redirect URI from it).
- **Client secret:** Google issues one for Desktop clients and **requires it at the token
  endpoint**, while explicitly treating it as *not confidential* for installed apps. The user
  pastes both client ID and secret in settings (storage per D-G5). PKCE is still mandatory —
  the secret is anti-typo, not the security boundary.
- **Authorization request** (`https://accounts.google.com/o/oauth2/v2/auth`):
  `client_id`, `redirect_uri=http://127.0.0.1:{port}`, `response_type=code`,
  `scope="openid email profile https://www.googleapis.com/auth/calendar.readonly"`,
  `code_challenge` (S256 of a 43–128 char verifier), `code_challenge_method=S256`,
  `state` (32 random bytes, base64url; verified on callback), `access_type=offline`,
  `prompt=select_account consent` (select_account → adding a *second* account never silently
  reuses the browser's current session; consent → a refresh token is guaranteed even on
  re-connect), `include_granted_scopes=true` (the incremental-scope hook Phases 2–3 rely on).
- **Token exchange** (`https://oauth2.googleapis.com/token`): form-encoded `code`, `client_id`,
  `client_secret`, `redirect_uri`, `grant_type=authorization_code`, `code_verifier`. Response
  carries `access_token`, `expires_in` (~3600 s), `refresh_token`, `id_token`, `scope`.
- **Identity:** decode the `id_token` JWT payload (base64url middle segment; no signature
  verification — it arrives directly from Google's token endpoint over TLS) for `sub`
  (the stable account key, D-G3/D-G5), `email`, `name`.
- **Refresh cadence:** on demand, not on a timer. `accessToken(for:)` refreshes when the cached
  token is missing or expires within a 60 s skew, single-flight per account (a second caller
  awaits the in-flight refresh). `invalid_grant` on refresh ⇒ account → `.needsReauth`
  (revoked/expired; also the weekly symptom of a consent screen left in Testing mode —
  Appendix A).
- **Disconnect:** best-effort `POST https://oauth2.googleapis.com/revoke?token=<refresh>`, then
  delete Keychain items and remove the account from the index regardless of revoke outcome.
- **Timeout/cancel:** the loopback server times out after 5 minutes; the settings row shows a
  cancel affordance that stops the listener.

### D-G3 — ID namespacing: `google:<sub>:<rawID>`; EventKit IDs stay bare

**Options:** (a) prefix only Google IDs, EventKit unchanged; (b) prefix all providers
(`eventkit:` too); (c) structured composite type instead of strings.

**Decision: (a).** Prefixing EventKit IDs would orphan every existing
`Meeting.calendarEventID` (`Models/Meeting.swift:19` — the dedupe key at
`MeetingsViewModel.swift:451` and the link path `MeetingService.linkToCalendarEvent`,
`MeetingService.swift:183`) and every persisted
entry in `CalendarSelectionStore`'s flat deselected set
(`CalendarSelectionStore.swift:39-45`, key `UserDefaultsKeys.swift:185`). A migration for those is
avoidable risk; bare-vs-prefixed cannot collide because EventKit `calendarIdentifier`s are UUIDs
that never contain the `google:` prefix.

**Scheme (normative):**

| Thing | ID |
|---|---|
| Account key | Google `sub` claim (stable across email changes; dedupes re-adds) |
| Calendar ID (`CalendarInfo.id`, `CalendarEventDTO.calendarID`) | `google:<sub>:<calendarId>` |
| Event ID (`CalendarEventDTO.id` → `Meeting.calendarEventID`) | `google:<sub>:<eventInstanceId>` |
| `seriesID` | see D-G8 |

- Google event fetches use `singleEvents=true`, so recurring events arrive as instances whose
  `id` is already occurrence-unique (`<seriesId>_<YYYYMMDDTHHMMSSZ>`) — no `#startTimestamp`
  suffix is needed (that suffix exists on the EventKit side only because `EKEvent.eventIdentifier`
  is series-scoped, `CalendarService.swift:505-509`).
- `CalendarSelectionStore` needs **no change**: namespaced calendar IDs land in the same flat
  deselected set; unknown IDs default to selected, which is exactly the desired behavior for a
  freshly connected account (`CalendarSelectionStore.swift:8-13`).
- Constants live in one place: `GoogleCalendarID.calendarID(sub:raw:)` /
  `.eventID(sub:raw:)` / `.accountSub(fromNamespacedID:)` (pure, unit-tested) so the prefix format
  is never hand-assembled twice.

### D-G4 — Fan-in shape: primary provider + `secondaryProviders` array on `CalendarService`

**Options:** (a) `[CalendarEventProviding]` array with a designated primary; (b) a
`CompositeCalendarProvider` wrapping N providers behind the same protocol; (c) a parallel
`GoogleCalendarService` publishing its own event lists.

**Decision: (a).** (c) would fork the choke point — two upcoming lists, two selection filters,
double the consumer wiring (brief scheduler, notifications, rules all read
`CalendarService.$upcomingEvents`). (b) hides per-provider identity exactly where we need it
(auth-status semantics, error attribution) and still needs the composite to answer "which provider
is the system one?" for `requestAccess`. (a) is additive on the existing init and keeps every
current test compiling.

**Semantics (normative):**

- `init(provider:selectionStore:lookAhead:grace:)` gains
  `secondaryProviders: [CalendarEventProviding] = []` (`CalendarService.swift:53-65`). The
  existing `provider` stays the **primary/system** provider (EventKit).
- `authorizationStatus` (published, `CalendarService.swift:28`) keeps reflecting the **primary**
  provider — permission prompts keep their meaning. Google connect state is *not* an authorization
  status; it surfaces through `GoogleAccountStore.$accounts` in the settings UI instead.
- **UI availability (Google-only users).** Four views currently gate their *entire* calendar UI
  on the primary status (via the VM mirror `MeetingsViewModel.calendarAuthorizationStatus` /
  `isCalendarAuthorized`, `ViewModels/MeetingsViewModel.swift:39,204,230-238,362`):
  `HomeNextSection` shows `connectCalendarCard` (`Views/MainWindow/ComingUpCard.swift:17-18`),
  `Views/Meetings/UpcomingMeetingsSection.swift:21-27`,
  `Views/Meetings/CalendarSelectionSection.swift:19` (blocks the whole per-account selection UI),
  and `Views/Meetings/MeetingLinkEventView.swift:28`. Without a fix, a Google-only user (EventKit
  denied) gets fan-in events that never render. `MeetingsViewModel` therefore gains a published
  availability concept:
  `var hasAnyCalendarSource: Bool` — `calendarAuthorizationStatus == .authorized` **or** ≥1
  connected Google account (fed from `GoogleAccountStore.$accounts` via Combine, same pattern as
  the existing status mirror). The four views gate on `hasAnyCalendarSource`;
  `CalendarSelectionSection` instead always renders its per-source groups and scopes the
  needs-access hint to the **macOS group only** (M4 enumerates all five files).
- `refresh(now:existingCalendarEventIDs:)` (`CalendarService.swift:98-113`): the early-out guard
  `authorizationStatus == .authorized` becomes *"any provider authorized"*
  (`([provider] + secondaryProviders).contains { $0.authorizationStatus == .authorized }`), so a
  user who denies macOS calendar access but connects Google still gets events. The query
  concatenates `events(from:to:)` across all providers (each unauthorized provider already
  returns `[]`); `republish()` is untouched — selection filtering and windowing are
  provider-agnostic once IDs are namespaced.
- `availableCalendars()` (`CalendarService.swift:156-158`) and
  `linkCandidates(around:window:)` (`CalendarService.swift:301-309`) concatenate across providers
  the same way (link candidates additionally keep their existing per-call authorization guard,
  now the any-provider version).
- `updateErrorMessage(for:)` (`CalendarService.swift:83-90`): the denied/restricted message is
  suppressed when at least one secondary provider is authorized (EventKit-denied + Google-connected
  is a working configuration, not an error). Today it only runs from `init` and `requestAccess()`
  (`CalendarService.swift:64,77`), so suppression would otherwise require a restart — it must
  additionally be re-evaluated at the top of every `refresh(now:existingCalendarEventIDs:)`, which
  runs on the 60 s poll and on every snapshot-change refresh, so connecting/disconnecting a Google
  account updates the message within one refresh cycle.
- **Per-provider failure:** a provider must never throw through the seam. On a *transient sync
  failure* (network, 4xx/5xx), `GoogleCalendarProvider` serves its last good snapshot and exposes
  the error via `GoogleCalendarSyncEngine.$lastSyncError` for the settings UI; EventKit behavior
  is unchanged — sync failures degrade to "its events go stale," never to an empty list. This
  invariant is scoped to sync failures: when **every** account is `.needsReauth` (revoked/expired
  auth) the provider's status drops out of `.authorized` and its events clear from the lists —
  intended, mirroring how EventKit-denied clears EventKit events.

### D-G5 — Account state: UserDefaults JSON index + Keychain tokens; no new SwiftData store

**Options:** (a) new `google-accounts.store` SwiftData store; (b) JSON array in UserDefaults for
non-secret metadata + Keychain for secrets; (c) everything in Keychain.

**Decision: (b).** Accounts are a handful of small, non-relational records with no query needs —
SwiftData would add a store file, a container, and schema-discipline overhead for nothing. (c)
makes the index awkward to publish/observe. (b) follows the OpenAI plugin's split (secrets in
keychain, metadata in defaults, `OpenAIPlugin.swift:2020` area) and respects single-writer
discipline: **`GoogleAccountStore` is the sole writer** of its defaults keys and its Keychain
namespace, mirroring how each meetings service solely owns its store.

**Layout (normative):**

- `UserDefaultsKeys` additions (`TypeWhisper/App/UserDefaultsKeys.swift`):
  - `googleAccountsIndex = "google.accounts.index"` — JSON-encoded `[GoogleAccount]`.
  - `googleOAuthClientID = "google.oauth.clientID"` — plain string (public identifier).
  - `googleTwinPromptHandled = "google.twinPrompt.handled"` — `[String]` of `sub`s (D-G6).
    Written **only** through `GoogleAccountStore.markTwinPromptHandled(_:)` /
    read via `isTwinPromptHandled(_:)`, preserving the store's single-writer ownership of every
    `google.*` defaults key.
- Keychain services (all automatically under `AppConstants.keychainServicePrefix`,
  `App/AppConstants.swift:64-70`, so Debug uses `com.meetingwhisper.mac.dev.apikey.…` and dev/release
  builds never collide — the existing prefix discipline):
  - `google.oauth.client-secret` — the pasted client secret (non-confidential per D-G2, but it
    doesn't belong in defaults).
  - `google.account.<sub>.refresh` — the per-account refresh token.
  - Disconnect calls `KeychainService.deleteAll(withServicePrefix: "google.account.<sub>.")`
    (`Services/Cloud/KeychainService.swift:95`) so any future per-account secrets (Phase 2/3
    tokens if ever split) are swept too.
- Access tokens are **in-memory only** (`GoogleAuthService` cache), never persisted.
- Client ID/secret config path: pasted into the "OAuth client" disclosure inside
  `GoogleAccountsSection` (M2). No hardcoded values anywhere; with no client configured, the
  Connect button is disabled with an explanatory string linking the runbook.

### D-G6 — Duplicate-source hazard: twin-calendar detection + guided deselection (calendar-level)

Same Google account synced into macOS Calendar via CalDAV ⇒ the same events arrive from both
providers with unrelated IDs (recon §A risk), producing duplicate rows and duplicate meetings.

**Options:** (a) event-level suppression (match by iCalUID/title+time across providers inside
`republish()`); (b) calendar-level: detect the EventKit "twin" calendars of a just-connected
Google account and guide the user to deselect them; (c) do nothing, rely on manual merge.

**Decision: (b).** Event-level suppression is a silent, heuristic, per-event mechanism running on
every republish — wrong matches *hide real events*, the failure mode is invisible, and EventKit
does not reliably expose iCalUID for cross-matching. Calendar-level deselection is coarse,
visible, reversible in the existing calendars UI, and runs through the already-proven selection
choke point (`republish()`, `CalendarService.swift:119-127`). (c) leaves the default experience
broken.

**Mechanics (normative):**

- Pure helper `TwinCalendarDetector.twins(eventKit:google:accountEmail:) -> [CalendarInfo]`:
  an EventKit calendar is a twin when its `sourceName` (`EKSource.title`, e.g. "Google" or the
  account email — `CalendarService.swift:463`) case-insensitively matches "google"/"gmail" or
  contains the account email, **and** its title case-insensitively equals a Google calendar's
  title or the account email (Google primary calendars are titled with the email).
- **Trigger:** evaluated on the first `.googleCalendarSnapshotDidChange` after a connect for any
  account whose `sub` is not yet handled (`GoogleAccountStore.isTwinPromptHandled(_:)` — writes
  route through the store, see D-G5), and **re-evaluated on subsequent snapshot changes while
  unhandled** (the first snapshot after connect can race the calendarList fetch). Skipped entirely
  when EventKit is not `.authorized` (no EventKit calendars ⇒ no twins to hide).
- **Inputs:** partition `CalendarService.availableCalendars()` by the `google:` ID prefix
  (D-G3) — non-prefixed entries are the EventKit side, prefixed entries whose ID carries the
  account's `sub` are the Google side. (Equivalent to reading the providers directly; the
  partition rule keeps the detector pure over one input list.)
- If twins exist, the settings section shows a one-time inline prompt:
  *"Some calendars from this Google account are also synced through macOS Calendar. Hide the
  macOS copies to avoid duplicate events?"* — **Hide duplicates** (default) deselects the twin
  EventKit calendar IDs via the normal
  `CalendarService.setCalendarSelected(false, for:)` path (`CalendarService.swift:168-171`);
  **Keep both** does nothing. Either choice records the `sub` as handled via
  `GoogleAccountStore.markTwinPromptHandled(_:)` (single-writer, D-G5).
- Escape hatches: re-enabling a hidden calendar in `CalendarSelectionSection` works as today;
  duplicates that still occur (e.g. an Exchange-relayed copy the detector can't see) fall back to
  the existing manual meeting merge (`MeetingMergePlanner`) — unchanged, out of scope.

### D-G7 — Sync model: cached snapshot behind a periodic sync engine; the provider seam stays synchronous

`CalendarEventProviding.events(from:to:)` is synchronous (`CalendarEventProviding.swift:97`) and
called from `refresh()` on the main actor — a network provider cannot answer inline.

**Options:** (a) make the protocol async (touches every provider, test fake, and call site);
(b) keep the seam synchronous and back the Google provider with an in-memory snapshot maintained
by an async sync engine.

**Decision: (b).** The 60 s UI poll (`MeetingsViewModel.swift:1660-1663`) already makes the
pipeline pull-based and eventually consistent; an async protocol buys nothing but churn.

- `GoogleCalendarSyncEngine` (owned by `ServiceContainer`, app-lifetime — deliberately *not* the
  UI-visibility-scoped poll, recon §B) syncs every **5 minutes** and immediately on: account
  connect/disconnect, calendar selection change, and manual "Refresh now". Each sync: for every
  connected account → `calendarList` → for each calendar, `events` in the window
  `[startOfDay(now) − 1d, now + 48h]` (superset of `CalendarService`'s lookback + 12 h look-ahead
  `CalendarService.swift:20,107`, with margin for the link picker's near-window queries),
  `singleEvents=true&showDeleted=false&maxResults=250` with pagination.
- On snapshot change the engine posts `Notification.Name.googleCalendarSnapshotDidChange`;
  `MeetingsViewModel` observes it and runs the same refresh it runs on its 60 s tick, so new
  events appear without waiting for the next poll.
- `GoogleCalendarProvider.events(from:to:)` filters the snapshot by overlap — pure, synchronous,
  fast. `requestAccess()` is a no-op returning current status; `authorizationStatus` is
  `.authorized` iff ≥1 account is `.connected`, else `.notDetermined`.
- The far-window link picker (`events(around:window:)`, ±7 d default) may exceed the synced
  window; the Google provider answers from whatever the snapshot holds (best-effort). Widening
  link-picker fetches on demand is an explicit non-goal for Phase 1 (noted in §8).

### D-G8 — `seriesID` continuity: use the Google event's `iCalUID` for recurring events

EventKit sets `seriesID` from `calendarItemExternalIdentifier`
(`CalendarService.swift:489`), which for CalDAV-synced Google calendars is derived from the
event's **iCalUID**. Google's API exposes the same `iCalUID` on event instances.

**Decision:** for a Google event with `recurringEventId` present, set
`seriesID = iCalUID` (bare, un-namespaced); non-recurring events get `seriesID = nil` (matching
the EventKit provider's rule, `CalendarService.swift:489`). This gives prior-meeting matching
(`priorMeetings(matching:)` via `Meeting.seriesID`, `Models/Meeting.swift:20`) a real chance of
recognizing a series across the EventKit→Google switchover, instead of guaranteeing a cold start.
If empirical QA (Appendix A checklist step 8 / §7 QA step 10) shows the formats never align,
nothing breaks — matching just starts fresh, exactly as a namespaced ID would. Do **not**
namespace `seriesID`: collision across accounts is harmless (it only groups prior meetings of the
same series) and namespacing would forfeit the continuity win.

---

## 4. Data model changes (all additive/optional)

### `CalendarEventDTO` (`Services/Meetings/CalendarEventProviding.swift:16-71`) — new optional fields (**lands in M3** — the Google mapper populates them; EventKit leaves them `nil` until M5)

```swift
/// Event description/notes as plain text (Google `description`, EventKit `notes`). nil when absent.
var eventNotes: String?
/// Video-conference join URL (Google conferenceData/hangoutLink; EventKit `url` when it looks
/// like a known conference host). nil when absent.
var conferencingURL: String?
/// Human label of the owning account for "split by account" attribution — the Google account
/// email; nil for EventKit events (the system calendar UI already shows source via CalendarInfo).
var accountLabel: String?
```

All three default to `nil` in the init (existing call sites compile unchanged).

### `Attendee` (`Models/Attendee.swift:5-47`) — new optional fields (**lands in M3**; Codable JSON blob ⇒ old payloads decode to `nil`, same precedent as `isSelf`)

```swift
/// Whether this attendee organizes the event (Google `organizer` flag). nil = unknown (D-G x).
var isOrganizer: Bool?
/// RSVP status raw value: "accepted" | "declined" | "tentative" | "needsAction". nil = unknown.
var responseStatusRaw: String?
var responseStatus: AttendeeResponseStatus? { responseStatusRaw.flatMap(AttendeeResponseStatus.init(rawValue:)) }
```

plus `enum AttendeeResponseStatus: String, Codable, Sendable { case accepted, declined, tentative, needsAction }`
(same file). `Attendee.init` gains the two parameters with `nil` defaults.
`ParticipantDirectoryService.ingest` is untouched — it keeps reading name+email
(`Services/Meetings/ParticipantDirectoryService.swift:55-80`).

### `Meeting` (`Models/Meeting.swift`) — two new optional columns (**lands in M5**; additive-only discipline, header :8-10)

```swift
/// Description/notes of the linked calendar event, snapshotted at meeting creation/link time.
/// Additive/optional ⇒ no migration (D-G, Phase 1). nil for non-calendar meetings.
var calendarNotes: String?
/// Video-conference join URL from the linked event. Additive/optional ⇒ no migration.
var conferencingURL: String?
```

(`calendarNotes`, not `notes`/`eventDescription` — `notes` is the relationship at
`Models/Meeting.swift:79-80` and `description` collides with `NSObject`.)
`Meeting.init` gains both with `nil` defaults; `MeetingService.createMeeting` and
`MeetingService.linkToCalendarEvent(calendarEventID:...)`
(`Services/Meetings/MeetingService.swift:183-200`) gain matching optional parameters written only
by `MeetingService` (single-writer). The view-model seam that drives linking is
`MeetingsViewModel.linkMeeting(_:to:)` (`ViewModels/MeetingsViewModel.swift:516`), which passes
the event's fields through.

### `CalendarService.MeetingProjection` (`CalendarService.swift:269-289`)

Add `var calendarNotes: String?` and `var conferencingURL: String?`, populated from the DTO in
`meetingProjection(for:)`.

### New value types (no persistence beyond D-G5)

```swift
struct GoogleAccount: Codable, Equatable, Identifiable, Sendable {
    var id: String            // Google `sub`
    var email: String
    var displayName: String?
    var grantedScopes: [String]
    var connectedAt: Date
    var statusRaw: String     // GoogleAccountStatus
}
enum GoogleAccountStatus: String, Codable, Sendable { case connected, needsReauth }
```

No `MeetingSource` change; no store schema change; no `CalendarSelectionStore` change.

---

## 5. Milestones

Each milestone leaves the app building and the full test suite green. New Swift files must be
added to `TypeWhisper.xcodeproj` (project.pbxproj) — no SDK/package changes anywhere.

### M1 — OAuth foundation: flow, tokens, account store (no UI)

**Create** (`TypeWhisper/Services/Google/`):

- `GoogleOAuthFlow.swift` — pure, static, fully unit-testable:
  - `struct GooglePKCE { let verifier: String; let challenge: String; static func generate() -> GooglePKCE }` (S256)
  - `static func authorizationURL(clientID:redirectURI:scopes:[String],state:challenge:loginHint:String?) -> URL`
    (assembles the D-G2 parameter set; `loginHint` powers incremental scope re-auth, §9)
  - `static func parseCallback(_ url: URL, expectedState: String) throws -> String` (auth code)
  - `struct GoogleTokenResponse: Decodable` (`accessToken/expiresIn/refreshToken/idToken/scope`)
  - `struct GoogleIDTokenClaims: Decodable { let sub, email: String; let name: String? }` +
    `static func decodeIDToken(_ jwt: String) throws -> GoogleIDTokenClaims`
- `GoogleLoopbackServer.swift` — `final class`, `NWListener` on `127.0.0.1` port 0;
  `func start() throws -> UInt16`, `var onCallback: @MainActor (URL) -> Void`, `func stop()`;
  serves a tiny localized "You can close this window." HTML page. Concurrency shape is the
  implementer's choice: the queue-confined `@unchecked Sendable` class with a hop to the
  main actor in `onCallback` is the proven precedent (`OpenAILoopbackOAuthServer`,
  `TypeWhisperPluginSDK/Plugins/OpenAIPlugin/OpenAIPlugin.swift:149`) — `@MainActor` internals are
  *not* required (Network callbacks arrive on their own queue). App-side reimplementation; do not
  import the plugin.
- `GoogleHTTPTransport.swift` — `protocol GoogleHTTPTransport: Sendable { func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) }`
  + `struct URLSessionGoogleTransport` (ephemeral session). The fakeable network seam for all
  Google services.
- `GoogleSecretStore.swift` — `@MainActor protocol GoogleSecretStoring` (`save/load/delete/deleteAll(prefix:)`)
  + `final class KeychainGoogleSecretStore` delegating to `KeychainService`
  (`Services/Cloud/KeychainService.swift:18,48,71,95`). The fakeable keychain seam.
- `GoogleAccountStore.swift` — `@MainActor final class GoogleAccountStore: ObservableObject`;
  sole writer of the D-G5 defaults keys + keychain namespace.
  `@Published private(set) var accounts: [GoogleAccount]`;
  `func upsert(_ account: GoogleAccount, refreshToken: String)` (dedupe by `sub`; on re-add,
  union `grantedScopes`, replace token); `func remove(accountID: String)`;
  `func refreshToken(for accountID: String) -> String?`;
  `func setStatus(_ status: GoogleAccountStatus, for accountID: String)`;
  `func markTwinPromptHandled(_ accountID: String)` / `func isTwinPromptHandled(_ accountID: String) -> Bool`
  (sole writer of the D-G6 defaults key; consumed in M4);
  `var clientID: String? { get set }`, `var clientSecret: String? { get set }`,
  `var isConfigured: Bool`.
- `GoogleAuthService.swift` — `@MainActor final class GoogleAuthService: ObservableObject`:
  - `func connectAccount() async throws -> GoogleAccount` — full D-G2 flow
    (`NSWorkspace.shared.open` for the browser; precedent `OpenAIPlugin.swift:1945`).
  - `func accessToken(for accountID: String) async throws -> String` — cache + 60 s skew +
    single-flight refresh; `invalid_grant` ⇒ `store.setStatus(.needsReauth, …)` +
    `throw GoogleAuthError.needsReauth`.
  - `func reauthorize(accountID: String, additionalScopes: [String]) async throws` — same flow
    with `login_hint` + `include_granted_scopes=true` (used by "Reconnect", and by Phases 2–3).
  - `func disconnect(accountID: String) async` — best-effort revoke + `store.remove`.
  - `enum GoogleAuthError: LocalizedError { case notConfigured, cancelled, timedOut, stateMismatch, exchangeFailed(String), refreshFailed(String), needsReauth }`
  - `static let calendarScope = "https://www.googleapis.com/auth/calendar.readonly"`,
    `static let identityScopes = ["openid", "email", "profile"]`.

**Modify:** `TypeWhisper/App/UserDefaultsKeys.swift` (three keys, D-G5);
`TypeWhisper/App/ServiceContainer.swift` (~:184 region): construct
`googleAccountStore`, `googleAuthService` (no calendar wiring yet).

**Tests** (`TypeWhisperTests/`):

- `GoogleOAuthFlowTests` — PKCE S256 vector, authorization-URL parameter set (asserts
  `access_type=offline`, `prompt`, `include_granted_scopes`, scopes joined), callback parse
  (code, state mismatch, error param), token-response decoding, ID-token payload decode
  (fixture JWT). Pure — no fakes needed.
- `GoogleAccountStoreTests` — ephemeral `UserDefaults(suiteName:)` + in-memory
  `GoogleSecretStoring` fake: upsert/dedupe by `sub`, scope union on re-add, remove sweeps the
  `google.account.<sub>.` prefix, status transitions persist.
- `GoogleAuthServiceTokenTests` — fake transport + fake secret store + injected clock: refresh on
  expiry skew, single-flight (two concurrent callers, one network call), `invalid_grant` ⇒
  `.needsReauth` status + error.

**EN strings:** none (no UI).

### M2 — Settings UI: Google accounts connect/disconnect

**Create:** `TypeWhisper/Views/Meetings/GoogleAccountsSection.swift` — a section styled like
`CalendarSelectionSection` (`Views/Meetings/CalendarSelectionSection.swift:8-70`):

- "OAuth client" disclosure: client ID text field, client secret secure field, a "Setup guide"
  caption pointing at Appendix A. Connect disabled until `isConfigured`.
- Account rows: email + display name, status badge (`Connected` / `Needs attention`), Reconnect
  (on `.needsReauth`) and Disconnect buttons; "Add Google Account…" button driving
  `GoogleAuthService.connectAccount()` with progress + cancel (stops the loopback server) and
  inline error text on failure.

**Modify:** `TypeWhisper/Views/Meetings/MeetingsSettingsView.swift` (insert section near
`CalendarSelectionSection()` at :29).

**Tests:** `GoogleAccountRowStateTests` — pure mapping `GoogleAccount` → row view-state (badge
string key, which buttons show) extracted as a static helper so the view stays logic-free.

**EN strings (dev adds DE):**
`google.accounts.sectionTitle` "Google Accounts";
`google.accounts.addAccount` "Add Google Account…";
`google.accounts.disconnect` "Disconnect";
`google.accounts.reconnect` "Reconnect";
`google.accounts.statusConnected` "Connected";
`google.accounts.statusNeedsReauth` "Needs attention — reconnect this account";
`google.accounts.clientSection` "Google OAuth client";
`google.accounts.clientID` "Client ID";
`google.accounts.clientSecret` "Client secret";
`google.accounts.clientHelp` "Create a Desktop-app OAuth client in Google Cloud console and paste its ID and secret here. See docs/specs/google-integration-phase1-auth-calendar.md, Appendix A.";
`google.accounts.notConfigured` "Enter an OAuth client ID and secret to connect accounts.";
`google.accounts.connecting` "Waiting for Google sign-in in your browser…";
`google.accounts.cancel` "Cancel";
`google.oauth.browserDone` "You're signed in. You can close this window and return to MeetingWhisper."
(the loopback response page).

### M3 — Google Calendar API client, sync engine, provider (not yet wired into fan-in)

**Create** (`TypeWhisper/Services/Google/`):

- `GoogleCalendarAPI.swift` — Codable API models (`GCalCalendarListEntry` {id, summary,
  primary?, backgroundColor?, accessRole}, `GCalEvent` {id, status, summary?, description?,
  start/end {date?, dateTime?}, attendees? [{email?, displayName?, organizer?, self?,
  responseStatus?}], organizer?, recurringEventId?, iCalUID?, hangoutLink?, conferenceData?,
  location?}, `GCalEventsPage` {items, nextPageToken?}) + request builders
  `calendarListRequest(token:)`, `eventsRequest(calendarID:token:timeMin:timeMax:pageToken:)`.
- `GoogleCalendarMapper.swift` — pure:
  - `static func calendarInfo(from: GCalCalendarListEntry, sub: String, accountEmail: String) -> CalendarInfo`
    (`id` namespaced per D-G3; `sourceName = accountEmail` — this is what makes the selection UI
    "split by account", since `CalendarInfo.sourceName` is already rendered,
    `CalendarSelectionSection.swift:59-63`; `color` from `backgroundColor` hex → `CalendarColor`,
    `.fallback` when absent).
  - `static func eventDTO(from: GCalEvent, calendar: CalendarInfo, sub: String, accountEmail: String) -> CalendarEventDTO?`
    — `nil` for `status == "cancelled"`; **normative:** every produced DTO sets
    `calendarName = calendar.title`, `calendarID = calendar.id` (the namespaced ID), and
    `calendarColor = calendar.color` — `republish()` treats `calendarID == nil` as always-selected
    (`CalendarService.swift:124-127`), so an unset `calendarID` would make Google events
    un-deselectable, and `calendarName` feeds capture-context rules
    (`MeetingContextRule.calendarNamePatterns`, `Models/MeetingContextRule.swift:62`);
    `isAllDay` when only `start.date`; `seriesID` per D-G8;
    `eventNotes` from `description` (HTML-stripped to plain text); `conferencingURL` =
    first `conferenceData.entryPoints` with `entryPointType == "video"`, else `hangoutLink`;
    `accountLabel = accountEmail`; attendees → `Attendee(name: displayName ?? email ?? "",
    email:, isSelf: self == true ? true : nil, isOrganizer:, responseStatusRaw:)` (the `isSelf`
    convention matches the EventKit provider, `CalendarService.swift:511-521`).
- `GoogleCalendarSyncEngine.swift` — `@MainActor final class`, `ObservableObject`; owns the
  snapshot `[(calendar: CalendarInfo, events: [CalendarEventDTO])]`; injected
  `GoogleHTTPTransport`, `GoogleAuthService`-conforming token seam
  (`protocol GoogleAccessTokenProviding { func accessToken(for accountID: String) async throws -> String }`),
  `GoogleAccountStore`, clock + interval; `func start()` (5-min timer per D-G7),
  `func syncNow() async`; `@Published private(set) var lastSyncError: String?`,
  `@Published private(set) var lastSyncAt: Date?`; posts
  `.googleCalendarSnapshotDidChange` on change. Per-account failure isolates (one account erroring
  never drops another account's snapshot); a `.needsReauth` from the token seam sets a
  user-facing `lastSyncError` and skips the account.
- `GoogleCalendarProvider.swift` — `CalendarEventProviding` over the engine's snapshot (D-G7
  semantics: overlap filter in `events(from:to:)`, `calendars()` from snapshot,
  `authorizationStatus` from account store).

**Modify:**

- `Services/Meetings/CalendarEventProviding.swift` — add the three §4 `CalendarEventDTO` fields
  (`eventNotes`, `conferencingURL`, `accountLabel`), `nil`-defaulted in the init, so this
  milestone builds standalone; the EventKit provider is untouched (leaves them `nil` until M5)
  and no existing call site changes.
- `Models/Attendee.swift` — add the §4 fields (`isOrganizer`, `responseStatusRaw` +
  `AttendeeResponseStatus`), `nil`-defaulted; zero behavior change for existing payloads.
- `ServiceContainer.swift` — construct engine + provider (still not passed to
  `CalendarService`; that flip is M4 so this milestone is reviewable without behavior change).
- `GoogleAccountsSection.swift` — show `lastSyncAt`/`lastSyncError` + "Refresh now" button.

**Tests:**

- `GoogleCalendarMapperTests` — fixture JSON: namespacing, all-day, cancelled dropped, D-G8
  seriesID rule, conference-URL precedence (conferenceData video > hangoutLink > nil),
  attendee mapping incl. `self`/`organizer`/`responseStatus`, HTML-stripped notes, color hex
  parse + fallback, **calendar attribution** (every DTO carries the namespaced `calendarID`, the
  calendar's title as `calendarName`, and its color — asserting none are `nil`).
- `AttendeeCodableCompatTests` — old JSON (no new keys) decodes with `nil`s; round-trip with
  `isOrganizer`/`responseStatusRaw`.
- `GoogleCalendarSyncEngineTests` — fake transport + fake token provider + fake clock:
  window math, pagination follow, per-account error isolation, `needsReauth` skip, snapshot
  change notification fired only on actual change.
- `GoogleCalendarProviderTests` — canned snapshot: overlap filtering, `events(around:window:)`
  default via the protocol extension, auth status from account store.

**EN strings:** `google.calendar.lastSync` "Last synced %@";
`google.calendar.refreshNow` "Refresh now";
`google.calendar.syncError` "Google Calendar sync failed: %@".

### M4 — CalendarService fan-in + per-account selection UI + twin mitigation

**Modify:**

- `Services/Meetings/CalendarService.swift` — D-G4 exactly: `secondaryProviders` init param;
  any-provider guards in `refresh` (:98-113), `linkCandidates` (:301-309); fan-in concat in
  `refresh`, `availableCalendars` (:156-158), `linkCandidates`; error-message suppression
  (:83-90). `republish()`/windowing/projection untouched.
- `App/ServiceContainer.swift:184` — `CalendarService(secondaryProviders: [googleCalendarProvider])`.
- `ViewModels/MeetingsViewModel.swift` — observe `.googleCalendarSnapshotDidChange` and run the
  same refresh as the 60 s tick (:1660-1663 path); add the published
  `hasAnyCalendarSource` availability flag (D-G4: primary `.authorized` **or** ≥1 connected
  account, recomputed from the existing status mirror :230-238 plus a `GoogleAccountStore.$accounts`
  subscription).
- **Google-only rendering fix (D-G4)** — switch the calendar-UI gates from
  `calendarAuthorizationStatus`/`isCalendarAuthorized` to `hasAnyCalendarSource` in:
  - `Views/MainWindow/ComingUpCard.swift:17-18` (`HomeNextSection`'s `connectCalendarCard` arm),
  - `Views/Meetings/UpcomingMeetingsSection.swift:21-27` (the status `switch`),
  - `Views/Meetings/MeetingLinkEventView.swift:28` (the `accessDenied` arm).
- `Views/Meetings/CalendarSelectionSection.swift` — replace the top-level authorization gate
  (:19) with always-rendered per-source groups: rows grouped by `calendar.sourceName` (section
  header per account/source); EventKit calendars keep their current source labels, Google groups
  appear under the account email; the needs-access hint (`meetings.calendar.calendarsNeedsAccess`)
  renders **inside the macOS group only** when EventKit is unauthorized, so per-account Google
  selection works for Google-only users.

**Create:** `Services/Google/TwinCalendarDetector.swift` (pure, D-G6) + the one-time prompt in
`GoogleAccountsSection` (post-connect), wiring **Hide duplicates** through
`CalendarService.setCalendarSelected(false, for:)` and recording the handled `sub`.

**Tests:**

- `CalendarServiceFanInTests` — two fake providers: concat + sort, unauthorized secondary yields
  primary-only, primary-denied + secondary-authorized still refreshes and suppresses the denied
  message, selection filter drops a deselected namespaced Google calendar, linkCandidates fan-in.
- `TwinCalendarDetectorTests` — pure matrix: Google-source + title match, email-titled primary,
  non-Google sources never matched, case-insensitivity.
- `CalendarSelectionGroupingTests` — pure grouping of `[CalendarSelectionRow]` by source
  (extract the grouping as a static helper).
- `CalendarSourceAvailabilityTests` — the `hasAnyCalendarSource` rule as a pure static
  `(CalendarAuthorizationStatus, [GoogleAccount]) -> Bool` helper: authorized/no accounts,
  denied/one connected, denied/only-needsReauth (false).

**EN strings:** `google.twins.title` "Duplicate calendars detected";
`google.twins.message` "Some calendars from %@ are also synced through macOS Calendar. Hide the macOS copies to avoid seeing every event twice?";
`google.twins.hide` "Hide duplicates";
`google.twins.keep` "Keep both".

### M5 — Rich event detail end-to-end

**Modify:**

(The `CalendarEventDTO` and `Attendee` field additions already landed in M3; M5 threads them
into EventKit, the projection, the store, and the UI.)

- `Services/Meetings/CalendarService.swift` — `MeetingProjection` + `meetingProjection(for:)`
  (:269-289) carry `calendarNotes`/`conferencingURL`; `EventKitCalendarProvider.dto(from:)`
  (:482-495) populates `eventNotes` from `EKEvent.notes` and `conferencingURL` from
  `EKEvent.url` when its host is a known conference domain (meet.google.com, zoom.us, teams
  .microsoft.com, webex.com) — pure helper `ConferenceURLDetector.detect(url:notes:)` also scans
  notes for the first such link (EventKit precedent: Google/Zoom links usually live in notes).
- `Models/Meeting.swift` — the two §4 columns; `Services/Meetings/MeetingService.swift` —
  optional `calendarNotes`/`conferencingURL` parameters on `createMeeting` and on
  `linkToCalendarEvent(calendarEventID:...)` (:183-200).
- `ViewModels/MeetingsViewModel.swift` — pass the two new projection fields through both
  seams: `createMeeting(from:)` (:446-467) and `linkMeeting(_:to:)` (:516).
- UI (minimal, additive): join-link button ("Join meeting") on `HomeNextHeroCard` and
  `HomeScheduleRow` (both private views inside `Views/MainWindow/ComingUpCard.swift`, :101/:287)
  and on the upcoming rows in `Views/Meetings/UpcomingMeetingsSection.swift` when
  `conferencingURL != nil` (opens in browser); event-notes block (collapsed disclosure) in the
  scheduled empty body (`Views/Meetings/MeetingDocumentBody.swift`, `scheduledEmptyBody` :34);
  attendee rows already rendered gain an organizer badge and a subtle RSVP glyph where attendee
  chips are drawn (dev locates the existing chip view; display-only).

**Tests:**

- `CalendarProjectionRichDetailTests` — projection carries notes/URL; nil-safe.
- `ConferenceURLDetectorTests` — pure: URL field vs notes scan, non-conference URLs ignored.
- Extend `GoogleCalendarMapperTests` if any mapping gap remains
  (`AttendeeCodableCompatTests` landed in M3 with the fields).

**EN strings:** `meetings.event.join` "Join meeting";
`meetings.event.detailsSection` "Event details";
`meetings.attendee.organizer` "Organizer".

---

## 6. Upstream-shared files touched

Target: **zero SDK/package files** — met (no change under `TypeWhisperPluginSDK/`).

App-side files that exist upstream and are touched (all additive, flagged for sync hygiene):

| File | Change |
|---|---|
| `TypeWhisper/App/ServiceContainer.swift` | one wiring block (new services + one init argument) |
| `TypeWhisper/App/UserDefaultsKeys.swift` | three added constants |
| `TypeWhisper/Resources/Localizable.xcstrings` | added keys only |
| `TypeWhisper.xcodeproj/project.pbxproj` | new file references |

Everything else modified is fork-owned meetings surface (`Services/Meetings/`, `Services/Google/`
(new), `ViewModels/MeetingsViewModel.swift`, `Views/Meetings/`, `Views/MainWindow/`,
`Models/Meeting.swift`/`Attendee.swift`). `Views/SettingsView.swift` is **not** touched (the new
section lives inside `MeetingsSettingsView`).

---

## 7. Test plan

**Unit** (per milestone, above; all runnable scoped, e.g.
`xcodebuild test … -only-testing:TypeWhisperTests/GoogleOAuthFlowTests`). Style: pure logic over
fakeable seams — the fakes are `GoogleHTTPTransport`, `GoogleSecretStoring`,
`GoogleAccessTokenProviding`, injected clocks, ephemeral `UserDefaults` suites, and canned
`CalendarEventProviding` providers (existing pattern from `CalendarServiceTests`). No test touches
the network, the real Keychain, or `EKEventStore`.

**Manual QA script** (real account; requires Appendix A completed and
`CodeSigning.local.xcconfig` present so TCC/keychain grants survive rebuilds — CLAUDE.md):

1. `scripts/build-dev-local.sh`; open Settings → Meetings. Google Accounts section shows the
   not-configured hint; Connect is disabled.
2. Paste client ID + secret. Click **Add Google Account…** → browser opens Google sign-in →
   consent screen lists Calendar (read-only) + profile scopes → approve → browser shows the
   "you can close this window" page → the account row appears with email + Connected badge.
3. Add a **second** account (different Google identity). Verify the account chooser appeared
   (`prompt=select_account`) and both rows are listed.
4. Calendars list now shows sections per source: macOS sources plus one group per Google account
   email, each calendar with color dot and checkbox ("split by account").
5. If the same Google account is also in macOS Calendar: verify the one-time duplicate prompt;
   choose **Hide duplicates**; confirm the EventKit twins are unchecked and upcoming events show
   only one copy. Re-check a twin manually and confirm events duplicate again (then re-uncheck).
6. Home → Coming Up: events from a Google-only calendar appear within ~1 min of connect; create
   a meeting from one; verify title/date/attendees; verify the event drops out of Upcoming
   (dedupe on the namespaced ID). Restart the app; verify no duplicate meeting is created.
7. Rich detail: pick a Google event with a description + Meet link → meeting shows "Event
   details" notes and a working **Join meeting** button; organizer badge visible on the
   organizer; attendee first/last name flow into Participants (directory unchanged).
8. Deselect a Google calendar → its events vanish everywhere (upcoming, earlier, link picker).
9. Disconnect an account → its calendars and events disappear; Keychain (Keychain Access,
   search `google.account.`) shows the token removed. Reconnect → same account row (no
   duplicate), events return.
10. Series continuity (D-G8): a recurring meeting previously captured via EventKit — open a new
   occurrence from the Google provider and check prior-meeting matching still surfaces the
   series' history. Record the result either way in the PR.
11. Revocation surfacing: revoke the app at <https://myaccount.google.com/permissions>, click
   **Refresh now** → account flips to "Needs attention" with the sync error shown; if it was the
   only connected account, its events clear from Upcoming/Earlier — **intended** (auth loss
   mirrors EventKit-denied, D-G4), not the stale-snapshot path. **Reconnect** heals it and events
   return.
12. Debug/Release separation: confirm the dev build wrote only `…mac.dev.apikey.google.…`
   keychain items.
13. **Google-only configuration** (D-G4/M4): with macOS Calendar access *denied* (System
   Settings → Privacy & Security → Calendars, or a fresh ad-hoc build without the TCC grant) and
   ≥1 Google account connected: Home "Next" shows Google events (no connect-calendar card),
   Upcoming/Earlier populate, the link-event picker offers Google candidates, and the Calendars
   settings list renders the Google account groups with the needs-access hint confined to the
   macOS group. No stray "calendar access denied" error banner appears.

---

## 8. Risks & open questions

- **Consent-screen publishing — decided (Marco, 2026-08-10): publish "In production" WITHOUT
  Google verification.** Each account sees a one-time unverified-app interstitial at connect;
  refresh tokens persist indefinitely (no 7-day Testing-mode expiry). Appendix A step 4 is the
  normative runbook. Phase 2/3's *restricted* Drive/Gmail scopes will force revisiting this
  (unverified production apps are blocked for restricted scopes — Testing mode or verification).
- **Duplicates across two connected Google accounts** (a calendar shared between them, or both
  invited to the same event) produce distinct namespaced IDs and are **not** covered by the D-G6
  twin prompt, which only pairs Google against EventKit. Workaround: deselect the shared calendar
  under one of the accounts. Cross-Google dedupe is explicitly out of scope for Phase 1.
- **Phase 2/3 restricted scopes** (Drive/Gmail readonly) are *restricted*, not merely sensitive:
  unverified production apps get blocked for them; Testing mode + test users works but carries
  the 7-day expiry. Phase 2 must revisit (see §9); nothing in Phase 1 forecloses either path.
- **D-G8 continuity is best-effort**: `calendarItemExternalIdentifier` formats vary by macOS
  version/account plumbing. Failure mode is benign (fresh series history). QA step 10 verifies.
- **Link-picker window vs snapshot window** (D-G7): ±7-day link candidates from Google are served
  best-effort from the −1d/+48h snapshot. If linking to older Google events matters, a follow-up
  can widen the sync window or add an on-demand fetch.
- **Twin detection heuristics** can miss (EKSource titled unusually, calendar renamed). Fallback
  is manual calendar deselection + manual meeting merge — both existing UI.
- **API quotas**: Calendar API default quotas are far above one user syncing every 5 min
  (~12 req/sync-cycle for a two-account setup); no backoff scaffold needed in Phase 1 beyond
  treating HTTP 403/429 as a sync error (surfaced, retried next tick).
- **Google color fidelity**: `backgroundColor` hex may differ from the EventKit color for the
  same logical calendar. Cosmetic only.
- **No `Meeting.googleAccountID`**: a meeting doesn't record which account its event came from
  beyond the namespaced `calendarEventID` prefix (parseable via
  `GoogleCalendarID.accountSub(fromNamespacedID:)`). Deliberate — avoid a column Phase 1 doesn't
  read. Revisit if Phase 3 needs per-meeting account affinity for email context.

---

## 9. Forward compatibility — Phase 2 (Drive) & Phase 3 (Gmail)

The auth layer is finished after Phase 1; later phases add **scopes and services only**:

- **Incremental scopes**: `GoogleAuthService.reauthorize(accountID:additionalScopes:)` +
  `include_granted_scopes=true` (D-G2) means Phase 2 calls it with
  `drive.readonly`, Phase 3 with `gmail.readonly`, against the *existing* account — Google merges
  grants; `GoogleAccountStore.upsert` unions `grantedScopes`. UI pattern: a per-feature "enable
  for this account" toggle that triggers reauthorize when the scope is missing
  (`account.grantedScopes` is the check).
- **Token access**: `GoogleAccessTokenProviding` is the one seam any new service needs
  (`accessToken(for accountID:)` — scope-agnostic because Google access tokens carry the union of
  granted scopes). `GoogleDriveSyncService`/`GmailContextService` take it exactly like
  `GoogleCalendarSyncEngine` does, plus their own `GoogleHTTPTransport`.
- **Error surfacing**: `.needsReauth` propagation and the settings badge are shared — a Drive 401
  routes through the same `setStatus` path.
- **Namespacing**: `GoogleCalendarID`'s `google:<sub>:` convention extends to Drive file IDs
  (Phase 2's persisted imported-file identity, recon §B) and Gmail message IDs unchanged.
- **Console runbook**: Appendix A already instructs enabling only the Calendar API; Phases 2–3
  add "enable Drive/Gmail API + add scope to consent screen" steps and must resolve the
  restricted-scope verification question (§8).

---

## Appendix A — Google Cloud console setup runbook

Result: an OAuth "Desktop app" client whose ID + secret you paste into
Settings → Meetings → Google Accounts → Google OAuth client. No secrets ship in the repo or app.

1. **Create a project**: <https://console.cloud.google.com/> → project picker → **New project**
   (e.g. `meetingwhisper-personal`). No billing account required for OAuth or Calendar API reads.
2. **Enable the API**: *APIs & Services → Library* → search **Google Calendar API** → **Enable**.
   (Do not enable Drive/Gmail yet — Phases 2–3.)
3. **Configure the consent screen**: *APIs & Services → OAuth consent screen* (newer consoles
   label this **Google Auth Platform → Branding/Audience** — same settings):
   - User type: **External** (personal @gmail.com accounts can't use Internal).
   - App name (e.g. "MeetingWhisper (personal)"), your email for support + developer contact.
   - **Scopes**: add `.../auth/calendar.readonly` (listed under Google Calendar API after step 2)
     plus `openid`, `email`, `profile`. (In Testing mode Google doesn't strictly require
     pre-listing, but listing keeps the config honest for the production switch.)
   - **Audience / Test users**: add every Google account you'll connect (yours + any work
     account) as test users.
4. **Publishing status — decided (spec §8): publish "In production" without verification.**
   Click *Publish app*. For the calendar.readonly (*sensitive*) scope this works without Google
   verification; each account sees an "unverified app" interstitial (*Advanced → Go to
   app*) **once** at connect, and refresh tokens do not auto-expire. Do **not** leave the app in
   **Testing** (the default): there, only listed test users can authorize and **refresh tokens
   expire after 7 days**, flipping every connected account to "Needs attention" weekly. (Phase
   2/3's Drive/Gmail scopes are *restricted* — unverified production apps are blocked for those,
   so that phase revisits Testing-vs-verification; see spec §8.)
5. **Create the client**: *APIs & Services → Credentials → Create credentials → OAuth client ID*
   → Application type **Desktop app** (matches D-G2; do **not** pick iOS — its custom-scheme
   redirect is deprecated by Google) → name it → **Create**. Desktop clients need no redirect URI
   configuration; the loopback `http://127.0.0.1:<any port>` is accepted automatically.
6. **Copy credentials**: note the **Client ID** (`…apps.googleusercontent.com`) and
   **Client secret** (Google treats desktop-app secrets as non-confidential, but we store it in
   the Keychain anyway).
7. **Paste into the app**: Settings → Meetings → **Google Accounts** → *Google OAuth client* →
   paste ID and secret → **Add Google Account…** and complete the browser flow.
8. **Sanity checks**: the consent flow shows the *unverified app* interstitial once per account
   (expected — step 4); token refresh survives an app restart (quit, relaunch, events still
   sync) and does **not** expire after a week (if it does, the consent screen was left in
   Testing); revoking access at <https://myaccount.google.com/permissions> should surface
   "Needs attention" on next sync.
