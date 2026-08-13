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
