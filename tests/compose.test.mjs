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
  assert.match(notesPage, /\/api\/compose\/image/);
  assert.match(notesPage, /vditor/i);
});

test('notes are a separate surface, not bound to clip cards', () => {
  assert.match(html, /href="\/notes.html"/);
  assert.match(html, /exclude.*note|exclude', 'note'/);
  assert.doesNotMatch(html, /data-compose-from/);
  assert.doesNotMatch(html, /id="composeSheet"/);
  assert.doesNotMatch(html, /id="composeFab"/);
  assert.doesNotMatch(html, /data-type="note"/);
  assert.match(notesPage, /new Vditor/);
  assert.match(notesPage, /\/api\/clips\?type=note/);
  assert.match(web, /notes\.html/);
  assert.match(web, /excludeType/);
});

test('design-taste lists note badge', () => {
  assert.match(taste, /`note`/);
  assert.match(taste, /笔记/);
});
