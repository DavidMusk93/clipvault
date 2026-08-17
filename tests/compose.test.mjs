import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const html = readFileSync(join(root, 'web/index.html'), 'utf8');
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
  assert.match(auth, /\/api\/(?:image|archive\/asset)\?sha=/);
  assert.match(web, /\/api\/image\?sha=/);
  assert.match(html, /\/api\/compose\/image/);
  assert.match(html, /!\[\]\(\$\{j\.url\}\)/);
});

test('web has 记一笔 sheet and note chip', () => {
  assert.match(html, /id="composeSheet"/);
  assert.match(html, /id="composeFab"/);
  assert.match(html, /data-type="note"/);
  assert.match(html, /openComposeSheet/);
  assert.match(html, /type === 'note'/);
  assert.match(html, /label: '笔记'/);
});

test('design-taste lists note badge', () => {
  assert.match(taste, /`note`/);
  assert.match(taste, /笔记/);
});
