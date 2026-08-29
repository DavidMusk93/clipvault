/**
 * Adult-risk URL gate: host/path only, never JWT/OAuth fragments.
 */
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { isAdultRiskUrl } from '../web/url-safety.mjs';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const indexHtml = readFileSync(join(root, 'web/index.html'), 'utf8');

const mediumJwt =
  'https://medium.com/@madithatisreedhar123/why-s3-file-system-mounts-are-a-game-changer-for-ecs-workloads-460e4da2ac62' +
  '#id_token=eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.xxx.CSkbxxxFvHoJbk';

test('Medium + Google id_token JWT is not adult (xxx lives in the hash)', () => {
  assert.equal(isAdultRiskUrl(mediumJwt), false);
  assert.equal(
    isAdultRiskUrl('https://medium.com/@x/why-s3-file-system-mounts-are-a-game-changer-460e4da2ac62'),
    false,
  );
});

test('known adult hosts still flag; javascript path does not', () => {
  assert.equal(isAdultRiskUrl('https://www.pornhub.com/video'), true);
  assert.equal(isAdultRiskUrl('https://missav.com/dm'), true);
  assert.equal(isAdultRiskUrl('https://pixiv.net/r18/foo'), true);
  assert.equal(isAdultRiskUrl('https://developer.mozilla.org/en-US/docs/Web/JavaScript'), false);
  assert.equal(isAdultRiskUrl('https://github.com/foo/javascript'), false);
});

test('index.html gate must not scan query/hash; allowlist medium', () => {
  const start = indexHtml.indexOf('function isAdultRiskUrl');
  assert.ok(start > 0, 'isAdultRiskUrl in index.html');
  const chunk = indexHtml.slice(start, start + 2200);
  assert.doesNotMatch(chunk, /u\.hash|u\.search/, 'must not concatenate hash/query into haystack');
  assert.match(chunk, /SAFE_HOST_SUFFIXES|medium\.com/, 'publishing hosts allowlisted');
  assert.match(chunk, /hostname\.split|host labels/, 'label match, not raw includes');
  assert.match(indexHtml, /consumeWallLocatorHash/, 'refresh must consume #h= so F5 does not yank');
});
