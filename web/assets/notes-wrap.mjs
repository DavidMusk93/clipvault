/**
 * Token-atomic wrapping, shared by every surface that wraps user text:
 *   - notes preview code blocks (`white-space: pre-wrap`) — web/assets/notes-editor/entry.js
 *   - notes preview prose + inline code                     — entry.js
 *   - CodeMirror source/split (`.cm-atomic` decorations)    — entry.js
 *   - wall / card prose (`.notes-rich`, `.md-preview`)      — web/index.html, dynamic import
 *
 * Why this exists: even with `white-space: pre-wrap` / `normal`, UAX #14 offers
 * soft wrap opportunities *inside* a run, so `--ip` renders as `--` / `ip` and a
 * query `x?a=b` splits after the `?`. CSS cannot see tokens: `word-break: keep-all`
 * does not suppress Latin hyphen breaks, and `overflow-wrap` only adds break
 * points, never removes (both measured in Chrome).
 *
 * Rule: a run that contains one of those inner break points is one atomic wrap
 * unit. Runs become `<span class="notes-tok">` (or a `.cm-atomic` mark in the
 * editor); a guard is `display: inline-block; max-width: 100%`, so it moves to the
 * next line whole, yet a run longer than the line still breaks inside (last
 * resort) instead of overflowing. Two adjacent inline-blocks with no whitespace
 * between them offer no wrap opportunity, so a run that highlight.js split across
 * spans (`--` + `ip`) stays glued.
 *
 * Nothing here mutates text: textContent — and therefore every copy button — is
 * byte-identical. Pure DOM, no dependencies; `notes-render.mjs` stays the only
 * innerHTML door.
 */

/** Class applied to each guarded run. Styled in notes-editor.css / index.html. */
export const TOKEN_CLASS = 'notes-tok';

/**
 * Characters Chrome can break *inside* a non-whitespace run.
 *
 * Measured on Chrome 154 with `white-space: pre-wrap; overflow-wrap: normal;
 * word-break: normal`, one candidate char per run, box width = prefix width:
 *
 *   BREAK      - ? – — … ： ／ － ！ ？ 、 。 ・ ． ， ；   (break after)  （  (break before)
 *   NO BREAK   / \ : ; . , = + @ & ! % $ _ | ~ ^ * # < > ( ) [ ] { } " ' ` · © °
 *   CJK        breaks between chars by design — never guard a CJK-only run
 *
 * Only the ones that read as a *split token* are guarded. ASCII `/ : . ,` and
 * friends already never break, and fullwidth/CJK punctuation is natural
 * typographic line breaking in Chinese prose, so those keep their break points.
 */
export const TOKEN_BREAK_RE = /[-?\u2013\u2014\u2026]/;

const SHOW_TEXT = 4;

/** All non-whitespace runs of `text`, in order. */
export function atomicRuns(text) {
  const s = String(text || '');
  const out = [];
  const re = /\S+/g;
  let m;
  while ((m = re.exec(s)) !== null) out.push({ start: m.index, end: m.index + m[0].length, text: m[0] });
  return out;
}

/**
 * The subset of `atomicRuns` worth guarding: runs with an inner break point.
 * Guarding a run with none is a no-op for layout, so this keeps the DOM small.
 * @param {string} text
 * @returns {{start:number,end:number,text:string}[]}
 */
export function guardRanges(text) {
  return atomicRuns(text).filter((r) => TOKEN_BREAK_RE.test(r.text));
}

/**
 * Wrap every guarded run inside `root` in a `notes-tok` span.
 *
 * Runs are computed over the concatenated text of `root`, then each text node is
 * split at the run edges and its covered pieces wrapped — so a run whose DOM
 * nodes were split by a highlighter is guarded on both sides of the split.
 *
 * @param {Element} root
 * @param {{skip?: string}} [opts] `skip` is a selector; text nodes inside a
 *   matching element are left alone (e.g. `'pre, .is-mono'` for a card body).
 * @returns {number} number of spans created
 */
export function wrapAtomicTokens(root, opts = {}) {
  if (!root || typeof root.ownerDocument?.createTreeWalker !== 'function') return 0;
  const skip = opts.skip ? String(opts.skip) : '';
  const doc = root.ownerDocument;
  const walker = doc.createTreeWalker(root, SHOW_TEXT, null);

  const nodes = [];
  const starts = [];
  let full = '';
  for (let n = walker.nextNode(); n; n = walker.nextNode()) {
    const v = n.nodeValue || '';
    if (!v) continue;
    const p = n.parentElement;
    if (skip && p && p.closest(skip)) continue;
    nodes.push(n);
    starts.push(full.length);
    full += v;
  }
  if (!nodes.length) return 0;

  const runs = guardRanges(full);
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
