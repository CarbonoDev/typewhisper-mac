const test = require('node:test');
const assert = require('node:assert');
const {
  parseCaptionBlock,
  isIconToken,
  stripIconTokens,
  looksLikeUIChrome,
  isPlausibleSpeakerName,
} = require('../src/selectors.js');

/** parseCaptionBlock only reads `innerText`, so a plain object stands in for the element. */
const block = (innerText) => ({ innerText });

test('a real caption turn parses into speaker and text', () => {
  assert.deepEqual(parseCaptionBlock(block('Ana García\nwe should ship it')), {
    speaker: 'Ana García',
    text: 'we should ship it',
  });
});

test('menu chrome with keyboard shortcuts is dropped wholesale', () => {
  // The pre-join screen's mic menu, as scraped in the wild.
  const chrome =
    'more_vert\nMore options mic Turn off microphone (⌘ + d) videocam Turn off camera (⌘ + e)';
  assert.equal(parseCaptionBlock(block(chrome)), null);
});

test('an email in the speaker slot marks the block as account chrome', () => {
  assert.equal(parseCaptionBlock(block('marco@carbonodev.com\nSwitch account')), null);
});

test('an icon ligature in the speaker slot marks the block as UI', () => {
  assert.equal(parseCaptionBlock(block('frame_person\nReframe for Marco')), null);
});

test('a video tile echoing the participant name is not a caption turn', () => {
  assert.equal(parseCaptionBlock(block('Marco Rivadeneyra\nMarco Rivadeneyra')), null);
});

test('inline icon tokens are stripped from otherwise real text', () => {
  const parsed = parseCaptionBlock(block('Ana García\nlet me visual_effects share my screen'));
  assert.deepEqual(parsed, { speaker: 'Ana García', text: 'let me share my screen' });
});

test('icon token detection requires the underscore shape', () => {
  assert.ok(isIconToken('more_vert'));
  assert.ok(isIconToken('present_to_all'));
  assert.ok(!isIconToken('hello'));
  assert.ok(!isIconToken('Ana'));
  assert.ok(!isIconToken('state_of_the_art'.toUpperCase())); // uppercase is not a ligature
});

test('stripIconTokens leaves normal sentences alone', () => {
  assert.equal(stripIconTokens('we should ship it'), 'we should ship it');
  assert.equal(stripIconTokens('mic_none expand_less'), '');
});

test('looksLikeUIChrome matches shortcut parentheticals only', () => {
  assert.ok(looksLikeUIChrome('Turn off microphone (⌘ + d)'));
  assert.ok(looksLikeUIChrome('Mute (Ctrl + D)'));
  assert.ok(!looksLikeUIChrome('we shipped it (finally) yesterday'));
});

test('plausible speaker names are names, not chrome', () => {
  assert.ok(isPlausibleSpeakerName('Ana García'));
  assert.ok(isPlausibleSpeakerName('Phil Kandera'));
  assert.ok(!isPlausibleSpeakerName('marco@carbonodev.com'));
  assert.ok(!isPlausibleSpeakerName('more_vert'));
  assert.ok(!isPlausibleSpeakerName(''));
  assert.ok(!isPlausibleSpeakerName('x'.repeat(49)));
});
