export const DEFAULT_SETTINGS = {
  /** Where the TypeWhisper local API listens. Must stay a loopback host. */
  baseUrl: 'http://127.0.0.1:8978',
  /** Optional bearer token, matching TypeWhisper's Local API setting. */
  apiToken: '',
  /** Master switch: when off the content script observes nothing and nothing is sent. */
  enabled: true,
};

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
