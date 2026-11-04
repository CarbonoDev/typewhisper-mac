/**
 * Diagnostics shared by the worker and the popup: a ring buffer of recent `[tw]` / `[tw-meet]` log
 * lines, the per-tab status each content script reports, and whether the app answered lately.
 *
 * Kept in `chrome.storage.session` (cleared with the browser session, never synced, readable by the
 * popup) so it survives the worker's frequent evictions; an in-memory fallback covers environments
 * without it (`node --test`). Nothing here talks to the network.
 *
 * The plain-words rendering (`describeStatus`) and the "Copy diagnostics" text (`formatDiagnostics`)
 * are pure, so the popup and the tests share them.
 */

export const LOG_KEY = 'tw_log';
export const TAB_STATUS_KEY = 'tw_tab_status';
export const APP_HEALTH_KEY = 'tw_app_health';
export const MAX_LOG_LINES = 100;

const memory = {};
function area() {
  const session = globalThis.chrome?.storage?.session;
  if (session) return session;
  return {
    async get(key) {
      return key in memory ? { [key]: memory[key] } : {};
    },
    async set(patch) {
      Object.assign(memory, JSON.parse(JSON.stringify(patch)));
    },
  };
}

let lines = null;
let tabs = null;
let health = null;
// Serialize read-modify-write so concurrent loggers never drop each other's lines.
let chain = Promise.resolve();
const serialized = (fn) => (chain = chain.then(fn, fn));

async function load() {
  if (lines && tabs && health) return;
  const store = area();
  const [l, t, h] = await Promise.all([store.get(LOG_KEY), store.get(TAB_STATUS_KEY), store.get(APP_HEALTH_KEY)]);
  lines = lines || l[LOG_KEY] || [];
  tabs = tabs || t[TAB_STATUS_KEY] || {};
  health = health || h[APP_HEALTH_KEY] || { reachable: null, lastError: null, lastOkAt: null, lastErrorAt: null };
}

/** Append one line (`source` is `[tw]` or `[tw-meet]`), keeping the newest MAX_LOG_LINES. */
export function appendLog(source, text) {
  return serialized(async () => {
    await load();
    lines.push(`${new Date().toISOString()} ${source} ${String(text).slice(0, 2000)}`);
    if (lines.length > MAX_LOG_LINES) lines.splice(0, lines.length - MAX_LOG_LINES);
    await area().set({ [LOG_KEY]: lines });
  });
}

function formatArgs(args) {
  return args
    .map((arg) => {
      if (typeof arg === 'string') return arg;
      if (arg instanceof Error) return arg.message;
      try {
        return JSON.stringify(arg);
      } catch {
        return String(arg);
      }
    })
    .join(' ');
}

/** The worker's logger: console plus the ring buffer. `level` is `log` or `warn`. */
export function workerLog(level, ...args) {
  (console[level] || console.log)('[tw]', ...args);
  appendLog('[tw]', formatArgs(args));
}

/**
 * Record the outcome of one call to the app. `reachable` is false only when the request itself
 * failed (app closed, API off); an HTTP error means the app is there but refused (`error` says why).
 * Logs on transitions only.
 */
export function noteApiResult({ reachable, error = null }) {
  return serialized(async () => {
    await load();
    const before = { ...health };
    const now = new Date().toISOString();
    health.reachable = reachable;
    if (reachable && !error) {
      health.lastOkAt = now;
      health.lastError = null;
    } else {
      health.lastError = error;
      health.lastErrorAt = now;
    }
    if (before.reachable !== reachable) {
      const line = reachable
        ? before.reachable === false
          ? 'app is reachable again'
          : 'app reachable'
        : `app unreachable: ${error}`;
      (reachable ? console.log : console.warn)('[tw]', line);
      lines.push(`${now} [tw] ${line}`);
      if (lines.length > MAX_LOG_LINES) lines.splice(0, lines.length - MAX_LOG_LINES);
      await area().set({ [LOG_KEY]: lines });
    }
    if (JSON.stringify(before) !== JSON.stringify(health)) await area().set({ [APP_HEALTH_KEY]: health });
  });
}

export function setTabStatus(tabId, status) {
  if (tabId == null) return Promise.resolve();
  return serialized(async () => {
    await load();
    tabs[tabId] = { ...status, receivedAt: new Date().toISOString() };
    await area().set({ [TAB_STATUS_KEY]: tabs });
  });
}

export function clearTabStatus(tabId) {
  return serialized(async () => {
    await load();
    if (!(tabId in tabs)) return;
    delete tabs[tabId];
    await area().set({ [TAB_STATUS_KEY]: tabs });
  });
}

/** Everything the popup needs, straight from storage (the popup has no access to worker memory). */
export async function readDiagnostics() {
  const store = area();
  const [l, t, h] = await Promise.all([store.get(LOG_KEY), store.get(TAB_STATUS_KEY), store.get(APP_HEALTH_KEY)]);
  return { lines: l[LOG_KEY] || [], tabs: t[TAB_STATUS_KEY] || {}, health: h[APP_HEALTH_KEY] || null };
}

/** For tests: forget the in-memory caches so the next call re-reads storage. */
export function resetForTests() {
  lines = null;
  tabs = null;
  health = null;
  for (const key of Object.keys(memory)) delete memory[key];
}

const ago = (iso, now) => {
  if (!iso) return 'never';
  const seconds = Math.max(0, Math.round((now - Date.parse(iso)) / 1000));
  if (seconds < 60) return `${seconds}s ago`;
  if (seconds < 3600) return `${Math.round(seconds / 60)} min ago`;
  return `${Math.round(seconds / 3600)} h ago`;
};

/**
 * Plain-words status for one tab. `status` is the content script's report (or undefined), `session`
 * the worker's persisted session for its call, `health` the app's last answer. Returns
 * `{ headline, lines }` — the headline says what is happening, the lines say why.
 */
export function describeStatus({ status, session, health, now = Date.now() } = {}) {
  const lines = [];
  if (!status) {
    return {
      headline: 'Nothing from Meet Bridge in this tab.',
      lines: ['Open a meet.google.com call in this tab. If you are on one, reload the tab: the page was opened before the extension was (re)loaded.'],
    };
  }
  if (status.enabled === false) return { headline: 'Capture is off.', lines: [] };
  if (!status.onCallPath) {
    return { headline: 'Not on a call page.', lines: ['Meet Bridge wakes up on a meet.google.com/abc-defg-hij (or /meet/abc-defg-hij) call page.'] };
  }

  let headline;
  if (!status.inCall) {
    headline = status.lobby ? 'Waiting in the lobby — not joined yet.' : 'On a Meet call page, but not detected as in the call.';
    if (status.whyNot) lines.push(status.whyNot);
  } else if (!status.meetingId) {
    headline = status.sessionError
      ? 'In the call, but the app has not taken the meeting.'
      : 'In the call — creating the meeting in the app…';
    if (status.sessionError) lines.push(`Last error: ${status.sessionError}`);
  } else {
    headline = 'In the call — meeting linked in the app.';
  }

  if (status.inCall) {
    lines.push(`In-call signal: ${status.inCallVia}.`);
    lines.push(
      status.captionsFound
        ? `Captions: reading (${status.captionsVia}); ${status.segmentsSent} segment(s) sent, last ${ago(status.lastSegmentAt, now)}.`
        : 'Captions: no caption region — turn on captions (CC) for a speaker-attributed transcript. The meeting is recorded either way.'
    );
    if (status.micReadable === true) lines.push(`Mic toggle: readable (${status.micVia}) — the floating mute button can work.`);
    else if (status.micReadable === false) lines.push('Mic toggle: not readable — the floating mute button stays hidden.');
  }
  if (session) {
    const queued = session.buffer?.length ?? 0;
    lines.push(`Queue: ${queued} segment(s) waiting; last delivered ${ago(session.lastFlushAt, now)}.`);
  }
  if (health) {
    if (health.reachable === false) lines.push(`App: unreachable since ${ago(health.lastErrorAt, now)} (${health.lastError}).`);
    else if (health.lastError) lines.push(`App: answered with an error ${ago(health.lastErrorAt, now)}: ${health.lastError}.`);
    else if (health.reachable) lines.push(`App: reachable, last answer ${ago(health.lastOkAt, now)}.`);
  }
  return { headline, lines };
}

/** The text "Copy diagnostics" puts on the clipboard. */
export function formatDiagnostics({ version, tabId, status, session, health, lines = [], now = Date.now() }) {
  const described = describeStatus({ status, session, health, now });
  const sessionSummary = session
    ? {
        meetingId: session.meetingId,
        queued: session.buffer?.length ?? 0,
        failures: session.failures,
        lastFlushAt: session.lastFlushAt || null,
        pendingEnd: session.pendingEnd || null,
      }
    : null;
  return [
    `Meet Bridge v${version} diagnostics — ${new Date(now).toISOString()}`,
    `tab: ${tabId ?? 'unknown'}`,
    '',
    described.headline,
    ...described.lines.map((line) => `  ${line}`),
    '',
    `status: ${JSON.stringify(status || null, null, 2)}`,
    `session: ${JSON.stringify(sessionSummary, null, 2)}`,
    `app: ${JSON.stringify(health || null, null, 2)}`,
    '',
    `last ${lines.length} log line(s):`,
    ...lines,
  ].join('\n');
}
