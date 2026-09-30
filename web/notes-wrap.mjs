/**
 * Token-atomic wrapping for notes code blocks (the 「换行」 toggle).
 *
 * Why this exists: in wrap mode the block is `white-space: pre-wrap`, but UAX #14
 * still offers a soft wrap opportunity *after a hyphen or slash*, so a flag such
 * as `--ip` renders as `--` / `ip` and `a/b` splits mid-path. CSS cannot see
 * tokens: `word-break: keep-all` does not suppress Latin hyphen breaks (verified
 * in Chrome), and `overflow-wrap` only adds more break points, never removes.
 *
 * Rule: every non-whitespace run is one atomic wrap unit. Runs become
 * `<span class="notes-tok">`; in wrap mode the span is
 * `display: inline-block; max-width: 100%`, so it moves to the next line whole,
 * yet a run longer than the line still breaks inside (last resort) instead of
 * scrolling. Two adjacent inline-blocks with no whitespace between them offer no
 * wrap opportunity, so a run that highlight.js split across spans (`--` + `ip`)
 * still stays glued.
 *
 * Pure DOM, no dependencies; `web/notes-render.mjs` stays the only innerHTML door.
 */

/** Class applied to each atomic run. Styled only under `.notes-code.is-wrap`. */
export const TOKEN_CLASS = 'notes-tok';

const SHOW_TEXT = 4;

/**
 * Atomic wrap units of `text`: maximal runs without whitespace.
 * @param {string} text
 * @returns {{start:number,end:number,text:string}[]}
 */
export function atomicRuns(text) {
  const s = String(text || '');
  const out = [];
  const re = /\S+/g;
  let m;
  while ((m = re.exec(s)) !== null) out.push({ start: m.index, end: m.index + m[0].length, text: m[0] });
  return out;
}

/**
 * Wrap every atomic run inside `root` in a `notes-tok` span.
 * Idempotent per call: text nodes created by an earlier call are plain text and
 * would be wrapped again, so callers must not re-run on an already-wrapped root.
 *
 * @param {Element} root element whose text content is code (usually `code`)
 * @returns {number} number of spans created
 */
export function wrapAtomicTokens(root) {
  if (!root || typeof root.ownerDocument?.createTreeWalker !== 'function') return 0;
  const doc = root.ownerDocument;
  const walker = doc.createTreeWalker(root, SHOW_TEXT, null);

  const nodes = [];
  const starts = [];
  let full = '';
  for (let n = walker.nextNode(); n; n = walker.nextNode()) {
    const v = n.nodeValue || '';
    if (!v) continue;
    nodes.push(n);
    starts.push(full.length);
    full += v;
  }
  if (!nodes.length) return 0;

  const runs = atomicRuns(full);
  if (!runs.length) return 0;

  let wrapped = 0;
  let ri = 0;
  for (let i = 0; i < nodes.length; i++) {
    const node = nodes[i];
    const v = node.nodeValue || '';
    const g0 = starts[i];
    const g1 = g0 + v.length;

    while (ri < runs.length && runs[ri].end <= g0) ri += 1;
    const pieces = [];
    for (let j = ri; j < runs.length && runs[j].start < g1; j += 1) {
      const a = Math.max(runs[j].start, g0) - g0;
      const b = Math.min(runs[j].end, g1) - g0;
      if (b > a) pieces.push([a, b]);
    }
    if (!pieces.length) continue;

    const frag = doc.createDocumentFragment();
    let cur = 0;
    for (const [a, b] of pieces) {
      if (a > cur) frag.appendChild(doc.createTextNode(v.slice(cur, a)));
      const span = doc.createElement('span');
      span.className = TOKEN_CLASS;
      span.textContent = v.slice(a, b);
      frag.appendChild(span);
      wrapped += 1;
      cur = b;
    }
    if (cur < v.length) frag.appendChild(doc.createTextNode(v.slice(cur)));
    node.parentNode.replaceChild(frag, node);
  }
  return wrapped;
}
