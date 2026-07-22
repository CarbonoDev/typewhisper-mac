export const DEFAULT_SETTINGS = {
  /** Where the TypeWhisper local API listens. Must stay a loopback host. */
  baseUrl: 'http://127.0.0.1:8978',
  /** Optional bearer token, matching TypeWhisper's Local API setting. */
  apiToken: '',
  /** Master switch: when off the content script observes nothing and nothing is sent. */
  enabled: true,
  /**
   * Click Meet's CC button when a call starts without captions (Meet resets them per call).
   * Bounded: at most 3 attempts, ~5s apart, only in the first ~30s of a session — so a user who
   * deliberately turns captions off is never click-fought.
   */
  autoEnableCaptions: true,
  /**
   * Steer Meet's caption-language picker once per session after captions come on. `''` leaves
   * Meet's own choice alone; `'en'` / `'es'` make ONE best-effort attempt to select that language.
   * Purely speculative DOM automation — a failure logs a diagnostic and gives up cleanly.
   */
  preferredCaptionLanguage: '',
  /**
   * Visually hide Meet's caption overlay while still reading it. Implemented with
   * `opacity: 0` + `pointer-events: none` — never `display: none` / `visibility: hidden`, which
   * would break `innerText`-based parsing (see the comment in content.js).
   */
  hideCaptionOverlay: true,
};

// NOTE: content.js is a classic (non-module) content script and cannot import this file; it reads
// the same defaults inline via `chrome.storage.local.get({...})`. Keep the two in sync.

export async function getSettings() {
  const stored = await chrome.storage.local.get(DEFAULT_SETTINGS);
  return { ...DEFAULT_SETTINGS, ...stored };
}

export async function setSettings(patch) {
  await chrome.storage.local.set(patch);
}

/** Reject anything that is not loopback — this extension must never post captions off-machine. */
export function isLoopbackUrl(value) {
  try {
    const url = new URL(value);
    return (
      (url.protocol === 'http:' || url.protocol === 'https:') &&
      ['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname)
    );
  } catch {
    return false;
  }
}
