/**
 * Capability-token shares: public /s/<token>, owner mint/revoke.
 * Run via scripts/check-frontend.sh
 */
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const swift = readFileSync(join(root, 'ClipFlow/WebServer.swift'), 'utf8');
const share = readFileSync(join(root, 'ClipFlow/ShareLinks.swift'), 'utf8');
const db = readFileSync(join(root, 'ClipFlow/DatabaseManager.swift'), 'utf8');
const html = readFileSync(join(root, 'web/index.html'), 'utf8');
const check = readFileSync(join(root, 'scripts/check-frontend.sh'), 'utf8');

test('share table and token helpers exist', () => {
  assert.match(db, /CREATE TABLE IF NOT EXISTS share_links/);
  assert.match(db, /revoked_at/);
  assert.match(db, /func createOrGetShare/);
  assert.match(db, /func revokeShares/);
  assert.match(share, /func newToken/);
  assert.match(share, /SecRandomCopyBytes/);
  assert.match(share, /rewriteAssets/);
  assert.match(share, /noindex/);
});

test('public share routes are served before TOTP gate', () => {
  const gate = swift.indexOf('if !loopback, !Self.publicRequestAuthorized');
  const sharePage = swift.indexOf('pathOnly.hasPrefix("/s/")');
  const shareAsset = swift.indexOf('pathOnly == "/api/share/asset"');
  assert.ok(gate > 0 && sharePage > 0 && shareAsset > 0);
  assert.ok(sharePage < gate, 'GET /s/ must run before unauthorized');
  assert.ok(shareAsset < gate, 'GET /api/share/asset must run before unauthorized');
  assert.match(swift, /handleShareCreate/);
  assert.match(swift, /handleShareRevoke/);
  assert.match(swift, /\/api\/share\/revoke/);
});

test('share page rewrites archive assets onto the token', () => {
  assert.match(share, /\/api\/share\/asset\?t=/);
  assert.match(swift, /allowsAsset/);
  assert.doesNotMatch(share, /archive-reader\.js/);
});

test('owner UI can copy and revoke a share link', () => {
  assert.match(html, /function copyShareLink/);
  assert.match(html, /function revokeShareLink/);
  assert.match(html, /function toggleShareLink/);
  assert.match(html, /data-share-id/);
  assert.doesNotMatch(html, /data-share-revoke/);
  assert.match(html, /id="notesShare"/);
  assert.doesNotMatch(html, /id="notesUnshare"/);
});

test('this file is in the deploy frontend gate', () => {
  assert.match(check, /tests\/share-links\.test\.mjs/);
});
