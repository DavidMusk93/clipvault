import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { JSDOM } from 'jsdom';
import { root } from './helpers/src.mjs';

const html = readFileSync(join(root, 'web/index.html'), 'utf8');
function setup(datasets, lastRun = null) {
  const dom = new JSDOM('<button data-history-days="1"></button><button data-history-days="7"></button><button data-history-kind="all"></button><button data-history-kind="ostore"></button><div id="bkHistoryChart"></div><div id="bkHistoryCoverage"></div><div id="bkHistoryDetail"></div>');
  const source = html.slice(html.indexOf('    let backupHistoryDays = 1;'), html.indexOf('    let backupMetricSelection =', html.indexOf('    let backupHistoryDays = 1;')));
  assert.ok(source.includes('async function refreshBackupHistory'));
  const fetch = async url => ({ok:true, json:async () => url.includes('/status?') ? ({ostore:{lastRun}}) : ({ok:true, events: datasets[new URL(url, 'http://local').searchParams.get('name')] || []}) });
  const run = new Function('document', 'fetch', 'API', 'formatLocalTime', 'fmtVal', 'fmtBytes', source + '\nreturn refreshBackupHistory;')(
    dom.window.document, fetch, '', n => `time:${n}`, n => `${n}ms`, n => `${n}B`);
  return {document:dom.window.document, run};
}

test('history orders actual runs, removes duplicate manual metrics and supports selection', async () => {
  const now = Date.now();
  const {document, run} = setup({
    backup_cycle:[{name:'backup_cycle', ts:now-3000, dur_ms:1000, ok:true}],
    backup_local_run:[{name:'backup_local_run', ts:now-3000, dur_ms:1000, ok:true, payload:{kind:'manual'}}, {name:'backup_local_run', ts:now-2000, dur_ms:2000, ok:false, payload:{kind:'automatic'}}],
    backup_ostore_run:[{name:'backup_ostore_run', ts:now-1000, dur_ms:3000, ok:true, payload:{applied:2,reused:3,bytes:100}}]
  }, {finishedUnix:(now-1000)/1000,durationSeconds:3,phase:'ok'});
  document.querySelector('[data-history-kind="all"]').click();
  await new Promise(r => setTimeout(r, 0));
  const buttons = document.querySelectorAll('#bkHistoryChart button');
  assert.equal(buttons.length, 3);
  assert.match(document.getElementById('bkHistoryDetail').textContent, /ostore 上传.*上传 2.*跳过 3/);
  buttons[1].click();
  assert.match(document.getElementById('bkHistoryDetail').textContent, /自动本机备份.*失败.*2000ms/);
  assert.equal(buttons[1].getAttribute('aria-pressed'), 'true');
});

test('history includes the last persisted ostore run without inventing older runs', async () => {
  const {document, run} = setup({}, {finishedUnix:Date.now()/1000-10,durationSeconds:2,phase:'ok',uploaded:1,skipped:4,uploadedBytes:10});
  document.querySelector('[data-history-kind="ostore"]').click();
  await new Promise(r => setTimeout(r, 0));
  assert.equal(document.querySelectorAll('#bkHistoryChart button').length, 1);
  assert.match(document.getElementById('bkHistoryDetail').textContent, /留存的上次运行/);
  assert.match(document.getElementById('bkHistoryCoverage').textContent, /逐轮记录从新版本开始/);
});

test('empty history remains empty', async () => {
  const {document, run} = setup({});
  await run();
  assert.match(document.getElementById('bkHistoryChart').textContent, /暂无运行记录/);
});
