/**
 * Session-analysis display logic: the sheet structure is fixed by taste
 * (① 损耗判定 → ② 损耗排行 → ③ 回合时间轴 → ④ 账本) and every builder must
 * escape user text. Run via scripts/check-frontend.sh.
 */
import assert from 'node:assert/strict';
import test from 'node:test';

import {
  mineBodyHtml, mineDataSig, mineDirectionsHtml, mineDraftMarkdown, mineSummaryHtml,
} from '../web/mine-render.mjs';

const FIXTURE = {
  ok: true,
  scope: 'session',
  n_rows: 1200,
  directions: [
    { id: 'user.prompt', title: '任务描述' },
    { id: 'agent.tools', title: '工具调用' },
  ],
  active: ['user.prompt', 'agent.tools'],
  summary: {
    n_rows: 1200,
    n_turns: 3,
    n_tools: 40,
    work_s: 900,
    wait_s: 12,
    fail_s: 30,
    fail_n: 2,
    cost_usd: 0.42,
    usage_turns: 3,
    cache_hit_pct: 98.1,
    tools_per_turn: 13.3,
    tokens_out: 1000,
    cache_write: 200,
    cache_read: 9000,
    health: { score: 77, grade: '尚可' },
    flow: { extra_roundtrips: 1 },
  },
  metrics: [
    { id: 'work_s', label: '工作秒', unit: 's', dir: 'down', value: 900, target: 600, delta: -30 },
    { id: 'cost_usd', label: '费用', unit: 'USD', dir: 'down', value: 0.42, target: 0.3, delta: 0.01 },
  ],
  series: { cache: { read: 9000, uncached: 200 } },
  losses: [{ id: 'rework', s: 740.6, usd: 2.059, kind: 'measured' }],
  findings: [
    {
      id: 'rework',
      sev: 'high',
      title: '返工往返 <img src=x onerror=alert(1)>',
      text: '整个回合是流程损耗',
      cause: '短催',
      action: '先给结论',
      gate: '- 首条 prompt 给全 cwd',
      draft: '每完成子目标先给结论+下一步再停。',
      impact: { s: 740.6, usd: 2.059, kind: 'measured' },
      metric: { id: 'work_s', now: 900, target: 600, unit: 's' },
      refs: [{ turn: 2, label: 'RunCommand / bash', exit_code: 1, event_id: 'e1' }],
      ack: { status: 'applied', closed: false, metric_id: 'work_s', at_now: 800, now: 900 },
    },
  ],
  turns: [
    { index: 1, phase: 'implement', ts: '2026-10-02 00:23:19', tools: 32, fails: 0, retries: 0, work_s: 71, wait_s: 0, cost_usd: 0.467, tokens_out: 169093, cache_write: 0, prompt: '继续。' },
    { index: 2, phase: 'debug', ts: '2026-10-02 00:33:19', tools: 8, fails: 2, retries: 1, work_s: 120, wait_s: 3, cost_usd: 0.1, tokens_out: 200, cache_write: 10, prompt: '修一下', nudge: true },
    { index: 3, phase: 'ship', ts: '2026-10-02 00:43:19', tools: 0, fails: 0, retries: 0, work_s: 5, wait_s: 0, cost_usd: 0, tokens_out: 0, cache_write: 0, prompt: '发' },
  ],
  window: { from: '2026-10-02 00:23:19', to: '2026-10-02 00:43:19', instances: ['mac-home'], truncated: false },
  blocks: {
    'agent.tools': {
      axis: 'agent',
      title: '工具调用',
      note: '工具调用分布',
      tables: [
        {
          caption: '工具',
          cols: [{ id: 'tool', title: '工具' }, { id: 'n', title: '调用' }],
          rows: [{ tool: 'RunCommand', n: 30 }, { tool: 'Edit', n: 10 }],
        },
      ],
    },
  },
};

test('the sheet renders the four sections in taste order', () => {
  const html = mineBodyHtml(FIXTURE);
  const order = ['mineVerdict', 'mineLosses', 'mineTimeline', 'mineLedger'].map((id) =>
    html.indexOf(`id="${id}"`),
  );
  assert.ok(order.every((i) => i >= 0), String(order));
  assert.deepEqual([...order].sort((a, b) => a - b), order, 'sections must be ordered');
  assert.match(html, /mine-nav/);
  assert.match(html, /损耗排行 · 按 \$ \/ 秒/);
});

test('user text is escaped; no raw markup leaks into the sheet', () => {
  const html = mineBodyHtml(FIXTURE);
  assert.ok(!html.includes('<img src=x'), 'raw img tag leaked');
  assert.ok(!/<script/i.test(html), 'script leaked');
  assert.match(html, /&lt;img src=x onerror=alert\(1\)&gt;/);
});

test('an open turn renders its detail in place', () => {
  const html = mineBodyHtml(FIXTURE, { openTurn: 2 });
  assert.match(html, /mine-turn-detail/);
  assert.match(html, /data-turn-detail="2"/);
  assert.match(html, /短催回合/);
  // A different turn is closed.
  assert.ok(!mineBodyHtml(FIXTURE, { openTurn: 3 }).includes('data-turn-detail="2"'));
});

test('direction chips mark the selected filter', () => {
  const html = mineDirectionsHtml(FIXTURE.directions, ['user.prompt']);
  const on = html.match(/class="mine-chip is-on"[^>]*>([^<]+)</);
  assert.equal(on && on[1], '任务描述');
  // Empty selection means "all on".
  assert.equal((mineDirectionsHtml(FIXTURE.directions, []).match(/is-on/g) || []).length, 2);
});

test('summary and AGENTS draft carry the window and the rules', () => {
  const sum = mineSummaryHtml(FIXTURE);
  assert.match(sum, /3 回合 · 40 工具/);
  assert.match(sum, /mac-home/);
  const md = mineDraftMarkdown(FIXTURE);
  assert.match(md, /# 从会话分析得到的约束/);
  assert.match(md, /每完成子目标先给结论\+下一步再停。/);
});

test('data signature changes when the numbers change (auto-refresh guard)', () => {
  const sig = mineDataSig(FIXTURE);
  assert.equal(sig, mineDataSig(FIXTURE));
  const changed = { ...FIXTURE, summary: { ...FIXTURE.summary, work_s: 901 } };
  assert.notEqual(sig, mineDataSig(changed));
  assert.equal(mineDataSig({ ok: false, error: 'x' }), 'err:x');
});
