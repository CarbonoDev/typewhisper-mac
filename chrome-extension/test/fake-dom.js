/**
 * Shared fake DOM for the selector and presence tests (not a test file itself: the runner's glob is
 * `*.test.js`).
 */
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
function installDom(roots, pathname, { bodyText = '' } = {}) {
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
    body: { textContent: bodyText },
  };
  if (pathname) globalThis.location = { pathname };
  return () => {
    globalThis.document = previous.document;
    globalThis.location = previous.location;
  };
}

module.exports = { FakeEl, installDom, matchesSelectorList };
