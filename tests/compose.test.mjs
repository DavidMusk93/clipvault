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
  assert.match(html, /vditor/i);
});

test('notes are a same-page panel, not clip-card chrome', () => {
  assert.match(html, /id="notesPanel"/);
  assert.match(html, /exclude.*note|exclude', 'note'/);
  assert.doesNotMatch(html, /data-compose-from/);
  assert.doesNotMatch(html, /id="composeSheet"/);
  assert.doesNotMatch(html, /想到的写下/);
  assert.doesNotMatch(html, /不挂在剪贴墙上/);
  assert.match(html, /new Vditor/);
  assert.match(html, /\/api\/clips\?type=note/);
  assert.match(web, /excludeType/);
  assert.match(html, /class="notes-frost"/);
  assert.match(html, /toolbarConfig:\s*\{\s*hide:\s*false/);
  assert.match(html, /#notesEditor \.vditor-toolbar \{[\s\S]{0,280}?display:\s*flex/);
  assert.doesNotMatch(html, /#notesEditor \.vditor-toolbar \{[\s\S]{0,180}?background:\s*transparent/);
});

test('design-taste lists note badge', () => {
  assert.match(taste, /`note`/);
  assert.match(taste, /笔记/);
});
