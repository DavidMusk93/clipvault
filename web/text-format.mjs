/**
 * ClipVault — display-only structured text formatting.
 * Prefer real formatters (js-beautify / sql-formatter / marked) when available;
 * fall back to conservative builtins. Copy path must use raw payload.
 */

import { renderMarkdownToHtml } from './markdown-render.mjs';

export const TEXT_PRETTY_MAX = 200000;

const KIND_META = {
  json:     { label: 'JSON', icon: 'data_object', lang: 'json' },
  ndjson:   { label: 'NDJSON', icon: 'list_alt', lang: 'json' },
  jwt:      { label: 'JWT', icon: 'key', lang: 'json' },
  url:      { label: 'URL', icon: 'link', lang: 'plaintext' },
  form:     { label: 'Form', icon: 'tune', lang: 'plaintext' },
  xml:      { label: 'XML', icon: 'code', lang: 'xml' },
  html:     { label: 'HTML', icon: 'html', lang: 'xml' },
  csv:      { label: 'CSV', icon: 'table', lang: 'plaintext' },
  env:      { label: 'ENV', icon: 'settings', lang: 'plaintext' },
  stack:    { label: 'Stack', icon: 'bug_report', lang: 'plaintext' },
  sql:      { label: 'SQL', icon: 'database', lang: 'sql' },
  markdown: { label: 'MD', icon: 'notes', lang: 'markdown' },
  yaml:     { label: 'YAML', icon: 'segment', lang: 'yaml' },
  base64:   { label: 'Base64', icon: 'lock', lang: 'plaintext' },
  plain:    { label: '', icon: 'notes', lang: 'plaintext' },
};

export function kindMeta(kind) {
  return KIND_META[kind] || KIND_META.plain;
}

/** Optional engines: { jsBeautify, htmlBeautify, sqlFormat, marked } */
export function resolveBeautifiers(custom) {
  if (custom && typeof custom === 'object') return custom;
  const g = typeof globalThis !== 'undefined' ? globalThis : {};
  let marked = null;
  if (typeof g.marked === 'function') marked = g.marked;
  else if (g.marked && typeof g.marked.parse === 'function') marked = g.marked;
  return {
    jsBeautify: typeof g.js_beautify === 'function' ? g.js_beautify : null,
    htmlBeautify: typeof g.html_beautify === 'function' ? g.html_beautify : null,
    sqlFormat:
      g.sqlFormatter && typeof g.sqlFormatter.format === 'function'
        ? (s, opts) => g.sqlFormatter.format(s, opts || { language: 'sql', tabWidth: 2, keywordCase: 'upper' })
        : null,
    marked,
  };
}

function tryParseJson(s) {
  try {
    return { ok: true, value: JSON.parse(s) };
  } catch (_) {
    return { ok: false };
  }
}

function isPlainObjectOrArray(v) {
  return v !== null && typeof v === 'object';
}

function b64ToUtf8(b64raw) {
  let b64 = String(b64raw || '').replace(/-/g, '+').replace(/_/g, '/').replace(/\s+/g, '');
  const pad = b64.length % 4;
  if (pad) b64 += '='.repeat(4 - pad);
  if (typeof atob === 'function') {
    const bin = atob(b64);
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    try {
      return new TextDecoder('utf-8', { fatal: false }).decode(bytes);
    } catch (_) {
      return bin;
    }
  }
  return Buffer.from(b64, 'base64').toString('utf8');
}

function looksLikeJwt(t) {
  const parts = t.split('.');
  if (parts.length !== 3) return false;
  if (parts.some((p) => !p || /\s/.test(p))) return false;
  if (parts[0].length < 8 || parts[1].length < 8) return false;
  if (!parts.every((p) => /^[A-Za-z0-9_-]+$/.test(p))) return false;
  try {
    const hdr = JSON.parse(b64ToUtf8(parts[0]));
    return hdr && typeof hdr === 'object' && (hdr.alg || hdr.typ);
  } catch (_) {
    return false;
  }
}

function formatJwt(t, beautifyJson) {
  const [h, p, sig] = t.split('.');
  const headerObj = JSON.parse(b64ToUtf8(h));
  let payloadStr;
  try {
    payloadStr = beautifyJson(JSON.stringify(JSON.parse(b64ToUtf8(p))));
  } catch (_) {
    payloadStr = b64ToUtf8(p);
  }
  return [
    '// header',
    beautifyJson(JSON.stringify(headerObj)),
    '',
    '// payload',
    payloadStr,
    '',
    '// signature',
    sig.slice(0, 32) + (sig.length > 32 ? '…' : ''),
  ].join('\n');
}

function looksLikeUrl(t) {
  if (t.length < 12 || /\s/.test(t)) return false;
  try {
    const u = new URL(t);
    return u.protocol === 'http:' || u.protocol === 'https:';
  } catch (_) {
    return false;
  }
}

/**
 * Structured URL parse for pretty display.
 * Product contract (do not regress either side):
 *  - openHref / canonical: full single-line href (card header strip)
 *  - display: multi-line parse — origin+path, then # query / # hash key=value
 *  - Never make display clickable; open only via explicit button + confirm
 */
export function formatUrlParts(t) {
  const u = new URL(t);
  const openHref = u.href;
  const lines = [];
  // first line is one logical URL line (host+path); query/hash expand below
  lines.push(`${u.protocol}//${u.host}${u.pathname}`);
  if (u.search && u.search.length > 1) {
    lines.push('');
    lines.push('# query');
    for (const [k, v] of u.searchParams.entries()) {
      lines.push(`${k} = ${v}`);
    }
  }
  if (u.hash && u.hash.length > 1) {
    lines.push('');
    lines.push('# hash');
    lines.push(u.hash.slice(1));
  }
  return { openHref, display: lines.join('\n'), host: u.host, path: u.pathname };
}

function looksLikeFormBody(t) {
  if (t.length < 3 || t.includes('\n') || t.includes(' ')) return false;
  if (!t.includes('=') || !t.includes('&')) return false;
  if (/^https?:\/\//i.test(t)) return false;
  const pairs = t.split('&');
  if (pairs.length < 2) return false;
  let ok = 0;
  for (const pair of pairs) {
    if (/^[A-Za-z0-9_.%+-]+=/.test(pair)) ok++;
  }
  return ok >= 2 && ok / pairs.length >= 0.7;
}

function decodeURIComponentSafe(s) {
  try {
    return decodeURIComponent(s.replace(/\+/g, ' '));
  } catch (_) {
    return s;
  }
}

function formatFormBody(t) {
  return t
    .split('&')
    .map((pair) => {
      const i = pair.indexOf('=');
      if (i < 0) return decodeURIComponentSafe(pair);
      return `${decodeURIComponentSafe(pair.slice(0, i))} = ${decodeURIComponentSafe(pair.slice(i + 1))}`;
    })
    .join('\n');
}

function looksLikeNdjson(t) {
  if (!t.includes('\n')) return false;
  const lines = t.split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
  if (lines.length < 2 || lines.length > 5000) return false;
  let n = 0;
  for (const line of lines.slice(0, 40)) {
    if (!(line[0] === '{' || line[0] === '[')) return false;
    const r = tryParseJson(line);
    if (!r.ok || !isPlainObjectOrArray(r.value)) return false;
    n++;
  }
  return n >= 2;
}

function formatNdjson(t, beautifyJson) {
  return t
    .split(/\r?\n/)
    .map((line) => {
      const s = line.trim();
      if (!s) return '';
      const r = tryParseJson(s);
      return r.ok ? beautifyJson(JSON.stringify(r.value)) : line;
    })
    .join('\n\n');
}

function looksLikeXml(t) {
  const s = t.trim();
  if (s.length < 8 || s[0] !== '<') return false;
  if (/^<!DOCTYPE\s+html/i.test(s) || /^<html[\s>]/i.test(s)) return 'html';
  if (/<\/[A-Za-z][\w:.-]*>/.test(s) || /\/>/.test(s) || /^<\?xml/i.test(s)) return 'xml';
  if (/^<[A-Za-z][\w:.-]*(\s[^>]*)?>/.test(s) && s.includes('</')) return 'xml';
  return false;
}

function prettyXmlFallback(xml) {
  const s = String(xml).trim().replace(/>\s*</g, '>\n<');
  const lines = s.split('\n');
  let ind = 0;
  const out = [];
  for (let line of lines) {
    line = line.trim();
    if (!line) continue;
    if (/^<\//.test(line)) ind = Math.max(0, ind - 1);
    out.push(`${'  '.repeat(ind)}${line}`);
    if (/^<\?/.test(line) || /^<!/.test(line) || /\/>$/.test(line) || /^<\//.test(line)) {
      /* keep */
    } else if (/^<[^>]+>.*<\/[^>]+>$/.test(line)) {
      /* same line */
    } else if (/^</.test(line) && !/^<\//.test(line)) {
      ind++;
    }
  }
  return out.join('\n');
}

function looksLikeCsv(t) {
  const lines = t.split(/\r?\n/).filter((l) => l.length);
  if (lines.length < 2 || lines.length > 2000) return false;
  const counts = lines.slice(0, 30).map((l) => (l.match(/,/g) || []).length);
  const c0 = counts[0];
  if (c0 < 1) return false;
  const same = counts.filter((c) => c === c0).length;
  if (same < Math.min(lines.length, 30) * 0.8) return false;
  if (/[{};]|function |const |SELECT /.test(t.slice(0, 200))) return false;
  return true;
}

function looksLikeEnv(t) {
  const lines = t.split(/\r?\n/).map((l) => l.trim()).filter((l) => l && !l.startsWith('#'));
  if (lines.length < 2) return false;
  let ok = 0;
  for (const line of lines.slice(0, 40)) {
    if (/^[A-Za-z_][A-Za-z0-9_]*\s*=\s*/.test(line)) ok++;
    else if (/^export\s+[A-Za-z_][A-Za-z0-9_]*\s*=/.test(line)) ok++;
  }
  return ok >= 2 && ok / Math.min(lines.length, 40) >= 0.7;
}

function looksLikeStack(t) {
  if (t.length < 40) return false;
  return (
    /^\s*at\s+\S+/m.test(t) ||
    /^\s*File ".+", line \d+/m.test(t) ||
    /\bTraceback \(most recent call last\):/.test(t) ||
    /^\s*#\d+\s+0x[0-9a-f]+/im.test(t) ||
    /\bException in thread\b/.test(t) ||
    /^\s*Caused by:/.test(t)
  );
}

const SQL_VERB = /^(SELECT|WITH|INSERT|UPDATE|DELETE|CREATE|ALTER|DROP|EXPLAIN|PRAGMA|REPLACE|MERGE|GRANT|REVOKE|TRUNCATE)\b/i;
const SQL_OBJECT = /\b(TABLE|INDEX|VIEW|SCHEMA|DATABASE|INTO|FROM|COLUMN|CONSTRAINT|TEMP|TEMPORARY|UNIQUE|OR\s+REPLACE)\b/i;
const SQL_CONT = /^(FROM|WHERE|JOIN|LEFT|RIGHT|INNER|OUTER|GROUP|ORDER|HAVING|LIMIT|OFFSET|VALUES|SET|INTO|UNION|ON|AND|OR|RETURNING)\b/i;
const SQL_COL = /^[A-Za-z_][\w]*\s+(TEXT|INTEGER|BIGINT|INT|VARCHAR|BOOLEAN|TIMESTAMP|DATETIME|NUMERIC|REAL|BLOB|PRIMARY|UNIQUE|NOT\s+NULL|REFERENCES)\b/i;

function stripSqlLeadingComments(t) {
  let s = String(t || '').trim();
  for (let n = 0; n < 12; n++) {
    if (s.startsWith('--')) {
      const nl = s.indexOf('\n');
      if (nl < 0) return '';
      s = s.slice(nl + 1).trim();
      continue;
    }
    if (s.startsWith('/*')) {
      const end = s.indexOf('*/');
      if (end < 0) return '';
      s = s.slice(end + 2).trim();
      continue;
    }
    break;
  }
  return s;
}

function markdownScore(t) {
  let score = 0;
  for (const line of String(t || '').split(/\n/).slice(0, 40)) {
    if (/^#{1,6}\s+\S/.test(line)) score += 2;
    if (/^\s*[-*+]\s+\S/.test(line)) score += 1;
    if (/^\s*\d+\.\s+\S/.test(line)) score += 1;
    if (/^\s*```/.test(line)) score += 2;
    if (/\[[^\]]+\]\([^)]+\)/.test(line)) score += 1;
    if (/^\s*>\s+\S/.test(line)) score += 1;
  }
  return score;
}

function cjkRatio(t) {
  const s = String(t || '');
  if (!s.length) return 0;
  let n = 0;
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    if (c >= 0x3400 && c <= 0x9fff) n++;
  }
  return n / s.length;
}

/** Whole document is SQL, not "a CREATE/SELECT line exists somewhere". */
function looksLikeSql(t) {
  if (t.length < 24) return false;
  if (markdownScore(t) >= 3) return false;
  const body = stripSqlLeadingComments(t);
  if (!body || !SQL_VERB.test(body)) return false;
  if (/^(CREATE|ALTER|DROP|GRANT|REVOKE|TRUNCATE)\b/i.test(body) && !SQL_OBJECT.test(body.slice(0, 240))) {
    return false;
  }
  const lines = t.split(/\n/);
  let sqlish = 0;
  let nonempty = 0;
  for (const line of lines.slice(0, 80)) {
    const s = line.trim();
    if (!s || s.startsWith('--')) continue;
    nonempty++;
    if (SQL_VERB.test(s) || SQL_CONT.test(s) || SQL_COL.test(s)) sqlish++;
  }
  const ratio = nonempty ? sqlish / nonempty : 0;
  if (nonempty <= 12) return true;
  if (cjkRatio(t) > 0.2 && ratio < 0.5) return false;
  return ratio >= 0.35;
}

function formatSqlFallback(sql) {
  // Quote + paren aware: never break inside strings or function call args.
  const s = String(sql || '').replace(/\r\n/g, '\n').replace(/\s+/g, ' ').trim();
  const keywords = [
    'LEFT JOIN', 'RIGHT JOIN', 'INNER JOIN', 'OUTER JOIN', 'CROSS JOIN', 'UNION ALL',
    'GROUP BY', 'ORDER BY', 'INSERT INTO', 'DELETE FROM', 'CREATE TABLE',
    'SELECT', 'FROM', 'WHERE', 'HAVING', 'LIMIT', 'OFFSET', 'UNION', 'VALUES', 'SET',
    'JOIN', 'AND', 'OR', 'WITH', 'UPDATE',
  ];
  let out = '';
  let i = 0;
  let inS = false;
  let inD = false;
  let depth = 0;
  while (i < s.length) {
    const ch = s[i];
    if (ch === "'" && !inD) { inS = !inS; out += ch; i++; continue; }
    if (ch === '"' && !inS) { inD = !inD; out += ch; i++; continue; }
    if (!inS && !inD) {
      if (ch === '(') { depth++; out += ch; i++; continue; }
      if (ch === ')') { depth = Math.max(0, depth - 1); out += ch; i++; continue; }
      if (ch === ' ' || ch === '\t') {
        let matched = null;
        const upper = s.slice(i).toUpperCase();
        for (const kw of keywords) {
          const pad = ' ' + kw;
          if (upper.startsWith(pad)) {
            const after = s[i + pad.length] || ' ';
            if (/[\s,(]/.test(after) || i + pad.length >= s.length) {
              matched = kw;
              break;
            }
          }
        }
        if (matched) {
          out += '\n' + matched;
          i += 1 + matched.length;
          continue;
        }
      }
      if (ch === ',' && depth === 0) {
        out += ',\n  ';
        i++;
        while (i < s.length && s[i] === ' ') i++;
        continue;
      }
    }
    out += ch;
    i++;
  }
  const lines = out.split('\n');
  const fixed = [];
  let inSelect = false;
  for (let line of lines) {
    const t = line.trim();
    const up = t.toUpperCase();
    if (up === 'SELECT' || up.startsWith('SELECT ')) {
      inSelect = true;
      if (t.toUpperCase().startsWith('SELECT ')) fixed.push('SELECT\n  ' + t.slice(7));
      else fixed.push(t);
      continue;
    }
    if (/^(FROM|WHERE|GROUP BY|ORDER BY|HAVING|LIMIT|OFFSET|UNION|JOIN|LEFT|RIGHT|INNER|OUTER|SET|VALUES)\b/i.test(up)) {
      inSelect = false;
      fixed.push(t);
      continue;
    }
    if (inSelect && !t.startsWith('  ')) fixed.push('  ' + t);
    else fixed.push(t);
  }
  return fixed.join('\n').replace(/\n{3,}/g, '\n\n').trim();
}

function looksLikeMarkdown(t) {
  if (t.length < 8 || t.length > TEXT_PRETTY_MAX) return false;
  if (t.split(/\n/).length < 2) return false;
  return markdownScore(t) >= 3;
}

function looksLikeYaml(t) {
  if (t.length < 8) return false;
  const tr = t.trim();
  if (tr[0] === '{' || tr[0] === '[') return false;
  const lines = t.split(/\n/).filter((l) => l.trim() && !l.trim().startsWith('#'));
  if (lines.length < 2) return false;
  let ok = 0;
  for (const line of lines.slice(0, 40)) {
    if (/^[\w.-]+\s*:\s+\S/.test(line)) ok++;
    else if (/^[\w.-]+\s*:\s*$/.test(line)) ok++;
    else if (/^\s+-\s+\S/.test(line)) ok++;
    else if (/^\s+[\w.-]+\s*:/.test(line)) ok++;
  }
  return ok >= 3 && ok / Math.min(lines.length, 40) >= 0.65;
}

function looksLikeBase64Blob(t) {
  const s = t.trim().replace(/\s+/g, '');
  if (s.length < 32 || s.length > 20000) return false;
  if (s.length % 4 !== 0) return false;
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(s)) return false;
  try {
    const utf = b64ToUtf8(s);
    if (!utf || utf.length < 8) return false;
    let printable = 0;
    for (let i = 0; i < utf.length; i++) {
      const c = utf.charCodeAt(i);
      if (c === 9 || c === 10 || c === 13 || (c >= 32 && c < 127) || c > 127) printable++;
    }
    return printable / utf.length >= 0.85;
  } catch (_) {
    return false;
  }
}

export function detectStructuredText(text) {
  const raw = String(text ?? '');
  const t = raw.trim();
  if (t.length < 2 || t.length > TEXT_PRETTY_MAX) return { kind: 'plain' };

  if (looksLikeJwt(t)) return { kind: 'jwt' };
  if (t[0] === '{' || t[0] === '[') {
    const r = tryParseJson(t);
    if (r.ok && isPlainObjectOrArray(r.value)) return { kind: 'json' };
  }
  if (looksLikeNdjson(t)) return { kind: 'ndjson' };
  if (looksLikeUrl(t)) return { kind: 'url' };
  if (looksLikeFormBody(t)) return { kind: 'form' };
  const xmlKind = looksLikeXml(t);
  if (xmlKind === 'html') return { kind: 'html' };
  if (xmlKind === 'xml') return { kind: 'xml' };
  if (looksLikeStack(t)) return { kind: 'stack' };
  if (looksLikeMarkdown(t)) return { kind: 'markdown' };
  if (looksLikeSql(t)) return { kind: 'sql' };
  if (looksLikeEnv(t)) return { kind: 'env' };
  if (looksLikeCsv(t)) return { kind: 'csv' };
  if (looksLikeYaml(t)) return { kind: 'yaml' };
  if (looksLikeBase64Blob(t)) return { kind: 'base64' };
  return { kind: 'plain' };
}

/**
 * @param {string} text
 * @param {{ beautifiers?: object, enabled?: boolean }} [options]
 */
export function formatTextForDisplay(text, options = {}) {
  const raw = String(text ?? '');
  if (options.enabled === false) {
    return { kind: 'plain', display: raw, pretty: false, label: '', icon: '', lang: 'plaintext', openHref: '', engine: '' };
  }

  const b = resolveBeautifiers(options.beautifiers);
  const beautifyJson = (jsonStr) => {
    try {
      const obj = typeof jsonStr === 'string' ? JSON.parse(jsonStr) : jsonStr;
      const compact = JSON.stringify(obj);
      if (b.jsBeautify) {
        try {
          return b.jsBeautify(compact, {
            indent_size: 2,
            space_in_empty_paren: true,
            keep_array_indentation: false,
          });
        } catch (_) {}
      }
      return JSON.stringify(obj, null, 2);
    } catch (_) {
      return String(jsonStr);
    }
  };
  const beautifyHtmlXml = (s, kind) => {
    if (b.htmlBeautify) {
      try {
        return b.htmlBeautify(s, {
          indent_size: 2,
          preserve_newlines: true,
          max_preserve_newlines: 2,
          wrap_line_length: 0,
          extra_liners: [],
          content_unformatted: ['pre', 'code', 'textarea'],
          // xml-ish
          indent_inner_html: true,
          end_with_newline: false,
        });
      } catch (_) {}
    }
    return prettyXmlFallback(s);
  };
  const beautifySql = (s) => {
    if (b.sqlFormat) {
      try {
        return b.sqlFormat(s, {
          language: 'sql',
          tabWidth: 2,
          keywordCase: 'upper',
          linesBetweenQueries: 1,
        });
      } catch (_) {}
    }
    return formatSqlFallback(s);
  };

  const det = detectStructuredText(raw);
  const meta = kindMeta(det.kind);
  const chip = (extra) => (extra ? `${meta.label} · ${extra}` : meta.label);
  const out = (fields) => ({
    kind: det.kind,
    display: raw,
    html: '',
    pretty: false,
    label: '',
    icon: meta.icon,
    lang: meta.lang,
    openHref: '',
    engine: '',
    ...fields,
  });

  try {
    switch (det.kind) {
      case 'json': {
        const pretty = beautifyJson(raw.trim());
        return out({
          display: pretty,
          pretty: true,
          label: chip(b.jsBeautify ? 'Beautify' : '已排版'),
          engine: b.jsBeautify ? 'js-beautify' : 'json',
        });
      }
      case 'ndjson':
        return out({
          display: formatNdjson(raw, beautifyJson),
          pretty: true,
          label: chip(b.jsBeautify ? 'Beautify' : '已排版'),
          engine: b.jsBeautify ? 'js-beautify' : 'json',
        });
      case 'jwt':
        return out({
          display: formatJwt(raw.trim(), beautifyJson),
          pretty: true,
          label: chip('已解码'),
          engine: b.jsBeautify ? 'js-beautify' : 'json',
        });
      case 'url': {
        const parts = formatUrlParts(raw.trim());
        return out({
          display: parts.display,
          pretty: true,
          label: chip('参数'),
          openHref: parts.openHref,
          engine: 'url',
        });
      }
      case 'form':
        return out({ display: formatFormBody(raw.trim()), pretty: true, label: chip('已展开'), engine: 'form' });
      case 'xml':
        return out({
          display: beautifyHtmlXml(raw, 'xml'),
          pretty: true,
          label: chip(b.htmlBeautify ? 'Beautify' : '已缩进'),
          engine: b.htmlBeautify ? 'js-beautify' : 'xml',
        });
      case 'html':
        return out({
          display: beautifyHtmlXml(raw, 'html'),
          pretty: true,
          label: chip(b.htmlBeautify ? 'Beautify' : '已缩进'),
          engine: b.htmlBeautify ? 'js-beautify' : 'html',
        });
      case 'csv':
        return out({
          display: raw.replace(/\r\n/g, '\n').replace(/\r/g, '\n'),
          pretty: true,
          label: chip('表格'),
          engine: 'csv',
        });
      case 'env':
        return out({
          display: raw.replace(/\r\n/g, '\n').trim() + '\n',
          pretty: true,
          label: chip('配置'),
          engine: 'env',
        });
      case 'stack':
        return out({
          display: raw.replace(/\r\n/g, '\n'),
          pretty: true,
          label: chip('堆栈'),
          engine: 'stack',
        });
      case 'sql':
        return out({
          display: beautifySql(raw),
          pretty: true,
          label: chip(b.sqlFormat ? 'sql-formatter' : '已断行'),
          engine: b.sqlFormat ? 'sql-formatter' : 'sql',
        });
      case 'markdown': {
        const src = raw.replace(/\r\n/g, '\n');
        const md = renderMarkdownToHtml(src, { marked: b.marked, purify: b.purify });
        if (md.ok && md.html) {
          return out({
            display: src,
            html: md.html,
            pretty: true,
            label: chip('预览'),
            engine: md.engine,
          });
        }
        // Library missing → plain source (no DIY markdown grammar)
        return out({
          display: src,
          html: '',
          pretty: true,
          label: chip('原文'),
          engine: md.engine || 'md',
        });
      }
      case 'yaml':
        return out({
          display: raw.replace(/\r\n/g, '\n'),
          pretty: true,
          label: chip('配置'),
          engine: 'yaml',
        });
      case 'base64': {
        const utf = b64ToUtf8(raw.trim().replace(/\s+/g, ''));
        const inner = detectStructuredText(utf);
        let display = '// decoded UTF-8\n' + utf;
        if (inner.kind === 'json') {
          try {
            display = '// decoded UTF-8 → JSON\n' + beautifyJson(utf.trim());
          } catch (_) {}
        }
        return out({ display, pretty: true, label: chip('已解码'), engine: 'base64' });
      }
      default:
        return out({ kind: 'plain', icon: '', lang: 'plaintext' });
    }
  } catch (_) {
    return out({ kind: 'plain', icon: '', lang: 'plaintext' });
  }
}

export function structuredKindIsCodey(kind) {
  return ['json', 'ndjson', 'jwt', 'xml', 'html', 'sql', 'yaml', 'base64'].includes(kind);
}
