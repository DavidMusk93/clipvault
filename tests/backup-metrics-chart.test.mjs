import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { JSDOM } from 'jsdom';
import { root } from './helpers/src.mjs';

const html = readFileSync(join(root, 'web/index.html'), 'utf8');
function setup(names, ok = true) {
  const dom = new JSDOM('<div id="bkMetrics"></div>');
  const start = html.indexOf("    let backupMetricSelection = 'p50_ms';");
  const end = html.indexOf('    async function refreshBackupStatus(', start);
  assert.ok(start >= 0 && end > start);
  const run = new Function('document', 'fetch', 'API', 'fmtCount', 'fmtVal', 'esc',
    html.slice(start, end) + '\nreturn refreshBackupMetrics;')(
      dom.window.document, async () => ({ ok, json: async () => ({ names }) }), '',
      String, (n) => n + 'ms', String);
  return { host: dom.window.document.getElementById('bkMetrics'), run };
}

test('manual backup chart uses backup_cycle and supports selection', async () => {
  const {host, run} = setup([{name:'wall_backup', n:999, p50_ms:5, p95_ms:9, max_ms:12}, {name:'backup_cycle', n:3, p50_ms:100, p95_ms:300, max_ms:400}]);
  await run();
  assert.match(host.textContent, /3 次手动本机备份/);
  assert.doesNotMatch(host.textContent, /999/);
  host.querySelector('[data-backup-metric="p95_ms"]').click();
  assert.match(host.textContent, /95% 的样本不超过此耗时 · 300ms/);
  assert.match(host.textContent, /不含 ostore 异步上传/);
  assert.equal(host.querySelector('[data-backup-metric="p95_ms"]').getAttribute('aria-pressed'), 'true');
});

test('manual backup chart shows no data rather than invented zeros', async () => {
  const {host, run} = setup([]);
  await run();
  assert.match(host.textContent, /暂无足够/);
  assert.equal(host.querySelector('button'), null);
});

test('manual backup chart reports request failure', async () => {
  const {host, run} = setup([], false);
  await run();
  assert.match(host.textContent, /无法读取/);
});
