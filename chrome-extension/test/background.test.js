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
  runtime: { onConnect: { addListener() {} } },
  action: { async setBadgeText() {}, async setBadgeBackgroundColor() {} },
};

globalThis.fetch = async (url, init) => {
  apiCalls.push({ url, body: JSON.parse(init.body) });
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
