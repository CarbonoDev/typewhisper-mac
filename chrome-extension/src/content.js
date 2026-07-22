/**
 * Content script: watches the Meet caption region and ships stabilized turns to the service worker.
 *
 * It never talks to the network itself — see the note at the top of `background.js`. Its whole job
 * is DOM observation plus keeping a port open, because an open port is also what stops MV3 from
 * evicting the worker mid-call.
 */

(() => {
  const TICK_MS = 1000;
  const PORT_RECYCLE_MS = 4 * 60 * 1000; // Chrome caps port lifetime at 5 minutes.
  const CAPTIONS_WARN_AFTER_MS = 25_000;

  let port = null;
  let portTimer = null;
  let tickTimer = null;
  let observer = null;
  let stabilizer = null;
  let captionRoot = null;
  let pendingHeuristic = null; // { root, text } — heuristic roots must mutate before adoption
  let sessionKey = null;
  let sessionStartedAt = null;
  let notInCallTicks = 0;
  let warnedAboutCaptions = false;
  let enabled = true;

  const log = (...args) => console.log('[tw-meet]', ...args);

  function connect() {
    try {
      port = chrome.runtime.connect({ name: 'tw-meet' });
    } catch (error) {
      log('could not connect to the extension worker:', error.message);
      return;
    }
    port.onMessage.addListener((message) => {
      if (message.type === 'session-ready') log('meeting id', message.meetingId);
      if (message.type === 'error') log('worker error:', message.message);
    });
    port.onDisconnect.addListener(() => {
      port = null;
    });

    if (sessionKey) {
      post({
        type: 'session-start',
        sessionKey,
        title: TWSelectors.readMeetingTitle(),
        account: TWSelectors.readAccountEmail(),
        startedAt: sessionStartedAt,
      });
    }
  }

  function post(message) {
    if (!port) connect();
    try {
      port?.postMessage(message);
    } catch {
      // The worker recycled between our check and the send; reconnect and drop this message. The
      // buffer that matters lives in the worker's storage, and unsent turns are re-emitted on the
      // next tick only if they were never acknowledged — losing one tick of captions is acceptable
      // next to blocking the observer.
      port = null;
      connect();
    }
  }

  function startSession() {
    const code = TWSelectors.readCallCode();
    if (!code || code === sessionKey) return;

    if (sessionKey) endSession();
    sessionKey = code;
    sessionStartedAt = new Date().toISOString();
    stabilizer = new CaptionStabilizer({ sessionStart: Date.now() });
    warnedAboutCaptions = false;
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
    return true;
  }

  function tick() {
    if (!enabled || !sessionKey || !stabilizer) return;
    if (!captionRoot || !document.contains(captionRoot)) {
      if (!attachObserver()) {
        maybeWarnAboutCaptions();
        return;
      }
    }

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
        'no captions detected — turn on captions in Meet (the CC button) for speaker-attributed transcript'
      );
    } else {
      log(
        'no caption region found. Meet may have changed its DOM. Candidate containers:',
        TWSelectors.describeCandidates()
      );
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
      tick();
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

  chrome.storage.local.get({ enabled: true }).then((settings) => {
    enabled = settings.enabled !== false;
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
  });

  // `pagehide` fires for tab close, navigation, and bfcache eviction alike; `beforeunload` does not
  // fire reliably in all of those.
  window.addEventListener('pagehide', () => {
    endSession();
    clearInterval(tickTimer);
    clearInterval(portTimer);
  });
})();
