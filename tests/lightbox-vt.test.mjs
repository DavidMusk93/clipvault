/**
 * Lightbox View Transition (#78) — thumbnail grows into the detail image.
 * Run: node --test tests/lightbox-vt.test.mjs
 *
 * Contract: same-document View Transition only, with the materialize keyframe
 * as fallback. The archive View lives in an iframe and therefore cannot share a
 * view-transition-name — it keeps its clip-path reveal.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const html = fs.readFileSync(path.join(__dirname, '../web/index.html'), 'utf8');

test('lightbox open uses a same-document View Transition with a feature guard', () => {
  assert.match(html, /function openLightboxWithTransition\(url, item, originEl\)/, 'VT wrapper exists');
  assert.match(html, /typeof document\.startViewTransition === 'function'/, 'feature-detected');
  assert.match(html, /openLightbox\(url, item\); return; \}/, 'falls back to the plain open');
  assert.match(html, /sheetReduce\(\)/, 'reduced motion falls back');
});

test('the shared element is the thumbnail, named on both ends', () => {
  assert.match(html, /cover\.style\.viewTransitionName = 'cv-lightbox-cover'/, 'old = thumbnail');
  assert.match(html, /img\.style\.viewTransitionName = 'cv-lightbox-cover'/, 'new = lightbox image');
  assert.match(html, /openLightboxWithTransition\(wrap\.getAttribute\('data-preview'\), item, wrap\)/, 'thumb passes its wrapper');
});

test('waits for real pixels but never hangs the transition', () => {
  assert.match(html, /img\.decode \? img\.decode\(\)\.catch\(/, 'awaits decode');
  assert.match(html, /setTimeout\(r, 800\)/, 'decode raced against a cap');
});

test('transition names are always cleared (no duplicate-name lockups)', () => {
  assert.match(html, /function clearLightboxVtNames\(\)/, 'cleanup helper');
  assert.match(html, /vt\.finished\.catch\(\(\) => \{\}\)\.finally\(clearLightboxVtNames\)/, 'cleared when finished (aborts swallowed)');
  assert.match(html, /function closeLightbox\(\) \{\s*clearLightboxVtNames\(\);/, 'cleared on close');
  assert.match(html, /catch \(_\) \{\s*clearLightboxVtNames\(\);/, 'cleared if startViewTransition throws');
});

test('timing is restrained and the fallback keyframe is intact', () => {
  assert.match(html, /::view-transition-group\(cv-lightbox-cover\)[\s\S]{0,120}320ms/, '320ms group');
  assert.match(html, /@keyframes materialize/, 'fallback kept');
  assert.match(html, /prefers-reduced-motion: reduce[\s\S]{0,220}::view-transition-group\(\*\)/, 'reduced motion disables VT');
});

test('the iframe archive View must not use a view-transition-name', () => {
  // An iframe cannot participate in a view transition — keep it on clip-path.
  const start = html.indexOf('function revealReaderSheet(');
  const end = html.indexOf('\n    function openArchiveReader(', start);
  assert.ok(start >= 0 && end > start, 'reveal bounded');
  const body = html.slice(start, end);
  assert.doesNotMatch(body, /viewTransitionName|startViewTransition/, 'no VT on the iframe sheet');
  assert.match(body, /cardEl\.style\.clipPath = inset/, 'still a clip-path reveal');
});
