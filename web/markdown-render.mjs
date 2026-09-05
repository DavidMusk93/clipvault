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
  ADD_ATTR: ['data-source-line', 'target', 'rel'],
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
      let html = parser([t]);
      html = purify.sanitize(String(html || ''), PURIFY_OPTS);
      html = html.replace(
        /^\s*<([a-zA-Z][a-zA-Z0-9]*)/,
        `<$1 data-source-line="${line}"`,
      );
      html = html.replace(/<a\b/gi, '<a target="_blank" rel="noopener noreferrer"');
      parts.push(html);
    }
    return { html: parts.join(''), ok: true, engine: 'marked+dompurify' };
  } catch (_) {
    return { html: '', ok: false, engine: 'marked-error' };
  }
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
