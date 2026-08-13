/**
 * ClipVault Notes-like HTML fragment pipeline.
 * Used by web/index.html (keep behavior in sync) and tests/notes-render.test.mjs.
 *
 * Goals:
 *  - Apple Notes-ish structure (lists, paragraphs, emphasis)
 *  - Collapse Writer/Cocoa empty spacer holes
 *  - Prose may wrap; empty Cocoa holes collapsed; mono/code pre + highlight
 */

/** @param {string} s */
export function normalizePlainText(s) {
  return String(s || '')
    .replace(/\u2028|\u2029/g, '\n')
    .replace(/\r\n?/g, '\n')
    .replace(/[\u200B-\u200D\uFEFF]/g, '')
    .replace(/\t+/g, ' ')
    .replace(/^[ \t]*[•‣▪◦⁃]\s*/gm, '• ')
    .replace(/[ \t]+\n/g, '\n')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}

/** Collapse empty block tags and runaway <br> (string-level, no DOM). */
export function collapseEmptyHtmlBlocks(html) {
  let s = String(html || '');
  let prev = null;
  let guard = 0;
  while (s !== prev && guard++ < 12) {
    prev = s;
    // empty p/div/li/h* with only br/nbsp/spans/whitespace
    s = s.replace(
      /<(p|div|li|h[1-6])(\s[^>]*)?>\s*(?:<br\s*\/?>|&nbsp;|\u00a0|\s|<\/?(?:span|font|b|i|u|em|strong)[^>]*>)*<\/\1>/gi,
      ''
    );
    // p with only whitespace text between tags after inner empty
    s = s.replace(/<(p|div)(\s[^>]*)?>[\s\u00a0]*<\/\1>/gi, '');
    // 3+ consecutive br → max 1 blank line
    s = s.replace(/(?:<br\s*\/?>\s*){3,}/gi, '<br>');
    // empty consecutive paragraphs leftovers
    s = s.replace(/(<\/p>\s*){2,}/gi, '</p>');
  }
  return s.trim();
}

/** Strip tags for plain preview / usefulness check. */
export function stripHtmlToText(html) {
  if (!html) return '';
  let s = String(html);
  const body = s.match(/<body[^>]*>([\s\S]*?)<\/body>/i);
  if (body) s = body[1];
  s = s
    .replace(/<script[\s\S]*?<\/script>/gi, '')
    .replace(/<style[\s\S]*?<\/style>/gi, '')
    .replace(/<br\s*\/?>/gi, '\n')
    .replace(/<\/(p|div|li|h[1-6]|tr)>/gi, '\n')
    .replace(/<li[^>]*>/gi, '• ')
    .replace(/<[^>]+>/g, '')
    .replace(/&nbsp;/g, ' ')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&amp;/g, '&')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'");
  if (typeof DOMParser !== 'undefined') {
    try {
      s = new DOMParser().parseFromString('<!doctype html><body>' + s, 'text/html').body.textContent || s;
    } catch (_) {}
  }
  return normalizePlainText(s);
}

function isVisuallyEmpty(el) {
  if (!el || el.nodeType !== 1) return true;
  if (el.querySelector && el.querySelector('img, video, svg, canvas')) return false;
  const t = (el.textContent || '').replace(/\u00a0/g, ' ').replace(/\s+/g, '');
  return t.length === 0;
}

/**
 * Cocoa / Notes HTML → Notes-like fragment.
 * @param {string} html
 * @returns {string}
 */
export function renderNotesFragment(html) {
  if (!html) return '';
  const raw = String(html);

  if (typeof DOMParser !== 'undefined') {
    try {
      const doc = new DOMParser().parseFromString(raw, 'text/html');
      const root = doc.body || doc;

      root.querySelectorAll('style, script, meta, title, link').forEach(el => el.remove());
      root.querySelectorAll('.Apple-tab-span, span[class*="Apple-tab"]').forEach(el => el.remove());

      root.querySelectorAll('.Apple-converted-space, span[class*="Apple-converted-space"]').forEach(el => {
        const parent = el.parentNode;
        if (!parent) return;
        while (el.firstChild) parent.insertBefore(el.firstChild, el);
        parent.removeChild(el);
      });

      // Multi-pass empty spacer removal (Writer / Cocoa holes)
      for (let pass = 0; pass < 8; pass++) {
        let removed = 0;
        root.querySelectorAll('p, li, div, h1, h2, h3, h4, h5, h6').forEach(el => {
          if (isVisuallyEmpty(el)) {
            el.remove();
            removed++;
          }
        });
        if (!removed) break;
      }

      // Collapse consecutive <br>
      root.querySelectorAll('br').forEach(br => {
        let n = 0;
        let sib = br.nextSibling;
        while (sib && (sib.nodeType === 3 && !sib.textContent.trim() || sib.nodeName === 'BR')) {
          if (sib.nodeName === 'BR') n++;
          const next = sib.nextSibling;
          if (sib.nodeName === 'BR' && n >= 1) sib.remove();
          sib = next;
        }
      });

      // Presentation sanitize: Chrome dark-mode copy leaves black bg / white text
      // on font/span/mark/etc. Strip ALL presentation attrs (not just a tag whitelist).
      sanitizePresentation(root);
      // Never render navigable links in the card (public-misclick risk).
      neutralizeAnchors(root);

      root.querySelectorAll('p').forEach(p => {
        const t = p.textContent || '';
        if (
          /^\s*(SELECT|FROM|WHERE|AND|OR|JOIN|GROUP|ORDER|LIMIT|INSERT|UPDATE|DELETE|CREATE|WITH)\b/i.test(t) ||
          /^\s{2,}\S/.test(t) ||
          /formatDateTime|AS\s+\w+,?\s*$/i.test(t)
        ) {
          p.classList.add('is-mono');
        }
      });

      root.querySelectorAll('span').forEach(span => {
        if (!span.attributes.length) {
          const parent = span.parentNode;
          if (!parent) return;
          while (span.firstChild) parent.insertBefore(span.firstChild, span);
          parent.removeChild(span);
        }
      });

      return collapseEmptyHtmlBlocks((root.innerHTML || '').trim());
    } catch (_) {
      /* fall through */
    }
  }

  // Regex fallback (Node without DOMParser, or parse failure)
  let s = raw;
  const body = s.match(/<body[^>]*>([\s\S]*?)<\/body>/i);
  if (body) s = body[1];
  s = s
    .replace(/<style[\s\S]*?<\/style>/gi, '')
    .replace(/<script[\s\S]*?<\/script>/gi, '')
    .replace(/<span class="Apple-tab-span"[^>]*>[\s\S]*?<\/span>/gi, '')
    .replace(/<span class="Apple-converted-space"[^>]*>([\s\S]*?)<\/span>/gi, '$1')
    .replace(/\sclass="(?!is-mono)[^"]*"/gi, '')
    .replace(/\sstyle=("|')[^"']*\1/gi, '')
    .replace(/\s(bgcolor|background|color|face|size)=("|')[^"']*\2/gi, '')
    .replace(/<a\b[^>]*>/gi, '<span class="url-inert">')
    .replace(/<\/a>/gi, '</span>');
  return collapseEmptyHtmlBlocks(s.trim());
}

/** Strip dark-mode / selection paint that turns cards black (Chrome HTML copy). */
export function sanitizePresentation(root) {
  if (!root || !root.querySelectorAll) return;
  root.querySelectorAll('*').forEach(el => {
    el.removeAttribute('style');
    el.removeAttribute('bgcolor');
    el.removeAttribute('background');
    el.removeAttribute('color');
    el.removeAttribute('face');
    el.removeAttribute('size');
    el.removeAttribute('width');
    el.removeAttribute('height');
    el.removeAttribute('align');
    // Drop foreign classes; keep is-mono if present
    const keepMono = el.classList && el.classList.contains('is-mono');
    const keepInert = el.classList && el.classList.contains('url-inert');
    el.removeAttribute('class');
    if (keepMono) el.classList.add('is-mono');
    if (keepInert) el.classList.add('url-inert');
  });
}

/** Convert <a href> → inert span (no navigation in card). */
export function neutralizeAnchors(root) {
  if (!root || !root.querySelectorAll) return;
  root.querySelectorAll('a').forEach(a => {
    const span = a.ownerDocument.createElement('span');
    span.className = 'url-inert';
    const href = a.getAttribute('href') || '';
    if (href) span.setAttribute('data-url', href);
    span.textContent = a.textContent || href;
    a.parentNode && a.parentNode.replaceChild(span, a);
  });
}


export function notesFragmentUseful(fragment) {
  if (!fragment) return false;
  if (/<(ul|ol|li|p|br|b|strong|i|em|u|h[1-6]|table|blockquote)\b/i.test(fragment)) {
    const plain = stripHtmlToText(fragment);
    return plain.length > 0 || /<(ul|ol|img|table)\b/i.test(fragment);
  }
  return stripHtmlToText(fragment).length > 0;
}

/** CSS policy tokens that must hold in web/index.html (regression guard). */
export const NOTES_CSS_POLICY = {
  /** product: rich text must NOT soft-wrap — pan instead (hard newlines only) */
  requireNotesPreNoSoftWrap: false, // prose white-space:normal; mono still pre
  /** mono / code runs unwrap */
  requireMonoPre: true,
  /** empty spacers must be hidden */
  requireEmptyPHidden: true,
  /** inner content max-content for horizontal pan */
  requireNotesInnerMaxContent: true,
  /** neutralize Chrome dark paint / black selection backgrounds */
  requireNeutralPresentation: true,
  /** no clickable <a href> in card HTML */
  requireNoNavigableAnchors: true,
};
