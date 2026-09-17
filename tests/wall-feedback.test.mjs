/**
 * Wall feedback — failure, retry and empty states.
 * Run: node --test tests/wall-feedback.test.mjs
 *
 * Contract (视觉词典下篇 #56–58): a refresh miss must never blank the wall;
 * an empty wall explains why and offers the next step; failure offers Retry.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const html = fs.readFileSync(path.join(__dirname, '../web/index.html'), 'utf8');

test('wall failure keeps existing cards and never wipes the grid', () => {
  // Old behaviour was `grid.innerHTML = 加载失败，请刷新` — destructive, no retry.
  assert.doesNotMatch(html, /加载失败，请刷新/, 'destructive wipe is gone');
  assert.match(html, /if \(clips\.length\) toast\('刷新失败，保留当前内容'\)/, 'content preserved on refresh miss');
  assert.match(html, /else renderWallError\(\)/, 'empty wall gets the error state');
});

test('wall error state is announced and offers Retry', () => {
  assert.match(html, /function renderWallError\(reason\)/, 'error renderer exists');
  assert.match(html, /class="empty is-error" role="alert"/, 'role=alert for assistive tech');
  assert.match(html, /data-wall-retry/, 'retry button');
  assert.match(html, /cloud_off/, 'icon + text (not colour alone)');
  assert.match(html, /\.empty\.is-error \.material-symbols-outlined \{ color: var\(--danger\)/, 'error colour token');
  assert.match(html, /\.empty-action \{/, 'shared empty/retry action button');
});

test('load-more failure stays at the bottom with a Retry', () => {
  assert.match(html, /function renderLoadMoreRetry\(\)/, 'load-more retry exists');
  assert.match(html, /data-wall-retry-more/, 'load-more retry button');
  assert.match(html, /gen === fetchGen && !loadMoreFailed/, 'retry row survives the finally hide');
  assert.match(html, /loadMoreFailed = false;/, 'flag resets on the next attempt');
});

test('retry buttons are delegated, not per-render', () => {
  assert.match(html, /closest\('\[data-wall-retry\]'\)[\s\S]{0,80}fetchPage\(\{ reset: true \}\)/, 'reset retry');
  assert.match(html, /closest\('\[data-wall-retry-more\]'\)[\s\S]{0,80}fetchPage\(\{ reset: false \}\)/, 'load-more retry');
});
