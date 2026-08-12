/**
 * ClipVault — display-only structured text formatting.
 * Philosophy: clipboard is for humans; pretty render raises efficiency.
 * Never mutate stored capture; copy must use raw payload.
 */

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

function formatJwt(t) {
  const [h, p, sig] = t.split('.');
  const header = JSON.stringify(JSON.parse(b64ToUtf8(h)), null, 2);
  let payload;
  try {
    payload = JSON.stringify(JSON.parse(b64ToUtf8(p)), null, 2);
  } catch (_) {
    payload = b64ToUtf8(p);
  }
  return [
    '// header',
    header,
    '',
    '// payload',
    payload,
    '',
    '// signature',
    sig.slice(0, 24) + (sig.length > 24 ? '…' : ''),
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

function formatUrl(t) {
  const u = new URL(t);
  const lines = [`${u.protocol}//${u.host}${u.pathname}`];
  if (u.search && u.search.length > 1) {
    lines.push('', '# query');
    const params = [...u.searchParams.entries()];
    if (!params.length) lines.push(u.search);
    else for (const [k, v] of params) lines.push(`${k}=${v}`);
  }
  if (u.hash && u.hash.length > 1) {
    lines.push('', '# hash', u.hash.slice(1));
  }
  return lines.join('\n');
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
      return `${decodeURIComponentSafe(pair.slice(0, i))}=${decodeURIComponentSafe(pair.slice(i + 1))}`;
    })
    .join('\n');
}

function looksLikeNdjson(t) {
  if (!t.includes('\n')) return false;
  const lines = t
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter(Boolean);
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

function formatNdjson(t) {
  return t
    .split(/\r?\n/)
    .map((line) => {
      const s = line.trim();
      if (!s) return '';
      const r = tryParseJson(s);
      return r.ok ? JSON.stringify(r.value, null, 2) : line;
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

function prettyXml(xml) {
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
      /* no + */
    } else if (/^<[^>]+>.*<\/[^>]+>$/.test(line)) {
      /* same line open close */
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

function formatCsv(t) {
  return t.replace(/\r\n/g, '\n').replace(/\r/g, '\n').split('\n').filter((l) => l.length).join('\n');
}

function looksLikeEnv(t) {
  const lines = t
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter((l) => l && !l.startsWith('#'));
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

function looksLikeSql(t) {
  return (
    /^\s*(SELECT|WITH|INSERT|UPDATE|DELETE|CREATE|ALTER|DROP|EXPLAIN|PRAGMA|REPLACE|MERGE)\b/im.test(t) &&
    t.length >= 12
  );
}

function formatSql(t) {
  return t
    .replace(/\s+/g, ' ')
    .trim()
    .replace(
      /\s+(SELECT|FROM|WHERE|AND|OR|JOIN|LEFT JOIN|RIGHT JOIN|INNER JOIN|OUTER JOIN|GROUP BY|ORDER BY|LIMIT|OFFSET|HAVING|UNION|VALUES|SET)\b/gi,
      '\n$1'
    )
    .replace(/\s*,\s*/g, ',\n  ');
}

function looksLikeMarkdown(t) {
  if (t.length < 8 || t.length > TEXT_PRETTY_MAX) return false;
  const lines = t.split(/\n/);
  if (lines.length < 2) return false;
  let score = 0;
  for (const line of lines.slice(0, 40)) {
    if (/^#{1,6}\s+\S/.test(line)) score += 2;
    if (/^\s*[-*+]\s+\S/.test(line)) score += 1;
    if (/^\s*\d+\.\s+\S/.test(line)) score += 1;
    if (/^\s*```/.test(line)) score += 2;
    if (/\[[^\]]+\]\([^)]+\)/.test(line)) score += 1;
    if (/^\s*>\s+\S/.test(line)) score += 1;
  }
  return score >= 3;
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

function formatBase64(t) {
  const s = t.trim().replace(/\s+/g, '');
  const utf = b64ToUtf8(s);
  const inner = detectStructuredText(utf);
  if (inner.kind === 'json') {
    try {
      return '// decoded UTF-8 → JSON\n' + JSON.stringify(JSON.parse(utf.trim()), null, 2);
    } catch (_) {}
  }
  return '// decoded UTF-8\n' + utf;
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
  if (looksLikeSql(t) && t.length >= 40) return { kind: 'sql' };
  if (looksLikeEnv(t)) return { kind: 'env' };
  if (looksLikeCsv(t)) return { kind: 'csv' };
  if (looksLikeMarkdown(t)) return { kind: 'markdown' };
  if (looksLikeYaml(t)) return { kind: 'yaml' };
  if (looksLikeBase64Blob(t)) return { kind: 'base64' };

  return { kind: 'plain' };
}

export function formatTextForDisplay(text) {
  const raw = String(text ?? '');
  const det = detectStructuredText(raw);
  const meta = kindMeta(det.kind);
  const chip = (extra) => (extra ? `${meta.label} · ${extra}` : meta.label);

  try {
    switch (det.kind) {
      case 'json': {
        const pretty = JSON.stringify(JSON.parse(raw.trim()), null, 2);
        return { kind: 'json', display: pretty, pretty: true, label: chip('已排版'), icon: meta.icon, lang: 'json' };
      }
      case 'ndjson':
        return { kind: 'ndjson', display: formatNdjson(raw), pretty: true, label: chip('已排版'), icon: meta.icon, lang: 'json' };
      case 'jwt':
        return { kind: 'jwt', display: formatJwt(raw.trim()), pretty: true, label: chip('已解码'), icon: meta.icon, lang: 'json' };
      case 'url':
        return { kind: 'url', display: formatUrl(raw.trim()), pretty: true, label: chip('参数展开'), icon: meta.icon, lang: 'plaintext' };
      case 'form':
        return { kind: 'form', display: formatFormBody(raw.trim()), pretty: true, label: chip('已展开'), icon: meta.icon, lang: 'plaintext' };
      case 'xml':
        return { kind: 'xml', display: prettyXml(raw), pretty: true, label: chip('已缩进'), icon: meta.icon, lang: 'xml' };
      case 'html':
        return { kind: 'html', display: prettyXml(raw), pretty: true, label: chip('已缩进'), icon: meta.icon, lang: 'xml' };
      case 'csv':
        return { kind: 'csv', display: formatCsv(raw), pretty: true, label: chip('表格文本'), icon: meta.icon, lang: 'plaintext' };
      case 'env':
        return { kind: 'env', display: raw.replace(/\r\n/g, '\n').trim() + '\n', pretty: true, label: chip('配置'), icon: meta.icon, lang: 'plaintext' };
      case 'stack':
        return { kind: 'stack', display: raw.replace(/\r\n/g, '\n'), pretty: true, label: chip('堆栈'), icon: meta.icon, lang: 'plaintext' };
      case 'sql':
        return { kind: 'sql', display: formatSql(raw), pretty: true, label: chip('已断行'), icon: meta.icon, lang: 'sql' };
      case 'markdown':
        return { kind: 'markdown', display: raw.replace(/\r\n/g, '\n'), pretty: true, label: chip('文档'), icon: meta.icon, lang: 'markdown' };
      case 'yaml':
        return { kind: 'yaml', display: raw.replace(/\r\n/g, '\n'), pretty: true, label: chip('配置'), icon: meta.icon, lang: 'yaml' };
      case 'base64':
        return { kind: 'base64', display: formatBase64(raw), pretty: true, label: chip('已解码'), icon: meta.icon, lang: 'plaintext' };
      default:
        return { kind: 'plain', display: raw, pretty: false, label: '', icon: '', lang: 'plaintext' };
    }
  } catch (_) {
    return { kind: 'plain', display: raw, pretty: false, label: '', icon: '', lang: 'plaintext' };
  }
}

export function structuredKindIsCodey(kind) {
  return ['json', 'ndjson', 'jwt', 'xml', 'html', 'sql', 'yaml', 'base64'].includes(kind);
}
