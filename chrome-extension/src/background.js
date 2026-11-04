/**
 * Service worker: owns every network call to TypeWhisper.
 *
 * The content script deliberately does no fetching. A content script runs in the page's origin, so
 * its requests are CORS-checked against meet.google.com and would be blocked; requests from here are
 * covered by `host_permissions` instead. It also means the page never sees the API token.
 *
 * MV3 evicts this worker aggressively, so nothing that must outlive a respawn lives only in memory:
 * the meeting id, the session start, the unsent segment buffer, the retry backoff and a pending
 * `/end` are all mirrored into `chrome.storage.local` on every change and reloaded on wake. (The
 * `flushing` lock is the one exception — it is per-worker by design.) A respawned worker re-posts to
 * `/v1/meetings/live` with the same session key and the app hands back the same meeting rather than
 * forking a duplicate.
 */

import { getSettings, isLoopbackUrl } from './config.js';
import { appendLog, clearTabStatus, noteApiResult, setTabStatus, workerLog } from './diagnostics.js';

const log = (...args) => workerLog('log', ...args);
const warn = (...args) => workerLog('warn', ...args);

const STORAGE_KEY = 'tw_sessions';
/** What the app last said about itself (the bridge version it ships with), for the popup. */
const APP_STATUS_KEY = 'tw_app_status';
/** This build of the bridge. Chrome runs whatever folder it was loaded from, so it says so. */
const BRIDGE_VERSION = chrome.runtime.getManifest?.().version || 'dev';
const FLUSH_INTERVAL_MS = 4000;
const FLUSH_AT_COUNT = 20;
const MAX_BUFFER = 2000;
const MAX_BACKOFF_MS = 60_000;
// How long the app may hold a command poll open. Chrome kills a worker whose fetch takes 30 s to
// answer, so this stays well under that.
const COMMAND_POLL_WAIT_S = 20;
// How long a command waits for the page's port to come back (it is recycled every few minutes).
const COMMAND_DELIVERY_RETRIES = 10;
const COMMAND_DELIVERY_RETRY_MS = 300;

/**
 * @typedef {object} Session
 * @property {string|null} meetingId
 * @property {string} title
 * @property {string} account
 * @property {string|null} startedAt   the meeting's start — set once, never overwritten on resume
 * @property {any[]} buffer            segments not yet accepted by the app
 * @property {number} failures         consecutive flush failures, driving the backoff
 * @property {number} nextAttemptAt    epoch ms before which the alarm skips this session
 * @property {boolean} flushing        per-worker lock; deliberately never persisted
 * @property {{endedAt: string}|null} pendingEnd  hang-up recorded but `/end` not yet accepted
 * @property {{micMuted: boolean, cameraOff: boolean|null}|null} [controls]  the user's mic/camera
 *   state as last read by the page; in memory only — the page re-announces it on every connect
 */
/** @type {Map<string, Session>} */
let sessions = new Map();
let loaded = false;

async function loadSessions() {
  if (loaded) return;
  const stored = await chrome.storage.local.get(STORAGE_KEY);
  const raw = stored[STORAGE_KEY] || {};
  sessions = new Map(
    Object.entries(raw).map(([key, value]) => [
      key,
      {
        failures: 0,
        nextAttemptAt: 0,
        buffer: [],
        meetingId: null,
        startedAt: null,
        pendingEnd: null,
        ...value,
        // Never restored: `flushing` is a per-worker lock, and a worker that woke up believing a
        // flush from its dead predecessor is still running would never flush again.
        flushing: false,
      },
    ])
  );
  loaded = true;
}

async function persistSessions() {
  const plain = {};
  for (const [key, session] of sessions) {
    plain[key] = {
      meetingId: session.meetingId,
      title: session.title,
      account: session.account,
      startedAt: session.startedAt,
      buffer: session.buffer,
      // Backoff state must survive eviction: MV3 respawns this worker constantly, and a reset
      // counter means hammering localhost every alarm tick while the app is closed.
      failures: session.failures,
      nextAttemptAt: session.nextAttemptAt || 0,
      // So does the intent to end: it is what lets a later cycle close a meeting whose final flush
      // failed. See `endSession`/`tryEnd`.
      pendingEnd: session.pendingEnd || null,
      // For the popup's "last delivered" line only.
      lastFlushAt: session.lastFlushAt || null,
    };
  }
  await chrome.storage.local.set({ [STORAGE_KEY]: plain });
}

function getSession(sessionKey) {
  let session = sessions.get(sessionKey);
  if (!session) {
    session = {
      meetingId: null,
      title: '',
      account: '',
      // Deliberately unset: a *new* session adopts the start the page reports, an existing one
      // keeps its own (see `enqueue`). `ensureMeeting` fills in a fallback if it is still missing.
      startedAt: null,
      buffer: [],
      failures: 0,
      nextAttemptAt: 0,
      flushing: false,
      pendingEnd: null,
    };
    sessions.set(sessionKey, session);
  }
  return session;
}

async function apiFetch(path, body) {
  const settings = await getSettings();
  if (!isLoopbackUrl(settings.baseUrl)) {
    throw new Error(`Refusing non-loopback API URL: ${settings.baseUrl}`);
  }
  const headers = { 'Content-Type': 'application/json' };
  if (settings.apiToken) headers.Authorization = `Bearer ${settings.apiToken}`;

  let response;
  try {
    response = await fetch(`${settings.baseUrl.replace(/\/$/, '')}${path}`, {
      method: 'POST',
      headers,
      body: JSON.stringify(body),
    });
  } catch (error) {
    // The request never got an answer: the app is closed, or its local API is off.
    noteApiResult({ reachable: false, error: `${error.message} (${settings.baseUrl})` });
    throw error;
  }

  if (!response.ok) {
    const text = await response.text().catch(() => '');
    const message = `${response.status} ${response.statusText}: ${text.slice(0, 200)}`;
    noteApiResult({ reachable: true, error: `${path} → ${message}` });
    throw new Error(message);
  }
  noteApiResult({ reachable: true });
  return response.json();
}

/** Create or resume the meeting for this call. Idempotent on `sessionKey`. */
async function ensureMeeting(sessionKey) {
  const session = getSession(sessionKey);
  if (session.meetingId) return session.meetingId;
  if (!session.startedAt) session.startedAt = new Date().toISOString();

  const result = await apiFetch('/v1/meetings/live', {
    session_key: sessionKey,
    title: session.title || sessionKey,
    account: session.account || undefined,
    started_at: session.startedAt,
  });
  session.meetingId = result.id;
  await persistSessions();
  log(`${result.created ? 'created' : 'resumed'} meeting ${result.id} for ${sessionKey}`);
  return session.meetingId;
}

async function enqueue(sessionKey, segments, meta = {}) {
  await loadSessions();
  const session = getSession(sessionKey);
  if (meta.title) session.title = meta.title;
  if (meta.account) session.account = meta.account;
  // Only a session that has no start of its own adopts the page's. A content script that (re)loads
  // mid-call reports the *reload* instant, but this session — and the meeting the app keyed to it —
  // began when the call did; overwriting it would restart the clock the segment timestamps are
  // relative to, folding the rest of the call on top of its own first half.
  if (meta.startedAt && !session.startedAt) session.startedAt = meta.startedAt;

  if (session.pendingEnd) {
    // Something is writing to this session again — a rejoin under the same call code, or a reload
    // right after an end we could not deliver. Cancel the pending end so the retry cycle does not
    // close a meeting that is live again.
    log(`${sessionKey} is active again; cancelling its pending end`);
    session.pendingEnd = null;
  }

  session.buffer.push(...segments);
  // Drop from the *front* if we ever overflow: the app already has the older material, and losing
  // the newest captions would be the more visible failure.
  if (session.buffer.length > MAX_BUFFER) {
    session.buffer.splice(0, session.buffer.length - MAX_BUFFER);
  }
  await persistSessions();

  if (session.buffer.length >= FLUSH_AT_COUNT) await flush(sessionKey);
}

async function flush(sessionKey) {
  await loadSessions();
  const session = sessions.get(sessionKey);
  if (!session || session.flushing || session.buffer.length === 0) return;

  session.flushing = true;
  const batch = session.buffer.slice(0, 500);
  try {
    const meetingId = await ensureMeeting(sessionKey);
    await apiFetch(`/v1/meetings/live/${meetingId}/segments`, { segments: batch });
    session.buffer.splice(0, batch.length);
    session.failures = 0;
    session.nextAttemptAt = 0;
    session.lastFlushAt = new Date().toISOString();
    await persistSessions();
    await setBadge('ok');
  } catch (error) {
    session.failures += 1;
    session.nextAttemptAt = Date.now() + Math.min(2 ** session.failures * 1000, MAX_BACKOFF_MS);
    // A 404 means the meeting was deleted in the app; forget it and let the next flush recreate one.
    if (String(error.message).startsWith('404')) session.meetingId = null;
    // Persist the backoff itself, not just the buffer — otherwise the next respawned worker starts
    // over at zero failures and retries immediately.
    await persistSessions();
    warn(`flush failed (attempt ${session.failures}):`, error.message);
    await setBadge('error');
  } finally {
    session.flushing = false;
  }
}

/**
 * Link a call that has no meeting yet, with or without captions. The meeting is normally created on
 * `session-start`; when that failed (the app was closed at join), a call with captions off would
 * otherwise never retry — the flush only runs for buffered segments — and the app would never learn
 * the user is in a meeting (no presence, no floating mute button). Runs on the live port's timer
 * only, so a session left behind by a crashed tab is never resurrected. Respects the flush backoff.
 * Returns true when this call created or resumed the meeting.
 */
async function ensureLinked(sessionKey) {
  await loadSessions();
  const session = sessions.get(sessionKey);
  if (!session || session.meetingId || session.pendingEnd || session.flushing) return false;
  if (session.buffer.length > 0) return false; // the flush links it on its way
  if (session.nextAttemptAt && Date.now() < session.nextAttemptAt) return false;
  try {
    await ensureMeeting(sessionKey);
    session.failures = 0;
    session.nextAttemptAt = 0;
    await persistSessions();
    if (session.controls) await reportControls(sessionKey, session.controls);
    return true;
  } catch (error) {
    session.failures += 1;
    session.nextAttemptAt = Date.now() + Math.min(2 ** session.failures * 1000, MAX_BACKOFF_MS);
    await persistSessions();
    warn(`could not create the meeting for ${sessionKey} (attempt ${session.failures}):`, error.message);
    return false;
  }
}

async function endSession(sessionKey) {
  await loadSessions();
  const session = sessions.get(sessionKey);
  if (!session) return;

  // Record the *intent* to end before flushing, and persist it: the common failure is the Mac app
  // being closed at hang-up, which fails both the final flush and the `/end` — and with the marker
  // only in memory (or only implied by "we got here"), a worker eviction right after would leave the
  // meeting `.live` forever with nothing left to retry it.
  if (!session.pendingEnd) session.pendingEnd = { endedAt: new Date().toISOString() };
  await persistSessions();

  await flush(sessionKey);
  await tryEnd(sessionKey);
  await persistSessions();
  await setBadge('idle');
}

/**
 * Close a meeting whose buffer has drained. Uses the timestamp recorded when the user actually left,
 * never `Date.now()` — a retry hours later must not claim the call ran that long. The session is
 * deleted only on success, so a failure is simply retried by the next alarm cycle.
 */
async function tryEnd(sessionKey) {
  const session = sessions.get(sessionKey);
  if (!session?.pendingEnd || session.buffer.length > 0) return;
  if (!session.meetingId) {
    // Nothing was ever created server-side (the call ended before a single flush succeeded and the
    // buffer is empty), so there is nothing to end — just stop tracking it.
    sessions.delete(sessionKey);
    return;
  }
  try {
    await apiFetch(`/v1/meetings/live/${session.meetingId}/end`, {
      ended_at: session.pendingEnd.endedAt,
    });
    sessions.delete(sessionKey);
  } catch (error) {
    // Leave the session (and its marker) in place for the next cycle; the meeting stays `live` in
    // the app until then, which the user can also close manually.
    warn('end failed; will retry:', error.message);
  }
}

/**
 * Tell the app the call is still open. The app only counts a caption session as "in a meeting"
 * while it keeps hearing from it, so this is what carries a quiet call between captions — and its
 * absence is what lets the app notice a call whose `/end` never arrived.
 *
 * Fire-and-forget by design: nothing is queued, persisted, or retried, and a failure leaves the
 * flush backoff alone. A 404 is not acted on either — an app build without this route answers 404
 * too, and forgetting the meeting id on that would fork a duplicate meeting on the next flush.
 */
async function heartbeat(sessionKey, participants) {
  await loadSessions();
  const session = sessions.get(sessionKey);
  if (!session?.meetingId || session.pendingEnd) return;
  // The app is known to be unreachable; the flush retry will find out when it is back.
  if (session.nextAttemptAt && Date.now() < session.nextAttemptAt) return;
  try {
    await apiFetch(
      `/v1/meetings/live/${session.meetingId}/heartbeat`,
      Number.isInteger(participants) ? { participants } : {}
    );
  } catch (error) {
    warn('heartbeat failed:', error.message);
  }
}

/**
 * Tell the app which build of the bridge this is, and remember which one the app ships with — so
 * the app's Settings and this extension's popup can both say when the loaded code is stale.
 * Fire-and-forget: an app build that predates the route answers 404 and nothing depends on it.
 */
async function hello() {
  try {
    const result = await apiFetch('/v1/bridge/hello', { version: BRIDGE_VERSION });
    await chrome.storage.local.set({
      [APP_STATUS_KEY]: { expectedVersion: result?.expected_version || null, checkedAt: Date.now() },
    });
  } catch {
    // Unreachable or too old to answer; the flush path reports real connection trouble.
  }
}

/** The wire shape of the mic/camera state, shared by the report and the poll. */
function controlsBody(controls) {
  if (!controls) return {};
  const body = { mic_muted: controls.micMuted };
  if (typeof controls.cameraOff === 'boolean') body.camera_off = controls.cameraOff;
  return body;
}

/**
 * Tell the app the user's mic/camera state (`controls`), or that this call can no longer be
 * controlled (`null`). Fire-and-forget like the heartbeat: the command poll re-asserts the current
 * state every few seconds anyway, so a lost report heals itself.
 */
async function reportControls(sessionKey, controls) {
  await loadSessions();
  const session = sessions.get(sessionKey);
  if (!session) return;
  session.controls = controls || null;
  if (!session.meetingId || session.pendingEnd) return;
  if (session.nextAttemptAt && Date.now() < session.nextAttemptAt) return;
  try {
    await apiFetch(`/v1/meetings/live/${session.meetingId}/controls`, controlsBody(session.controls));
  } catch (error) {
    warn('controls report failed:', error.message);
  }
}

/**
 * Ask the app for the next command from its floating call controls. The app holds the request open
 * until there is one (or the wait runs out), which is what makes a click there feel instant without
 * the app being able to push to an extension. Returns the commands, or `null` when this session
 * has nothing to poll for (not linked to a meeting yet, already hung up, or call control is off).
 * Throws when the app cannot be reached — the caller backs off.
 */
async function pollCommands(sessionKey) {
  await loadSessions();
  const session = sessions.get(sessionKey);
  if (!session?.meetingId || session.pendingEnd || !session.controls) return null;
  const result = await apiFetch(`/v1/meetings/live/${session.meetingId}/commands/poll`, {
    wait_seconds: COMMAND_POLL_WAIT_S,
    ...controlsBody(session.controls),
  });
  return Array.isArray(result?.commands) ? result.commands : [];
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** The page's current port per call — where commands are delivered. Per-worker, never persisted. */
const livePorts = new Map();
/** Calls with a command loop running in this worker. */
const commandLoops = new Set();

/** Bring the call's tab and window to the front. Needs no `tabs` permission: the port names its own tab. */
async function focusCallTab(port) {
  const tab = port.sender?.tab;
  if (!tab?.id) return;
  try {
    await chrome.tabs.update(tab.id, { active: true });
    if (tab.windowId != null) await chrome.windows.update(tab.windowId, { focused: true });
  } catch (error) {
    warn('could not focus the call tab:', error.message);
  }
}

async function deliverCommand(sessionKey, command) {
  for (let attempt = 0; attempt < COMMAND_DELIVERY_RETRIES; attempt += 1) {
    const port = livePorts.get(sessionKey);
    if (port) {
      if (command.action === 'focus') {
        await focusCallTab(port);
        return;
      }
      try {
        port.postMessage({ type: 'command', command });
        return;
      } catch {
        // The port died between the lookup and the send; wait for its replacement.
      }
    }
    await sleep(COMMAND_DELIVERY_RETRY_MS);
  }
  warn(`dropped "${command.action}": the call's page is not connected`);
}

/**
 * One loop per call, for as long as its page is connected and reporting mic/camera state. It is
 * tied to the call rather than to a port so the page's periodic port recycle never strands a
 * command that came back on the old port's request.
 */
async function runCommandLoop(sessionKey) {
  if (commandLoops.has(sessionKey)) return;
  commandLoops.add(sessionKey);
  let failures = 0;
  try {
    for (;;) {
      if (!livePorts.has(sessionKey)) {
        // Either the periodic recycle (a new port follows at once) or the tab is gone.
        await sleep(COMMAND_DELIVERY_RETRIES * COMMAND_DELIVERY_RETRY_MS);
        if (!livePorts.has(sessionKey)) return;
      }
      try {
        const commands = await pollCommands(sessionKey);
        if (commands === null) {
          // Hung up, or call control switched off: stop (a new `controls` report restarts us).
          // Otherwise the meeting is just not linked yet — the session start is still in flight.
          const session = sessions.get(sessionKey);
          if (!session || session.pendingEnd || !session.controls) return;
          await sleep(1000);
          continue;
        }
        failures = 0;
        for (const command of commands) await deliverCommand(sessionKey, command);
      } catch (error) {
        // The app is closed, or too old to know this route: retry ever more slowly, never spin.
        failures += 1;
        await sleep(Math.min(2 ** failures * 1000, MAX_BACKOFF_MS));
      }
    }
  } finally {
    commandLoops.delete(sessionKey);
  }
}

async function setBadge(state) {
  const map = {
    ok: { text: '●', color: '#2e7d32' },
    error: { text: '!', color: '#c62828' },
    idle: { text: '', color: '#000000' },
  };
  const badge = map[state] || map.idle;
  try {
    await chrome.action.setBadgeText({ text: badge.text });
    await chrome.action.setBadgeBackgroundColor({ color: badge.color });
  } catch {
    // Badge is cosmetic; never let it break a flush.
  }
}

// Periodic flush: catches buffers that never reached FLUSH_AT_COUNT, retries after failures, and
// retries the `/end` of a session that hung up while the app was unreachable.
chrome.alarms.create('tw-flush', { periodInMinutes: 1 });
chrome.alarms.onAlarm.addListener(async (alarm) => {
  if (alarm.name !== 'tw-flush') return;
  await loadSessions();
  for (const [key, session] of sessions) {
    // Exponential backoff on a failing endpoint (the app being closed is the common case) so we do
    // not retry every minute forever. The buffer is safe on disk in the meantime.
    if (session.nextAttemptAt && Date.now() < session.nextAttemptAt) continue;
    await flush(key);
    if (session.pendingEnd) {
      await tryEnd(key);
      await persistSessions();
    }
  }
});

/**
 * The content script holds this port open for the life of the call, which is also what keeps this
 * worker from being evicted mid-meeting. It reconnects every few minutes because Chrome caps a
 * port's lifetime.
 */
chrome.runtime.onConnect.addListener((port) => {
  if (port.name !== 'tw-meet') return;
  let sessionKey = null;
  const announceReady = () => {
    const session = sessionKey && sessions.get(sessionKey);
    if (!session?.meetingId) return;
    try {
      port.postMessage({ type: 'session-ready', meetingId: session.meetingId, startedAt: session.startedAt });
    } catch {
      // The port is gone; the next connect re-announces the session and gets its own answer.
    }
  };
  let flushTimer = setInterval(async () => {
    if (!sessionKey) return;
    await flush(sessionKey);
    if (await ensureLinked(sessionKey)) announceReady();
  }, FLUSH_INTERVAL_MS);

  port.onMessage.addListener(async (message) => {
    try {
      switch (message.type) {
        case 'session-start':
          sessionKey = message.sessionKey;
          // Every (re)connect, so the app's "which bridge is connected" stays current.
          hello();
          await loadSessions();
          getSession(sessionKey);
          await enqueue(sessionKey, [], {
            title: message.title,
            account: message.account,
            startedAt: message.startedAt,
          });
          // No caption is needed for this: the meeting exists from the moment the call is joined, so
          // presence and the floating mute button work on a call with captions off.
          await ensureMeeting(sessionKey);
          // Report the start we actually keyed the meeting to, not the one the page just sent: on a
          // resumed session they differ, and the content script re-bases its caption timestamps on
          // this value so they stay relative to the meeting (see `adoptSessionStart`).
          announceReady();
          // A `controls` report that raced ahead of the meeting was kept but not sent; send it now.
          if (sessions.get(sessionKey)?.controls) {
            await reportControls(sessionKey, sessions.get(sessionKey).controls);
          }
          break;
        case 'segments':
          sessionKey = message.sessionKey || sessionKey;
          if (message.segments?.length) await enqueue(sessionKey, message.segments);
          break;
        case 'heartbeat':
          sessionKey = message.sessionKey || sessionKey;
          if (sessionKey) await heartbeat(sessionKey, message.participants);
          break;
        case 'controls':
          sessionKey = message.sessionKey || sessionKey;
          if (!sessionKey) break;
          livePorts.set(sessionKey, port);
          await reportControls(sessionKey, {
            micMuted: message.micMuted === true,
            cameraOff: typeof message.cameraOff === 'boolean' ? message.cameraOff : null,
          });
          runCommandLoop(sessionKey);
          break;
        case 'controls-off':
          sessionKey = message.sessionKey || sessionKey;
          if (sessionKey) await reportControls(sessionKey, null);
          break;
        case 'session-end':
          // Take the key from the message like `segments` does: a `session-end` that had to wait in
          // the content script's outbox arrives over a *fresh* port, which has no key of its own —
          // dropping it there would leave the meeting live with nothing to retry.
          sessionKey = message.sessionKey || sessionKey;
          if (sessionKey) await endSession(sessionKey);
          break;
        default:
          break;
      }
    } catch (error) {
      warn('port message failed:', error.message);
      port.postMessage({ type: 'error', message: error.message });
    }
  });

  port.onDisconnect.addListener(() => {
    clearInterval(flushTimer);
    flushTimer = null;
    if (sessionKey && livePorts.get(sessionKey) === port) livePorts.delete(sessionKey);
    // Do not end the session here: a disconnect is usually just the periodic reconnect or a worker
    // recycle, not the user leaving the call. `session-end` is explicit.
    if (sessionKey) flush(sessionKey);
  });
});

/**
 * Diagnostics from the content scripts — sent with `runtime.sendMessage` rather than over the
 * call's port, because they matter most exactly when there is no call (and so no port): the popup
 * must be able to say why nothing started.
 */
chrome.runtime.onMessage?.addListener((message, sender) => {
  if (message?.type === 'tw-status') setTabStatus(sender.tab?.id, message.status);
  if (message?.type === 'tw-log' && typeof message.line === 'string') appendLog('[tw-meet]', message.line);
  return false;
});
chrome.tabs?.onRemoved?.addListener((tabId) => clearTabStatus(tabId));
// A tab that loads a new document drops its old status: a Meet page's content script reports again
// once loaded, and any other site must not keep showing the last call's state. (`status` needs no
// `tabs` permission; only the URL would.)
chrome.tabs?.onUpdated?.addListener((tabId, info) => {
  if (info.status === 'loading') clearTabStatus(tabId);
});

// Exported for `node --test` only — in the browser this file is driven entirely by the listeners
// above. The queueing rules (what is persisted, when the backoff applies, when a meeting is ended)
// are the parts worth regression-testing, and they need no DOM.
export {
  sessions,
  loadSessions,
  persistSessions,
  getSession,
  enqueue,
  flush,
  heartbeat,
  endSession,
  ensureLinked,
  tryEnd,
  reportControls,
  pollCommands,
  hello,
};
