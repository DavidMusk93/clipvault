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
  assert.doesNotMatch(js, /milkdown-top-bar/);
  assert.match(restart, /rsync -a/);
  assert.match(restart, /web\//);
});

test('notes preview code is Apple light, not a charcoal well', () => {
  assert.match(css, /\.notes-code[\s\S]{0,180}#f5f5f7/);
  assert.doesNotMatch(css, /\.notes-preview-inner pre[\s\S]{0,120}background:\s*#1d1d1f/);
  assert.match(css, /Xcode Light/);
  assert.match(entry, /appleLight/);
  assert.match(entry, /enhancePreview/);
  assert.match(html, /#f2f2f7/);
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
  assert.match(html, /\.notes-panel \{[\s\S]{0,280}opacity: 0;/);
  assert.doesNotMatch(html, /\.notes-panel \{[\s\S]{0,200}translateY\(18px\)/);
});
