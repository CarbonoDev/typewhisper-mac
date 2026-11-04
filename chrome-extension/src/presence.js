/**
 * Are we in the call, or still in the lobby? — the "in call" ladder.
 *
 * The lobby ("Ready to join?"), the knock screen ("Asking to be let in…") and the call itself all
 * share the `/abc-defg-hij` (or `/meet/abc-defg-hij`) path, so the URL never decides. Nothing starts a session until one rung
 * below matches; any ONE rung is enough, so a Meet redesign has to break all of them at once before
 * the bridge goes silent. Rungs, checked in this order (the matching rung is reported as `via`):
 *
 *   Strong — only ever rendered once actually joined; trusted on their own:
 *   1. `leave-label`     — the leave/hang-up button by its localized aria-label (LEAVE_CALL_LABELS).
 *   2. `caption-selector`— a caption container found by a precise selector (CAPTION_CONTAINER_SELECTORS).
 *   3. `caption-region`  — a captions *region* found by label (never the CC toggle; see selectors.js).
 *
 *   Lobby-gated — each is vetoed while any lobby tell is visible (a join button by label/text/jsname,
 *   a "ready to join" / knock / "you left" text; LOBBY_*). The veto is what keeps pre-join junk
 *   meetings out: the mic/camera toggles, for one, exist in the lobby too.
 *   4. `leave-jsname`    — the leave button by Meet's own handle (LEAVE_CALL_JSNAMES).
 *   5. `hangup-icon`     — a button carrying the `call_end` Material ligature (its icon *text*), in
 *                          its label or its content — locale-independent.
 *   6. `side-panels`     — at least two of the call's side-panel buttons (details / people / chat /
 *                          activities), by label (SIDE_PANEL_LABELS).
 *   7. `mic-toggle`      — the user's own mic toggle with a readable `data-is-muted`, found by
 *                          `findCallControl('mic')` (jsname, label, or the "(⌘ + d)" shortcut hint).
 *
 * `detectInCall()` also returns every probe's result, which `explainNotInCall()` turns into the
 * plain-words "why not" the popup shows — the repair hint for when Meet changes.
 *
 * Residual risk, by design: in a UI locale none of the LOBBY_* lists covers, rung 7 can fire in the
 * lobby. The content script additionally requires the signal to hold for two ticks.
 */

(() => {
  const S =
    typeof TWSelectors !== 'undefined'
      ? TWSelectors // eslint-disable-line no-undef
      : typeof require === 'function'
        ? require('./selectors.js')
        : null;

  /** aria-labels of the leave/end-call button, per locale — present only once actually in the call. */
  const LEAVE_CALL_LABELS = [
    'leave call', // en
    'leave meeting',
    'end call',
    'hang up',
    'anruf verlassen', // de
    'anruf beenden',
    'besprechung verlassen',
    'salir de la llamada', // es
    'abandonar la llamada',
    'salir de la reunión',
    'salir de la reunion',
    'abandonar la reunión',
    'colgar',
    'finalizar llamada',
    'quitter l’appel', // fr
    "quitter l'appel",
    'quitter la réunion',
    'sair da chamada', // pt
    'sair da reunião',
    'encerrar chamada',
    'abbandona la chiamata', // it
    'esci dalla chiamata',
    'gesprek verlaten', // nl
  ];

  /** Meet's internal handle for the leave button. Speculative; lobby-gated for that reason. */
  const LEAVE_CALL_JSNAMES = ['CQylAd'];

  /** The hang-up icon as Meet renders it: a Material ligature, i.e. literal text. */
  const HANGUP_ICONS = ['call_end'];

  /** Side-panel toggles that only exist in the call's toolbar, grouped by panel. */
  const SIDE_PANEL_LABELS = {
    details: ['meeting details', 'call details', 'detalles de la reunión', 'detalles de la llamada', 'besprechungsdetails', 'détails de la réunion', 'detalhes da reunião', 'dettagli della riunione'],
    people: ['show everyone', 'people', 'participants', 'mostrar a todos', 'personas', 'participantes', 'alle anzeigen', 'personen', 'teilnehmer', 'afficher tout le monde', 'pessoas', 'persone', 'partecipanti', 'deelnemers'],
    chat: ['chat with everyone', 'chatear con todos', 'chat con todos', 'mit allen chatten', 'discuter avec tous', 'conversar com todos', 'chatta con tutti', 'chatten met iedereen', 'in-call messages', 'mensajes de la llamada'],
    activities: ['activities', 'actividades', 'aktivitäten', 'activités', 'atividades', 'attività', 'activiteiten'],
  };

  /** The lobby's join button (label or visible text), per locale. Its presence vetoes rungs 4–7. */
  const LOBBY_JOIN_LABELS = [
    'join now', // en
    'ask to join',
    'join here too',
    'switch here',
    'rejoin',
    'unirse ahora', // es
    'unirme ahora',
    'pedir unirse',
    'pedir unirme',
    'solicitar unirse',
    'solicitar unirme',
    'volver a unirse',
    'volver a unirte',
    'unirse aquí también',
    'jetzt teilnehmen', // de
    'teilnahme anfragen',
    'erneut teilnehmen',
    'participer', // fr ("Participer à la réunion" stays in-call-free: lobby only)
    'demander à participer',
    'participar agora', // pt
    'pedir para participar',
    'partecipa ora', // it
    'chiedi di partecipare',
    'nu deelnemen', // nl
    'vragen om deel te nemen',
  ];

  const escapeRegExp = (value) => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const LOBBY_JOIN_PATTERNS = LOBBY_JOIN_LABELS.map((needle) => ({
    needle,
    pattern: new RegExp(`(^|[^\\p{L}])${escapeRegExp(needle)}($|[^\\p{L}])`, 'u'),
  }));

  /** Meet's internal handle for the lobby join button. */
  const LOBBY_JOIN_JSNAMES = ['Qx7uuf'];

  /** Lobby, knock and post-call screen texts (substring of the page text). */
  const LOBBY_TEXTS = [
    'ready to join?',
    'asking to be let in',
    'someone lets you in',
    'you left the meeting',
    '¿todo listo para unirte?',
    'listo para unirte',
    'pidiendo que te dejen entrar',
    'alguien te deje entrar',
    'saliste de la reunión',
    'abandonaste la reunión',
    'bereit zum teilnehmen',
    'prêt à participer',
    'pronto para participar',
    'pronto a partecipare',
    'klaar om deel te nemen',
  ];

  const lower = (value) => String(value || '').toLowerCase();
  const textOf = (el) => lower(el.textContent != null ? el.textContent : el.innerText).trim();
  const labelOf = (el) =>
    `${lower(el.getAttribute('aria-label'))} ${lower(el.getAttribute('data-tooltip'))}`.trim();
  const includesAny = (haystack, needles) => needles.find((needle) => haystack.includes(needle)) || null;

  function allButtons() {
    return Array.from(document.querySelectorAll('button, [role="button"]'));
  }

  /** The first lobby tell on the page (`"join button: join now"`), or `null`. */
  function findLobbyTell(buttons = allButtons()) {
    for (const el of buttons) {
      const jsname = el.getAttribute('jsname');
      if (jsname && LOBBY_JOIN_JSNAMES.includes(jsname)) return `join button (jsname ${jsname})`;
      const label = labelOf(el);
      // Visible text only when short: a join button says two or three words, a panel says a lot.
      const text = textOf(el);
      const own = [label, text.length <= 40 ? text : ''].join(' ');
      // Whole-phrase match so "participer" never hits "participants".
      const hit = LOBBY_JOIN_PATTERNS.find(({ pattern }) => pattern.test(own));
      if (hit) return `join button "${hit.needle}"`;
    }
    const body = typeof document !== 'undefined' && document.body ? textOf(document.body) : '';
    const text = includesAny(body, LOBBY_TEXTS);
    return text ? `lobby text "${text}"` : null;
  }

  /**
   * Run every probe. Returns `{ inCall, via, lobby, probes }` — `via` is the first matching rung
   * (see the header), `lobby` the lobby tell that vetoed the weak rungs (or `null`).
   */
  function detectInCall() {
    const buttons = allButtons();
    const probes = {
      leaveLabel: null,
      captionSelector: null,
      captionRegion: false,
      leaveJsname: null,
      hangupIcon: false,
      sidePanels: [],
      micToggle: null,
    };

    for (const el of buttons) {
      const label = labelOf(el);
      if (!probes.leaveLabel && label) probes.leaveLabel = includesAny(label, LEAVE_CALL_LABELS);
      const jsname = el.getAttribute('jsname');
      if (!probes.leaveJsname && jsname && LEAVE_CALL_JSNAMES.includes(jsname)) probes.leaveJsname = jsname;
      if (!probes.hangupIcon) {
        const tokens = `${label} ${textOf(el)}`.split(/\s+/);
        probes.hangupIcon = HANGUP_ICONS.some((icon) => tokens.includes(icon));
      }
      for (const [panel, labels] of Object.entries(SIDE_PANEL_LABELS)) {
        if (!probes.sidePanels.includes(panel) && label && labels.some((needle) => label === needle || label.startsWith(`${needle} `) || label.startsWith(`${needle}(`))) {
          probes.sidePanels.push(panel);
        }
      }
    }
    if (S) {
      probes.captionSelector =
        S.CAPTION_CONTAINER_SELECTORS.find((selector) => document.querySelector(selector)) || null;
      probes.captionRegion = S.captionRegionsByLabel().length > 0;
      const mic = S.findCallControl('mic');
      probes.micToggle = mic && mic.muted !== null ? mic.via : null;
    }

    const result = (inCall, via, lobby = null) => ({ inCall, via, lobby, probes });
    if (probes.leaveLabel) return result(true, 'leave-label');
    if (probes.captionSelector) return result(true, 'caption-selector');
    if (probes.captionRegion) return result(true, 'caption-region');

    const weak = probes.leaveJsname
      ? 'leave-jsname'
      : probes.hangupIcon
        ? 'hangup-icon'
        : probes.sidePanels.length >= 2
          ? 'side-panels'
          : probes.micToggle
            ? 'mic-toggle'
            : null;
    // The lobby check is the expensive one (page text), so it only runs when it can change the answer.
    const lobby = findLobbyTell(buttons);
    if (!weak) return result(false, null, lobby);
    return lobby ? result(false, null, lobby) : result(true, weak);
  }

  function inActiveCall() {
    return detectInCall().inCall;
  }

  /** Plain-words "why are we not in the call", for the popup and the diagnostics. */
  function explainNotInCall(detection) {
    if (!detection || detection.inCall) return '';
    const p = detection.probes || {};
    const parts = [];
    if (detection.lobby) {
      parts.push(`this looks like the lobby or a waiting screen (${detection.lobby})`);
    }
    parts.push(`leave button not found (labels tried: ${LEAVE_CALL_LABELS.slice(0, 6).join(', ')}, …)`);
    parts.push(p.hangupIcon ? 'hang-up icon seen' : 'no hang-up icon');
    parts.push(p.captionSelector || p.captionRegion ? 'caption region seen' : 'no caption region');
    parts.push(p.micToggle ? `mic toggle readable (${p.micToggle})` : 'mic toggle not readable');
    parts.push(
      p.sidePanels && p.sidePanels.length
        ? `side-panel buttons: ${p.sidePanels.join(', ')}`
        : 'no side-panel buttons'
    );
    return `No in-call signal matched: ${parts.join('; ')}.`;
  }

  /** Human name of a rung, for log lines and the popup. */
  const RUNG_NAMES = {
    'leave-label': 'leave button (label)',
    'caption-selector': 'caption container',
    'caption-region': 'caption region (label)',
    'leave-jsname': 'leave button (jsname)',
    'hangup-icon': 'hang-up icon',
    'side-panels': 'side-panel buttons',
    'mic-toggle': 'mic toggle outside the lobby',
  };

  const TWPresenceAPI = {
    detectInCall,
    inActiveCall,
    explainNotInCall,
    findLobbyTell,
    RUNG_NAMES,
    LEAVE_CALL_LABELS,
    LOBBY_JOIN_LABELS,
  };
  if (typeof self !== 'undefined') self.TWPresence = TWPresenceAPI;
  if (typeof module !== 'undefined' && module.exports) module.exports = TWPresenceAPI;
})();
