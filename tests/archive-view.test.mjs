import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const swift = readFileSync(join(root, 'ClipFlow/WebServer.swift'), 'utf8');

test('archive view allows youtube/vimeo frames', () => {
  assert.match(swift, /frame-src https:\/\/www\.youtube-nocookie\.com https:\/\/www\.youtube\.com https:\/\/player\.vimeo\.com/);
});

test('archive view restores mermaid sequence strokes dropped by Readability', () => {
  assert.match(swift, /svg\[aria-roledescription="sequence"\] line\[marker-end\]/);
  assert.match(swift, /stroke:#1d1d1f/);
  assert.match(swift, /svg\[aria-roledescription="sequence"\] marker path/);
});

test('archive view sizes youtube iframes and adds a watch link', () => {
  assert.match(swift, /iframe\[src\*="youtube-nocookie"\]/);
  assert.match(swift, /aspect-ratio:16\/9/);
  assert.match(swift, /cv-video-fallback/);
  assert.match(swift, /decorateArchiveMedia/);
  assert.match(swift, /youtube\.com\/watch\?v=/);
});

test('archive view does not disable article links', () => {
  assert.doesNotMatch(swift, /a\{pointer-events:none;color:inherit;text-decoration:none;\}/);
});

test('archive view promotes weixin lazy data-src over 1px svg src', () => {
  assert.match(swift, /promoteLazyImages/);
  assert.match(swift, /data-src/);
  assert.match(swift, /data:image\/svg/);
});

test('public tunnel path /clipvault is stripped to local routes', () => {
  assert.match(swift, /static let publicPathPrefix = "\/clipvault"/);
  assert.match(swift, /stripPublicPrefix/);
});

test('archive images are CAS assets, not publisher CDN', () => {
  const inliner = readFileSync(join(root, 'ClipFlow/ArchiveImageInliner.swift'), 'utf8');
  assert.match(inliner, /\/api\/archive\/asset\?sha=/);
  assert.match(swift, /sendArchiveAsset/);
  assert.match(swift, /img-src 'self' data: blob:/);
  assert.doesNotMatch(swift, /img-src \*/);
});
