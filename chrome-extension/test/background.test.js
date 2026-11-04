const test = require('node:test');
const assert = require('node:assert');

/**
 * Service-worker queueing rules, driven directly.
 *
 * `background.js` is an ES module that registers its listeners at import time, so the `chrome` and
 * `fetch` stubs go in first and the module is pulled in with a dynamic import. The tests then call
 * the queue functions the way the port/alarm listeners do — no browser involved.
 */

const STORAGE_KEY = 'tw_sessions';

/** Fake `chrome.storage.local`, plus a record of every API call the worker made. */
let storage = {};
let apiCalls = [];
/** The worker's `runtime.onConnect` listener, captured so a test can drive a page's port. */
let connectListener = null;
/** Swap to make the local API fail (the app being closed is the case that matters). */
let apiUp = true;

globalThis.chrome = {
  storage: {
    local: {
      async get(query) {
        if (typeof query === 'string') {
          return Object.prototype.hasOwnProperty.call(storage, query) ? { [query]: storage[query] } : {};
        }
        const out = {};
        for (const [key, fallback] of Object.entries(query || {})) {
          out[key] = Object.prototype.hasOwnProperty.call(storage, key) ? storage[key] : fallback;
        }
        return out;
      },
      async set(patch) {
        // Round-trip through JSON like the real storage does, so anything unserializable would show.
        Object.assign(storage, JSON.parse(JSON.stringify(patch)));
      },
    },
  },
  alarms: { create() {}, onAlarm: { addListener() {} } },
  runtime: {
    onConnect: {
      addListener(listener) {
        connectListener = listener;
      },
    },
    getManifest: () => ({ version: '9.9.9' }),
  },
  action: { async setBadgeText() {}, async setBadgeBackgroundColor() {} },
};

globalThis.fetch = async (url, init) => {
  apiCalls.push({ url, body: JSON.parse(init.body) });
  // A real long-poll holds; an instant answer would spin the command loop.
  if (url.endsWith('/commands/poll')) await new Promise((resolve) => setTimeout(resolve, 20));
  if (!apiUp) {
    return { ok: false, status: 500, statusText: 'Internal Server Error', async text() { return 'down'; } };
  }
  return { ok: true, async json() { return { id: 'meeting-1', created: true }; } };
};

let bg;
test.before(async () => {
  bg = await import('../src/background.js');
});

const segment = (text) => ({ speaker: 'Ana', text, start: 0, end: 1 });
const persisted = (key) => storage[STORAGE_KEY][key];

test.beforeEach(() => {
  apiCalls = [];
  apiUp = true;
});

test('a resumed session keeps its original start instead of the page reload instant', async () => {
  const key = 'aaa-bbbb-ccc';
  await bg.enqueue(key, [], { title: 'Standup', startedAt: '2026-08-12T09:00:00.000Z' });
  // A mid-call page reload announces the session again, reporting *its* start.
  await bg.enqueue(key, [], { title: 'Standup', startedAt: '2026-08-12T09:31:00.000Z' });

  assert.equal(bg.sessions.get(key).startedAt, '2026-08-12T09:00:00.000Z');
  assert.equal(persisted(key).startedAt, '2026-08-12T09:00:00.000Z');
});

test('a failed flush persists its backoff so a respawned worker does not retry immediately', async () => {
  const key = 'bbb-cccc-ddd';
  apiUp = false;
  await bg.enqueue(key, [segment('we should ship it')], { startedAt: '2026-08-12T09:00:00.000Z' });
  await bg.flush(key);

  const stored = persisted(key);
  assert.equal(stored.failures, 1, 'the failure count must survive worker eviction');
  assert.ok(stored.nextAttemptAt > Date.now(), 'so must the next-attempt time');
  assert.equal(stored.buffer.length, 1, 'and the unsent segment stays buffered');
  assert.ok(!('flushing' in stored), 'the per-worker lock must never be persisted');

  // Once the app is back, the flush succeeds and the backoff is cleared.
  apiUp = true;
  await bg.flush(key);
  assert.equal(persisted(key).failures, 0);
  assert.equal(persisted(key).nextAttemptAt, 0);
  assert.equal(persisted(key).buffer.length, 0);
});

test('an end that could not be delivered is retried later with the original timestamp', async () => {
  const key = 'ccc-dddd-eee';
  await bg.enqueue(key, [segment('closing thought')], { startedAt: '2026-08-12T09:00:00.000Z' });

  // The Mac app is closed as the user hangs up: both the final flush and the end fail.
  apiUp = false;
  await bg.endSession(key);
  const marker = persisted(key).pendingEnd;
  assert.ok(marker?.endedAt, 'the intent to end must be persisted, not just attempted');
  assert.ok(bg.sessions.has(key), 'the session stays until the app confirms the end');

  // Next alarm cycle, with the app running again — exactly what the alarm listener does per
  // session: flush, retry the end, persist.
  apiUp = true;
  apiCalls = [];
  await bg.flush(key);
  await bg.tryEnd(key);
  await bg.persistSessions();

  const end = apiCalls.find((call) => call.url.endsWith('/end'));
  assert.ok(end, 'the end is retried once the buffer drains');
  assert.equal(end.body.ended_at, marker.endedAt, 'with the recorded hang-up time, not "now"');
  assert.equal(bg.sessions.has(key), false, 'and only then is the session forgotten');
  assert.equal(persisted(key), undefined);
});

test('a session that becomes active again cancels its pending end', async () => {
  const key = 'ddd-eeee-fff';
  await bg.enqueue(key, [segment('first half')], { startedAt: '2026-08-12T09:00:00.000Z' });

  apiUp = false;
  await bg.endSession(key);
  assert.ok(persisted(key).pendingEnd);

  // The user rejoins the same call code before the retry lands.
  apiUp = true;
  await bg.enqueue(key, [segment('back again')]);
  assert.equal(bg.sessions.get(key).pendingEnd, null);
  assert.equal(persisted(key).pendingEnd, null);

  // So the retry step is a no-op and the meeting stays live.
  apiCalls = [];
  await bg.tryEnd(key);
  assert.equal(apiCalls.length, 0);
  assert.ok(bg.sessions.has(key));
});

test('a heartbeat reports the open call with its head count, and only for a linked, live session', async () => {
  const key = 'eee-ffff-ggg';
  // No meeting yet (nothing has flushed): there is nothing to keep alive.
  await bg.enqueue(key, [], { startedAt: '2026-08-12T09:00:00.000Z' });
  await bg.heartbeat(key, 3);
  assert.equal(apiCalls.length, 0);

  await bg.enqueue(key, [segment('hello')]);
  await bg.flush(key);
  apiCalls = [];
  await bg.heartbeat(key, 3);
  assert.equal(apiCalls.length, 1);
  assert.ok(apiCalls[0].url.endsWith('/v1/meetings/live/meeting-1/heartbeat'));
  assert.deepEqual(apiCalls[0].body, { participants: 3 });

  // A head count the page could not read is sent as "unknown", never as zero.
  apiCalls = [];
  await bg.heartbeat(key, null);
  assert.deepEqual(apiCalls[0].body, {});

  // Once the user has hung up, a late heartbeat must not revive the meeting.
  apiUp = false;
  await bg.endSession(key);
  apiUp = true;
  apiCalls = [];
  await bg.heartbeat(key, 3);
  assert.equal(apiCalls.length, 0);
});

test('a failed heartbeat leaves the flush backoff and the meeting link alone', async () => {
  const key = 'fff-gggg-hhh';
  await bg.enqueue(key, [segment('hello')], { startedAt: '2026-08-12T09:00:00.000Z' });
  await bg.flush(key);

  apiUp = false;
  await bg.heartbeat(key, 2);
  assert.equal(bg.sessions.get(key).failures, 0);
  assert.equal(bg.sessions.get(key).nextAttemptAt, 0);
  assert.equal(bg.sessions.get(key).meetingId, 'meeting-1');
});

test('mic and camera state is reported in the wire shape, and withdrawn with an empty body', async () => {
  const key = 'mic-ctrl-one';
  await bg.enqueue(key, [segment('hello')]);
  await bg.flush(key); // links the meeting
  apiCalls = [];

  await bg.reportControls(key, { micMuted: true, cameraOff: null });
  assert.equal(apiCalls.length, 1);
  assert.ok(apiCalls[0].url.endsWith('/v1/meetings/live/meeting-1/controls'));
  // An unreadable camera is omitted rather than sent as a guess.
  assert.deepEqual(apiCalls[0].body, { mic_muted: true });

  await bg.reportControls(key, { micMuted: false, cameraOff: true });
  assert.deepEqual(apiCalls[1].body, { mic_muted: false, camera_off: true });

  // Call control switched off in the options: the app is told there is nothing to control.
  await bg.reportControls(key, null);
  assert.deepEqual(apiCalls[2].body, {});
  assert.equal(bg.sessions.get(key).controls, null);

  // The state is never persisted — the page re-announces it on every connect.
  await bg.reportControls(key, { micMuted: true, cameraOff: false });
  assert.equal(persisted(key).controls, undefined);
});

test('the command poll carries the current state and only runs for a linked, live, controllable call', async () => {
  const key = 'mic-ctrl-two';
  // Not linked to a meeting yet, and no state reported: nothing to poll for.
  await bg.enqueue(key, []);
  assert.equal(await bg.pollCommands(key), null);
  await bg.reportControls(key, { micMuted: false, cameraOff: false });
  assert.equal(await bg.pollCommands(key), null);
  assert.equal(apiCalls.length, 0);

  await bg.enqueue(key, [segment('hello')]);
  await bg.flush(key);
  apiCalls = [];

  const commands = await bg.pollCommands(key);
  assert.deepEqual(commands, []); // the stubbed app answers without a `commands` array
  assert.ok(apiCalls[0].url.endsWith('/v1/meetings/live/meeting-1/commands/poll'));
  assert.equal(apiCalls[0].body.mic_muted, false);
  assert.equal(apiCalls[0].body.camera_off, false);
  assert.ok(apiCalls[0].body.wait_seconds > 0 && apiCalls[0].body.wait_seconds < 30);

  // Once the user has hung up, nothing keeps a request open against the finished call.
  apiCalls = [];
  bg.sessions.get(key).pendingEnd = { endedAt: '2026-08-12T10:00:00.000Z' };
  assert.equal(await bg.pollCommands(key), null);
  assert.equal(apiCalls.length, 0);
});

test('an unreachable app fails the command poll loudly so the loop can back off', async () => {
  const key = 'mic-ctrl-thr';
  await bg.enqueue(key, [segment('hello')]);
  await bg.flush(key);
  await bg.reportControls(key, { micMuted: true, cameraOff: null });

  apiUp = false;
  await assert.rejects(() => bg.pollCommands(key));
});

test('hello reports this build and remembers which one the app ships with', async () => {
  await bg.hello();
  assert.equal(apiCalls.length, 1);
  assert.ok(apiCalls[0].url.endsWith('/v1/bridge/hello'));
  assert.deepEqual(apiCalls[0].body, { version: '9.9.9' });
  // The stubbed app names no version of its own.
  assert.equal(storage.tw_app_status.expectedVersion, null);

  // An unreachable (or too old) app must never break the session start that triggered it.
  apiUp = false;
  await bg.hello();
});

test('version comparison is numeric, so only an extension that is behind the app is told to reload', async () => {
  const { isOlderVersion } = await import('../src/config.js');
  assert.ok(isOlderVersion('0.9.1', '0.10.0'));
  assert.ok(isOlderVersion('0.3', '0.3.1'));
  assert.ok(!isOlderVersion('0.4.0', '0.4.0'));
  // The app being behind this extension is not this extension's problem.
  assert.ok(!isOlderVersion('0.4.0', '0.3.0'));
});

test('a refused version check names the real cause instead of blaming an old app', async () => {
  const { describeHelloFailure } = await import('../src/config.js');
  // Not on the allowlist: the message carries the ID to paste, and captions cannot flow.
  const refused = describeHelloFailure(403, '0.4.1', 'abcdefghijklmnopabcdefghijklmnop');
  assert.equal(refused.ok, false);
  assert.match(refused.message, /abcdefghijklmnopabcdefghijklmnop/);
  assert.match(refused.message, /Allowed Browser Extensions/);

  assert.equal(describeHelloFailure(401, '0.4.1', 'id').ok, false);
  assert.match(describeHelloFailure(401, '0.4.1', 'id').message, /token/i);

  // Only a missing route means an older app — and captions still work against one.
  const older = describeHelloFailure(404, '0.4.1', 'id');
  assert.equal(older.ok, true);
  assert.match(older.message, /older than this extension/);

  assert.match(describeHelloFailure(500, '0.4.1', 'id').message, /500/);
});

/** A page's port into the worker, as `chrome.runtime.connect` would hand it over. */
function connectPage() {
  const onMessage = [];
  const onDisconnect = [];
  const port = {
    name: 'tw-meet',
    sender: { tab: { id: 7 } },
    posted: [],
    onMessage: { addListener: (fn) => onMessage.push(fn) },
    onDisconnect: { addListener: (fn) => onDisconnect.push(fn) },
    postMessage(message) {
      port.posted.push(message);
    },
    send: (message) => Promise.all(onMessage.map((fn) => fn(message))),
    disconnect: () => onDisconnect.forEach((fn) => fn()),
  };
  connectListener(port);
  return port;
}

const calledPaths = () => apiCalls.map((call) => new URL(call.url).pathname);

test('joining a call creates the meeting with captions off, and heartbeat and controls flow', async () => {
  const key = 'jjj-kkkk-lll';
  const port = connectPage();
  try {
    await port.send({ type: 'session-start', sessionKey: key, title: 'Weekly sync', startedAt: new Date().toISOString() });
    assert.ok(calledPaths().includes('/v1/meetings/live'), 'the meeting is created at join, no caption needed');
    assert.deepEqual(port.posted.find((m) => m.type === 'session-ready')?.meetingId, 'meeting-1');

    await port.send({ type: 'heartbeat', sessionKey: key, participants: 3 });
    const beat = apiCalls.find((call) => call.url.endsWith('/heartbeat'));
    assert.deepEqual(beat?.body, { participants: 3 });

    await port.send({ type: 'controls', sessionKey: key, micMuted: true, cameraOff: false });
    const controls = apiCalls.find((call) => call.url.endsWith('/controls'));
    assert.deepEqual(controls?.body, { mic_muted: true, camera_off: false });
    assert.ok(!calledPaths().some((path) => path.endsWith('/segments')), 'no caption was ever sent');

    await port.send({ type: 'session-end', sessionKey: key });
    assert.ok(calledPaths().includes('/v1/meetings/live/meeting-1/end'));
  } finally {
    port.disconnect();
  }
});

test('a meeting that could not be created at join is linked later without any caption', async () => {
  const key = 'mmm-nnnn-ooo';
  const port = connectPage();
  try {
    apiUp = false;
    await port.send({ type: 'session-start', sessionKey: key, startedAt: new Date().toISOString() });
    assert.ok(port.posted.some((m) => m.type === 'error'), 'the page hears that the app refused');
    assert.equal(bg.sessions.get(key).meetingId, null);

    apiUp = true;
    bg.sessions.get(key).controls = { micMuted: false, cameraOff: null };
    assert.equal(await bg.ensureLinked(key), true);
    assert.equal(bg.sessions.get(key).meetingId, 'meeting-1');
    // The mic state that arrived while unlinked reaches the app once the meeting exists.
    assert.ok(calledPaths().includes('/v1/meetings/live/meeting-1/controls'));
    assert.equal(await bg.ensureLinked(key), false, 'already linked: nothing to do');
  } finally {
    port.disconnect();
    bg.sessions.get(key).controls = null;
    await bg.endSession(key);
  }
});

test('a failed link backs off instead of hammering the app', async () => {
  const key = 'ppp-qqqq-rrr';
  await bg.enqueue(key, [], { startedAt: new Date().toISOString() });
  apiUp = false;
  assert.equal(await bg.ensureLinked(key), false);
  assert.ok(bg.sessions.get(key).nextAttemptAt > Date.now());
  const before = apiCalls.length;
  apiUp = true;
  assert.equal(await bg.ensureLinked(key), false, 'still inside the backoff window');
  assert.equal(apiCalls.length, before);
  await bg.endSession(key);
});
