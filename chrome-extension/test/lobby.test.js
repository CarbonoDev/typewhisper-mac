const test = require('node:test');
const assert = require('node:assert');
const { createLobbyMuter } = require('../src/lobby.js');

/** A toggle whose `click()` flips its own state, the way Meet's does. */
function toggle(muted, { disabled = false, via = 'aria-label' } = {}) {
  const control = { muted, disabled, via, clicks: 0 };
  control.element = {
    click() {
      control.clicks += 1;
      if (control.muted !== null) control.muted = !control.muted;
    },
  };
  return control;
}

/** A muter over a fixed set of controls; the settle re-read runs synchronously. */
function setup(controls) {
  const lines = [];
  const changes = [];
  const muter = createLobbyMuter({
    findControl: (kind) => controls[kind] || null,
    log: (...args) => lines.push(args.join(' ')),
    schedule: (fn) => fn(),
    onChange: (state) => changes.push(state),
  });
  return { muter, lines, changes };
}

const LOBBY = { callCode: 'abc-defg-hij', inLobby: true, inCall: false, hasSession: false, settings: {} };

test('clicks a live mic and camera in the lobby and reports them turned off', () => {
  const controls = { mic: toggle(false), camera: toggle(false) };
  const { muter, lines } = setup(controls);
  const state = muter.tick(LOBBY);
  assert.equal(controls.mic.clicks, 1);
  assert.equal(controls.camera.clicks, 1);
  assert.deepEqual(state, { mic: 'turned-off', camera: 'turned-off' });
  assert.ok(lines.some((line) => line.startsWith('lobby: turned off the microphone (via aria-label)')));
  assert.ok(lines.some((line) => line.startsWith('lobby: turned off the camera')));
});

test('leaves an already-muted toggle alone, and logs it once', () => {
  const controls = { mic: toggle(true), camera: toggle(true) };
  const { muter, lines } = setup(controls);
  for (let i = 0; i < 5; i += 1) muter.tick(LOBBY);
  assert.equal(controls.mic.clicks, 0);
  assert.equal(controls.camera.clicks, 0);
  assert.deepEqual(muter.snapshot(), { mic: 'already-off', camera: 'already-off' });
  assert.equal(lines.filter((line) => line.includes('microphone already off')).length, 1);
});

test('does nothing in the call, with a session, or outside the lobby', () => {
  const controls = { mic: toggle(false), camera: toggle(false) };
  const { muter, lines } = setup(controls);
  muter.tick({ ...LOBBY, inCall: true });
  muter.tick({ ...LOBBY, hasSession: true });
  muter.tick({ ...LOBBY, inLobby: false });
  muter.tick({ ...LOBBY, callCode: null });
  assert.equal(controls.mic.clicks, 0);
  assert.equal(controls.camera.clicks, 0);
  assert.deepEqual(lines, []);
});

test('falls back to findLobbyTell when the caller does not say', () => {
  const controls = { mic: toggle(false) };
  let tell = null;
  const muter = createLobbyMuter({
    findControl: (kind) => controls[kind] || null,
    findLobbyTell: () => tell,
    schedule: (fn) => fn(),
    maxTicks: 100,
  });
  const { inLobby, ...rest } = LOBBY; // eslint-disable-line no-unused-vars
  muter.tick(rest);
  assert.equal(controls.mic.clicks, 0);
  tell = 'join button "join now"';
  muter.tick(rest);
  assert.equal(controls.mic.clicks, 1);
});

test('honors each setting and the master switch', () => {
  const controls = { mic: toggle(false), camera: toggle(false) };
  const { muter } = setup(controls);
  muter.tick({ ...LOBBY, settings: { enabled: false } });
  assert.equal(controls.mic.clicks + controls.camera.clicks, 0);
  muter.tick({ ...LOBBY, settings: { lobbyMuteMic: false } });
  assert.equal(controls.mic.clicks, 0);
  assert.equal(controls.camera.clicks, 1);
  muter.tick({ ...LOBBY, settings: { lobbyMuteMic: false, lobbyMuteCamera: false } });
  assert.equal(controls.mic.clicks, 0);
  assert.deepEqual(muter.snapshot(), { mic: null, camera: 'turned-off' });
});

test('clicks once per visit even when the user turns the mic back on', () => {
  const controls = { mic: toggle(false), camera: toggle(true) };
  const { muter, lines } = setup(controls);
  muter.tick(LOBBY);
  assert.equal(controls.mic.clicks, 1);
  controls.mic.muted = false; // the user switches it back on in the lobby
  for (let i = 0; i < 20; i += 1) muter.tick(LOBBY);
  assert.equal(controls.mic.clicks, 1);
  assert.equal(lines.filter((line) => line.includes('microphone')).length, 1);
});

test('a click that does not take is reported as left on, and not retried', () => {
  const controls = { mic: toggle(false) };
  controls.mic.element.click = () => {
    controls.mic.clicks += 1; // Meet ignored it
  };
  const { muter, lines } = setup(controls);
  muter.tick({ ...LOBBY, settings: { lobbyMuteCamera: false } });
  muter.tick({ ...LOBBY, settings: { lobbyMuteCamera: false } });
  assert.equal(controls.mic.clicks, 1);
  assert.equal(muter.snapshot().mic, 'left-on');
  assert.ok(lines.some((line) => line.includes('does not read as off')));
});

test('the settle re-read happens after the click, not before', () => {
  const controls = { mic: toggle(false) };
  const pending = [];
  const muter = createLobbyMuter({
    findControl: (kind) => controls[kind] || null,
    schedule: (fn, ms) => pending.push({ fn, ms }),
    settleMs: 150,
  });
  muter.tick({ ...LOBBY, settings: { lobbyMuteCamera: false } });
  assert.equal(muter.snapshot().mic, 'clicked');
  assert.equal(pending.length, 1);
  assert.equal(pending[0].ms, 150);
  muter.tick({ ...LOBBY, settings: { lobbyMuteCamera: false } }); // a tick before the settle
  assert.equal(controls.mic.clicks, 1);
  pending[0].fn();
  assert.equal(muter.snapshot().mic, 'turned-off');
});

test('re-arms on a new call code', () => {
  const controls = { mic: toggle(false), camera: toggle(true) };
  const { muter } = setup(controls);
  muter.tick(LOBBY);
  controls.mic.muted = false;
  muter.tick(LOBBY);
  assert.equal(controls.mic.clicks, 1);
  muter.tick({ ...LOBBY, callCode: 'xyz-wxyz-xyz' });
  assert.equal(controls.mic.clicks, 2);
  assert.equal(muter.snapshot().mic, 'turned-off');
});

test('re-arms when the lobby shows again after a session for the same code', () => {
  const controls = { mic: toggle(false), camera: toggle(true) };
  const { muter } = setup(controls);
  muter.tick(LOBBY);
  controls.mic.muted = false; // unmuted in the call
  muter.tick({ ...LOBBY, inLobby: false, inCall: true, hasSession: true });
  muter.tick({ ...LOBBY, inLobby: false }); // the call ends
  assert.equal(controls.mic.clicks, 1);
  muter.tick(LOBBY); // rejoin: back in the lobby
  assert.equal(controls.mic.clicks, 2);
});

test('gives up quietly on a toggle that stays unreadable', () => {
  const controls = { mic: toggle(null), camera: toggle(false, { disabled: true }) };
  const { muter, lines } = setup(controls);
  for (let i = 0; i < 9; i += 1) muter.tick(LOBBY);
  assert.deepEqual(muter.snapshot(), { mic: null, camera: null });
  assert.deepEqual(lines, []);
  for (let i = 0; i < 20; i += 1) muter.tick(LOBBY);
  assert.deepEqual(muter.snapshot(), { mic: 'unreadable', camera: 'unreadable' });
  assert.equal(controls.mic.clicks + controls.camera.clicks, 0);
  assert.equal(lines.length, 2);
  assert.ok(lines[0].includes('state unreadable'));
  assert.ok(lines[1].includes('disabled'));
});

test('a missing toggle counts toward the same bound', () => {
  const { muter, lines } = setup({});
  for (let i = 0; i < 30; i += 1) muter.tick(LOBBY);
  assert.deepEqual(muter.snapshot(), { mic: 'unreadable', camera: 'unreadable' });
  assert.equal(lines.length, 2);
  assert.ok(lines[0].includes('not found'));
});

test('a toggle that appears late in the lobby is still turned off', () => {
  const controls = {};
  const { muter } = setup(controls);
  muter.tick(LOBBY);
  muter.tick(LOBBY);
  controls.mic = toggle(false);
  controls.camera = toggle(false);
  muter.tick(LOBBY);
  assert.deepEqual(muter.snapshot(), { mic: 'turned-off', camera: 'turned-off' });
});

test('onChange fires on transitions only', () => {
  const controls = { mic: toggle(true), camera: toggle(true) };
  const { muter, changes } = setup(controls);
  for (let i = 0; i < 5; i += 1) muter.tick(LOBBY);
  assert.equal(changes.length, 2);
  assert.deepEqual(changes[1], { mic: 'already-off', camera: 'already-off' });
});
