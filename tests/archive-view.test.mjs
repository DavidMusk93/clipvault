import assert from 'node:assert/strict';
import { readFileSync, existsSync, statSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { src, root } from './helpers/src.mjs';

const swift = src('WebServer.swift');
const archiveSwift = src('WebArchiveService.swift');
const inlinerSwift = src('ArchiveImageInliner.swift');
const weixinSwift = src('WeixinArticleHTML.swift');
const viewCss = readFileSync(join(root, 'web/assets/archive-view.css'), 'utf8');
const readerJs = readFileSync(join(root, 'web/assets/archive-reader.js'), 'utf8');

test('weixin articles are fetched direct, not through the SOCKS web view', () => {
  assert.match(archiveSwift, /WeixinArticleHTML\.isArticleURL/);
  assert.match(archiveSwift, /WeixinArticleHTML\.extract/);
  assert.match(archiveSwift, /engine: "weixin-html"/);
  assert.match(archiveSwift, /prefersDirectHost/);
  assert.match(archiveSwift, /timeoutFired/);
  assert.match(inlinerSwift, /prefersDirectHost\(url\.host\)/);
  assert.match(inlinerSwift, /WeixinArticleHTML\.attributeRegex\("src"\)/);
  assert.doesNotMatch(inlinerSwift, /\\bsrc\\s\*=/);
  assert.match(weixinSwift, /attributeRegex/);
});

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
  assert.match(swift, /archive-view\.css\?v=20261103a/);
  assert.match(swift, /highlight\.min\.js\?v=11\.7\.0/);
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
  assert.match(readerJs, /function guessLang/);
  assert.match(readerJs, /hljs\.highlight\(/);
  assert.doesNotMatch(readerJs, /highlightAuto/);
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

test('x.com article dump is rebuilt from Draft.js, not Readability <p> soup', () => {
  const xhtml = src('XArticleHTML.swift');
  const svc = src('WebArchiveService.swift');
  assert.match(xhtml, /x-article\+draftjs/);
  assert.match(xhtml, /x-status/);
  assert.match(xhtml, /renderStatus/);
  assert.match(xhtml, /api\.vxtwitter\.com/);
  assert.match(xhtml, /header-two/);
  assert.match(xhtml, /MARKDOWN/);
  assert.match(xhtml, /renderFence/);
  assert.match(xhtml, /headingLike/);
  assert.match(xhtml, /isUsableArticleHTML/);
  assert.match(xhtml, /media_entities/);
  assert.match(xhtml, /mediaItems/);
  assert.match(xhtml, /mediaIndex/);
  assert.match(xhtml, /cv-x-dropped/);
  assert.match(xhtml, /DIVIDER/);
  assert.match(xhtml, /<hr>/);
  // Quoted tweets: TWEET atomic -> cv-x-tweet card, never dropped.
  assert.match(xhtml, /type == "TWEET"/);
  assert.match(xhtml, /tweetIndex/);
  assert.match(xhtml, /cv-x-tweet/);
  assert.match(viewCss, /figure\.cv-x-tweet/);
  assert.match(xhtml, /target=\\"_blank\\"/);
  assert.match(xhtml, /safeHTTPURL/);
  assert.match(xhtml, /headingShift/);
  assert.match(xhtml, /mediaExpected/);
  assert.match(xhtml, /struct Coverage/);
  assert.match(svc, /coverageJSON/);
  assert.match(svc, /XArticleHTML\.archive/);
  assert.match(svc, /XArticleHTML\.enrich/);
  assert.match(svc, /XArticleHTML\.isUsableArticleHTML/);
  assert.doesNotMatch(svc, /contains\("<pre"\) \|\| html\.lowercased\(\)\.contains\("<h2"\)/);
});

test('archive extract keeps diagram lists Readability would drop', () => {
  const svc = src('WebArchiveService.swift');
  const rdb = src('Readability.js');
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

test('archive view flattens Medium picture/srcset so CSP self images paint', () => {
  const inliner = src('ArchiveImageInliner.swift');
  assert.match(inliner, /func flattenPictures/);
  assert.match(inliner, /<source\\b/);
  assert.match(inliner, /srcset/);
  assert.match(swift, /flattenPictures\(self\.promoteLazyImages/);
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
  const auth = src('ClipVaultAuth.swift');
  assert.match(swift, /publicRequestAuthorized/);
  assert.match(swift, /isLoopbackRequest/);
  assert.match(swift, /ClipVaultAuth\.shared\.isSessionAuthorized/);
  assert.match(swift, /pathOnly == "\/login"/);
  assert.match(swift, /login\/setup/);
  assert.match(swift, /pathOnly.hasPrefix\("\/s\/"\)/);
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
  const inliner = src('ArchiveImageInliner.swift');
  assert.match(inliner, /\/api\/archive\/asset\?sha=/);
  assert.match(swift, /sendArchiveAsset/);
  assert.match(swift, /img-src 'self' data: blob:/);
  assert.doesNotMatch(swift, /img-src \*/);
});

test('archive sync ships the document closure, not just the HTML sha', () => {
  const closure = src('ArchiveBlobClosure.swift');
  const sync = src('CloudDocsSyncService.swift');
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

test('wall image 404 hydrates the same CAS replicas as archive', () => {
  const swift = src('WebServer.swift');
  const db = src('DatabaseManager.swift');
  const backup = src('CloudDocsBackupService.swift');
  assert.match(swift, /func loadClipImageBytes/);
  assert.match(swift, /hydrateBlob\(raw\)/);
  assert.match(db, /func materializeBlobsIfSymlinked/);
  assert.match(db, /try\? Data\(contentsOf: url\)/);
  assert.match(backup, /resolvingSymlinksInPath/);
  assert.match(backup, /local CAS unlistable/);
  assert.match(backup, /throws -> CASSyncResult/);
});

test('stripped language class still highlights sql and rust, not prose', async (t) => {
  const { JSDOM } = await import('jsdom');
  const hljsSrc = readFileSync(join(root, 'web/assets/highlight.min.js'), 'utf8');
  assert.match(hljsSrc, /BSD-3-Clause/);
  assert.ok(hljsSrc.length > 80_000);
  const sql = 'select i as k, md5(i::varchar) as v\\nfrom generate_series(1, {rows}) t(i)';
  const rust = 'let mut parquet_options = ParquetOptions::default();\\nparquet_options.dictionary_enabled = false;\\ndf.write_parquet(\\n    \\"t.parquet\\",\\n    Some(table_options)\\n).await?;';
  const plan = '# pushdown_filters disabled\\nFilterExec k=&lt;VAL&gt; (output_rows=1)\\n  DataSourceExec predicate=k=&lt;VAL&gt;';
  const prose = 'The values come from the table where the key matches a point lookup.';
  const dom = new JSDOM(
    `<!DOCTYPE html><html data-cv-enhance><body><main class="cv-article">
      <pre><code>${sql}</code></pre>
      <pre><code>${rust}</code></pre>
      <pre><code>${plan}</code></pre>
      <pre><code>${prose}</code></pre>
      <pre><code class="language-go">package main\\nfunc main() {\\n  x := 1\\n}</code></pre>
    </main></body></html>`,
    { runScripts: 'outside-only', url: 'http://127.0.0.1/api/archive/view' }
  );
  t.after(() => dom.window.close());
  dom.window.eval(hljsSrc);
  dom.window.eval(readerJs);
  // jsdom stays readyState=loading; a deferred script in a browser runs at interactive.
  if (dom.window.document.readyState === 'loading') {
    dom.window.document.dispatchEvent(new dom.window.Event('DOMContentLoaded'));
  }
  const plates = [...dom.window.document.querySelectorAll('.cv-code')];
  assert.equal(plates.length, 5);
  const label = (plate) => plate.querySelector('.cv-code-lang').textContent;
  assert.equal(label(plates[0]), 'SQL');
  assert.match(plates[0].innerHTML, /hljs-keyword/);
  assert.match(plates[0].innerHTML, />select</);
  assert.equal(label(plates[1]), 'Rust');
  assert.match(plates[1].innerHTML, /hljs-keyword/);
  assert.match(plates[1].innerHTML, />let</);
  assert.equal(label(plates[2]), '代码');
  assert.equal(plates[2].querySelector('.hljs-keyword, .cv-k'), null);
  assert.equal(label(plates[3]), '代码');
  assert.equal(plates[3].querySelector('.hljs-keyword, .cv-k'), null);
  assert.equal(label(plates[4]), 'Go');
  assert.match(plates[4].innerHTML, /hljs-keyword/);
});

test('archive HTML contract: asset sha is 64 hex and extractable', () => {
  const sha = '50e702b10be74b6200de24bce7a5ab906ef6a137a2beefbc3e9966e109eb42da';
  const html = `<img src="/api/archive/asset?sha=${sha}" alt="x">`;
  const refs = [...html.matchAll(/\/api\/archive\/asset\?sha=([0-9a-f]{64})/gi)].map((m) => m[1]);
  assert.deepEqual(refs, [sha]);
});
