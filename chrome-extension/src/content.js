/**
 * Content script: watches the Meet caption region and ships stabilized turns to the service worker.
 *
 * It never talks to the network itself — see the note at the top of `background.js`. Its job is
 * DOM observation plus keeping a port open (an open port is also what stops MV3 from evicting the
 * worker mid-call), plus two pieces of tightly bounded UI automation: the captions auto-enable
 * click and the one-shot caption-language steering. Both fail soft — a miss is logged and capture
 * carries on untouched.
 */

(() => {
  const TICK_MS = 1000;
  const PORT_RECYCLE_MS = 4 * 60 * 1000; // Chrome caps port lifetime at 5 minutes.
  const CAPTIONS_WARN_AFTER_MS = 25_000;
  // How often the app is told the call is still open. The app stops counting a caption session as
  // "in a meeting" after five minutes without a caption or one of these, so a minute leaves room
  // for several to go missing.
  const HEARTBEAT_MS = 60_000;

  // Auto-enable bounds: never click-fight a user who deliberately turned captions off.
  const AUTO_CC_MAX_ATTEMPTS = 3;
  const AUTO_CC_COOLDOWN_MS = 5000;
  const AUTO_CC_WINDOW_MS = 30_000; // only within the first ~30s of a session

  // Language steering: how long (in ticks) to look for the settings entry point once captions are
  // on, and how long to wait for an opened picker to render its options.
  const LANG_ENTRY_SEARCH_TICKS = 20;
  const LANG_DIALOG_WAIT_TICKS = 5;

  // Messages that failed to reach the worker wait here until the next successful connect. Capped
  // for the same reason as the worker's MAX_BUFFER, and dropping from the *front* for the same
  // reason too: if the worker stays unreachable long enough to overflow this, the newest captions
  // are the ones worth keeping.
  const MAX_OUTBOX = 200;

  let port = null;
  /** @type {object[]} unsent messages, oldest first. */
  const outbox = [];
  let portTimer = null;
  let tickTimer = null;
  let observer = null;
  let stabilizer = null;
  let captionRoot = null;
  let pendingHeuristic = null; // { root, text } — heuristic roots must mutate before adoption
  let sessionKey = null;
  let sessionStartedAt = null;
  let notInCallTicks = 0;
  let lastHeartbeatAt = 0;
  let warnedAboutCaptions = false;
  let enabled = true;
  let autoEnableCaptions = true;
  let preferredCaptionLanguage = '';
  let hideCaptionOverlay = true;
  let ccAttempts = 0;
  let lastCcAttemptAt = 0;
  // One-shot state machine for caption-language steering: idle → opened → selected → done, with
  // gave-up as the terminal failure state. Reset per session (and on a language-setting change).
  let langSteer = { phase: 'idle', entryTicks: 0, dialogTicks: 0 };

  const log = (...args) => console.log('[tw-meet]', ...args);

  function connect() {
    try {
      port = chrome.runtime.connect({ name: 'tw-meet' });
    } catch (error) {
      log('could not connect to the extension worker:', error.message);
      return;
    }
    port.onMessage.addListener((message) => {
      if (message.type === 'session-ready') {
        log('meeting id', message.meetingId);
        adoptSessionStart(message.startedAt);
      }
      if (message.type === 'error') log('worker error:', message.message);
    });
    port.onDisconnect.addListener(() => {
      port = null;
    });

    if (sessionKey) {
      const start = {
        type: 'session-start',
        sessionKey,
        title: TWSelectors.readMeetingTitle(),
        account: TWSelectors.readAccountEmail(),
        startedAt: sessionStartedAt,
      };
      // Announced ahead of the outbox: the worker may have been evicted and needs the session key
      // before buffered segments mean anything. If even this fails, it goes to the *front* of the
      // outbox so the next connect still sends it first.
      if (!sendNow(start)) outbox.unshift(start);
    }
    drainOutbox();
  }

  /** Post over the live port, reporting failure instead of reconnecting. Never throws. */
  function sendNow(message) {
    if (!port) return false;
    try {
      port.postMessage(message);
      return true;
    } catch {
      port = null;
      return false;
    }
  }

  function post(message) {
    if (!port) connect();
    if (sendNow(message)) return;
    // The worker recycled between our check and the send. A caption turn exists *only here* until
    // the worker has it — the worker's storage buffer cannot cover a message it never received — so
    // hold it and reconnect; `connect()` drains the outbox once the new port is up. Failing sends
    // must never block the observer, hence buffer-and-continue rather than retry inline.
    queueForRetry(message);
    connect();
  }

  function queueForRetry(message) {
    outbox.push(message);
    if (outbox.length > MAX_OUTBOX) {
      const dropped = outbox.splice(0, outbox.length - MAX_OUTBOX).length;
      log(`outbox full — dropped the ${dropped} oldest unsent message(s)`);
    }
  }

  /** Flush buffered messages in order; anything still unsent goes back to the front of the queue. */
  function drainOutbox() {
    if (!port || outbox.length === 0) return;
    const pending = outbox.splice(0, outbox.length);
    log(`resending ${pending.length} buffered message(s) after reconnect`);
    for (let i = 0; i < pending.length; i += 1) {
      if (!sendNow(pending[i])) {
        outbox.unshift(...pending.slice(i));
        return;
      }
    }
  }

  /**
   * Adopt the worker's authoritative meeting start.
   *
   * The stabilizer is created with `Date.now()` because the page has nothing better, but the worker
   * *resumes* a session by call code — after a mid-call reload the meeting already started minutes
   * ago, and timestamping from the reload instant would fold the second half of the call on top of
   * the first (the segments API takes seconds relative to the meeting start). So the worker reports
   * the start it has persisted and we re-base on it.
   *
   * Residual: segments emitted in the sub-second before `session-ready` arrives still carry the
   * local base. That is at most the first tick, and downstream speaker transfer is text-anchored.
   */
  function adoptSessionStart(startedAt) {
    if (!stabilizer || !startedAt) return;
    const parsed = Date.parse(startedAt);
    if (!Number.isFinite(parsed)) return;
    // Reject nonsense rather than silently shifting the whole transcript: a start in the future, or
    // one from a stale session persisted under this call code days ago.
    if (parsed > Date.now() + 60_000 || Date.now() - parsed > 12 * 60 * 60 * 1000) {
      log('ignoring implausible session start from the worker:', startedAt);
      return;
    }
    if (parsed === stabilizer.sessionStart) return;

    const shiftSeconds = Math.round((stabilizer.sessionStart - parsed) / 1000);
    stabilizer.sessionStart = parsed;
    log(
      `adopted the meeting start reported by the worker (${startedAt});`,
      `caption timestamps shift by +${shiftSeconds}s`
    );
  }

  function startSession() {
    const code = TWSelectors.readCallCode();
    if (!code || code === sessionKey) return;

    if (sessionKey) endSession();
    sessionKey = code;
    // Page-local start: only ever used for the *this page* windows (captions warning, auto-CC), which
    // must stay relative to when this content script started, not to the meeting.
    sessionStartedAt = new Date().toISOString();
    // Provisional timestamp base — replaced by the worker's persisted start on `session-ready`
    // (see `adoptSessionStart`), which is what makes a mid-call reload keep meeting-relative times.
    stabilizer = new CaptionStabilizer({ sessionStart: Date.now() });
    warnedAboutCaptions = false;
    // The session start is itself a sign of life; the first heartbeat follows one interval later.
    lastHeartbeatAt = Date.now();
    ccAttempts = 0;
    lastCcAttemptAt = 0;
    langSteer = { phase: 'idle', entryTicks: 0, dialogTicks: 0 };
    log('session started for call', sessionKey);
    connect();
    post({
      type: 'session-start',
      sessionKey,
      title: TWSelectors.readMeetingTitle(),
      account: TWSelectors.readAccountEmail(),
      startedAt: sessionStartedAt,
    });
  }

  function endSession() {
    if (!sessionKey) return;
    if (stabilizer) {
      const remaining = stabilizer.flushAll(Date.now());
      if (remaining.length) post({ type: 'segments', sessionKey, segments: remaining });
    }
    post({ type: 'session-end', sessionKey });
    log('session ended for call', sessionKey);
    sessionKey = null;
    stabilizer = null;
  }

  /**
   * Keep-alive for a quiet call: captions are the app's only other evidence that the meeting is
   * still running, and a long silence (or captions that never turned on) would otherwise read as
   * "the call is over". Sent only while someone else is in the room — sitting alone in an open
   * call is not a meeting, and that is exactly the tab-left-open case this must not keep alive.
   * An unreadable head count still sends: the leave button says the call is open, and a broken
   * probe must not end it.
   */
  function maybeHeartbeat() {
    if (!sessionKey || Date.now() - lastHeartbeatAt < HEARTBEAT_MS) return;
    lastHeartbeatAt = Date.now();
    const participants = TWSelectors.readParticipantCount();
    if (participants !== null && participants <= 1) return;
    // Never queued for retry: a heartbeat that missed its moment is worthless, the next one is due
    // in a minute anyway.
    if (!port) connect();
    sendNow({ type: 'heartbeat', sessionKey, participants });
  }

  function attachObserver() {
    const found = TWSelectors.findCaptionRoot();
    if (!found) {
      pendingHeuristic = null;
      return false;
    }
    if (captionRoot === found.root) return true;

    if (found.via === 'heuristic') {
      // A selector rung *identifies* captions; the heuristic only suspects them, and lobby tiles
      // and open menus score on it too. So a heuristic root must first behave like captions —
      // its text must change between two ticks — before we adopt it and start shipping its text.
      const text = (found.root.innerText || '').trim();
      if (!pendingHeuristic || pendingHeuristic.root !== found.root) {
        pendingHeuristic = { root: found.root, text };
        return false;
      }
      if (pendingHeuristic.text === text) return false;
      pendingHeuristic = null;
    }

    observer?.disconnect();
    captionRoot = found.root;
    observer = new MutationObserver(() => tick());
    observer.observe(captionRoot, { childList: true, subtree: true, characterData: true });
    log('attached to caption region via', found.via);
    if (hideCaptionOverlay) hideOverlay(captionRoot);
    return true;
  }

  /**
   * Visually hide the caption overlay while keeping it fully readable.
   *
   * CRITICAL: this must stay `opacity` — never `display: none` or `visibility: hidden`. For
   * non-rendered elements `innerText` falls back to `textContent`, which drops the layout-derived
   * `\n` line structure that `parseCaptionBlock` uses to split speaker from speech; captions would
   * keep "working" while silently mis-attributing every turn. An opacity-0 element still has
   * layout, so `innerText` (and our parsing) is unaffected.
   */
  function hideOverlay(root) {
    if (!root) return;
    root.style.setProperty('opacity', '0', 'important');
    root.style.setProperty('pointer-events', 'none', 'important');
    log('caption overlay hidden (captions are still captured)');
  }

  function showOverlay(root) {
    if (!root) return;
    root.style.removeProperty('opacity');
    root.style.removeProperty('pointer-events');
    log('caption overlay restored');
  }

  function tick() {
    if (!enabled || !sessionKey || !stabilizer) return;
    if (!captionRoot || !document.contains(captionRoot)) {
      if (!attachObserver()) {
        maybeWarnAboutCaptions();
        return;
      }
    }

    // Meet occasionally rebuilds inline styles on the caption container; re-assert the hiding
    // whenever it has been wiped (adoption of a rotated root re-applies it in attachObserver).
    if (hideCaptionOverlay && captionRoot.style.opacity !== '0') hideOverlay(captionRoot);

    const blocks = TWSelectors.readCaptionBlocks(captionRoot);
    const segments = stabilizer.observe(blocks, Date.now());
    if (segments.length) {
      log(`+${segments.length} segment(s)`, segments.map((s) => `${s.speaker ?? '?'}: ${s.text}`));
      post({ type: 'segments', sessionKey, segments });
    }
  }

  function maybeWarnAboutCaptions() {
    if (warnedAboutCaptions || !sessionStartedAt) return;
    if (Date.now() - Date.parse(sessionStartedAt) < CAPTIONS_WARN_AFTER_MS) return;
    warnedAboutCaptions = true;

    const toggle = TWSelectors.findCaptionToggle();
    if (toggle) {
      log(
        'no captions detected — turn on captions in Meet (the CC button) for speaker-attributed transcript' +
          (ccAttempts > 0 ? ` (auto-enable clicked the toggle ${ccAttempts}x without effect)` : '')
      );
    } else {
      log(
        'no caption region found. Meet may have changed its DOM. Candidate containers:',
        TWSelectors.describeCandidates()
      );
    }
  }

  /**
   * Click the CC button when a session starts without captions. Meet makes captions per-call
   * opt-in, so this runs early in every session — but strictly bounded (attempt cap, cooldown,
   * first-30s window) so a user who deliberately turns captions off mid-call is never fought.
   */
  function maybeAutoEnableCaptions() {
    if (!autoEnableCaptions || !sessionKey || !sessionStartedAt) return;
    if (captionRoot && document.contains(captionRoot)) return; // captions already detected
    if (TWSelectors.captionsAppearActive()) return;
    if (Date.now() - Date.parse(sessionStartedAt) > AUTO_CC_WINDOW_MS) return;
    if (ccAttempts >= AUTO_CC_MAX_ATTEMPTS) return;
    if (Date.now() - lastCcAttemptAt < AUTO_CC_COOLDOWN_MS) return;

    const toggle = TWSelectors.findCaptionToggle();
    if (!toggle) return; // no localized label matched; maybeWarnAboutCaptions covers diagnostics

    // `captionToggleState` is tri-state: true = on, false = off, null = no aria-pressed at all.
    // With no attribute we fall back to what we already checked above — no caption region is
    // rendering any text — and treat that as off.
    const state = TWSelectors.captionToggleState(toggle);
    if (state === true) return; // toggle says on; the region just has not rendered yet

    ccAttempts += 1;
    lastCcAttemptAt = Date.now();
    log(
      `auto-enabling captions: clicking the CC toggle (attempt ${ccAttempts}/${AUTO_CC_MAX_ATTEMPTS},` +
        ` toggle reports ${state === null ? 'unknown (no aria-pressed)' : 'off'})`
    );
    toggle.click();
  }

  /** Close whatever Meet dialog/menu is open, the way a user would. */
  function sendEscape() {
    const target = document.activeElement || document.body;
    for (const type of ['keydown', 'keyup']) {
      target.dispatchEvent(
        new KeyboardEvent(type, {
          key: 'Escape',
          code: 'Escape',
          keyCode: 27,
          which: 27,
          bubbles: true,
          cancelable: true,
        })
      );
    }
  }

  /**
   * One-shot, best-effort steering of Meet's caption language: open the caption-settings entry
   * point, click the option matching `preferredCaptionLanguage`, close the dialog. This is
   * speculative DOM automation over UI we do not control, so it is a state machine across ticks
   * (idle → opened → selected → done / gave-up) with exactly one attempt per session: any failure
   * presses Escape, dumps the open picker's candidates for ladder repair, and gives up cleanly —
   * caption capture itself is never at risk.
   */
  function stepLanguageSteering() {
    if (!preferredCaptionLanguage || !sessionKey) return;
    if (langSteer.phase === 'done' || langSteer.phase === 'gave-up') return;

    if (langSteer.phase === 'idle') {
      // Only steer once captions are actually on — the language picker lives behind them.
      if (!captionRoot || !document.contains(captionRoot)) return;

      const entry = TWSelectors.findCaptionSettingsButton();
      if (!entry) {
        langSteer.entryTicks += 1;
        if (langSteer.entryTicks >= LANG_ENTRY_SEARCH_TICKS) {
          langSteer.phase = 'gave-up';
          log(
            'caption-language steering: no caption-settings entry point found; leaving the language as Meet has it.',
            'If Meet renamed the control, repair CAPTION_SETTINGS_LABELS in selectors.js.'
          );
        }
        return;
      }
      log(
        `caption-language steering: opening caption settings to select "${preferredCaptionLanguage}"`,
        '(one attempt per call)'
      );
      entry.click();
      langSteer.phase = 'opened';
      return;
    }

    if (langSteer.phase === 'opened') {
      const candidates = TWSelectors.collectLanguageOptions();
      const match = TWSelectors.matchLanguageOption(candidates, preferredCaptionLanguage);
      if (match) {
        log('caption-language steering: selecting', match.dataValue || match.label);
        match.element.click();
        langSteer.phase = 'selected';
        return;
      }
      langSteer.dialogTicks += 1;
      if (langSteer.dialogTicks >= LANG_DIALOG_WAIT_TICKS) {
        langSteer.phase = 'gave-up';
        log(
          `caption-language steering: no option matched "${preferredCaptionLanguage}" — giving up.`,
          'Candidates in the open picker (repair matchLanguageOption/CAPTION_LANGUAGE_NAMES from this):',
          TWSelectors.describeLanguageCandidates()
        );
        sendEscape();
      }
      return;
    }

    if (langSteer.phase === 'selected') {
      sendEscape();
      langSteer.phase = 'done';
      log('caption-language steering: language selected, dialog closed');
    }
  }

  function onCallPath() {
    // The call-code path appears for the lobby ("Ready to join?") as well as the call itself, so
    // this alone must never start capture — the lobby's tiles and menus are what the heuristic
    // used to scrape as "captions". `TWSelectors.inActiveCall()` supplies the joined signal.
    return /^\/[a-z]{3}-[a-z]{4}-[a-z]{3}/i.test(location.pathname);
  }

  function loop() {
    if (!enabled) return;
    if (onCallPath() && TWSelectors.inActiveCall()) {
      notInCallTicks = 0;
      startSession();
      attachObserver();
      maybeAutoEnableCaptions();
      stepLanguageSteering();
      tick();
      maybeHeartbeat();
    } else if (sessionKey) {
      // Leaving must stick for a few ticks before we end the session: the leave-button probe can
      // miss for a frame during Meet's DOM churn, and a spurious end would complete the meeting
      // and fork a fresh one on the next tick. A path change is unambiguous — end immediately.
      notInCallTicks += 1;
      if (!onCallPath() || notInCallTicks >= 3) {
        endSession();
        notInCallTicks = 0;
      }
    }
  }

  // This file is a classic content script (not a module), so it cannot import DEFAULT_SETTINGS
  // from config.js — the inline defaults here must mirror it.
  chrome.storage.local
    .get({
      enabled: true,
      autoEnableCaptions: true,
      preferredCaptionLanguage: '',
      hideCaptionOverlay: true,
    })
    .then((settings) => {
      enabled = settings.enabled !== false;
      autoEnableCaptions = settings.autoEnableCaptions !== false;
      preferredCaptionLanguage = settings.preferredCaptionLanguage || '';
      hideCaptionOverlay = settings.hideCaptionOverlay !== false;
      if (!enabled) {
        log('disabled in options; not observing');
        return;
      }

      tickTimer = setInterval(loop, TICK_MS);
      portTimer = setInterval(() => {
        // Proactive recycle: a port Chrome tears down at the 5-minute mark would otherwise take the
        // service worker with it in the middle of a call.
        port?.disconnect();
        port = null;
        connect();
      }, PORT_RECYCLE_MS);
      loop();
    });

  chrome.storage.onChanged.addListener((changes) => {
    if (changes.enabled) {
      enabled = changes.enabled.newValue !== false;
      if (!enabled) endSession();
    }
    if (changes.autoEnableCaptions) {
      autoEnableCaptions = changes.autoEnableCaptions.newValue !== false;
    }
    if (changes.preferredCaptionLanguage) {
      preferredCaptionLanguage = changes.preferredCaptionLanguage.newValue || '';
      // A newly chosen language mid-call gets its own single attempt.
      langSteer = { phase: 'idle', entryTicks: 0, dialogTicks: 0 };
      if (preferredCaptionLanguage) {
        log(`caption language preference changed to "${preferredCaptionLanguage}"`);
      }
    }
    if (changes.hideCaptionOverlay) {
      hideCaptionOverlay = changes.hideCaptionOverlay.newValue !== false;
      if (captionRoot && document.contains(captionRoot)) {
        if (hideCaptionOverlay) hideOverlay(captionRoot);
        else showOverlay(captionRoot);
      }
    }
  });

  // `pagehide` fires for tab close, navigation, and bfcache eviction alike; `beforeunload` does not
  // fire reliably in all of those.
  window.addEventListener('pagehide', () => {
    endSession();
    clearInterval(tickTimer);
    clearInterval(portTimer);
  });
})();
