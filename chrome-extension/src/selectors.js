/**
 * Google Meet DOM discovery.
 *
 * Meet ships obfuscated, rotating class names, so nothing here is allowed to be load-bearing on its
 * own. Discovery runs as a ladder, cheapest and most stable first:
 *
 *   1. `jsname` attributes  — Meet's own internal handles. They rotate far less often than classes.
 *   2. `aria-label` regions — semantic and stable, but localized, hence the translation table.
 *   3. legacy class names   — last resort, known to break.
 *   4. structural heuristic — no selector at all: find the subtree that *behaves* like captions.
 *
 * When every rung fails, `describeCandidates()` dumps a structural report to the console so the
 * ladder can be repaired from one real call instead of guesswork. Keep every Meet-specific string in
 * this file — it is meant to be the single place that needs editing when Meet changes.
 */

// Rung 1+3: direct selectors for the caption scroll container, best-known first.
const CAPTION_CONTAINER_SELECTORS = [
  'div[jsname="dsyhDe"]',
  'div[jsname="YSxPC"]',
  '.a4cQT',
  '.iOzk7',
];

// Rung 2: `aria-label` values Meet uses for the captions region, per locale. Matched
// case-insensitively as a substring, so "Captions" also catches "Live captions".
const CAPTION_REGION_LABELS = [
  'captions', // en
  'untertitel', // de
  'subtítulos', // es
  'subtitulos',
  'sous-titres', // fr
  'legendas', // pt
  'sottotitoli', // it
  'ondertiteling', // nl
];

/** The CC toggle button — used both to point the user at it and for the auto-enable click. */
const CAPTION_TOGGLE_LABELS = [
  'captions',
  'untertitel',
  'subtítulos',
  'subtitulos',
  'sous-titres',
  'legendas',
  'sottotitoli',
  'ondertiteling',
];

/**
 * aria-labels of the caption-settings entry point (the gear/language control on the caption bar or
 * in the settings sheet), per locale — the door to the caption-language picker. Substring-matched
 * case-insensitively like CAPTION_REGION_LABELS. Deliberately caption-specific: a bare "settings"
 * would also match Meet's main gear. Speculative by nature — repair from a real call's
 * `describeLanguageCandidates()` / `describeCandidates()` output when Meet renames it.
 */
const CAPTION_SETTINGS_LABELS = [
  'caption settings', // en
  'captions settings',
  'change caption language',
  'caption language',
  'untertiteleinstellungen', // de
  'einstellungen für untertitel',
  'untertitelsprache',
  'configuración de subtítulos', // es
  'configuracion de subtitulos',
  'idioma de los subtítulos',
  'paramètres des sous-titres', // fr
  'langue des sous-titres',
  'configurações da legenda', // pt
  'configurações de legendas',
  'idioma das legendas',
  'impostazioni dei sottotitoli', // it
  'lingua dei sottotitoli',
  'ondertitelinstellingen', // nl
  'taal van ondertiteling',
];

/**
 * How each supported caption language is *named* across major UI locales, for matching the
 * language picker's options when they carry no machine-readable `data-value`. Accented and
 * accent-stripped spellings are both listed because matching is a plain substring check.
 */
const CAPTION_LANGUAGE_NAMES = {
  en: ['english', 'inglés', 'ingles', 'inglês', 'englisch', 'anglais', 'inglese', 'engels'],
  es: ['spanish', 'español', 'espanol', 'spanisch', 'espagnol', 'espanhol', 'spagnolo', 'spaans'],
};

/** aria-labels of the leave/end-call button, per locale — present only once actually in the call. */
const LEAVE_CALL_LABELS = [
  'leave call', // en
  'end call',
  'anruf verlassen', // de
  'salir de la llamada', // es
  'abandonar la llamada',
  'quitter l’appel', // fr
  "quitter l'appel",
  'sair da chamada', // pt
  'abbandona la chiamata', // it
  'gesprek verlaten', // nl
];

function matchesAnyLabel(el, labels) {
  const label = (el.getAttribute('aria-label') || '').toLowerCase();
  if (!label) return false;
  return labels.some((needle) => label.includes(needle));
}

/**
 * Noise filters. Meet's UI chrome leaks into scraped text in ways that are detectable without a
 * translation table: Material icon glyphs render as ligature *text* (`more_vert`, `frame_person`),
 * menus carry keyboard shortcuts, and account chrome carries emails. Speech has none of those.
 */

/** `more_vert`, `present_to_all`, `visual_effects`… — a Material icon ligature, never a word of speech. */
function isIconToken(value) {
  return /^[a-z0-9]+(?:_[a-z0-9]+)+$/.test(value.trim());
}

/** Remove icon ligature tokens that Meet renders inline with visible text. */
function stripIconTokens(line) {
  return line
    .split(/\s+/)
    .filter((word) => !isIconToken(word))
    .join(' ');
}

/** Keyboard-shortcut chrome — "(⌘ + d)", "(Ctrl + E)" — appears in menus and tooltips, never in captions. */
function looksLikeUIChrome(text) {
  return /\((?:⌘|⌥|⌃|ctrl|cmd|alt|shift)\s*\+/i.test(text);
}

/** A caption speaker line is a display name: short, no icon tokens, and never an email address. */
function isPlausibleSpeakerName(value) {
  const name = value.trim();
  if (!name || name.length > 48) return false;
  if (/\S+@\S+\.\S+/.test(name)) return false; // account-switcher chrome, not a caption name
  if (name.split(/\s+/).some(isIconToken)) return false;
  return true;
}

/**
 * Rung 4 — structural heuristic. A caption block is the only thing on a Meet page that is
 * simultaneously: an avatar image, a short constant name, and a long body of text that mutates. We
 * look for the shallowest ancestor holding at least one avatar + a meaningful run of text, while
 * excluding the participant panel (which has avatars but static text) by requiring the text to be
 * longer than a name.
 */
function heuristicCaptionRoot() {
  const avatars = Array.from(
    document.querySelectorAll('img[src*="googleusercontent.com"], img[src*="lh3.google"]')
  );
  const scored = new Map();

  for (const avatar of avatars) {
    let node = avatar.parentElement;
    let depth = 0;
    while (node && depth < 6) {
      const text = (node.innerText || '').trim();
      // A caption block carries a name *plus* speech; a roster row carries only a name.
      if (text.length > 40 && text.includes(' ')) {
        scored.set(node, (scored.get(node) || 0) + 1);
      }
      node = node.parentElement;
      depth += 1;
    }
  }

  let best = null;
  let bestScore = 0;
  for (const [node, score] of scored) {
    if (score > bestScore) {
      best = node;
      bestScore = score;
    }
  }
  return best;
}

/** Tags and roles that make an element a *control*, never a caption region. */
const INTERACTIVE_TAGS = new Set(['BUTTON', 'A', 'INPUT', 'SELECT', 'TEXTAREA']);
const INTERACTIVE_ROLES = new Set([
  'button',
  'link',
  'menuitem',
  'menuitemcheckbox',
  'menuitemradio',
  'switch',
  'checkbox',
  'tab',
  'option',
]);
/** Roles a caption container plausibly carries — enough on their own to accept it. */
const CAPTION_SHAPED_ROLES = new Set(['region', 'log', 'status', 'complementary']);
const CONTROL_ANCESTOR_SELECTOR = [
  'button',
  'a',
  '[role="button"]',
  '[role="menuitem"]',
  '[role="menuitemcheckbox"]',
  '[role="menuitemradio"]',
  '[role="switch"]',
  '[role="tab"]',
].join(', ');

function isInteractiveElement(el) {
  if (INTERACTIVE_TAGS.has((el.tagName || '').toUpperCase())) return true;
  return INTERACTIVE_ROLES.has((el.getAttribute('role') || '').trim().toLowerCase());
}

/**
 * Rung 2, shared by `findCaptionRoot()` and `inActiveCall()`: labelled elements that plausibly *are*
 * the caption region.
 *
 * The label test alone is far too loose. CAPTION_REGION_LABELS and CAPTION_TOGGLE_LABELS are the
 * same words ("captions", "untertitel", …) because the toggle is *named after* the region, so the
 * CC control, its tooltip and its menu entry all match — and Meet builds those as
 * `div[role="button"]` as often as `<button>` (which is why `findCaptionToggle()` queries both).
 * A bare `tagName !== 'BUTTON'` check therefore lets a lobby CC control masquerade as a caption
 * region, which would both start a session on the "Ready to join?" screen and hand
 * `readCaptionBlocks()` a button's guts to scrape.
 *
 * So a candidate must not be a control (nor sit inside one) and must then look like a container:
 * either a caption-shaped role, or a body of text too long to be a control's label. The tradeoff:
 * an *unlabelled-role* caption region that is still empty is rejected until it has text — harmless,
 * since an empty region carries nothing to capture, and `inActiveCall()` still has the leave-call
 * rung. Erring the other way is what produced the pre-join junk meetings.
 */
function captionRegionsByLabel() {
  const found = [];
  for (const el of document.querySelectorAll('[aria-label]')) {
    if (!matchesAnyLabel(el, CAPTION_REGION_LABELS)) continue;
    if (isInteractiveElement(el)) continue;
    // A label-carrying wrapper *inside* a control (Meet's tooltip spans) is still that control.
    if (typeof el.closest === 'function' && el.closest(CONTROL_ANCESTOR_SELECTOR)) continue;

    if (CAPTION_SHAPED_ROLES.has((el.getAttribute('role') || '').trim().toLowerCase())) {
      found.push(el);
      continue;
    }
    const text = (el.innerText || '').trim();
    if (text.length > 40 && text.includes(' ')) found.push(el);
  }
  return found;
}

/** Walk the ladder. Returns `{ root, via }` or `null`. */
function findCaptionRoot() {
  for (const selector of CAPTION_CONTAINER_SELECTORS) {
    const el = document.querySelector(selector);
    if (el) return { root: el, via: `selector:${selector}` };
  }

  const [region] = captionRegionsByLabel();
  if (region) return { root: region, via: 'aria-label' };

  const heuristic = heuristicCaptionRoot();
  if (heuristic) return { root: heuristic, via: 'heuristic' };

  return null;
}

/**
 * Split a caption root into `{ speaker, text, key }` blocks.
 *
 * Meet nests one element per speaker turn inside the root. Rather than naming those elements, we
 * take the root's direct children and read each one's first short line as the speaker and the rest
 * as speech — which is exactly how Meet lays a caption block out visually, and survives class
 * renames.
 */
function readCaptionBlocks(root) {
  const blocks = [];
  for (const child of root.children) {
    const parsed = parseCaptionBlock(child);
    if (parsed) blocks.push({ element: child, ...parsed });
  }

  // Some Meet builds put every turn one level deeper (the root is a scroll wrapper with a single
  // child). Unwrap once when the direct-children read produced nothing usable.
  if (blocks.length === 0 && root.children.length === 1) {
    return readCaptionBlocks(root.children[0]);
  }
  return blocks;
}

function parseCaptionBlock(element) {
  const raw = (element.innerText || '').trim();
  if (!raw) return null;
  if (looksLikeUIChrome(raw)) return null; // a menu or tooltip, whatever container it sat in

  const rawLines = raw
    .split('\n')
    .map((line) => line.trim())
    .filter(Boolean);
  // A block *led* by a bare icon glyph is a UI control (menu anchor, tile overlay), not a caption
  // turn — a caption block always leads with the speaker's name.
  if (rawLines.length > 0 && rawLines[0].split(/\s+/).every(isIconToken)) return null;

  const lines = rawLines.map((line) => stripIconTokens(line).trim()).filter(Boolean);
  if (lines.length === 0) return null;

  // The speaker line is short and has no sentence punctuation; anything else means Meet collapsed
  // the name and the speech onto one line, in which case we have speech but no attributable name.
  const first = lines[0];
  const looksLikeName = first.length > 0 && first.length <= 48 && !/[.!?]$/.test(first);

  if (looksLikeName && lines.length > 1) {
    // A name slot holding an email or leftover chrome means the whole block is UI, not a turn.
    if (!isPlausibleSpeakerName(first)) return null;
    const text = lines.slice(1).join(' ');
    if (text === first) return null; // a video tile echoing the participant's name
    return { speaker: first, text };
  }
  return { speaker: null, text: lines.join(' ') };
}

/** Whether captions appear to be switched on right now. */
function captionsAppearActive() {
  const found = findCaptionRoot();
  if (!found) return false;
  return (found.root.innerText || '').trim().length > 0;
}

/**
 * Find the CC toggle. Historically we only pointed the user at it; with `autoEnableCaptions` the
 * content script may also click it — bounded, early-session-only, never against a deliberate off.
 */
function findCaptionToggle() {
  const buttons = document.querySelectorAll('button[aria-label], [role="button"][aria-label]');
  for (const button of buttons) {
    if (matchesAnyLabel(button, CAPTION_TOGGLE_LABELS)) return button;
  }
  return null;
}

/**
 * Tri-state read of the CC toggle: `true`/`false` when `aria-pressed` says so, `null` when the
 * attribute is absent (some Meet builds omit it). Callers must treat `null` as "unknown" and fall
 * back to whether a caption region is actually rendering — never as "off" on its own.
 */
function captionToggleState(toggle) {
  if (!toggle || typeof toggle.getAttribute !== 'function') return null;
  const pressed = (toggle.getAttribute('aria-pressed') || '').toLowerCase();
  if (pressed === 'true' || pressed === 'mixed') return true;
  if (pressed === 'false') return false;
  return null;
}

/** The caption-settings entry point (door to the language picker), by the aria-label ladder. */
function findCaptionSettingsButton() {
  const buttons = document.querySelectorAll('button[aria-label], [role="button"][aria-label]');
  for (const button of buttons) {
    if (matchesAnyLabel(button, CAPTION_SETTINGS_LABELS)) return button;
  }
  return null;
}

/**
 * Candidate options of whatever picker/menu is currently open, as plain descriptors. The roles
 * cover Meet's known widget shapes (listbox options, menu radio items, material `li[data-value]`
 * rows); the descriptors feed `matchLanguageOption`, which is pure and testable without a DOM.
 */
function collectLanguageOptions() {
  const nodes = document.querySelectorAll('[role="option"], [role="menuitemradio"], li[data-value]');
  const candidates = [];
  for (const el of nodes) {
    candidates.push({
      element: el,
      dataValue: el.getAttribute('data-value') || '',
      label: `${el.getAttribute('aria-label') || ''} ${(el.textContent || '').trim()}`.trim(),
    });
  }
  return candidates;
}

/**
 * Pure matcher for the caption-language picker. `candidates` are `{ dataValue, label }`
 * descriptors (from `collectLanguageOptions`); `langCode` is `'en'` / `'es'`.
 *
 * Precedence: a machine-readable `data-value` beginning with the code (`en`, `en-US`, `es-419`)
 * always beats the localized display name, because names need a translation table and Meet's
 * `data-value`s do not. Returns the matched descriptor or `null`.
 */
function matchLanguageOption(candidates, langCode) {
  const code = (langCode || '').trim().toLowerCase();
  if (!code) return null;

  for (const candidate of candidates) {
    const dataValue = (candidate.dataValue || '').trim().toLowerCase();
    if (dataValue && dataValue.startsWith(code)) return candidate;
  }

  const names = CAPTION_LANGUAGE_NAMES[code] || [];
  for (const candidate of candidates) {
    const label = (candidate.label || '').toLowerCase();
    if (names.some((name) => label.includes(name))) return candidate;
  }
  return null;
}

/**
 * Diagnostic dump of the currently open picker's options — the language-steering counterpart of
 * `describeCandidates()`. Logged when no option matched, so the ladder (labels, roles, data-values)
 * can be repaired from one real call.
 */
function describeLanguageCandidates() {
  return collectLanguageOptions()
    .slice(0, 40)
    .map(({ element, dataValue, label }) => ({
      role: element.getAttribute('role'),
      dataValue: dataValue || null,
      ariaLabel: element.getAttribute('aria-label'),
      preview: label.slice(0, 80),
    }));
}

/**
 * Diagnostic dump for when the ladder fails outright. Prints the most caption-shaped subtrees on the
 * page with their attributes, which is enough to add a new `jsname` to rung 1.
 */
function describeCandidates() {
  const report = [];
  const all = document.querySelectorAll('div');
  for (const el of all) {
    const text = (el.innerText || '').trim();
    if (text.length < 30 || text.length > 2000) continue;
    if (el.children.length === 0 || el.children.length > 12) continue;
    report.push({
      jsname: el.getAttribute('jsname'),
      ariaLabel: el.getAttribute('aria-label'),
      role: el.getAttribute('role'),
      className: typeof el.className === 'string' ? el.className : '',
      children: el.children.length,
      preview: text.slice(0, 120),
    });
  }
  return report.slice(0, 25);
}

/**
 * Whether we are past the lobby. The green-room shows the same `/abc-defg-hij` path as the call
 * itself, so the URL alone would start capture on the "Ready to join?" screen — where everything
 * the heuristic can find is UI chrome (the source of the pre-join transcript noise). In-call is
 * detected by the leave-call button; a caption region found by a precise rung also counts, so an
 * unlisted locale still works the moment captions are on.
 */
function inActiveCall() {
  const buttons = document.querySelectorAll('button[aria-label], [role="button"][aria-label]');
  for (const button of buttons) {
    if (matchesAnyLabel(button, LEAVE_CALL_LABELS)) return true;
  }
  for (const selector of CAPTION_CONTAINER_SELECTORS) {
    if (document.querySelector(selector)) return true;
  }
  // Only a *region* counts here, never a CC control: the lobby renders the captions toggle too, and
  // treating it as the joined signal is exactly how pre-join junk meetings got created.
  return captionRegionsByLabel().length > 0;
}

/**
 * The Google account this call is joined from, for the app's fallback meeting title. The account
 * button's aria-label embeds the email in every locale ("Google Account: Marco (m@x.com)"), so an
 * email regex needs no translation table.
 */
function readAccountEmail() {
  const candidates = document.querySelectorAll(
    'a[href*="accounts.google.com"][aria-label], a[aria-label*="@"], [role="button"][aria-label*="@"]'
  );
  for (const el of candidates) {
    const match = (el.getAttribute('aria-label') || '').match(/[\w.+-]+@[\w-]+(?:\.[\w-]+)+/);
    if (match) return match[0];
  }
  return null;
}

/**
 * The Meet call code (`abc-defg-hij`) — our stable session identity.
 *
 * Anything that is not shaped like a call code is `null`, never a best guess: the code is what the
 * app keys a live meeting on, so accepting a stray first path segment (`landing`, `new`, `_meet`)
 * would create a bogus meeting — and `readMeetingTitle()` would then name it after that junk.
 */
function readCallCode() {
  const path = location.pathname.replace(/^\//, '').split('/')[0];
  return /^[a-z]{3}-[a-z]{4}-[a-z]{3}$/i.test(path) ? path : null;
}

/** Best-effort human title for the call; falls back to the call code. */
function readMeetingTitle() {
  const title = (document.title || '').trim();
  const cleaned = title
    .replace(/^Meet\s*[–—-]\s*/i, '')
    .replace(/\s*[–—-]\s*Google Meet$/i, '')
    .trim();
  if (cleaned && !/^google meet$/i.test(cleaned) && !/^meet$/i.test(cleaned)) return cleaned;
  return readCallCode();
}

const TWSelectorsAPI = {
  findCaptionRoot,
  captionRegionsByLabel,
  readCaptionBlocks,
  parseCaptionBlock,
  captionsAppearActive,
  findCaptionToggle,
  captionToggleState,
  findCaptionSettingsButton,
  collectLanguageOptions,
  matchLanguageOption,
  describeLanguageCandidates,
  describeCandidates,
  inActiveCall,
  readAccountEmail,
  readCallCode,
  readMeetingTitle,
  isIconToken,
  stripIconTokens,
  looksLikeUIChrome,
  isPlausibleSpeakerName,
};

// Usable both as a content-script global and as a CommonJS module under `node --test` (the pure
// noise filters and `parseCaptionBlock` take plain `{ innerText }` objects, so they test without a DOM).
if (typeof self !== 'undefined') self.TWSelectors = TWSelectorsAPI;
if (typeof module !== 'undefined' && module.exports) {
  module.exports = TWSelectorsAPI;
}
