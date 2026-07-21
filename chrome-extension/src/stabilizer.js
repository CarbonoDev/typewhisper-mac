/**
 * Caption stabilizer.
 *
 * Meet captions are a *rolling revision buffer*, not a stream of finished lines: a block appears,
 * its text grows word by word, the tail gets rewritten as the recognizer changes its mind, and the
 * block is eventually evicted when it scrolls out. Naively recording every mutation produces a
 * transcript full of half-sentences and duplicated fragments.
 *
 * The rule this exploits: **revisions only ever touch the tail.** Text far enough behind the
 * writing head is settled. So each block emits in two ways:
 *
 *   - *prefix flush* — once a block accumulates enough text, everything up to the last sentence
 *     boundary before a tail guard is emitted and never revisited. This keeps long monologues
 *     flowing instead of buffering for minutes.
 *   - *finalize* — when a block stops changing (idle) or leaves the DOM, whatever is left is
 *     emitted and the block is closed.
 *
 * Timestamps are wall-clock relative to session start, shifted back by `captionLagMs` because Meet
 * renders a caption noticeably after the words were spoken. That shift is an estimate and is not
 * relied upon for correctness — downstream speaker transfer is text-anchored, not time-anchored.
 */

const DEFAULTS = {
  /** Emit a prefix once this many unemitted characters have piled up in one block. */
  prefixFlushChars: 320,
  /** Never emit within this many characters of the writing head — that region is still being revised. */
  tailGuardChars: 90,
  /** A block untouched for this long is considered finished. */
  stabilizeMs: 2500,
  /** How far captions trail the actual speech. */
  captionLagMs: 1200,
  /** How many recent emissions to remember for duplicate suppression. */
  dedupeHistory: 12,
};

class CaptionStabilizer {
  constructor(options = {}) {
    this.options = { ...DEFAULTS, ...options };
    this.sessionStart = options.sessionStart ?? 0;
    /** @type {Map<any, object>} live block state, keyed by the caption element. */
    this.blocks = new Map();
    /** Recently emitted texts, for suppressing Meet's occasional block re-creation. */
    this.recent = [];
  }

  /**
   * Feed the current set of caption blocks. Returns the segments finalized by this observation.
   *
   * @param {Array<{element: any, speaker: string|null, text: string}>} blocks
   * @param {number} now epoch ms
   */
  observe(blocks, now) {
    const emitted = [];
    const seen = new Set();

    for (const block of blocks) {
      seen.add(block.element);
      const text = normalizeText(block.text);
      if (!text) continue;

      let state = this.blocks.get(block.element);
      if (!state) {
        state = {
          speaker: block.speaker,
          text,
          firstSeen: now,
          lastChanged: now,
          emittedChars: 0,
          segmentStart: now,
        };
        this.blocks.set(block.element, state);
      } else {
        // A speaker rename on an existing block means Meet reused the element for a new turn:
        // close the old turn out before adopting the new one.
        if (block.speaker && state.speaker && block.speaker !== state.speaker) {
          const tail = this.#finalizeState(state, now, emitted);
          if (tail) this.#remember(tail.text);
          state.speaker = block.speaker;
          state.text = text;
          state.emittedChars = 0;
          state.segmentStart = now;
        } else {
          if (block.speaker && !state.speaker) state.speaker = block.speaker;
          if (text !== state.text) {
            state.text = text;
            state.lastChanged = now;
          }
        }
      }

      const pending = state.text.slice(state.emittedChars);
      if (pending.length > this.options.prefixFlushChars) {
        const cut = stablePrefixLength(pending, this.options.tailGuardChars);
        if (cut > 0) {
          const chunk = pending.slice(0, cut).trim();
          if (chunk && !this.#isDuplicate(chunk)) {
            emitted.push(this.#makeSegment(state, chunk, state.segmentStart, now));
            this.#remember(chunk);
          }
          state.emittedChars += cut;
          state.segmentStart = now;
        }
      }
    }

    // Blocks that vanished from the DOM, or went quiet, are done.
    for (const [element, state] of this.blocks) {
      const gone = !seen.has(element);
      const idle = now - state.lastChanged > this.options.stabilizeMs;
      if (!gone && !idle) continue;

      const segment = this.#finalizeState(state, now, emitted);
      if (segment) this.#remember(segment.text);
      // An idle-but-present block stays tracked (Meet may resume writing into it) with everything
      // emitted; a removed one is dropped entirely.
      if (gone) this.blocks.delete(element);
    }

    return emitted;
  }

  /** Emit whatever is still pending on every tracked block — used when the call ends. */
  flushAll(now) {
    const emitted = [];
    for (const [element, state] of this.blocks) {
      this.#finalizeState(state, now, emitted);
      this.blocks.delete(element);
    }
    return emitted;
  }

  #finalizeState(state, now, sink) {
    const pending = state.text.slice(state.emittedChars).trim();
    if (!pending || this.#isDuplicate(pending)) {
      state.emittedChars = state.text.length;
      return null;
    }
    const segment = this.#makeSegment(state, pending, state.segmentStart, state.lastChanged);
    state.emittedChars = state.text.length;
    state.segmentStart = now;
    sink.push(segment);
    return segment;
  }

  #makeSegment(state, text, startMs, endMs) {
    const lag = this.options.captionLagMs;
    const toSeconds = (ms) => Math.max(0, (ms - lag - this.sessionStart) / 1000);
    const start = toSeconds(startMs);
    return {
      speaker: state.speaker || null,
      text,
      start,
      end: Math.max(start, toSeconds(endMs)),
    };
  }

  #isDuplicate(text) {
    return this.recent.includes(text);
  }

  #remember(text) {
    this.recent.push(text);
    if (this.recent.length > this.options.dedupeHistory) this.recent.shift();
  }
}

function normalizeText(text) {
  return (text || '').replace(/\s+/g, ' ').trim();
}

/**
 * How much of `pending` is safe to emit: everything up to the last sentence boundary that sits at
 * least `tailGuard` characters behind the writing head. Falls back to a word boundary when the
 * speaker has not finished a sentence in a long time, and to nothing at all when even that would
 * cut into the guard.
 */
function stablePrefixLength(pending, tailGuard) {
  const limit = pending.length - tailGuard;
  if (limit <= 0) return 0;

  const head = pending.slice(0, limit);

  // Last sentence terminator in the head region.
  const sentence = head.match(/[.!?…](?=[^.!?…]*$)/);
  if (sentence && sentence.index > 0) return sentence.index + 1;

  const word = head.lastIndexOf(' ');
  return word > 0 ? word : 0;
}

// Usable both as a content-script global and as a CommonJS module under `node --test`.
if (typeof self !== 'undefined') self.CaptionStabilizer = CaptionStabilizer;
if (typeof module !== 'undefined' && module.exports) {
  module.exports = { CaptionStabilizer, stablePrefixLength, normalizeText };
}
