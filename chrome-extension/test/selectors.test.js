const test = require('node:test');
const assert = require('node:assert');
const {
  parseCaptionBlock,
  isIconToken,
  stripIconTokens,
  looksLikeUIChrome,
  isPlausibleSpeakerName,
  findCaptionRoot,
  inActiveCall,
  readCallCode,
} = require('../src/selectors.js');

/** parseCaptionBlock only reads `innerText`, so a plain object stands in for the element. */
const block = (innerText) => ({ innerText });

/**
 * Minimal fake DOM. `selectors.js` only touches `document`/`location` inside function bodies, so a
 * stub installed before the call is enough to exercise the discovery ladder — no jsdom needed. The
 * selector matcher supports exactly what the ladder uses: an optional tag, `.class`, `[attr]`,
 * `[attr="value"]`, `[attr*="value"]`, and comma-separated groups.
 */
class FakeEl {
  constructor({ tag = 'div', attrs = {}, className = '', innerText = '', children = [] } = {}) {
    this.tagName = tag.toUpperCase();
    this.attrs = attrs;
    this.className = className;
    this.children = children;
    this.parentElement = null;
    this._ownText = innerText;
    for (const child of children) child.parentElement = this;
  }
  get innerText() {
    const fromChildren = this.children.map((child) => child.innerText).filter(Boolean);
    return [this._ownText, ...fromChildren].filter(Boolean).join('\n');
  }
  getAttribute(name) {
    if (name === 'class') return this.className || null;
    return Object.prototype.hasOwnProperty.call(this.attrs, name) ? this.attrs[name] : null;
  }
  closest(selectorList) {
    let node = this;
    while (node) {
      if (matchesSelectorList(node, selectorList)) return node;
      node = node.parentElement;
    }
    return null;
  }
}

function matchesSimple(el, selector) {
  const tag = selector.match(/^[a-zA-Z]+/);
  if (tag && el.tagName !== tag[0].toUpperCase()) return false;
  const tokens = selector.slice(tag ? tag[0].length : 0).match(/\[[^\]]+\]|\.[\w-]+/g) || [];
  for (const token of tokens) {
    if (token.startsWith('.')) {
      if (!String(el.className).split(/\s+/).includes(token.slice(1))) return false;
      continue;
    }
    const parsed = token.match(/^\[([\w-]+)(?:(\*?=)"([^"]*)")?\]$/);
    if (!parsed) return false;
    const [, name, operator, value] = parsed;
    const actual = el.getAttribute(name);
    if (actual === null) return false;
    if (operator === '=' && actual !== value) return false;
    if (operator === '*=' && !actual.includes(value)) return false;
  }
  return true;
}

function matchesSelectorList(el, selectorList) {
  return selectorList
    .split(',')
    .map((part) => part.trim())
    .some((part) => matchesSimple(el, part));
}

/** Install `document` (and optionally `location`) for one test; returns the restore function. */
function installDom(roots, pathname) {
  const all = [];
  const walk = (el) => {
    all.push(el);
    el.children.forEach(walk);
  };
  roots.forEach(walk);

  const previous = { document: globalThis.document, location: globalThis.location };
  globalThis.document = {
    querySelectorAll: (selector) => all.filter((el) => matchesSelectorList(el, selector)),
    querySelector: (selector) => all.find((el) => matchesSelectorList(el, selector)) || null,
    title: '',
  };
  if (pathname) globalThis.location = { pathname };
  return () => {
    globalThis.document = previous.document;
    globalThis.location = previous.location;
  };
}

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

test('a real caption region is adopted and counts as being in the call', () => {
  const region = new FakeEl({
    attrs: { role: 'region', 'aria-label': 'Captions' },
    children: [new FakeEl({ innerText: 'Ana García\nwe should ship it this week' })],
  });
  const restore = installDom([region]);
  try {
    assert.deepEqual(findCaptionRoot(), { root: region, via: 'aria-label' });
    assert.equal(inActiveCall(), true);
  } finally {
    restore();
  }
});

test('a lobby captions toggle is never mistaken for a caption region', () => {
  // The "Ready to join?" screen: a CC control built as div[role="button"] (Meet ships both shapes),
  // with a labelled tooltip wrapper inside it, and no leave-call button anywhere.
  const toggle = new FakeEl({
    attrs: { role: 'button', 'aria-label': 'Turn on captions' },
    innerText: 'closed_caption',
    children: [
      new FakeEl({
        tag: 'span',
        attrs: { 'aria-label': 'Turn on captions (c)' },
        innerText: 'Turn on captions to see what people are saying, in this call',
      }),
    ],
  });
  const restore = installDom([toggle]);
  try {
    assert.equal(inActiveCall(), false, 'the lobby must never start a session');
    assert.equal(findCaptionRoot(), null);
  } finally {
    restore();
  }
});

test('readCallCode accepts a call code and rejects anything else', () => {
  const cases = [
    ['/abc-defg-hij', 'abc-defg-hij'],
    ['/abc-defg-hij/companion', 'abc-defg-hij'],
    ['/landing', null],
    ['/', null],
    ['/_meet/abc-defg-hij', null],
    ['/abc-defg-hijk', null],
  ];
  for (const [pathname, expected] of cases) {
    const restore = installDom([], pathname);
    try {
      assert.equal(readCallCode(), expected, `pathname ${pathname}`);
    } finally {
      restore();
    }
  }
});

test('plausible speaker names are names, not chrome', () => {
  assert.ok(isPlausibleSpeakerName('Ana García'));
  assert.ok(isPlausibleSpeakerName('Phil Kandera'));
  assert.ok(!isPlausibleSpeakerName('marco@carbonodev.com'));
  assert.ok(!isPlausibleSpeakerName('more_vert'));
  assert.ok(!isPlausibleSpeakerName(''));
  assert.ok(!isPlausibleSpeakerName('x'.repeat(49)));
});
