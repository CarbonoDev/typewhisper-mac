const test = require('node:test');
const assert = require('node:assert');
const { CaptionStabilizer, stablePrefixLength } = require('../src/stabilizer.js');

/** Stand-in for a caption element; identity is all the stabilizer uses. */
const block = (id) => ({ id });

function makeStabilizer(overrides = {}) {
  return new CaptionStabilizer({ sessionStart: 0, captionLagMs: 0, ...overrides });
}

test('a growing caption emits once, after it goes idle', () => {
  const s = makeStabilizer();
  const el = block('a');

  assert.deepEqual(s.observe([{ element: el, speaker: 'Ana', text: 'we should' }], 1000), []);
  assert.deepEqual(s.observe([{ element: el, speaker: 'Ana', text: 'we should ship' }], 1500), []);
  assert.deepEqual(s.observe([{ element: el, speaker: 'Ana', text: 'we should ship it' }], 2000), []);

  const out = s.observe([{ element: el, speaker: 'Ana', text: 'we should ship it' }], 6000);
  assert.equal(out.length, 1);
  assert.equal(out[0].speaker, 'Ana');
  assert.equal(out[0].text, 'we should ship it');
});

test('tail revisions do not produce duplicated fragments', () => {
  const s = makeStabilizer();
  const el = block('a');

  s.observe([{ element: el, speaker: 'Ana', text: 'lets talk about the deploy' }], 1000);
  // Meet rewrites the tail: "deploy" -> "deployment window".
  s.observe([{ element: el, speaker: 'Ana', text: 'lets talk about the deployment window' }], 1400);

  const out = s.observe([{ element: el, speaker: 'Ana', text: 'lets talk about the deployment window' }], 5000);
  assert.equal(out.length, 1);
  assert.equal(out[0].text, 'lets talk about the deployment window');
});

test('a long monologue flushes a settled prefix instead of buffering', () => {
  const s = makeStabilizer();
  const el = block('a');
  const sentence = 'This is a complete thought that ends here. ';

  let text = '';
  let flushed = [];
  for (let i = 0; i < 12; i += 1) {
    text += sentence;
    flushed = flushed.concat(s.observe([{ element: el, speaker: 'Ana', text }], 1000 + i * 200));
  }

  assert.ok(flushed.length > 0, 'expected at least one prefix flush before the block went idle');
  // A flush must never cut mid-sentence.
  for (const segment of flushed) {
    assert.match(segment.text, /\.$/);
  }
  // And it must never emit text still inside the revision guard.
  const emitted = flushed.map((s) => s.text).join(' ');
  assert.ok(emitted.length < text.length);
});

test('a block leaving the DOM is finalized', () => {
  const s = makeStabilizer();
  const el = block('a');

  s.observe([{ element: el, speaker: 'Ana', text: 'quick point before I go' }], 1000);
  const out = s.observe([], 1200); // element evicted; not idle yet

  assert.equal(out.length, 1);
  assert.equal(out[0].text, 'quick point before I go');
  assert.equal(s.blocks.size, 0);
});

test('a speaker change on a reused element closes the previous turn', () => {
  const s = makeStabilizer();
  const el = block('a');

  s.observe([{ element: el, speaker: 'Ana', text: 'I think yes' }], 1000);
  const out = s.observe([{ element: el, speaker: 'Beto', text: 'I disagree' }], 1200);

  assert.equal(out.length, 1);
  assert.equal(out[0].speaker, 'Ana');
  assert.equal(out[0].text, 'I think yes');

  const next = s.flushAll(2000);
  assert.equal(next.length, 1);
  assert.equal(next[0].speaker, 'Beto');
  assert.equal(next[0].text, 'I disagree');
});

test('a re-created block with identical text is not emitted twice', () => {
  const s = makeStabilizer();

  s.observe([{ element: block('a'), speaker: 'Ana', text: 'same words' }], 1000);
  const first = s.observe([], 1100);
  assert.equal(first.length, 1);

  // Meet drops and recreates the turn as a fresh element.
  s.observe([{ element: block('b'), speaker: 'Ana', text: 'same words' }], 1200);
  const second = s.observe([], 1300);
  assert.equal(second.length, 0);
});

test('timestamps are session-relative seconds and shifted by caption lag', () => {
  const s = new CaptionStabilizer({ sessionStart: 10_000, captionLagMs: 1000 });
  const el = block('a');

  s.observe([{ element: el, speaker: 'Ana', text: 'hello' }], 15_000);
  const out = s.observe([], 15_500);

  assert.equal(out.length, 1);
  assert.equal(out[0].start, 4); // (15000 - 1000 - 10000) / 1000
  assert.ok(out[0].end >= out[0].start);
});

test('timestamps never go negative for captions at the very start', () => {
  const s = new CaptionStabilizer({ sessionStart: 10_000, captionLagMs: 5000 });
  const el = block('a');

  s.observe([{ element: el, speaker: 'Ana', text: 'hi' }], 10_200);
  const out = s.observe([], 10_400);

  assert.equal(out[0].start, 0);
});

test('stablePrefixLength refuses to cut inside the revision guard', () => {
  assert.equal(stablePrefixLength('short', 90), 0);
  assert.equal(stablePrefixLength('a'.repeat(50), 90), 0);
});

test('stablePrefixLength prefers a sentence boundary over a word boundary', () => {
  const text = 'First sentence here. Second one trails off with many more words after it';
  const cut = stablePrefixLength(text, 20);
  assert.equal(text.slice(0, cut), 'First sentence here.');
});
