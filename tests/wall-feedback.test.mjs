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

function extractFunction(source, name) {
  const start = source.indexOf(`function ${name}(`);
  assert.ok(start >= 0, `${name} not found`);
  const open = source.indexOf('{', start);
  let depth = 0;
  for (let i = open; i < source.length; i++) {
    if (source[i] === '{') depth++;
    else if (source[i] === '}') {
      depth--;
      if (depth === 0) return source.slice(start, i + 1);
    }
  }
  throw new Error(`${name} unbalanced`);
}

test('empty wall explains the reason and offers the matching next step', () => {
  const fnSrc = extractFunction(html, 'wallEmptyMarkup');
  const mk = (searchQuery, currentFilter, trash) =>
    new Function('searchQuery', 'currentFilter', 'esc', `${fnSrc}; return wallEmptyMarkup;`)(
      searchQuery, currentFilter, (s) => String(s)
    )(trash);

  assert.match(mk('', 'all', true), /回收箱是空的/, 'trash has its own copy');
  assert.match(mk('', 'all', true), /保留 30 天/, 'and explains retention');

  assert.match(mk('kafka lag', 'all', false), /没有匹配「kafka lag」的记录/, 'search names the query');
  assert.match(mk('kafka lag', 'all', false), /清除搜索/, 'search can be cleared');

  assert.match(mk('', 'image', false), /没有这种类型的记录/, 'type filter has its own copy');
  assert.match(mk('', 'image', false), /显示全部/, 'filter can be dropped');

  assert.match(mk('', 'all', false), /还没有记录/, 'truly empty library');
  assert.match(mk('', 'all', false), /复制任意文字或图片/, 'says how content arrives');

  // The old generic copy and the stuck「加载中…」branch are gone.
  assert.doesNotMatch(html, /没有匹配的记录/, 'generic copy removed');
  assert.match(html, /host\.innerHTML = wallEmptyMarkup\(inTrash\)/, 'empty branch uses the helper');
});

test('clear-filter escape hatch resets every wall filter and reloads', () => {
  assert.match(html, /function clearWallFilters\(\)/, 'helper exists');
  assert.match(html, /searchQuery = '';\s*currentFilter = 'all';\s*currentView = 'library';/, 'resets all three');
  assert.match(html, /input\.value = ''/, 'clears the search box');
  assert.match(html, /closest\('\[data-wall-clear\]'\)[\s\S]{0,60}clearWallFilters\(\)/, 'delegated');
});

test('cards paint removes stale placeholders (boot loader must not linger)', () => {
  // layoutMasonry used to keep `.empty`, so the「加载中…」block survived under the cards.
  assert.doesNotMatch(html, /!cards\.includes\(ch\) && !ch\.classList\.contains\('empty'\)/, 'old keep-empty guard gone');
  assert.match(html, /only cards live here/, 'documented');
});
