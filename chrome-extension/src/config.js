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
  /**
   * Report the user's own mic/camera state to the app and click those two toggles when the app's
   * floating call controls ask. Off means no state leaves the page and no command is honored.
   */
  allowCallControl: true,
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

/**
 * Numeric comparison of dotted versions ("0.10.0" is newer than "0.9.1"). Used to tell "this
 * extension is behind the app" (reload it) from "the app is behind this extension" (nothing to do
 * here).
 */
export function isOlderVersion(version, other) {
  const parts = (value) => String(value || '').split('.').map((part) => parseInt(part, 10) || 0);
  const a = parts(version);
  const b = parts(other);
  for (let i = 0; i < Math.max(a.length, b.length); i += 1) {
    const left = a[i] || 0;
    const right = b[i] || 0;
    if (left !== right) return left < right;
  }
  return false;
}

/**
 * What a failed `POST /v1/bridge/hello` means, in the user's terms. The POST is the honest
 * connection test: Chrome sends no `Origin` on an extension's GET, so `GET /v1/status` succeeds
 * even when the app would refuse every caption this extension posts.
 *
 * Returns `{ message, ok }` — `ok` is whether captions can still flow despite the failure.
 */
export function describeHelloFailure(status, version, extensionId) {
  switch (status) {
    case 403:
      return {
        message:
          `TypeWhisper refuses this extension. Add its ID — ${extensionId} — under ` +
          'Settings › Advanced › API Server › Allowed Browser Extensions.',
        ok: false,
      };
    case 401:
      return {
        message:
          'TypeWhisper rejected the API token. Copy it again from Settings › Advanced › API Server.',
        ok: false,
      };
    case 404:
      return {
        message: `Connected, but the app is older than this extension (v${version}) and does not know its version check.`,
        ok: true,
      };
    default:
      return { message: `TypeWhisper answered ${status} to the version check.`, ok: false };
  }
}
