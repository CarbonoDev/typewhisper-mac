const test = require('node:test');
const assert = require('node:assert');
const { createStatusTracker, formatLogArgs, PUBLISH_EVERY_MS } = require('../src/status.js');

function tracker() {
  const lines = [];
  const sent = [];
  let clock = 1_000_000;
  const t = createStatusTracker({
    version: '0.5.0',
    log: (line) => lines.push(line),
    forward: (snapshot) => sent.push(snapshot),
    now: () => clock,
  });
  return { t, lines, sent, advance: (ms) => (clock += ms) };
}

test('each transition is logged once, not once per tick', () => {
  const { t, lines } = tracker();
  for (let i = 0; i < 5; i += 1) t.update({ onCallPath: true, callCode: 'abc-defg-hij', inCall: false });
  for (let i = 0; i < 5; i += 1) t.update({ inCall: true, inCallVia: 'leave button (label)' });
  t.update({ inCall: false, inCallVia: null, lobby: null });
  assert.deepEqual(lines, [
    'on a Meet call page (abc-defg-hij); waiting for an in-call signal',
    'in-call signal matched: leave button (label)',
    'in-call signal lost',
  ]);
});

test('session, meeting, captions and mic transitions read in plain words', () => {
  const { t, lines } = tracker();
  t.update({ sessionKey: 'abc-defg-hij' });
  t.update({ meetingId: 'm-1' });
  t.update({ captionsFound: true, captionsVia: 'aria-label' });
  t.update({ captionsFound: false });
  t.update({ micReadable: true, micVia: 'jsname:hw0c9' });
  t.update({ micReadable: false });
  t.update({ sessionKey: null });
  assert.deepEqual(lines, [
    'session started for call abc-defg-hij',
    'linked to app meeting m-1',
    'caption region lost',
    'mic toggle readable (jsname:hw0c9)',
    'mic toggle not readable — floating mute button stays hidden',
    'session ended for call abc-defg-hij',
  ]);
});

test('transitions publish at once; counters wait for the throttle', () => {
  const { t, sent, advance, lines } = tracker();
  t.publish(); // the initial status always goes out
  assert.equal(sent.length, 1);

  t.update({ segmentsSent: 3 });
  t.publish();
  assert.equal(sent.length, 1, 'a counter alone does not publish immediately');
  assert.equal(lines.length, 0, 'and is never logged');
  advance(PUBLISH_EVERY_MS);
  t.publish();
  assert.equal(sent.length, 2);
  assert.equal(sent[1].segmentsSent, 3);

  t.update({ inCall: true, inCallVia: 'hang-up icon' });
  t.publish();
  assert.equal(sent.length, 3, 'a transition publishes without waiting');
  t.publish();
  assert.equal(sent.length, 3, 'nothing new, nothing sent');
});

test('log arguments are flattened to one bounded line', () => {
  assert.equal(formatLogArgs(['matched', { via: 'x' }]), 'matched {"via":"x"}');
  assert.equal(formatLogArgs(['x'.repeat(5000)]).length, 2000);
});
