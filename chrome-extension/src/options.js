import { getSettings, setSettings, isLoopbackUrl } from './config.js';

const $ = (id) => document.getElementById(id);
const status = $('status');

function report(message, ok) {
  status.textContent = message;
  status.className = ok ? 'ok' : 'bad';
}

async function load() {
  const settings = await getSettings();
  $('enabled').checked = settings.enabled;
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
    report('Connected to TypeWhisper.', true);
  } catch (error) {
    report(`Could not reach TypeWhisper: ${error.message}`, false);
  }
});

load();
