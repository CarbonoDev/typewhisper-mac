/**
 * Service worker: owns every network call to TypeWhisper.
 *
 * The content script deliberately does no fetching. A content script runs in the page's origin, so
 * its requests are CORS-checked against meet.google.com and would be blocked; requests from here are
 * covered by `host_permissions` instead. It also means the page never sees the API token.
 *
 * MV3 evicts this worker aggressively, so nothing lives only in memory: the meeting id and the
 * unsent segment buffer are mirrored into `chrome.storage.local` on every change and reloaded on
 * wake. A respawned worker re-posts to `/v1/meetings/live` with the same session key and the app
 * hands back the same meeting rather than forking a duplicate.
 */

import { getSettings, isLoopbackUrl } from './config.js';

const STORAGE_KEY = 'tw_sessions';
const FLUSH_INTERVAL_MS = 4000;
const FLUSH_AT_COUNT = 20;
const MAX_BUFFER = 2000;
const MAX_BACKOFF_MS = 60_000;

/** @type {Map<string, {meetingId: string|null, title: string, startedAt: string, buffer: any[], failures: number, flushing: boolean}>} */
let sessions = new Map();
let loaded = false;

async function loadSessions() {
  if (loaded) return;
  const stored = await chrome.storage.local.get(STORAGE_KEY);
  const raw = stored[STORAGE_KEY] || {};
  sessions = new Map(
    Object.entries(raw).map(([key, value]) => [
      key,
      { failures: 0, flushing: false, buffer: [], meetingId: null, ...value },
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
      startedAt: session.startedAt,
      buffer: session.buffer,
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
      startedAt: new Date().toISOString(),
      buffer: [],
      failures: 0,
      flushing: false,
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

  const response = await fetch(`${settings.baseUrl.replace(/\/$/, '')}${path}`, {
    method: 'POST',
    headers,
    body: JSON.stringify(body),
  });

  if (!response.ok) {
    const text = await response.text().catch(() => '');
    throw new Error(`${response.status} ${response.statusText}: ${text.slice(0, 200)}`);
  }
  return response.json();
}

/** Create or resume the meeting for this call. Idempotent on `sessionKey`. */
async function ensureMeeting(sessionKey) {
  const session = getSession(sessionKey);
  if (session.meetingId) return session.meetingId;

  const result = await apiFetch('/v1/meetings/live', {
    session_key: sessionKey,
    title: session.title || sessionKey,
    started_at: session.startedAt,
  });
  session.meetingId = result.id;
  await persistSessions();
  console.log(`[tw] ${result.created ? 'created' : 'resumed'} meeting ${result.id} for ${sessionKey}`);
  return session.meetingId;
}

async function enqueue(sessionKey, segments, meta = {}) {
  await loadSessions();
  const session = getSession(sessionKey);
  if (meta.title) session.title = meta.title;
  if (meta.startedAt) session.startedAt = meta.startedAt;

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
    await persistSessions();
    await setBadge('ok');
  } catch (error) {
    session.failures += 1;
    session.nextAttemptAt = Date.now() + Math.min(2 ** session.failures * 1000, MAX_BACKOFF_MS);
    // A 404 means the meeting was deleted in the app; forget it and let the next flush recreate one.
    if (String(error.message).startsWith('404')) session.meetingId = null;
    console.warn(`[tw] flush failed (attempt ${session.failures}):`, error.message);
    await setBadge('error');
  } finally {
    session.flushing = false;
  }
}

async function endSession(sessionKey) {
  await loadSessions();
  const session = sessions.get(sessionKey);
  if (!session) return;

  await flush(sessionKey);
  if (session.meetingId && session.buffer.length === 0) {
    try {
      await apiFetch(`/v1/meetings/live/${session.meetingId}/end`, {
        ended_at: new Date().toISOString(),
      });
      sessions.delete(sessionKey);
    } catch (error) {
      // Leave the session in place so a later flush can retry; the meeting simply stays `live`
      // in the app until then, which the user can close manually.
      console.warn('[tw] end failed:', error.message);
    }
  }
  await persistSessions();
  await setBadge('idle');
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

// Periodic flush: catches buffers that never reached FLUSH_AT_COUNT, and retries after failures.
chrome.alarms.create('tw-flush', { periodInMinutes: 1 });
chrome.alarms.onAlarm.addListener(async (alarm) => {
  if (alarm.name !== 'tw-flush') return;
  await loadSessions();
  for (const [key, session] of sessions) {
    // Exponential backoff on a failing endpoint (the app being closed is the common case) so we do
    // not retry every minute forever. The buffer is safe on disk in the meantime.
    if (session.nextAttemptAt && Date.now() < session.nextAttemptAt) continue;
    await flush(key);
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
  let flushTimer = setInterval(() => sessionKey && flush(sessionKey), FLUSH_INTERVAL_MS);

  port.onMessage.addListener(async (message) => {
    try {
      switch (message.type) {
        case 'session-start':
          sessionKey = message.sessionKey;
          await loadSessions();
          getSession(sessionKey);
          await enqueue(sessionKey, [], {
            title: message.title,
            startedAt: message.startedAt,
          });
          await ensureMeeting(sessionKey);
          port.postMessage({ type: 'session-ready', meetingId: sessions.get(sessionKey)?.meetingId });
          break;
        case 'segments':
          sessionKey = message.sessionKey || sessionKey;
          if (message.segments?.length) await enqueue(sessionKey, message.segments);
          break;
        case 'session-end':
          if (sessionKey) await endSession(sessionKey);
          break;
        default:
          break;
      }
    } catch (error) {
      console.warn('[tw] port message failed:', error.message);
      port.postMessage({ type: 'error', message: error.message });
    }
  });

  port.onDisconnect.addListener(() => {
    clearInterval(flushTimer);
    flushTimer = null;
    // Do not end the session here: a disconnect is usually just the periodic reconnect or a worker
    // recycle, not the user leaving the call. `session-end` is explicit.
    if (sessionKey) flush(sessionKey);
  });
});
