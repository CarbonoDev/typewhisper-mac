import { getSettings, setSettings, isLoopbackUrl, isOlderVersion } from './config.js';

const $ = (id) => document.getElementById(id);
const status = $('status');

function report(message, ok) {
  status.textContent = message;
  status.className = ok ? 'ok' : 'bad';
}

const BRIDGE_VERSION = chrome.runtime.getManifest().version;

async function load() {
  $('version').textContent = `Version ${BRIDGE_VERSION}.`;
  const settings = await getSettings();
  $('enabled').checked = settings.enabled;
  $('autoEnableCaptions').checked = settings.autoEnableCaptions;
  $('hideCaptionOverlay').checked = settings.hideCaptionOverlay;
  $('allowCallControl').checked = settings.allowCallControl;
  $('preferredCaptionLanguage').value = settings.preferredCaptionLanguage;
  $('baseUrl').value = settings.baseUrl;
  $('apiToken').value = settings.apiToken;
}

$('save').addEventListener('click', async () => {
  const baseUrl = $('baseUrl').value.trim() || 'http://127.0.0.1:8978';
  if (!isLoopbackUrl(baseUrl)) {
    report('API URL must be a loopback address (127.0.0.1 or localhost).', false);
    return;
  }
  await setSettings({
    enabled: $('enabled').checked,
    autoEnableCaptions: $('autoEnableCaptions').checked,
    hideCaptionOverlay: $('hideCaptionOverlay').checked,
    allowCallControl: $('allowCallControl').checked,
    preferredCaptionLanguage: $('preferredCaptionLanguage').value,
    baseUrl,
    apiToken: $('apiToken').value.trim(),
  });
  report('Saved.', true);
});

$('test').addEventListener('click', async () => {
  const settings = await getSettings();
  if (!isLoopbackUrl(settings.baseUrl)) {
    report('API URL must be a loopback address.', false);
    return;
  }
  try {
    const headers = settings.apiToken ? { Authorization: `Bearer ${settings.apiToken}` } : {};
    const response = await fetch(`${settings.baseUrl.replace(/\/$/, '')}/v1/status`, { headers });
    if (!response.ok) {
      report(`TypeWhisper answered ${response.status}.`, false);
      return;
    }
    // Say which build this is, and learn which one the app ships with. An app too old for the
    // route answers 404, which is itself worth saying.
    const hello = await fetch(`${settings.baseUrl.replace(/\/$/, '')}/v1/bridge/hello`, {
      method: 'POST',
      headers: { ...headers, 'Content-Type': 'application/json' },
      body: JSON.stringify({ version: BRIDGE_VERSION }),
    });
    const expected = hello.ok ? (await hello.json()).expected_version : null;
    if (!hello.ok) {
      report(`Connected, but the app is older than this extension (v${BRIDGE_VERSION}).`, true);
    } else if (expected && isOlderVersion(BRIDGE_VERSION, expected)) {
      report(`Connected — this is v${BRIDGE_VERSION}, the app ships v${expected}. Reload the extension.`, false);
    } else {
      report(`Connected to TypeWhisper (Meet Bridge v${BRIDGE_VERSION}).`, true);
    }
  } catch (error) {
    report(`Could not reach TypeWhisper: ${error.message}`, false);
  }
});

load();
