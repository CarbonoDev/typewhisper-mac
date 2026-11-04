const test = require('node:test');
const assert = require('node:assert');
const { detectInCall, inActiveCall, explainNotInCall, findLobbyTell } = require('../src/presence.js');
const { FakeEl, installDom } = require('./fake-dom.js');

/** The user's own mic toggle as Meet renders it, in the lobby and in the call alike. */
const micToggle = (muted = 'false', label = 'Turn off microphone (⌘ + d)') =>
  new FakeEl({ tag: 'button', attrs: { 'aria-label': label, 'data-is-muted': muted }, innerText: 'mic' });
const button = (attrs, innerText = '') => new FakeEl({ tag: 'button', attrs, innerText });

function withDom(roots, fn, options) {
  const restore = installDom(roots, '/abc-defg-hij', options);
  try {
    return fn();
  } finally {
    restore();
  }
}

test('the leave button by its Spanish label is enough on its own', () => {
  withDom([button({ 'aria-label': 'Salir de la llamada' }, 'call_end')], () => {
    const result = detectInCall();
    assert.equal(result.inCall, true);
    assert.equal(result.via, 'leave-label');
  });
});

test('newer English and Spanish leave labels are recognized', () => {
  for (const label of ['Leave meeting', 'Salir de la reunión', 'Abandonar la llamada']) {
    withDom([button({ 'aria-label': label })], () => assert.equal(inActiveCall(), true, label));
  }
});

test('with every label rotated away, a readable mic toggle outside the lobby means in the call', () => {
  withDom([micToggle('true', 'Mikrofon (⌘ + d)'), button({ 'aria-label': 'Weitere Optionen' }, 'more_vert')], () => {
    const result = detectInCall();
    assert.equal(result.inCall, true);
    assert.equal(result.via, 'mic-toggle');
  });
});

test('the lobby is never in the call, even though its mic toggle is readable', () => {
  for (const join of ['Join now', 'Ask to join', 'Unirse ahora', 'Pedir unirse']) {
    // Meet's join button carries its words as text, not as an aria-label.
    withDom([micToggle(), button({}, join)], () => {
      const result = detectInCall();
      assert.equal(result.inCall, false, join);
      assert.match(result.lobby, /join button/);
      assert.match(explainNotInCall(result), /lobby/);
    });
  }
});

test('the join button is recognized by its jsname in an unlisted locale', () => {
  withDom([micToggle(), button({ jsname: 'Qx7uuf' }, 'Liity nyt')], () => {
    assert.equal(inActiveCall(), false);
  });
});

test('the knock screen ("Asking to be let in") is not the call', () => {
  withDom([micToggle(), button({}, 'call_end')], () => assert.equal(inActiveCall(), false), {
    bodyText: 'Asking to be let in… You will join the call when someone lets you in',
  });
});

test('the hang-up icon ligature is a locale-free in-call signal', () => {
  withDom([button({ 'aria-label': 'Puhelu' }, 'call_end')], () => {
    const result = detectInCall();
    assert.equal(result.inCall, true);
    assert.equal(result.via, 'hangup-icon');
  });
});

test('the leave button by jsname counts, outside the lobby', () => {
  withDom([button({ jsname: 'CQylAd' })], () => assert.equal(detectInCall().via, 'leave-jsname'));
  withDom([button({ jsname: 'CQylAd' }), button({}, 'Join now')], () => assert.equal(inActiveCall(), false));
});

test('two side-panel buttons count, one alone does not', () => {
  withDom([button({ 'aria-label': 'Chat with everyone' }), button({ 'aria-label': 'Meeting details' })], () => {
    assert.equal(detectInCall().via, 'side-panels');
  });
  withDom([button({ 'aria-label': 'Chat with everyone' })], () => assert.equal(inActiveCall(), false));
});

test('a French "Participants" panel is not mistaken for the lobby\'s "Participer" button', () => {
  withDom([micToggle('false', 'Micro (⌘ + d)'), button({ 'aria-label': 'Participants' }, 'Participants')], () => {
    assert.equal(findLobbyTell(), null);
    assert.equal(inActiveCall(), true);
  });
});

test('a bare call page explains, in plain words, which signals were looked for', () => {
  withDom([button({ 'aria-label': 'More options' }, 'more_vert')], () => {
    const result = detectInCall();
    assert.equal(result.inCall, false);
    const why = explainNotInCall(result);
    assert.match(why, /leave button not found \(labels tried: leave call/);
    assert.match(why, /no caption region/);
    assert.match(why, /mic toggle not readable/);
  });
});

test('nothing to explain once in the call', () => {
  withDom([button({ 'aria-label': 'Leave call' })], () => assert.equal(explainNotInCall(detectInCall()), ''));
});
