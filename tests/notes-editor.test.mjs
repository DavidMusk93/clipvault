/**
 * Compose notes editor is CodeMirror 6 source + marked preview, not Crepe/Vditor.
 */
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';
import test from 'node:test';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const html = readFileSync(join(root, 'web/index.html'), 'utf8');
const entry = readFileSync(join(root, 'web/assets/notes-editor/entry.js'), 'utf8');
const css = readFileSync(join(root, 'web/assets/notes-editor/notes-editor.css'), 'utf8');
const vendor = readFileSync(join(root, 'scripts/vendor-notes-editor.sh'), 'utf8');
const restart = readFileSync(join(root, 'scripts/restart-clipflow.sh'), 'utf8');
const js = readFileSync(join(root, 'web/assets/notes-editor/notes-editor.js'), 'utf8');
const swift = readFileSync(join(root, 'ClipFlow/WebServer.swift'), 'utf8');

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
  assert.match(swift, /max-age=60/);
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
});

test('panel is source + preview split', () => {
  assert.match(html, /id="notesEditor"/);
  assert.match(html, /data-mode="source"/);
  assert.match(html, /data-mode="split"/);
  assert.match(html, /data-mode="preview"/);
  assert.match(html, /id="notesTools"/);
  assert.match(html, /id="notesStatus"/);
  assert.doesNotMatch(html, /milkdown-top-bar/);
  assert.doesNotMatch(html, /id="notesMeta"/);
  assert.match(css, /notes-source/);
  assert.match(css, /notes-preview/);
  assert.match(entry, /dataset\.mode/);
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
  assert.match(html, /--sheet-y/);
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
  assert.match(html, /notes-editor\.js\?v=n15/);
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
});

test('open notes lock the wall so chips and format toolbar cannot drag', () => {
  assert.match(html, /html\.notes-open/);
  assert.match(html, /body\.notes-open[\s\S]{0,80}overflow:\s*hidden/);
  assert.match(html, /body\.notes-open \.chips,/);
  assert.match(html, /body\.notes-open main/);
  assert.match(html, /setNotesWallLocked/);
  assert.match(html, /setAttribute\('inert'/);
  assert.match(html, /notesBackdropEvent/);
  assert.match(html, /\.notes-panel\.open \.notes-frost[\s\S]{0,80}pointer-events:\s*auto/);
  assert.match(
    html,
    /\n    \.notes-frost \{\n      position: absolute; inset: 0;\n      pointer-events: none;/,
  );
});
