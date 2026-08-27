import assert from 'node:assert/strict';
import { readFileSync, existsSync, statSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const swift = readFileSync(join(root, 'ClipFlow/WebServer.swift'), 'utf8');
const viewCss = readFileSync(join(root, 'web/assets/archive-view.css'), 'utf8');
const readerJs = readFileSync(join(root, 'web/assets/archive-reader.js'), 'utf8');

test('archive view allows youtube/vimeo frames', () => {
  assert.match(swift, /frame-src https:\/\/www\.youtube-nocookie\.com https:\/\/www\.youtube\.com https:\/\/player\.vimeo\.com/);
});

test('archive view restores mermaid sequence strokes dropped by Readability', () => {
  assert.match(viewCss, /svg\[aria-roledescription="sequence"\] line\[marker-end\]/);
  assert.match(viewCss, /stroke: #1d1d1f/);
  assert.match(viewCss, /svg\[aria-roledescription="sequence"\] marker path/);
});

test('archive view drops Pico gray wash and styles code/figures as their own medium', () => {
  assert.doesNotMatch(swift, /picocss/);
  assert.match(swift, /archive-view\.css\?v=20260827f/);
  assert.match(swift, /style-src 'self' 'unsafe-inline'/);
  assert.match(viewCss, /background: #1d1d1f/);
  assert.match(viewCss, /\.cv-code/);
  assert.match(viewCss, /\.cv-figure/);
  assert.match(viewCss, /\.cv-lightbox/);
  assert.match(viewCss, /figcaption/);
  assert.match(readerJs, /function enhanceTechnicalMedia/);
  assert.match(readerJs, /function wrapCodeBlocks/);
  assert.match(readerJs, /function wrapFigures/);
  assert.match(readerJs, /function highlightSource/);
  assert.match(readerJs, /Line wrapping/);
  assert.match(readerJs, /cv-code-copy/);
  assert.match(readerJs, /function toneFigure/);
  assert.match(readerJs, /avg < 72 && trans < 0\.3/);
  assert.doesNotMatch(readerJs, /trans > 0\.4 && avg > 160/);
  assert.match(viewCss, /\.cv-figure\.is-dark/);
  assert.match(viewCss, /background: #f5f5f7/);
  assert.match(readerJs, /function wrapCallouts/);
  assert.match(readerJs, /isCalloutArticle/);
  assert.match(viewCss, /\.cv-callout/);
  assert.match(viewCss, /cv-callout-ico/);
});

test('archive view self-hosts JetBrains Mono for code, not a font CDN', () => {
  const font = join(root, 'web/assets/fonts/JetBrainsMono-Variable.woff2');
  const ofl = join(root, 'web/assets/fonts/OFL.txt');
  assert.equal(existsSync(font), true);
  assert.ok(statSync(font).size > 80_000);
  assert.match(readFileSync(font).subarray(0, 4).toString('ascii'), /wOF2/);
  assert.match(readFileSync(ofl, 'utf8'), /SIL OPEN FONT LICENSE/i);
  assert.match(viewCss, /font-family: "JetBrains Mono"/);
  assert.match(viewCss, /--cv-mono/);
  assert.match(viewCss, /\/assets\/fonts\/JetBrainsMono-Variable\.woff2/);
  assert.doesNotMatch(viewCss, /fonts\.googleapis|cdn\.jsdelivr.*jetbrains/i);
  assert.match(swift, /font-src 'self'/);
  assert.match(swift, /case "woff2": ctype = "font\/woff2"/);
});

test('archive extract keeps diagram lists Readability would drop', () => {
  const svc = readFileSync(join(root, 'ClipFlow/WebArchiveService.swift'), 'utf8');
  const rdb = readFileSync(join(root, 'ClipFlow/Resources/Readability.js'), 'utf8');
  assert.match(svc, /repairOrphanFigures/);
  assert.match(svc, /figcaption/);
  assert.match(rdb, /diagramList/);
  assert.match(rdb, /keep technical-article diagram lists/);
});

test('archive view sizes youtube iframes and adds a watch link', () => {
  assert.match(viewCss, /iframe\[src\*="youtube-nocookie"\]/);
  assert.match(viewCss, /aspect-ratio: 16 \/ 9/);
  assert.match(viewCss, /cv-video-fallback/);
  assert.match(swift, /decorateArchiveMedia/);
  assert.match(swift, /youtube\.com\/watch\?v=/);
});

test('archive view does not disable article links', () => {
  assert.doesNotMatch(swift, /a\{pointer-events:none;color:inherit;text-decoration:none;\}/);
});

test('archive view promotes weixin lazy data-src over 1px svg src', () => {
  assert.match(swift, /promoteLazyImages/);
  assert.match(swift, /data-src/);
  assert.match(swift, /data:image\/svg/);
});

test('public tunnel hosts require TOTP session, Access JWT, or optional origin token', () => {
  const auth = readFileSync(join(root, 'ClipFlow/ClipVaultAuth.swift'), 'utf8');
  assert.match(swift, /publicRequestAuthorized/);
  assert.match(swift, /isLoopbackRequest/);
  assert.match(swift, /ClipVaultAuth\.shared\.isSessionAuthorized/);
  assert.match(swift, /pathOnly == "\/login"/);
  assert.match(swift, /login\/setup/);
  assert.doesNotMatch(swift, /WWW-Authenticate/);
  assert.match(auth, /otpauth:\/\/totp/);
  assert.match(auth, /clipvault_sess/);
  assert.match(auth, /CCHmacAlgorithm\(kCCHmacAlgSHA1\)/);
});

test('compose notes use CAS image sha and a dedicated type', () => {
  assert.match(swift, /handleComposeSave/);
  assert.match(swift, /\/api\/compose/);
  assert.match(swift, /isCompose/);
});

test('public tunnel path /clipvault is stripped to local routes', () => {
  assert.match(swift, /static let publicPathPrefix = "\/clipvault"/);
  assert.match(swift, /stripPublicPrefix/);
});

test('archive images are CAS assets, not publisher CDN', () => {
  const inliner = readFileSync(join(root, 'ClipFlow/ArchiveImageInliner.swift'), 'utf8');
  assert.match(inliner, /\/api\/archive\/asset\?sha=/);
  assert.match(swift, /sendArchiveAsset/);
  assert.match(swift, /img-src 'self' data: blob:/);
  assert.doesNotMatch(swift, /img-src \*/);
});

test('archive sync ships the document closure, not just the HTML sha', () => {
  const closure = readFileSync(join(root, 'ClipFlow/ArchiveBlobClosure.swift'), 'utf8');
  const sync = readFileSync(join(root, 'ClipFlow/CloudDocsSyncService.swift'), 'utf8');
  assert.match(closure, /archive/);
  assert.match(closure, /asset/);
  assert.match(closure, /blob_keys/);
  assert.match(closure, /\[0-9a-f\]\{64\}/);
  assert.match(closure, /static func keys\(root:/);
  assert.match(sync, /enqueueArchive/);
  assert.match(sync, /repairArchiveClosures/);
  assert.match(sync, /hydrateBlob/);
  assert.doesNotMatch(sync, /blobKeys: \[htmlSHA\]/);
});

test('archive HTML contract: asset sha is 64 hex and extractable', () => {
  const sha = '50e702b10be74b6200de24bce7a5ab906ef6a137a2beefbc3e9966e109eb42da';
  const html = `<img src="/api/archive/asset?sha=${sha}" alt="x">`;
  const refs = [...html.matchAll(/\/api\/archive\/asset\?sha=([0-9a-f]{64})/gi)].map((m) => m[1]);
  assert.deepEqual(refs, [sha]);
});
