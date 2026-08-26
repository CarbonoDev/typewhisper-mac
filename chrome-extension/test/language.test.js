const test = require('node:test');
const assert = require('node:assert');
const { matchLanguageOption, captionToggleState } = require('../src/selectors.js');

/** matchLanguageOption is pure over `{ dataValue, label }` descriptors — no DOM needed. */
const option = (dataValue, label) => ({ dataValue, label });

test('a data-value with the language-code prefix wins', () => {
  const options = [option('de-DE', 'Deutsch'), option('en-US', 'English (United States)')];
  assert.equal(matchLanguageOption(options, 'en'), options[1]);
});

test('es matches regional Spanish data-values, not English ones', () => {
  const options = [
    option('en-US', 'English (United States)'),
    option('es-419', 'Español (Latinoamérica)'),
  ];
  assert.equal(matchLanguageOption(options, 'es'), options[1]);
  assert.equal(matchLanguageOption(options, 'en'), options[0]);
});

test('a data-value match beats a display-name match', () => {
  // The label lies ("English") but the machine-readable value says Spanish — trust the value.
  const options = [option('', 'English'), option('es-ES', 'English')];
  assert.equal(matchLanguageOption(options, 'es'), options[1]);
});

test('with no data-values, the localized display name decides', () => {
  const byName = (label, code) => matchLanguageOption([option('', label)], code);
  // "English" across major UI locales.
  assert.ok(byName('English', 'en'));
  assert.ok(byName('Inglés (Estados Unidos)', 'en')); // es UI
  assert.ok(byName('Englisch', 'en')); // de UI
  assert.ok(byName('Anglais', 'en')); // fr UI
  assert.ok(byName('Inglês (Estados Unidos)', 'en')); // pt UI
  assert.ok(byName('Inglese', 'en')); // it UI
  assert.ok(byName('Engels', 'en')); // nl UI
  // "Spanish" across major UI locales.
  assert.ok(byName('Spanish (Mexico)', 'es'));
  assert.ok(byName('Español', 'es'));
  assert.ok(byName('Spanisch', 'es'));
  assert.ok(byName('Espagnol', 'es'));
  assert.ok(byName('Espanhol', 'es'));
  assert.ok(byName('Spagnolo', 'es'));
  assert.ok(byName('Spaans', 'es'));
});

test('names never cross-match the other language', () => {
  const options = [option('', 'Español (España)'), option('', 'Deutsch')];
  assert.equal(matchLanguageOption(options, 'en'), null);
});

test('aria-label text counts as label material', () => {
  // collectLanguageOptions folds aria-label and textContent into one label string.
  const options = [option('', 'English (United States) selected')];
  assert.equal(matchLanguageOption(options, 'en'), options[0]);
});

test('an empty or unknown preference matches nothing', () => {
  const options = [option('en-US', 'English')];
  assert.equal(matchLanguageOption(options, ''), null);
  assert.equal(matchLanguageOption(options, null), null);
  assert.equal(matchLanguageOption([], 'en'), null);
});

test('captionToggleState reads aria-pressed as a tri-state', () => {
  const toggle = (pressed) => ({ getAttribute: () => pressed });
  assert.equal(captionToggleState(toggle('true')), true);
  assert.equal(captionToggleState(toggle('false')), false);
  assert.equal(captionToggleState(toggle(null)), null); // attribute absent → unknown, not off
  assert.equal(captionToggleState(null), null);
});
