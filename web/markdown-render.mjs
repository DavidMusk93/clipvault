/**
 * ClipVault Markdown preview — thin wrapper over mature libs.
 * Parse:  marked (https://github.com/markedjs/marked)
 * Sanitize: DOMPurify (https://github.com/cure53/DOMPurify)
 * No home-grown markdown grammar. Copy path always uses raw source.
 *
 * AGENTS §8: after sanitize, neutralize <a href> → inert spans (no mis-clicks).
 */

/**
 * @param {string} src
 * @param {{ marked?: any, purify?: any }} engines
 * @returns {{ html: string, engine: string, ok: boolean }}
 */
export function renderMarkdownToHtml(src, engines = {}) {
  const text = String(src ?? '').replace(/\r\n/g, '\n');
  const marked = engines.marked ?? (typeof globalThis !== 'undefined' ? globalThis.marked : null);
  const purify = engines.purify ?? (typeof globalThis !== 'undefined' ? globalThis.DOMPurify : null);

  if (!marked || (typeof marked.parse !== 'function' && typeof marked !== 'function')) {
    return { html: '', engine: '', ok: false };
  }

  let rawHtml = '';
  try {
    if (typeof marked.parse === 'function') {
      // marked v5+
      if (typeof marked.setOptions === 'function') {
        marked.setOptions({ gfm: true, breaks: true });
      }
      rawHtml = marked.parse(text, { async: false, gfm: true, breaks: true });
    } else {
      rawHtml = marked(text);
    }
  } catch (e) {
    return { html: '', engine: 'marked-error', ok: false };
  }

  let safe = String(rawHtml || '');
  if (purify && typeof purify.sanitize === 'function') {
    safe = purify.sanitize(safe, {
      USE_PROFILES: { html: true },
      FORBID_TAGS: ['script', 'style', 'iframe', 'object', 'embed', 'form', 'input', 'button'],
      FORBID_ATTR: ['style'], // avoid dark-paint / layout break-in from clipboard md
      ALLOW_DATA_ATTR: false,
    });
  } else {
    // No DOMPurify → refuse HTML (never inject unsanitized library output).
    return { html: '', engine: 'marked-no-purify', ok: false };
  }

  safe = neutralizeAnchorsHtml(safe);
  return { html: safe, engine: 'marked+dompurify', ok: true };
}

const PURIFY_OPTS = {
  USE_PROFILES: { html: true },
  FORBID_TAGS: ['script', 'style', 'iframe', 'object', 'embed', 'form', 'input', 'button'],
  FORBID_ATTR: ['style'],
  ALLOW_DATA_ATTR: false,
  ADD_ATTR: ['data-source-line', 'data-source-end-line', 'target', 'rel'],
};

/**
 * Notes preview: GFM HTML with data-source-line on block roots. Links stay navigable.
 * @param {string} src
 * @param {{ marked?: any, purify?: any }} engines
 * @returns {{ html: string, ok: boolean, engine: string }}
 */
/**
 * Notes source may use Word-style nested markers (`a.` / `i.`) which GFM
 * does not parse. Map them to indented `1.` so marked builds nested <ol>.
 * Only indented lines (2+ spaces) so a column-0 "a.m." / "i.e." stays prose.
 */
export function toGfmNestedLists(src) {
  const lines = String(src ?? '').replace(/\r\n/g, '\n').split('\n');
  let fence = false;
  return lines.map((line) => {
    if (/^\s{0,3}```/.test(line)) {
      fence = !fence;
      return line;
    }
    if (fence) return line;
    const m = /^([ \t]{2,})([a-z]|[ivxlcdm]+)[.)]([ \t]+)(.*)$/i.exec(line);
    if (!m) return line;
    return `${m[1]}1. ${m[4]}`;
  }).join('\n');
}

export function renderMarkdownBlocks(src, engines = {}) {
  const text = toGfmNestedLists(String(src ?? '').replace(/\r\n/g, '\n'));
  const marked = engines.marked ?? (typeof globalThis !== 'undefined' ? globalThis.marked : null);
  const purify = engines.purify ?? (typeof globalThis !== 'undefined' ? globalThis.DOMPurify : null);
  if (!marked || (typeof marked.lexer !== 'function' && typeof marked.parse !== 'function')) {
    return { html: '', ok: false, engine: '' };
  }
  if (!purify || typeof purify.sanitize !== 'function') {
    return { html: '', ok: false, engine: 'marked-no-purify' };
  }
  try {
    if (typeof marked.setOptions === 'function') {
      marked.setOptions({ gfm: true, breaks: true });
    }
    const lexer = typeof marked.lexer === 'function' ? marked.lexer.bind(marked) : null;
    const parser = typeof marked.parser === 'function' ? marked.parser.bind(marked) : null;
    if (!lexer || !parser) {
      const raw = typeof marked.parse === 'function'
        ? marked.parse(text, { async: false, gfm: true, breaks: true })
        : marked(text);
      const safe = purify.sanitize(String(raw || ''), PURIFY_OPTS);
      return { html: safe, ok: true, engine: 'marked+dompurify' };
    }
    const tokens = lexer(text);
    let pos = 0;
    const parts = [];
    for (const t of tokens) {
      const raw = String(t.raw || '');
      const i = raw ? text.indexOf(raw, pos) : pos;
      const at = i >= 0 ? i : pos;
      const line = text.slice(0, at).split('\n').length;
      pos = at + raw.length;
      const lineTo = tokenLineSpan(raw, line);
      let html = parser([t]);
      html = purify.sanitize(String(html || ''), PURIFY_OPTS);
      html = html.replace(
        /^\s*<([a-zA-Z][a-zA-Z0-9]*)/,
        `<$1 data-source-line="${line}" data-source-end-line="${lineTo}"`,
      );
      html = html.replace(/<a\b/gi, '<a target="_blank" rel="noopener noreferrer"');
      parts.push(html);
    }
    return { html: parts.join(''), ok: true, engine: 'marked+dompurify' };
  } catch (_) {
    return { html: '', ok: false, engine: 'marked-error' };
  }
}

function clampNum(n, lo, hi) {
  return Math.min(hi, Math.max(lo, n));
}

/** Inclusive source line of the last row in a marked token. */
export function tokenLineSpan(raw, lineFrom) {
  const from = Math.max(1, Number(lineFrom) || 1);
  const text = String(raw || '');
  if (!text) return from;
  const nl = (text.match(/\n/g) || []).length;
  const extra = text.endsWith('\n') ? Math.max(0, nl - 1) : nl;
  return from + extra;
}

/**
 * @typedef {{ lineFrom: number, lineTo: number, y: number, height: number }} PreviewBlock
 */

function previewBlocks(blocks) {
  const list = [];
  for (const b of blocks || []) {
    const lineFrom = Number(b && (b.lineFrom ?? b.line));
    const y = Number(b && b.y);
    const height = Number(b && b.height);
    if (!Number.isFinite(lineFrom) || !Number.isFinite(y)) continue;
    const lineTo = Number(b && b.lineTo);
    list.push({
      lineFrom,
      lineTo: Math.max(lineFrom, Number.isFinite(lineTo) ? lineTo : lineFrom),
      y,
      height: Math.max(0, Number.isFinite(height) ? height : 0),
    });
  }
  list.sort((a, b) => a.lineFrom - b.lineFrom || a.y - b.y);
  return list;
}

/**
 * Fractional source line → preview scrollTop (VS Code / MarkEdit).
 * line 1 = first source line; 7.5 = halfway through line 7.
 * atEnd pins to maxY so source-at-bottom is preview-at-bottom.
 */
export function mapSourceToPreviewScroll(line, blocks, maxY, opts = {}) {
  const max = Math.max(0, Number(maxY) || 0);
  if (max <= 0) return 0;
  if (opts && opts.atEnd) return max;
  const x = Number(line);
  if (!Number.isFinite(x) || x <= 1) return 0;

  const list = previewBlocks(blocks);
  const lastLine = Math.max(1, Number(opts.lastLine) || 1);
  if (!list.length) {
    if (lastLine <= 1) return 0;
    return clampNum(((x - 1) / (lastLine - 1)) * max, 0, max);
  }

  let prev = null;
  let next = null;
  for (const b of list) {
    if (b.lineFrom <= x + 1e-9) prev = b;
    else {
      next = b;
      break;
    }
  }

  if (!prev) {
    const first = list[0];
    const span = first.lineFrom - 1;
    const p = span > 0 ? (x - 1) / span : 0;
    return clampNum(first.y * p, 0, max);
  }

  if (prev.lineTo > prev.lineFrom && x < prev.lineTo) {
    const p = (x - prev.lineFrom) / (prev.lineTo - prev.lineFrom);
    return clampNum(prev.y + prev.height * p, 0, max);
  }

  if (next && next.lineFrom !== prev.lineFrom) {
    const fromLine = Math.max(prev.lineTo, prev.lineFrom);
    const span = next.lineFrom - fromLine;
    const between = span > 0 ? (x - fromLine) / span : 0;
    const prevBottom = prev.y + prev.height;
    return clampNum(prevBottom + between * (next.y - prevBottom), 0, max);
  }

  if (!next && x >= lastLine) return max;
  const span = Math.max(1e-9, lastLine - prev.lineFrom);
  const p = clampNum((x - prev.lineFrom) / span, 0, 1);
  return clampNum(prev.y + prev.height * p, 0, max);
}

/** Preview scrollTop → fractional source line (inverse of mapSourceToPreviewScroll). */
export function mapPreviewToSourceLine(y, blocks, maxY, lastLine, opts = {}) {
  const last = Math.max(1, Number(lastLine) || 1);
  if (opts && opts.atEnd) return last;
  const max = Math.max(0, Number(maxY) || 0);
  const top = clampNum(Number(y) || 0, 0, max);
  if (top <= 0) return 1;

  const list = previewBlocks(blocks);
  if (!list.length) {
    if (max <= 0) return 1;
    return 1 + (top / max) * (last - 1);
  }

  let prev = null;
  let next = null;
  for (const b of list) {
    if (b.y <= top + 1e-9) prev = b;
    else {
      next = b;
      break;
    }
  }
  if (!prev) return 1;

  const prevBottom = prev.y + prev.height;
  if (top + 1e-9 < prevBottom || !next) {
    if (prev.height > 0 && prev.lineTo > prev.lineFrom) {
      const p = clampNum((top - prev.y) / prev.height, 0, 1);
      return prev.lineFrom + p * (prev.lineTo - prev.lineFrom);
    }
    if (next && next.y > prev.y) {
      const p = clampNum((top - prev.y) / (next.y - prev.y), 0, 1);
      return prev.lineFrom + p * (next.lineFrom - prev.lineFrom);
    }
    if (!next && max > 0 && top >= max - 1) return last;
    const p = prev.height > 0 ? clampNum((top - prev.y) / prev.height, 0, 1) : 0;
    return prev.lineFrom + p * Math.max(0, last - prev.lineFrom);
  }

  const gap = next.y - prevBottom;
  const p = gap > 0 ? (top - prevBottom) / gap : 0;
  return prev.lineTo + p * (next.lineFrom - prev.lineTo);
}

function anchorPoints(anchors, lastLine, maxY) {
  const pts = [{ line: 1, y: 0 }];
  for (const a of anchors || []) {
    const line = Number(a && a.line);
    const y = Number(a && a.y);
    if (!Number.isFinite(line) || !Number.isFinite(y)) continue;
    pts.push({
      line: clampNum(line, 1, lastLine),
      y: clampNum(y, 0, maxY),
    });
  }
  pts.push({ line: lastLine, y: maxY });
  return pts;
}

/**
 * Source line → preview scrollTop. Anchors are `{line, y}` in scroller content.
 * Missing anchors fall back to proportional mapping so split panes still move.
 */
export function mapLineToScrollTop(line, anchors, docLines, maxY) {
  const max = Math.max(0, Number(maxY) || 0);
  if (max <= 0) return 0;
  const lastLine = Math.max(1, Number(docLines) || 1);
  const n = clampNum(Number(line) || 1, 1, lastLine);
  const pts = anchorPoints(anchors, lastLine, max);
  pts.sort((a, b) => a.line - b.line || a.y - b.y);
  if (n <= pts[0].line) return pts[0].y;
  for (let i = 1; i < pts.length; i++) {
    if (n <= pts[i].line) {
      const a = pts[i - 1];
      const b = pts[i];
      if (b.line === a.line) return b.y;
      return a.y + ((n - a.line) / (b.line - a.line)) * (b.y - a.y);
    }
  }
  return max;
}

/** Preview scrollTop → source line (inverse of mapLineToScrollTop). */
export function mapScrollTopToLine(y, anchors, docLines, maxY) {
  const max = Math.max(0, Number(maxY) || 0);
  const lastLine = Math.max(1, Number(docLines) || 1);
  if (max <= 0) return 1;
  const top = clampNum(Number(y) || 0, 0, max);
  const pts = anchorPoints(anchors, lastLine, max);
  pts.sort((a, b) => a.y - b.y || a.line - b.line);
  if (top <= pts[0].y) return pts[0].line;
  for (let i = 1; i < pts.length; i++) {
    if (top <= pts[i].y) {
      const a = pts[i - 1];
      const b = pts[i];
      if (b.y === a.y) return b.line;
      return a.line + ((top - a.y) / (b.y - a.y)) * (b.line - a.line);
    }
  }
  return lastLine;
}

/** AGENTS §8: display only — no navigable links in card. */
export function neutralizeAnchorsHtml(html) {
  if (typeof DOMParser === 'undefined') {
    return String(html || '')
      .replace(/<a\b[^>]*>/gi, '<span class="url-inert md-link">')
      .replace(/<\/a>/gi, '</span>');
  }
  try {
    const doc = new DOMParser().parseFromString(`<!doctype html><body>${html}`, 'text/html');
    const root = doc.body || doc;
    root.querySelectorAll('a').forEach((a) => {
      const span = doc.createElement('span');
      span.className = 'url-inert md-link';
      const href = a.getAttribute('href') || '';
      if (href) span.setAttribute('data-url', href);
      span.textContent = a.textContent || href;
      a.parentNode && a.parentNode.replaceChild(span, a);
    });
    return (root.innerHTML || '').trim();
  } catch (_) {
    return String(html || '');
  }
}
