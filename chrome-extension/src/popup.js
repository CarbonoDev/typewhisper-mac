import { getSettings, setSettings, isOlderVersion } from './config.js';
import { describeStatus, formatDiagnostics, readDiagnostics } from './diagnostics.js';

const STORAGE_KEY = 'tw_sessions';
const version = chrome.runtime.getManifest().version;

/** Which build this is, and whether the app ships a different one (see `hello` in background.js). */
async function renderVersion() {
  const stored = await chrome.storage.local.get('tw_app_status');
  const expected = stored.tw_app_status?.expectedVersion;
  document.getElementById('version').textContent =
    expected && isOlderVersion(version, expected)
      ? `Meet Bridge v${version} — the app ships v${expected}; reload this extension.`
      : `Meet Bridge v${version}`;
}

/** The active tab's id. Needs no `tabs` permission: only the URL is withheld, not the id. */
async function activeTabId() {
  try {
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    return tab?.id ?? null;
  } catch {
    return null;
  }
}

/** Everything known about the active tab: its status, its call's session, the app's health, the log. */
async function gather() {
  const [tabId, diagnostics, stored] = await Promise.all([
    activeTabId(),
    readDiagnostics(),
    chrome.storage.local.get(STORAGE_KEY),
  ]);
  const status = tabId != null ? diagnostics.tabs[tabId] : undefined;
  const sessions = stored[STORAGE_KEY] || {};
  const session = status?.sessionKey ? sessions[status.sessionKey] : undefined;
  return { tabId, status, session, sessions, health: diagnostics.health, lines: diagnostics.lines };
}

async function render() {
  renderVersion();
  const settings = await getSettings();
  document.getElementById('enabled').checked = settings.enabled;

  const { status, session, sessions, health } = await gather();
  const described = settings.enabled
    ? describeStatus({ status, session, health })
    : { headline: 'Capture is off.', lines: [] };
  document.getElementById('headline').textContent = described.headline;
  const why = document.getElementById('why');
  why.replaceChildren(
    ...described.lines.map((line) => {
      const item = document.createElement('li');
      item.textContent = line;
      return item;
    })
  );

  // Calls in *other* tabs, so a popup opened from the wrong tab still says something is running.
  const others = Object.entries(sessions).filter(([key]) => key !== status?.sessionKey);
  document.getElementById('state').textContent = others.length
    ? `Other calls: ${others
        .map(([key, s]) => `${key} (${s.meetingId ? 'linked' : 'not linked'}${s.buffer?.length ? `, ${s.buffer.length} queued` : ''})`)
        .join(', ')}.`
    : '';
}

document.getElementById('enabled').addEventListener('change', async (event) => {
  await setSettings({ enabled: event.target.checked });
  render();
});

document.getElementById('copy').addEventListener('click', async () => {
  const { tabId, status, session, health, lines } = await gather();
  const text = formatDiagnostics({ version, tabId, status, session, health, lines });
  const copied = document.getElementById('copied');
  try {
    await navigator.clipboard.writeText(text);
    copied.textContent = `Copied (${lines.length} log lines).`;
  } catch (error) {
    copied.textContent = `Could not copy: ${error.message}`;
  }
});

document.getElementById('options').addEventListener('click', (event) => {
  event.preventDefault();
  chrome.runtime.openOptionsPage();
});

// Live while open: the content script reports every few seconds, and transitions at once.
chrome.storage.onChanged.addListener((changes, area) => {
  if (area === 'session' || changes[STORAGE_KEY]) render();
});

render();
