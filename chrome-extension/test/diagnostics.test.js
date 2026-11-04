const test = require('node:test');
const assert = require('node:assert');

// No `chrome.storage.session` here, so the module uses its in-memory fallback.
let d;
test.before(async () => {
  d = await import('../src/diagnostics.js');
});
test.beforeEach(() => d.resetForTests());

test('the log ring buffer keeps only the newest lines', async () => {
  for (let i = 0; i < d.MAX_LOG_LINES + 25; i += 1) await d.appendLog('[tw-meet]', `line ${i}`);
  const { lines } = await d.readDiagnostics();
  assert.equal(lines.length, d.MAX_LOG_LINES);
  assert.match(lines[0], /\[tw-meet\] line 25$/);
  assert.match(lines.at(-1), new RegExp(`line ${d.MAX_LOG_LINES + 24}$`));
});

test('app reachability is logged on transitions only', async () => {
  await d.noteApiResult({ reachable: true });
  await d.noteApiResult({ reachable: true });
  await d.noteApiResult({ reachable: false, error: 'Failed to fetch (http://127.0.0.1:8978)' });
  await d.noteApiResult({ reachable: false, error: 'Failed to fetch (http://127.0.0.1:8978)' });
  await d.noteApiResult({ reachable: true });
  const { lines, health } = await d.readDiagnostics();
  assert.deepEqual(
    lines.map((line) => line.replace(/^\S+ /, '')),
    ['[tw] app reachable', '[tw] app unreachable: Failed to fetch (http://127.0.0.1:8978)', '[tw] app is reachable again']
  );
  assert.equal(health.reachable, true);
  assert.equal(health.lastError, null);
});

test('tab status is stored per tab and forgotten when the tab closes', async () => {
  await d.setTabStatus(7, { inCall: true });
  await d.setTabStatus(8, { inCall: false });
  await d.clearTabStatus(7);
  const { tabs } = await d.readDiagnostics();
  assert.deepEqual(Object.keys(tabs), ['8']);
});

const baseStatus = {
  enabled: true,
  onCallPath: true,
  callCode: 'abc-defg-hij',
  inCall: false,
  whyNot: 'No in-call signal matched: leave button not found (labels tried: leave call, …); no caption region.',
  segmentsSent: 0,
};

test('a call page with no in-call signal says why, in plain words', () => {
  const { headline, lines } = d.describeStatus({ status: baseStatus });
  assert.match(headline, /not detected as in the call/);
  assert.match(lines[0], /leave button not found/);
});

test('the lobby reads as the lobby', () => {
  const { headline } = d.describeStatus({ status: { ...baseStatus, lobby: 'join button "join now"' } });
  assert.match(headline, /lobby/);
});

test('a joined call with captions off still reads as a linked meeting, and says what captions add', () => {
  const now = Date.parse('2026-01-05T10:00:00Z');
  const { headline, lines } = d.describeStatus({
    status: { ...baseStatus, inCall: true, inCallVia: 'hang-up icon', meetingId: 'm-1', captionsFound: false, micReadable: true, micVia: 'jsname:hw0c9' },
    session: { buffer: [], lastFlushAt: null },
    health: { reachable: true, lastError: null, lastOkAt: '2026-01-05T09:59:50Z' },
    now,
  });
  assert.equal(headline, 'In the call — meeting linked in the app.');
  assert.ok(lines.some((line) => /no caption region — turn on captions/.test(line)));
  assert.ok(lines.some((line) => /floating mute button can work/.test(line)));
  assert.ok(lines.some((line) => /App: reachable, last answer 10s ago/.test(line)));
});

test('an unreachable app is named as the reason the meeting is missing', () => {
  const { headline, lines } = d.describeStatus({
    status: { ...baseStatus, inCall: true, inCallVia: 'leave button (label)', sessionError: 'Failed to fetch' },
    health: { reachable: false, lastError: 'Failed to fetch', lastErrorAt: new Date().toISOString() },
  });
  assert.match(headline, /app has not taken the meeting/);
  assert.ok(lines.some((line) => /App: unreachable/.test(line)));
});

test('no status from the tab tells the user to reload it', () => {
  assert.match(d.describeStatus({}).lines[0], /reload the tab/);
});

test('the copied diagnostics carry the version, the explanation and the log', () => {
  const text = d.formatDiagnostics({
    version: '0.5.0',
    tabId: 7,
    status: baseStatus,
    lines: ['2026-01-05T10:00:00.000Z [tw-meet] Meet Bridge v0.5.0 loaded'],
  });
  assert.match(text, /^Meet Bridge v0\.5\.0 diagnostics/);
  assert.match(text, /leave button not found/);
  assert.match(text, /last 1 log line\(s\):\n.*Meet Bridge v0\.5\.0 loaded/);
});
