/**
 * ClipVault §8 adult-risk URL gate.
 *
 * Scan host labels + path segments only. Never query/hash: OAuth/JWT fragments
 * (e.g. Medium `#id_token=…CSkbxxx…`) are dense base64 and false-positive on
 * short needles like `xxx` / `jav`.
 *
 * Publishing hosts (medium.com, github.com, …) are allowlisted: they may host
 * occasional NSFW, but a clipboard preview must not treat a random tech post
 * as porn. Non-risky URLs still go through the generic confirm on open.
 */

export const SAFE_HOST_SUFFIXES = [
  'medium.com',
  'github.com',
  'githubusercontent.com',
  'gitlab.com',
  'google.com',
  'googleapis.com',
  'googleusercontent.com',
  'gstatic.com',
  'youtube.com',
  'youtu.be',
  'wikipedia.org',
  'wikimedia.org',
  'apple.com',
  'icloud.com',
  'mzstatic.com',
  'amazon.com',
  'amazonaws.com',
  'aws.amazon.com',
  'stackoverflow.com',
  'stackexchange.com',
  'microsoft.com',
  'office.com',
  'cloudflare.com',
  'twitter.com',
  'x.com',
  'linkedin.com',
  'notion.so',
  'substack.com',
  'dev.to',
  'arxiv.org',
  'npmjs.com',
  'pypi.org',
  'rust-lang.org',
];

/** Exact DNS labels (pornhub.com → "pornhub"). Not substrings of other labels. */
export const ADULT_HOST_LABELS = new Set([
  'porn', 'xxx', 'xvideos', 'pornhub', 'xhamster', 'xnxx', 'onlyfans', 'redtube',
  'spankbang', 'brazzers', 'youporn', 'chaturbate', 'stripchat',
  'jav', 'javbus', 'javlibrary', 'missav', 'avmoo', 'avgle', 'javdb', 'javtrailers',
  'nhentai', 'hanime', 'hentai', 'rule34', 'e-hentai', 'exhentai',
  'dmm', 'fanza', 'dlsite', 'fantia',
  'nsfw', 'r18', 'adult', 'erome', 'thothub', 'hqporner',
  'sex', 'nude', 'camgirl', 'camwhore',
]);

/** Full path segments only (`/r18/`, not `…r18…` inside a slug). */
export const ADULT_PATH_SEGMENTS = new Set([
  'porn', 'xxx', 'nsfw', 'r18', '18+', 'hentai', 'nhentai', 'onlyfans',
  'adult', 'nude',
]);

export function hostIsAllowlisted(hostname) {
  const h = String(hostname || '').toLowerCase().replace(/^www\./, '');
  if (!h) return false;
  return SAFE_HOST_SUFFIXES.some((s) => h === s || h.endsWith('.' + s));
}

export function isAdultRiskUrl(href) {
  try {
    const u = new URL(String(href || '').trim());
    if (u.protocol !== 'http:' && u.protocol !== 'https:') return false;
    const host = u.hostname.toLowerCase();
    if (hostIsAllowlisted(host)) return false;
    const labels = host.split('.').filter(Boolean);
    if (labels.some((l) => ADULT_HOST_LABELS.has(l))) return true;
    const segs = u.pathname.toLowerCase().split('/').filter(Boolean);
    if (segs.some((s) => ADULT_PATH_SEGMENTS.has(s))) return true;
    return false;
  } catch (_) {
    return false;
  }
}
