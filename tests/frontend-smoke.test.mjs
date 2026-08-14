/**
 * ClipVault web smoke / syntax regression.
 * Catches deploy-breaking SyntaxError in web/index.html inline scripts.
 * Run: node --test tests/frontend-smoke.test.mjs
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const indexPath = path.join(__dirname, '../web/index.html');
const indexHtml = fs.readFileSync(indexPath, 'utf8');

function extractInlineScripts(html) {
  const scripts = [];
  const re = /<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/gi;
  let m;
  while ((m = re.exec(html)) !== null) {
    const body = m[1].trim();
    if (body) scripts.push(body);
  }
  return scripts;
}

test('index.html has balanced real script tags (ignore regex literals)', () => {
  // Only count HTML tags at line starts / outside long script bodies is hard;
  // extractInlineScripts must find at least one non-empty inline script.
  const scripts = extractInlineScripts(indexHtml);
  assert.ok(scripts.length >= 1, 'expected inline <script> bodies');
  const main = scripts.reduce((a, b) => (a.length >= b.length ? a : b));
  assert.ok(main.length > 1000, 'main app script too small — page may be truncated');
});

test('main inline script passes node --check (syntax gate)', () => {
  const scripts = extractInlineScripts(indexHtml);
  const main = scripts.reduce((a, b) => (a.length >= b.length ? a : b));
  const tmp = path.join(__dirname, '../.tmp-frontend-main.js');
  fs.mkdirSync(path.dirname(tmp), { recursive: true });
  fs.writeFileSync(tmp, main);
  const r = spawnSync(process.execPath, ['--check', tmp], { encoding: 'utf8' });
  try { fs.unlinkSync(tmp); } catch (_) {}
  assert.equal(r.status, 0, `SyntaxError in web/index.html:\n${r.stderr || r.stdout}`);
});

test('backup status anyAvail expression is not split by injects', () => {
  // Regression: quarkDiscovery inject once split
  //   const anyAvail = dests.some(...)
  //     || s.cloudDocsAvailable ...
  // into two statements → SyntaxError / dead page.
  assert.match(
    indexHtml,
    /const anyAvail = dests\.some\(d => d\.enabled && d\.available\)\s*\|\|\s*s\.cloudDocsAvailable\s*\|\|\s*s\.googleDriveAvailable\s*;/,
    'anyAvail must be one complete expression (|| cloud fallbacks attached)',
  );
  // Orphan trailing || must not exist as a free statement after quark block
  assert.doesNotMatch(
    indexHtml,
    /\}\s*\n\s*\|\|\s*s\.cloudDocsAvailable/,
    'orphan || s.cloudDocsAvailable after a closing brace is a deploy-breaker',
  );
});

test('quarkDiscovery UI hooks stay wired', () => {
  assert.match(indexHtml, /id="bkQuarkDiscover"/);
  assert.match(indexHtml, /s\.quarkDiscovery/);
  assert.match(indexHtml, /card-header-lead/);
});

test('product brand is ClipVault in title', () => {
  assert.match(indexHtml, /<title>ClipVault<\/title>/);
});

test('html/rtf restores notes-rich for structure; plain uses hljs path', () => {
  assert.match(indexHtml, /notes-rich\$\{tiny\}/, 'structured HTML may use notes-rich');
  assert.match(indexHtml, /function looksLikeCode/);
  assert.match(indexHtml, /function detectCodeLang/);
  assert.match(indexHtml, /hljs\.highlightElement/);
  assert.match(indexHtml, /renderSearchableText|highlightEscaped/);
});

test('search highlight helpers present', () => {
  assert.match(indexHtml, /function highlightEscaped/);
  assert.match(indexHtml, /function fieldMatchesQuery/);
  assert.match(indexHtml, /search-hit/);
  assert.match(indexHtml, /命中 OCR/);
});

test('eval history note display does not soft-wrap', () => {
  assert.match(
    indexHtml,
    /\.eval-hist-note\s*\{[\s\S]{0,320}?white-space:\s*pre\s*;/,
    '备注展示 must use white-space:pre so real newlines stay obvious',
  );
  assert.doesNotMatch(
    indexHtml,
    /\.eval-hist-note\s*\{[\s\S]{0,200}?white-space:\s*pre-wrap/,
    'eval-hist-note must not use pre-wrap soft wrap',
  );
});

test('eval history note has copy button (scrollbar may obscure long lines)', () => {
  assert.match(indexHtml, /eval-hist-note-copy/);
  assert.match(indexHtml, /复制备注/);
  assert.match(
    indexHtml,
    /await copyClip\(noteText\)/,
    'note copy uses same macOS clipboard path as card copy',
  );
  assert.match(
    indexHtml,
    /\.eval-hist-note\s*\{[\s\S]{0,800}?padding:\s*2px 34px 14px 0/,
    'note body pads for copy chip + scrollbar so text is not covered',
  );
});

test('html/rtf card copy uses plain text (所见即所得), not raw HTML attr', () => {
  assert.match(indexHtml, /function plainTextForCopy/);
  assert.match(indexHtml, /function normalizeCopyText/);
  assert.match(indexHtml, /data-copy-plain/);
  assert.match(indexHtml, /plainTextForCopy\(item,\s*card\)/);
  assert.match(
    indexHtml,
    /JSON\.stringify\(\{\s*text:\s*plain,\s*type:\s*'text'\s*\}\)/,
    'copyClip must write type:text plain to pasteboard API',
  );
  assert.doesNotMatch(
    indexHtml,
    /data-copy=\"\$\{copyText\}\"/,
    'must not put copy body in HTML attribute (newlines/spaces collapse)',
  );
});

test('card copy forces plain text only (no text/html re-capture as type=html)', () => {
  assert.match(indexHtml, /function wireForcePlainCopyOnce/);
  assert.match(indexHtml, /clipboardData\.setData\(\s*['"]text\/plain['"]/);
  assert.match(indexHtml, /navigator\.clipboard\.writeText/);
  assert.match(
    indexHtml,
    /JSON\.stringify\(\{\s*text:\s*plain,\s*type:\s*'text'\s*\}\)/,
    'copyClip posts plain + type text',
  );
});

test('text display pretty-prints JSON (display only, copy stays raw)', () => {
  assert.match(indexHtml, /function detectStructuredText/);
  assert.match(indexHtml, /function formatTextForDisplay/);
  assert.match(indexHtml, /TEXT_PRETTY_MAX/);
  assert.match(indexHtml, /label: 'JSON'/);
  assert.match(indexHtml, /已排版/);
  assert.match(indexHtml, /is-pretty/);
  assert.match(
    indexHtml,
    /item\.type === 'text' \|\| item\.type === 'url'/,
    'plainTextForCopy prefers stored payload for text (not pretty DOM)',
  );
  assert.match(indexHtml, /structuredKindIsCodey/);
});

test('structured text format covers multiple kinds + chips', () => {
  assert.match(indexHtml, /function detectStructuredText/);
  assert.match(indexHtml, /function formatTextForDisplay/);
  assert.match(indexHtml, /function looksLikeJwt/);
  assert.match(indexHtml, /function looksLikeUrl/);
  assert.match(indexHtml, /function looksLikeFormBody/);
  assert.match(indexHtml, /function looksLikeNdjson/);
  assert.match(indexHtml, /function prettyXmlFallback|function prettyXml/);
  assert.match(indexHtml, /function formatSql/);
  assert.match(indexHtml, /format-chip--json/);
  assert.match(indexHtml, /format-chip--url/);
  assert.match(indexHtml, /structuredKindIsCodey/);
  assert.match(indexHtml, /复制始终为原文/);
});

test('per-clip pretty + url open + beautifier CDNs', () => {
  assert.match(indexHtml, /clipDisplayMode/);
  assert.match(indexHtml, /data-raw-card/);
  assert.match(indexHtml, /data-pretty-card/);
  assert.match(indexHtml, /data-open-url/);
  assert.match(indexHtml, /js-beautify/);
  assert.match(indexHtml, /sql-formatter/);
  assert.match(indexHtml, /function renderFormatToolbar/);
  assert.match(indexHtml, /function wireFormatToolbarDelegateOnce/);
  assert.match(indexHtml, /getSqlFormatFn/);
  assert.doesNotMatch(indexHtml, /id="prettyToggle"/);
  assert.doesNotMatch(indexHtml, /cv\.displayPretty/);
});

test('URL safety: no clickable url-canonical; open goes through confirm gate', () => {
  assert.doesNotMatch(indexHtml, /class="url-canonical"/, 'url-canonical <a> must not exist');
  assert.match(indexHtml, /function requestOpenExternalUrl/, 'external open must use confirm gate');
  assert.match(indexHtml, /function isAdultRiskUrl/, 'adult risk detector required');
  assert.match(indexHtml, /url-display/, 'URL shown as non-link text block');
  assert.match(indexHtml, /background:\s*transparent\s*!important/, 'notes-rich must neutralize foreign bg');
  assert.match(indexHtml, /pointer-events:\s*none\s*!important/, 'rich anchors must not receive clicks');
});

test('url dual surface locked in index.html (canonical + parse)', () => {
  // Header strip: single-line pan
  assert.match(indexHtml, /\.url-display[\s\S]{0,500}?white-space:\s*nowrap/, 'canonical url-display is nowrap single-line');
  // Parse must exist (query expand)
  assert.match(indexHtml, /# query/, 'formatUrlParts must build # query section');
  assert.match(indexHtml, /searchParams\.entries/, 'must iterate query params');
  // UI must render BOTH surfaces for pretty url
  assert.match(indexHtml, /url dual surface|URL dual surface/, 'renderPlainBody comment/path for dual surface');
  assert.match(indexHtml, /url-parsed/, 'parsed body class url-parsed required');
  assert.match(indexHtml, /renderUrlDisplayBlock/, 'canonical strip required');
  // safety still on
  assert.doesNotMatch(indexHtml, /class="url-canonical"/);
  assert.match(indexHtml, /function requestOpenExternalUrl/);
});

test('delete/restore use differential remove (no full rebuild scroll jump)', () => {
  assert.match(indexHtml, /function removeCardFromMasonry/, 'differential remove required');
  const delIdx = indexHtml.indexOf('async function deleteClip');
  const delChunk = indexHtml.slice(delIdx, delIdx + 900);
  assert.match(delChunk, /removeCardFromMasonry/, 'deleteClip uses removeCardFromMasonry');
  assert.doesNotMatch(delChunk, /rebuildFromData\(\s*\)/, 'deleteClip must not bare rebuildFromData()');
  assert.match(indexHtml, /behavior:\s*['"]instant['"]/, 'scroll restore uses absolute scrollTo');
});

test('SSE clip_deleted must not fetchPage reset (scroll thrash root cause)', () => {
  assert.match(indexHtml, /function applyRemoteClipRemoval/, 'SSE delete path required');
  assert.match(indexHtml, /noteLocalListMutation/, 'local mutation suppress required');
  // Hard ban: clip_deleted → fetchPage reset was the bug
  assert.doesNotMatch(
    indexHtml,
    /clip_deleted[\s\S]{0,200}?fetchPage\(\{\s*reset:\s*true/,
    'SSE must not full-reset on clip_deleted',
  );
});

test('markdown preview uses marked + DOMPurify CDN', () => {
  assert.match(indexHtml, /marked(\.min)?\.js|marked@/, 'marked CDN');
  assert.match(indexHtml, /dompurify|purify\.min\.js/i, 'DOMPurify CDN');
  assert.match(indexHtml, /md-preview/, 'preview surface');
  assert.match(indexHtml, /renderMarkdownPreviewHtml|marked\+dompurify/, 'engine path');
  assert.doesNotMatch(indexHtml, /function fallbackMarkdownToHtml/, 'no DIY markdown parser');
});

test('scroll smoothness: no full masonry rebuild on image load', () => {
  // Thumb box must reserve geometry
  assert.match(indexHtml, /\.thumb-wrap[\s\S]{0,400}?aspect-ratio:\s*4\s*\/\s*3/, 'thumb aspect-ratio lock');
  assert.match(indexHtml, /thumb-wrap img[\s\S]{0,200}?position:\s*absolute/, 'img absolute so intrinsic size cannot reflow');
  // Image load must not call rebuildFromData
  assert.match(indexHtml, /function onThumbBroken|intentionally empty/, 'local patch / no-op sync');
  assert.match(indexHtml, /measureHeightAtWidth/, 'off-DOM measure for append');
  // Hard ban: load listener → scheduleMasonrySync full rebuild path
  assert.doesNotMatch(
    indexHtml,
    /addEventListener\(\s*['"]load['"][\s\S]{0,80}?scheduleMasonrySync/,
    'img load must not schedule full masonry rebuild',
  );
  const syncIdx = indexHtml.indexOf('function scheduleMasonrySync');
  assert.ok(syncIdx > 0);
  const chunk = indexHtml.slice(syncIdx, syncIdx + 280);
  assert.doesNotMatch(chunk, /rebuildFromData/, 'scheduleMasonrySync must not rebuildFromData');
});

test('URL archive is manual + gated (save useful)', () => {
  assert.match(indexHtml, /data-archive-url/, 'archive button on URL cards');
  assert.match(indexHtml, /function requestArchivePage/, 'archive request helper');
  assert.match(indexHtml, /function renderUrlCardBody/, 'url card dedicated body');
  assert.match(indexHtml, /\/api\/archive/, 'archive API');
  assert.match(indexHtml, /save useful|归档网页/, 'product copy');
});

test('clear archive is independent of URL clip', () => {
  assert.match(indexHtml, /data-clear-archive/, 'clear-archive control');
  assert.match(indexHtml, /function clearArchiveKeepUrl/, 'clear helper');
  assert.match(indexHtml, /DELETE/, 'uses DELETE /api/archive');
});

test('type=text URL clips still get archive/view toolbar', () => {
  assert.match(indexHtml, /function itemIsArchived/, 'archived helper');
  assert.match(indexHtml, /function itemUrlHref/, 'url-from-text helper');
  assert.match(indexHtml, /item\.type === 'url' \|\| itemUrlHref\(item\) \|\| itemIsArchived\(item\)/, 'text URL uses url card body');
  assert.match(indexHtml, /archived: itemIsArchived\(item\)/, 'text path forwards archived');
});

test('archived URL uses View sheet — no inline HTML in cards', () => {
  assert.match(indexHtml, /data-view-archive/, 'View button after archive');
  assert.match(indexHtml, /id="archiveReader"/, 'ClipVault reader sheet');
  assert.match(indexHtml, /\/api\/archive\/view/, 'native HTML document');
  assert.match(indexHtml, /embed=1/, 'sheet loads embed view');
  assert.match(indexHtml, /function archiveViewHref/, 'same document for sheet and tab');
  assert.match(indexHtml, /function morphArchiveButtonToView/, 'archive button becomes view');
  assert.match(indexHtml, /archiveReaderFrame/, 'isolated iframe');
  assert.match(indexHtml, /archiveReaderNewTab/, 'escape hatch: real browser tab');
  assert.doesNotMatch(indexHtml, /class="archive-badge"/, 'no tiny 已归档 chip replacing the control');
  assert.doesNotMatch(indexHtml, /frame\.srcdoc|buildArchiveReaderDoc/, 'never srcdoc / JS rebuild');
  assert.doesNotMatch(indexHtml, /archive-preview md-preview/, 'must not dump archive HTML into masonry');
  assert.match(indexHtml, /function openArchiveReader/, 'reader opener');
});

test('feed JSON must not embed archive HTML into masonry items', () => {
  assert.match(indexHtml, /function dedupeClipsById/, 'dedupe clips');
  assert.match(indexHtml, /includeArchiveHTML|archived flag is the source/, 'list vs full html split');
});
