/**
 * Join with the mic and camera off — the lobby muter.
 *
 * On Meet's joining screen ("Ready to join?" / "¿Todo listo para unirte?") the user's own mic and
 * camera toggles are live before the call is joined. With `lobbyMuteMic` / `lobbyMuteCamera` on,
 * this turns each one off ONCE per lobby visit, so the user walks into the call muted unless they
 * deliberately turned it back on.
 *
 * Rules, all of which exist so this never fights the user:
 * - Acts only in the lobby: a lobby tell is visible (`TWPresence.findLobbyTell()`), the in-call
 *   ladder says not in the call, and no session exists. Inside the call the user and the app's
 *   floating controls own the toggles.
 * - One click per toggle per visit. A visit is the call code; it re-arms when the code changes, or
 *   when the lobby shows again after a session for that code ended (a rejoin). Turning the mic back
 *   on in the lobby is respected — it is never clicked again in the same visit.
 * - Only a toggle that reads live (`muted === false`), enabled, is clicked. One already off is left
 *   alone. A toggle that stays missing, unreadable or disabled for `maxTicks` ticks is given up on
 *   with one diagnostic line.
 * - Every log line is a transition: at most one per toggle per visit (two when a click is re-read).
 *
 * Pure apart from the injected `findControl` / `log` / `schedule`, so it is tested under
 * `node --test` without a DOM.
 */

(() => {
  const DEFAULT_SETTLE_MS = 150;
  const DEFAULT_MAX_TICKS = 10;
  const KINDS = ['mic', 'camera'];
  const NAMES = { mic: 'microphone', camera: 'camera' };
  const SETTING = { mic: 'lobbyMuteMic', camera: 'lobbyMuteCamera' };

  // Per-toggle outcome, also what the status reports: `null` (nothing yet / setting off),
  // `'clicked'` (waiting for the settle re-read), `'turned-off'`, `'already-off'`, `'left-on'`
  // (clicked, still reads live) or `'unreadable'` (given up).

  function createLobbyMuter({
    findControl,
    findLobbyTell = () => null,
    log = () => {},
    schedule = (fn, ms) => setTimeout(fn, ms),
    settleMs = DEFAULT_SETTLE_MS,
    maxTicks = DEFAULT_MAX_TICKS,
    onChange = () => {},
  } = {}) {
    let visit = null; // call code of the current lobby visit
    let joined = false; // a session (or the call) was seen during this visit
    let kinds = freshKinds();

    function freshKinds() {
      return Object.fromEntries(KINDS.map((kind) => [kind, { result: null, misses: 0 }]));
    }

    function snapshot() {
      return Object.fromEntries(KINDS.map((kind) => [kind, kinds[kind].result]));
    }

    function set(kind, result) {
      if (kinds[kind].result === result) return;
      kinds[kind].result = result;
      onChange(snapshot());
    }

    function rearm(code) {
      const hadResults = KINDS.some((kind) => kinds[kind].result !== null);
      visit = code;
      joined = false;
      kinds = freshKinds();
      if (hadResults) onChange(snapshot());
    }

    function settle(kind) {
      const control = findControl(kind);
      const via = control ? ` (via ${control.via})` : '';
      if (control && control.muted === true) {
        set(kind, 'turned-off');
        log(`lobby: turned off the ${NAMES[kind]}${via}`);
      } else {
        set(kind, 'left-on');
        log(
          `lobby: clicked the ${NAMES[kind]} toggle${via} but it does not read as off` +
            (control ? (control.muted === null ? ' (state unreadable)' : '') : ' (toggle gone)') +
            '; not clicking it again'
        );
      }
    }

    function step(kind) {
      const state = kinds[kind];
      if (state.result !== null) return; // one decision per toggle per visit
      const control = findControl(kind);
      const readable = control && control.muted !== null && !control.disabled;
      if (!readable) {
        state.misses += 1;
        if (state.misses >= maxTicks) {
          set(kind, 'unreadable');
          const why = !control ? 'not found' : control.disabled ? 'disabled' : 'state unreadable';
          log(
            `lobby: could not read the ${NAMES[kind]} toggle (${why}) after ${maxTicks} ticks; leaving it as it is.`,
            'If Meet renamed the control, repair CALL_CONTROLS in selectors.js.'
          );
        }
        return;
      }
      if (control.muted === true) {
        set(kind, 'already-off');
        log(`lobby: ${NAMES[kind]} already off (via ${control.via})`);
        return;
      }
      set(kind, 'clicked');
      control.element.click();
      schedule(() => settle(kind), settleMs);
    }

    /**
     * One loop tick. `inLobby` is whether a lobby tell is visible (falls back to `findLobbyTell()`),
     * `inCall` the in-call ladder's answer, `hasSession` whether a capture session exists.
     * Returns the per-toggle results.
     */
    function tick({ callCode, inLobby, inCall = false, hasSession = false, settings = {} } = {}) {
      if (!callCode) return snapshot();
      if (callCode !== visit) rearm(callCode);
      if (inCall || hasSession) {
        joined = true;
        return snapshot();
      }
      const lobby = inLobby === undefined ? Boolean(findLobbyTell()) : Boolean(inLobby);
      if (!lobby) return snapshot();
      // Back in the lobby after a session for this code ended: a rejoin is a new visit.
      if (joined) rearm(callCode);
      if (settings.enabled === false) return snapshot();
      for (const kind of KINDS) {
        if (settings[SETTING[kind]] === false) continue;
        step(kind);
      }
      return snapshot();
    }

    return { tick, snapshot };
  }

  const TWLobbyAPI = { createLobbyMuter, DEFAULT_MAX_TICKS };
  if (typeof self !== 'undefined') self.TWLobby = TWLobbyAPI;
  if (typeof module !== 'undefined' && module.exports) module.exports = TWLobbyAPI;
})();
