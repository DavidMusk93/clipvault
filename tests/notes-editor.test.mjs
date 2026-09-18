/**
 * Compose notes editor is CodeMirror 6 source + marked preview, not Crepe/Vditor.
 */
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';
import test from 'node:test';
import { src, root } from './helpers/src.mjs';

// jsdom is a dev-only dependency (npm ci). Skip cleanly when absent so the CI
// Swift job (check-frontend.sh runs without an npm install) still passes.
let JSDOM = null;
let skipJsdom = false;
try {
  ({ JSDOM } = await import('jsdom'));
} catch {
  skipJsdom = 'jsdom not installed — run `npm ci`';
}

const html = readFileSync(join(root, 'web/index.html'), 'utf8');
const entry = readFileSync(join(root, 'web/assets/notes-editor/entry.js'), 'utf8');
const css = readFileSync(join(root, 'web/assets/notes-editor/notes-editor.css'), 'utf8');
const vendor = readFileSync(join(root, 'scripts/vendor-notes-editor.sh'), 'utf8');
const restart = readFileSync(join(root, 'scripts/restart-clipvault.sh'), 'utf8');
const js = readFileSync(join(root, 'web/assets/notes-editor/notes-editor.js'), 'utf8');
const swift = src('WebServer.swift');

test('notes editor is CodeMirror 6, not Crepe/Vditor', () => {
  assert.match(entry, /from '@codemirror\/view'/);
  assert.match(entry, /from '@codemirror\/lang-markdown'/);
  assert.match(entry, /ClipNotesEditor/);
  assert.doesNotMatch(entry, /@milkdown\/crepe|new Crepe|vditor/i);
  assert.match(vendor, /@codemirror\/view/);
  assert.doesNotMatch(vendor, /@milkdown\/crepe/);
  assert.match(js, /ClipNotesEditor/);
  assert.match(js, /notes-md-block/);
  assert.match(js, /createRoot/);
  assert.doesNotMatch(js, /milkdown-top-bar/);
  assert.match(restart, /rsync -a/);
  assert.match(restart, /web\//);
});

test('notes preview code is Apple light, not a charcoal well', () => {
  assert.match(css, /\.notes-code[\s\S]{0,180}#f5f5f7/);
  assert.match(css, /background:\s*#f5f5f7\s*!important/);
  assert.doesNotMatch(css, /\.notes-preview-inner pre[\s\S]{0,80}background:\s*#1d1d1f/);
  assert.match(css, /Xcode Light/);
  assert.match(entry, /appleLight/);
  assert.match(entry, /enhancePreview/);
  assert.match(html, /#f2f2f7/);
  assert.match(html, /notes-editor\.css\?v=/);
});

test('preview mode measure is 0.618 of the parent pane', () => {
  assert.match(css, /\[data-mode="preview"\] \.notes-preview-inner \{\n  width: 61\.8%;/);
  assert.match(css, /\[data-mode="preview"\] \.notes-preview-inner \{ width: 100%; \}/);
  assert.match(css, /\.notes-preview-inner \{[\s\S]{0,80}max-width: 38rem;/);
});

test('preview code wraps and has a copy button', () => {
  assert.match(css, /white-space:\s*pre;/);
  assert.match(css, /\.notes-code\.is-wrap[\s\S]{0,220}pre-wrap/);
  assert.match(css, /overflow-x:\s*auto/);
  assert.match(css, /\.notes-code-copy/);
  assert.match(css, /\.notes-code-wrap/);
  assert.match(css, /\.notes-code-head/);
  assert.match(css, /\.notes-code-actions \{[\s\S]{0,80}gap:\s*4px/);
  assert.match(css, /\.notes-code-copy,\n\.notes-code-wrap \{[\s\S]{0,480}box-shadow:/);
  assert.match(entry, /actions\.className = 'notes-code-actions'/);
  assert.match(entry, /function copyNotesCode/);
  assert.match(entry, /function loadCodeWrap/);
  assert.match(entry, /function syncCodeWrap/);
  assert.match(entry, /clipvault\.notes\.codeWrap/);
  assert.match(entry, /btn\.className = 'notes-code-copy'/);
  assert.match(entry, /wrapBtn\.className = 'notes-code-wrap'/);
  assert.match(entry, /closest\('\.notes-code-copy'\)/);
  assert.match(entry, /navigator\.clipboard\.writeText/);
  assert.doesNotMatch(css, /\.notes-preview-inner pre[\s\S]{0,200}white-space:\s*pre-wrap/);
});

test('notes remember the open note and support Apple tags', () => {
  assert.match(html, /clipvault\.notes\.id/);
  assert.match(html, /notes\/\$\{|notes\/' \+|notes\//);
  assert.match(html, /kind === 'notes'/);
  assert.match(html, /extractNoteTags/);
  assert.match(html, /id="notesTagBar"/);
  assert.match(html, /id="notesTitleView"/);
  assert.match(html, /formatTaggedHtml/);
  assert.match(html, /#f5a400/);
  assert.match(css, /\.notes-preview \.notes-tag/);
  assert.doesNotMatch(css, /background:\s*#ffe566/);
  assert.match(entry, /tagifyPreview/);
  assert.match(swift, /max-age=60, must-revalidate/);
});

test('nested lists indent in source and restyle in preview', () => {
  assert.match(entry, /function indentList/);
  assert.match(entry, /olMarker/);
  assert.match(entry, /key: 'Tab'/);
  assert.match(entry, /key: 'Shift-Tab'/);
  assert.match(entry, /continueList/);
  assert.match(entry, /lastSiblingOlMarker/);
  assert.match(entry, /nextOlMarker/);
  assert.doesNotMatch(entry, /head !== line\.to/);
  assert.match(css, /ol ol \{ list-style-type: lower-alpha/);
  assert.match(entry, /renderPreview\(next, true, \{ preserveScroll: false, remap: true \}\)/);
});

test('save status is labeled and retries on failure', () => {
  assert.match(html, /id="notesStatusLabel"/);
  assert.match(html, /scheduleNoteRetry/);
  assert.match(html, /保存失败/);
  assert.match(html, /notes-new-plus/);
  assert.doesNotMatch(html, />新一篇</);
  assert.doesNotMatch(html, /notes-status-dot/);
  assert.match(html, /id="notesStatus"/);
  assert.match(html, /id="notesLink"/);
  assert.match(html, /id="notesShare"/);
  assert.match(html, /\.notes-status\[data-state="saved"\] \{ color: #248A3D; \}/);
  assert.match(html, /\.notes-status\[data-state="dirty"\] \{ color: #C47A2C; \}/);
  // Save-state text morph (#20, restrained): cross-fade + numeric width tween so
  // the toolbar buttons beside the label never jump. No blur at 11px.
  assert.match(html, /transition: width 0\.18s var\(--spring\)/, 'slot width tweens');
  assert.match(html, /\.notes-status-label\.is-swapping \{ opacity: 0; transition: none; \}/, 'label cross-fade');
  assert.match(html, /next !== prevState/, 'morph only on state change — error countdown must not flicker');
  assert.match(html, /prefers-reduced-motion: reduce\)\s*\{\s*\.notes-status \{ transition: color/, 'reduced motion drops the width tween');
});

test('save status morphs on state change and only swaps text on same state', { skip: skipJsdom }, () => {
  const start = html.indexOf('function notesStatus(');
  assert.ok(start >= 0, 'notesStatus not found');
  const open = html.indexOf('{', start);
  let depth = 0;
  let end = -1;
  for (let i = open; i < html.length; i++) {
    if (html[i] === '{') depth++;
    else if (html[i] === '}') {
      depth--;
      if (depth === 0) { end = i + 1; break; }
    }
  }
  const fnSrc = html.slice(start, end);
  const dom = new JSDOM('<!DOCTYPE html><body><span class="notes-status" id="notesStatus" data-state="idle"><span class="notes-status-label" id="notesStatusLabel"></span></span></body>');
  const { document } = dom.window;
  const el = document.getElementById('notesStatus');
  const label = document.getElementById('notesStatusLabel');
  const notesStatus = new Function('document', `${fnSrc}; return notesStatus;`)(document);

  notesStatus('dirty');
  assert.equal(el.dataset.state, 'dirty');
  assert.equal(label.textContent, '未保存');
  assert.equal(el.title, '未保存');

  notesStatus('saving');
  assert.equal(label.textContent, '保存中');
  notesStatus('saved');
  assert.equal(label.textContent, '已保存');

  // Error countdown re-paints the same state: text swaps, morph class must not linger.
  notesStatus('error', '保存失败，5s 后重试');
  assert.equal(el.dataset.state, 'error');
  assert.equal(label.textContent, '保存失败，5s 后重试');
  notesStatus('error', '保存失败，4s 后重试');
  assert.equal(label.textContent, '保存失败，4s 后重试');
  assert.equal(label.classList.contains('is-swapping'), false);

  notesStatus('idle');
  assert.equal(label.textContent, '');
});

test('panel is source + preview split', () => {
  assert.match(html, /id="notesEditor"/);
  assert.match(html, /data-mode="source"/);
  assert.match(html, /data-mode="split"/);
  assert.match(html, /data-mode="preview"/);
  assert.match(html, /id="notesTools"/);
  assert.match(html, /id="notesStatus"/);
  assert.match(entry, /notes_md_compile/);
  assert.match(entry, /notes_preview_ms/);
  assert.match(entry, /phase: 'compile'/);
  assert.match(entry, /phase: 'paint'/);
  assert.doesNotMatch(html, /milkdown-top-bar/);
  assert.doesNotMatch(html, /id="notesMeta"/);
  assert.match(css, /notes-source/);
  assert.match(css, /notes-preview/);
  assert.match(entry, /dataset\.mode/);
});

test('preview mode keeps the preview pane in a 1fr track', () => {
  assert.match(css, /grid-template-areas:\s*"source split preview"/);
  assert.match(css, /\[data-mode="split"\] \{\n  grid-template-columns: 0\.46fr 5px 0\.54fr;/);
  assert.match(css, /\[data-mode="preview"\] \{\n  grid-template-columns: 1fr;/);
  assert.doesNotMatch(css, /\[data-mode="preview"\] \{\s*grid-template-columns:\s*0 0 1fr/);
});

test('opening a note defaults to preview; new note is split', () => {
  assert.match(entry, /function loadMode\(\) \{\n  return 'preview'\n\}/);
  assert.match(entry, /opts\.mode && MODES\.includes\(opts\.mode\)/);
  assert.doesNotMatch(entry, /localStorage\.getItem\(MODE_KEY\)/);
  assert.match(html, /ensureNotesEditor\(noteStripTitle\(item\.textContent \|\| '', t\), 'preview'\)/);
  assert.match(html, /ensureNotesEditor\('', 'split'\)/);
  assert.doesNotMatch(html, /ensureNotesEditor\('', 'source'\)/);
  assert.match(html, /applyNotesMode\('preview'\)/);
  assert.match(html, /notes-chrome'\)\?\.classList\.toggle\('is-preview'/);
  assert.match(html, /\.notes-chrome\.is-preview \.notes-tools \{[\s\S]{0,80}visibility:\s*hidden/);
  assert.match(html, /\.notes-chrome\.is-preview \.notes-status \{[\s\S]{0,40}visibility:\s*hidden/);
  assert.doesNotMatch(html, /tools\.hidden = mode === 'preview'/);
  assert.match(css, /\.notes-work \{\n  flex: 1;\n  min-height: 0;\n  display: grid;\n  grid-template-columns: 1fr;/);
  assert.doesNotMatch(css, /\.notes-work \{\n[\s\S]{0,160}grid-template-columns: 0\.46fr/);
});

test('title-line #tags are searchable; heading syntax is not a tag', () => {
  assert.match(html, /function extractNoteTags/);
  assert.doesNotMatch(html, /#\{1,6\}\\s\/\.test\(line\)\) continue/);
  assert.match(html, /q\.startsWith\('#'\)/);
  assert.match(html, /id="notesRelated"/);
  assert.match(html, /function openNotesLinkToast/);
  const tags = extractNoteTags('# 网关 #auto #gateway\n\nbody #work\n');
  assert.deepEqual(tags, ['auto', 'gateway', 'work']);
  assert.deepEqual(extractNoteTags('# 纯标题\n\nhello'), []);
});

function extractNoteTags(md) {
  const text = String(md || '');
  const tags = [];
  const seen = new Set();
  let fence = false;
  for (const line of text.split('\n')) {
    if (/^\s{0,3}```/.test(line)) { fence = !fence; continue; }
    if (fence) continue;
    const re = /(^|[^\w#])#([\p{L}\p{N}_/-]{1,32})/gu;
    let m;
    while ((m = re.exec(line))) {
      const k = m[2].toLowerCase();
      if (seen.has(k)) continue;
      seen.add(k);
      tags.push(m[2]);
    }
  }
  return tags;
}
function escapeRegExp(s) {
  return String(s || '').replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}
function noteStripTitle(md, title) {
  const t = (title || '').trim();
  const raw = String(md || '');
  if (!t) return raw;
  const esc = escapeRegExp(t);
  return raw.replace(new RegExp('^#\\s+' + esc + '(?:\\n\\n|\\n)?'), '');
}
function trimNoteTrailingBlanks(md) {
  return String(md || '').replace(/(?:\r?\n[ \t]*)+$/, '');
}

test('strip title eats the separator blank line, not an extra body line', () => {
  assert.match(html, /function noteStripTitle/);
  assert.match(html, /function noteStripTitle[\s\S]{0,220}escapeRegExp\(t\)/);
  assert.doesNotMatch(html, /function noteStripTitle[\s\S]{0,400}\|\[\\\\\]/);
  assert.ok(html.includes("'(?:\\\\n\\\\n|\\\\n)?'"));
  assert.equal(noteStripTitle('# T\n\nhello', 'T'), 'hello');
  assert.equal(noteStripTitle('# T\nhello', 'T'), 'hello');
  assert.equal(noteStripTitle('# T\n\n\nhello', 'T'), '\nhello');
  assert.equal(noteStripTitle('# T\n\nhello\n\n', 'T'), 'hello\n\n');
  assert.equal(noteStripTitle('# b+tree impl\n\nbody', 'b+tree impl'), 'body');
  assert.equal(noteStripTitle('# C++ notes\n\nx', 'C++ notes'), 'x');
  assert.equal(noteStripTitle('# foo.bar\n\nz', 'foo.bar'), 'z');
  assert.equal(noteStripTitle('# (draft)\n\nok', '(draft)'), 'ok');
});

test('trailing blanks trim only on close, not on autosave', () => {
  assert.match(html, /function trimNoteTrailingBlanks/);
  assert.match(html, /function flushNoteTrailingTrim/);
  assert.match(html, /async function closeNotesPanel\(\) \{\n      await flushNoteTrailingTrim\(\);/);
  assert.doesNotMatch(html, /function saveNoteNow[\s\S]{0,400}trimNoteTrailingBlanks/);
  assert.equal(trimNoteTrailingBlanks('hello\n\n'), 'hello');
  assert.equal(trimNoteTrailingBlanks('hello\n  \n\t\n'), 'hello');
  assert.equal(trimNoteTrailingBlanks('hello'), 'hello');
});

test('compose save does not broadcast wall update', () => {
  const start = swift.indexOf('func handleComposeSave');
  const slice = swift.slice(start, start + 1800);
  assert.match(slice, /compose_saved/);
  assert.doesNotMatch(slice, /broadcastSSE\(event: "update"\)/);
  assert.match(html, /d\.type === 'compose_saved'/);
});

test('notes panel open does not translate the chrome', () => {
  assert.match(html, /body\.notes-open \.top-bar/);
  assert.doesNotMatch(html, /body\.notes-open \.top-bar[\s\S]{0,80}translateY\(-120%\)/);
  assert.match(html, /id="wallScene"/);
  assert.match(html, /function playSheet/);
  assert.match(html, /assets\/motion\.js/);
  assert.match(html, /function animateSheetProgress/);
  assert.match(html, /const killer = setTimeout\(once, cap\)/);
  assert.match(html, /Math\.abs\(v - toP\) < 0\.002/);
  assert.doesNotMatch(html, /notesOpenBtn'\)\?\.classList\.add\('is-on'\)/);
  assert.doesNotMatch(html, /\.notes-panel \{[\s\S]{0,200}translateY\(18px\)/);
});

test('notes pin reuses clip pin API and sorts pinned first', () => {
  assert.match(html, /function toggleNotePin/);
  assert.match(html, /function noteIsPinned/);
  assert.match(html, /\/api\/clips\/pin/);
  assert.match(html, /note-pin/);
  assert.match(html, /pinnedAt DESC|Number\(b\.pinnedAt\)/);
  assert.doesNotMatch(html, /note_pin/);
});

test('split panes sync source and preview scroll', () => {
  assert.match(entry, /mapSourceToPreviewScroll/);
  assert.match(entry, /mapPreviewToSourceLine/);
  assert.match(entry, /syncPreviewToSource/);
  assert.match(entry, /syncSourceToPreview/);
  assert.match(entry, /lineBlockAtHeight/);
  assert.match(entry, /atEnd/);
  assert.match(entry, /data-source-end-line/);
  assert.match(entry, /yInScroller/);
  assert.match(entry, /previewEl\.addEventListener\('scroll'/);
  assert.doesNotMatch(entry, /best\.offsetTop/);
  assert.doesNotMatch(entry, /mapLineToScrollTop/);
  assert.match(css, /\.notes-preview-inner \{[\s\S]{0,80}position:\s*relative/);
  assert.match(html, /notes-editor\.js\?v=n27/);
  assert.match(html, /notes-editor\.css\?v=n27/);
});

test('preview compiles blocks incrementally and React reconciles by hash', () => {
  const preview = readFileSync(join(root, 'web/notes-preview.mjs'), 'utf8');
  assert.match(preview, /from 'react'/);
  assert.match(preview, /react-dom\/client/);
  assert.match(preview, /createRoot/);
  assert.match(preview, /dangerouslySetInnerHTML/);
  assert.match(preview, /useLayoutEffect/);
  assert.match(preview, /className: 'notes-md-block'/);
  assert.match(preview, /key: b\.key/);
  assert.doesNotMatch(preview, /notes-md-pad/);
  assert.doesNotMatch(preview, /setWin/);
  assert.match(entry, /compileMarkdownBlocks/);
  assert.match(entry, /mountNotesPreview/);
  assert.match(entry, /preview\.render\(/);
  assert.match(entry, /preview\.unmount\(/);
  assert.match(entry, /paintingPreview/);
  assert.match(entry, /keepTop/);
  assert.match(entry, /stickBottom/);
  assert.match(entry, /paintingPreview\) return/);
  assert.match(entry, /preserveScroll: false/);
  assert.match(entry, /const remap = !!\(opts && opts.remap\)/);
  assert.match(entry, /remap && mode === 'split'\) syncPreviewToSource\(view, \{ force: true \}\)/);
  assert.match(entry, /schedulePreview[\s\S]{0,280}requestAnimationFrame/);
  assert.match(entry, /renderPreview\(lastMd\)/);
  assert.doesNotMatch(entry, /function swapPreview/);
  assert.doesNotMatch(entry, /previewInner\.innerHTML/);
  assert.doesNotMatch(entry, /IMG' && mode === 'split'\) queueSyncFromSource/);
  assert.match(css, /\.notes-md-block \{[\s\S]{0,40}display:\s*contents/);
  assert.match(vendor, /react@18/);
  assert.match(vendor, /react-dom@18/);
  assert.match(vendor, /notes-preview\.mjs/);
  assert.match(vendor, /notes-preview-window\.mjs/);
});

test('notes tools include GFM strikethrough and do not clip the bar', () => {
  assert.match(html, /data-cmd="strike"[^>]*>S</);
  assert.doesNotMatch(html, /format_strikethrough/);
  assert.doesNotMatch(html, /data-cmd="strike"[^>]*>删</);
  assert.match(html, /button\[data-cmd="strike"\][\s\S]{0,80}text-decoration:\s*line-through/);
  assert.match(html, /data-cmd="h3"/);
  assert.match(html, /data-cmd="hr"/);
  assert.match(html, /\.notes-tools \{[\s\S]{0,160}flex-wrap:\s*wrap/);
  assert.doesNotMatch(html, /\.notes-tools \{[\s\S]{0,160}overflow:\s*hidden/);
  assert.match(entry, /case 'strike': wrapSelection\(view, '~~'\)/);
  assert.match(entry, /if \(mode === 'preview'\) return/);
  assert.match(entry, /Mod-Shift-x/);
  assert.match(entry, /aroundLeft === left && aroundRight === r/);
  assert.match(css, /\.notes-preview-inner del/);
  assert.match(js, /case"strike"/);
});

test('open notes lock the wall so chips and format toolbar cannot drag', () => {
  assert.match(html, /html\.notes-open/);
  assert.doesNotMatch(
    html,
    /html\.notes-open[\s\S]{0,160}overflow:\s*hidden/,
    'overflow:hidden on html/body unsticks chrome and jumps first card ~121px',
  );
  assert.match(html, /function lockPageScroll/);
  assert.match(html, /dataset\.scrollLock/);
  assert.match(html, /position = 'fixed'/);
  assert.match(html, /body\.notes-open \.chips,/);
  assert.match(html, /body\.notes-open main/);
  assert.match(html, /sheet-unlocking/);
  assert.match(html, /body\.notes-open:not\(\.sheet-unlocking\) main/);
  assert.match(html, /contain: strict/);
  assert.doesNotMatch(html, /sheet-unlocking\) \.wall-scene/);
  assert.match(html, /function beginSheetUnlock/);
  assert.match(html, /setNotesWallLocked/);
  assert.match(html, /setAttribute\('inert'/);
  assert.match(html, /notesBackdropEvent/);
  assert.match(html, /\.notes-panel\.open \.notes-frost[\s\S]{0,80}pointer-events:\s*auto/);
  assert.match(
    html,
    /\n    \.notes-frost \{\n      position: absolute; inset: 0;\n      pointer-events: none;/,
  );
});
