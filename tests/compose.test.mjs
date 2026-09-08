import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const html = readFileSync(join(root, 'web/index.html'), 'utf8');
const notesPage = readFileSync(join(root, 'web/notes.html'), 'utf8');
const auth = readFileSync(join(root, 'ClipFlow/ComposeNotes.swift'), 'utf8');
const db = readFileSync(join(root, 'ClipFlow/DatabaseManager.swift'), 'utf8');
const web = readFileSync(join(root, 'ClipFlow/WebServer.swift'), 'utf8');
const sync = readFileSync(join(root, 'ClipFlow/CloudDocsSyncService.swift'), 'utf8');
const taste = readFileSync(join(root, 'docs/design-taste.md'), 'utf8');

test('compose is a note type, not an edit of capture', () => {
  assert.match(auth, /ClipboardType\.note|type=note|case note/);
  assert.match(db, /CREATE TABLE IF NOT EXISTS compose_ops/);
  assert.match(db, /func saveComposeNote/);
  assert.match(db, /type = 'note'/);
  assert.match(web, /\/api\/compose/);
  assert.match(web, /\/api\/compose\/image/);
  assert.match(web, /sha=/);
  assert.match(sync, /kind: "compose"/);
  assert.match(sync, /recordLocalCompose/);
});

test('compose images go to CAS sha URLs', () => {
  assert.match(auth, /blobKeys\(in markdown/);
  assert.match(auth, /sha=/);
  assert.match(web, /\/api\/image\?sha=/);
  assert.match(html, /\/api\/compose\/image/);
  assert.match(html, /ClipNotesEditor/);
});

test('compose autosave keeps trailing blank lines in the stored body', () => {
  assert.match(auth, /replacingOccurrences\(of: "\\r\\n", with: "\\n"\)/);
  assert.doesNotMatch(auth, /replacingOccurrences\(of: "\\r\\n", with: "\\n"\)\s*\.trimmingCharacters/);
  assert.match(auth, /trimmed by the client when the notes panel closes/);
});

test('compose concurrent edits use parentHash + diff3, not last apply wins', () => {
  assert.match(db, /planComposeWrite/);
  assert.match(db, /ComposeMerge\.threeWay/);
  assert.match(db, /parent_hash/);
  assert.match(web, /parentHash/);
  assert.match(sync, /parentHash = "parent_hash"/);
  assert.match(html, /parentHash/);
  assert.match(html, /notesMergeHint/);
  assert.match(html, /<<<<<<< /);
  assert.match(taste, /三路合并/);
});

test('notes list load failure must not open a blank new note', () => {
  assert.match(html, /notesState.loaded && !notesState.items.length/);
  assert.match(html, /clipvault-sessions-pause/);
  assert.match(html, /clipvault-sessions-resume/);
  assert.match(html, /clipvault-ui-metrics/);
  assert.match(html, /function animateSheetProgress/);
  assert.match(html, /if \(v === toP\) once\(\)/);
});

test('idle notes resync without a full page refresh', () => {
  assert.match(html, /function mergeNotesHead/);
  assert.match(html, /await mergeNotesHead\(\)/);
  assert.match(html, /lastLocalSaveAt/);
  assert.doesNotMatch(html, /if \(!notesState\.loaded\) \{\s*try \{ await loadNotesList/);
  assert.doesNotMatch(
    html,
    /d\.id !== notesState\.id && notesState\.loaded/,
  );
  assert.match(html, /d\.type === 'compose_saved'[\s\S]{0,180}mergeNotesHead/);
});

test('notes are a same-page panel, not clip-card chrome', () => {
  assert.match(html, /id="notesPanel"/);
  assert.match(html, /exclude.*note|exclude', 'note'/);
  assert.doesNotMatch(html, /data-compose-from/);
  assert.doesNotMatch(html, /id="composeSheet"/);
  assert.doesNotMatch(html, /想到的写下/);
  assert.doesNotMatch(html, /不挂在剪贴墙上/);
  assert.doesNotMatch(html, /new Vditor|vditor/i);
  assert.match(html, /ClipNotesEditor\.mount/);
  assert.match(html, /\/api\/clips\?type=note/);
  assert.match(web, /excludeType/);
  assert.match(html, /class="notes-frost"/);
  assert.match(html, /data-mode="split"/);
});

test('notes editor is a local CodeMirror 6 bundle', () => {
  const js = readFileSync(join(root, 'web/assets/notes-editor/notes-editor.js'), 'utf8');
  const css = readFileSync(join(root, 'web/assets/notes-editor/notes-editor.css'), 'utf8');
  const entry = readFileSync(join(root, 'web/assets/notes-editor/entry.js'), 'utf8');
  assert.match(js, /ClipNotesEditor/);
  assert.match(css, /notes-preview/);
  assert.match(entry, /from '@codemirror\/view'/);
  assert.doesNotMatch(entry, /@milkdown\/crepe/);
  assert.match(html, /\/assets\/notes-editor\/notes-editor\.js/);
});

test('design-taste lists note badge', () => {
  assert.match(taste, /`note`/);
  assert.match(taste, /笔记/);
});
