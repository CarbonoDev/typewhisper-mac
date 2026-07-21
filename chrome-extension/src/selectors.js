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

/** The CC toggle button, so we can tell the user whether captions are actually on. */
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

function matchesAnyLabel(el, labels) {
  const label = (el.getAttribute('aria-label') || '').toLowerCase();
  if (!label) return false;
  return labels.some((needle) => label.includes(needle));
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

/** Walk the ladder. Returns `{ root, via }` or `null`. */
function findCaptionRoot() {
  for (const selector of CAPTION_CONTAINER_SELECTORS) {
    const el = document.querySelector(selector);
    if (el) return { root: el, via: `selector:${selector}` };
  }

  const regions = document.querySelectorAll('[role="region"][aria-label], [aria-label]');
  for (const el of regions) {
    if (matchesAnyLabel(el, CAPTION_REGION_LABELS) && el.tagName !== 'BUTTON') {
      return { root: el, via: 'aria-label' };
    }
  }

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

  const lines = raw
    .split('\n')
    .map((line) => line.trim())
    .filter(Boolean);
  if (lines.length === 0) return null;

  // The speaker line is short and has no sentence punctuation; anything else means Meet collapsed
  // the name and the speech onto one line, in which case we have speech but no attributable name.
  const first = lines[0];
  const looksLikeName = first.length > 0 && first.length <= 48 && !/[.!?]$/.test(first);

  if (looksLikeName && lines.length > 1) {
    return { speaker: first, text: lines.slice(1).join(' ') };
  }
  return { speaker: null, text: lines.join(' ') };
}

/** Whether captions appear to be switched on right now. */
function captionsAppearActive() {
  const found = findCaptionRoot();
  if (!found) return false;
  return (found.root.innerText || '').trim().length > 0;
}

/** Find the CC toggle so the UI can point the user at it (we never click it ourselves). */
function findCaptionToggle() {
  const buttons = document.querySelectorAll('button[aria-label], [role="button"][aria-label]');
  for (const button of buttons) {
    if (matchesAnyLabel(button, CAPTION_TOGGLE_LABELS)) return button;
  }
  return null;
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

/** The Meet call code (`abc-defg-hij`) — our stable session identity. */
function readCallCode() {
  const path = location.pathname.replace(/^\//, '').split('/')[0];
  return /^[a-z]{3}-[a-z]{4}-[a-z]{3}$/i.test(path) ? path : path || null;
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

self.TWSelectors = {
  findCaptionRoot,
  readCaptionBlocks,
  parseCaptionBlock,
  captionsAppearActive,
  findCaptionToggle,
  describeCandidates,
  readCallCode,
  readMeetingTitle,
};
