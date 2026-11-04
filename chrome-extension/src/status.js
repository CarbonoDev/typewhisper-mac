/**
 * The content script's status: one small object saying what the bridge sees in this tab, which the
 * worker stores per tab and the popup shows in plain words ("why is nothing happening?").
 *
 * The tracker also owns the *transition log*: every watched field that changes produces one
 * `[tw-meet]` line (entered the call page, in-call signal matched/lost, captions found/lost, mic
 * toggle readable/unreadable, …) — never one per tick. Those lines reach the console and, through
 * `forward`, the worker's ring buffer that the popup's "Copy diagnostics" button copies.
 *
 * Pure apart from the injected `log`/`forward`/`now`, so it is tested under `node --test`.
 */

(() => {
  /** How often an unchanged-but-dirty status (counters) is re-published; transitions go at once. */
  const PUBLISH_EVERY_MS = 3000;

  const DEFAULT_STATUS = {
    version: null,
    enabled: true,
    onCallPath: false,
    callCode: null,
    inCall: false,
    inCallVia: null,
    whyNot: '',
    lobby: null,
    sessionKey: null,
    meetingId: null,
    sessionError: null,
    captionsFound: false,
    captionsVia: null,
    micReadable: null,
    micVia: null,
    segmentsSent: 0,
    lastSegmentAt: null,
    updatedAt: null,
  };

  /** One log line per transition of a watched field; `null` = change silently. */
  const TRANSITIONS = {
    enabled: (v) => (v ? 'capture switched on' : 'capture switched off in options'),
    onCallPath: (v, s) =>
      v ? `on a Meet call page (${s.callCode || 'unknown code'}); waiting for an in-call signal` : 'left the Meet call page',
    inCall: (v, s) =>
      v ? `in-call signal matched: ${s.inCallVia}` : `in-call signal lost${s.lobby ? ` (${s.lobby})` : ''}`,
    sessionKey: (v, s, prev) => (v ? `session started for call ${v}` : `session ended for call ${prev}`),
    meetingId: (v) => (v ? `linked to app meeting ${v}` : null),
    sessionError: (v) => (v ? `the app did not take the session: ${v}` : 'session error cleared'),
    // "found" is logged by content.js on every (re)attach, with the rung that matched.
    captionsFound: (v) => (v ? null : 'caption region lost'),
    micReadable: (v, s) =>
      v === null ? null : v ? `mic toggle readable (${s.micVia})` : 'mic toggle not readable — floating mute button stays hidden',
  };

  function createStatusTracker({ version = null, log = () => {}, forward = () => {}, now = Date.now } = {}) {
    const state = { ...DEFAULT_STATUS, version };
    let dirty = true;
    let urgent = true;
    let lastPublishedAt = 0;

    /** Apply a patch; log each watched transition once the whole patch is in place. */
    function update(patch) {
      const changed = [];
      for (const [key, value] of Object.entries(patch)) {
        if (state[key] === value) continue;
        changed.push([key, state[key]]);
        state[key] = value;
      }
      if (changed.length === 0) return;
      dirty = true;
      for (const [key, previous] of changed) {
        const describe = TRANSITIONS[key];
        if (!describe) continue;
        urgent = true;
        const line = describe(state[key], state, previous);
        if (line) log(line);
      }
    }

    /** The snapshot to send, when one is due (`null` otherwise). Marks it sent. */
    function takeIfDue() {
      if (!dirty) return null;
      const t = now();
      if (!urgent && t - lastPublishedAt < PUBLISH_EVERY_MS) return null;
      dirty = false;
      urgent = false;
      lastPublishedAt = t;
      state.updatedAt = new Date(t).toISOString();
      return { ...state };
    }

    function publish() {
      const snapshot = takeIfDue();
      if (snapshot) forward(snapshot);
      return snapshot;
    }

    return { state, update, takeIfDue, publish };
  }

  /** Render a log argument for the worker's ring buffer: objects as bounded JSON. */
  function formatLogArgs(args) {
    return args
      .map((arg) => {
        if (typeof arg === 'string') return arg;
        try {
          return JSON.stringify(arg);
        } catch {
          return String(arg);
        }
      })
      .join(' ')
      .slice(0, 2000);
  }

  const TWStatusAPI = { createStatusTracker, formatLogArgs, DEFAULT_STATUS, PUBLISH_EVERY_MS };
  if (typeof self !== 'undefined') self.TWStatus = TWStatusAPI;
  if (typeof module !== 'undefined' && module.exports) module.exports = TWStatusAPI;
})();
