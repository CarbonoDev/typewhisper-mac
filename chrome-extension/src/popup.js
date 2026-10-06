import { getSettings, setSettings, isOlderVersion } from './config.js';

const STORAGE_KEY = 'tw_sessions';

/** Which build this is, and whether the app ships a different one (see `hello` in background.js). */
async function renderVersion() {
  const mine = chrome.runtime.getManifest().version;
  const stored = await chrome.storage.local.get('tw_app_status');
  const expected = stored.tw_app_status?.expectedVersion;
  document.getElementById('version').textContent =
    expected && isOlderVersion(mine, expected)
      ? `Meet Bridge v${mine} — the app ships v${expected}; reload this extension.`
      : `Meet Bridge v${mine}`;
}

async function render() {
  renderVersion();
  const settings = await getSettings();
  document.getElementById('enabled').checked = settings.enabled;

  const stored = await chrome.storage.local.get(STORAGE_KEY);
  const sessions = Object.entries(stored[STORAGE_KEY] || {});
  const state = document.getElementById('state');

  if (!settings.enabled) {
    state.textContent = 'Capture is off.';
    return;
  }
  if (sessions.length === 0) {
    state.textContent = 'No active call.';
    return;
  }
  const [key, session] = sessions[0];
  const pending = session.buffer?.length ?? 0;
  state.textContent = session.meetingId
    ? `Call ${key} → meeting linked${pending ? `, ${pending} segment(s) queued` : ''}.`
    : `Call ${key} → not yet linked to a meeting.`;
}

document.getElementById('enabled').addEventListener('change', async (event) => {
  await setSettings({ enabled: event.target.checked });
  render();
});

document.getElementById('options').addEventListener('click', (event) => {
  event.preventDefault();
  chrome.runtime.openOptionsPage();
});

render();
