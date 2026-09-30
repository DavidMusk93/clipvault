/**
 * Session analysis is the product: an attributable loss ledger the Agent can
 * re-measure, plus a sheet that shows the ledger instead of hiding it.
 * Run via scripts/check-frontend.sh.
 */
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import { root } from './helpers/src.mjs';

const html = readFileSync(join(root, 'trae_hooks/web/sessions.html'), 'utf8');
const server = readFileSync(join(root, 'trae_hooks/server.py'), 'utf8');
const mine = readFileSync(join(root, 'trae_hooks/mine.py'), 'utf8');
const agents = readFileSync(join(root, 'AGENTS.md'), 'utf8');
const check = readFileSync(join(root, 'scripts/check-frontend.sh'), 'utf8');
const designPath = join(root, 'docs/session-analysis.md');

test('this file and session_mine_main.py are in the deploy gate', () => {
  assert.match(check, /session-mine\.test\.mjs/);
  assert.match(check, /session_mine_main\.py/);
});

test('AGENTS.md treats sessions as an asset that must be mined', () => {
  assert.match(agents, /会话是资产/);
  assert.match(agents, /\/api\/mine/);
  assert.match(agents, /分析.*调试/);
});

test('the analysis contract is a tracked design doc', () => {
  assert.ok(existsSync(designPath), 'docs/session-analysis.md must exist');
  const doc = readFileSync(designPath, 'utf8');
  assert.match(doc, /doc_id: clipvault-session-analysis-v2/);
  assert.match(doc, /kind: design/);
  assert.match(doc, /authority: design/);
  assert.match(doc, /verified_by:/);
  // The four value criteria and the layer model are the doc's spine.
  for (const word of ['可归因', '可行动', '可验证', '量纲', 'L0 账本', 'L1 归因', 'L2 结论', 'L3 闭环']) {
    assert.match(doc, new RegExp(word));
  }
  assert.match(doc, /反模式/);
});

test('server exposes /api/mine without tool bodies, plus the agent view', () => {
  assert.match(server, /path == "\/api\/mine"/);
  assert.match(server, /mine_session/);
  assert.match(server, /format/);
  assert.match(server, /baseline/);
  assert.match(mine, /substr\(coalesce\(tool_input/);
  assert.match(mine, /substr\(coalesce\(tool_response/);
  assert.doesNotMatch(mine, /SELECT \* FROM hook_events/);
});

test('analysis fab sits above the debug fab', () => {
  assert.match(html, /id="mineOpen"/);
  assert.match(html, />分析<\/button>/);
  assert.match(html, /cv-corner-stack/);
  assert.match(html, /insertBefore\(mineHost, corner\.firstChild\)/);
  assert.match(html, /cv-corner-stack \.cv-metrics-float/);
  assert.doesNotMatch(html, /\.cv-metrics-float \{ bottom: 64px/);
  assert.doesNotMatch(html, /\.cv-mine-float \{[\s\S]{0,80}bottom:\s*52px/);
  assert.match(html, /data-scope="session"/);
  assert.match(html, /data-scope="recent"/);
  assert.match(html, /复制 AGENTS 草稿/);
  assert.match(html, /cv\.trae\.mine\.v1/);
  assert.match(html, /sessMetricsCtl\?\.setOpen/);
});

test('analysis is a stage sheet, not a 420px pop with ellipsis', () => {
  assert.match(html, /cv-mine-sheet/);
  assert.match(html, /inset:\s*8px 8px 52px 8px/);
  const sheet = html.slice(html.indexOf('.cv-mine-sheet {'), html.indexOf('.cv-mine-fab.is-on'));
  assert.match(sheet, /overflow-wrap:\s*anywhere/);
  assert.doesNotMatch(sheet, /width:\s*min\(420px/);
  assert.doesNotMatch(sheet, /text-overflow:\s*ellipsis/);
  assert.doesNotMatch(sheet, /backdrop-filter/);
  assert.match(sheet, /background: #fafafa/);
});

test('the sheet shows the ledger instead of collapsing it', () => {
  // Owner rule: 不要折叠细节, 所见即所得. The old <details> 方向明细 is gone.
  assert.doesNotMatch(html, /mine-tables<\/details>|class="mine-tables"/);
  assert.match(html, /const renderLedger/);
  assert.match(html, /class="mine-blk axis-\$\{axis\}"/);
  assert.match(html, /始终展开/);
  assert.match(html, /const renderLosses/);
  assert.match(html, /const renderTimeline/);
  assert.match(html, /const renderVerdict/);
  assert.match(html, /\.mine-turn\.ph-review/);
});

test('the sheet is designed: color channels, charts, interaction', () => {
  const sheet = html.slice(html.indexOf('.cv-mine-sheet {'), html.indexOf('.cv-mine-fab.is-on'));
  for (const token of ['--mine-time', '--mine-money', '--mine-loss', '--mine-good', '--mine-user', '--mine-agent']) {
    assert.match(sheet, new RegExp(token));
  }
  assert.match(sheet, /\.mc-stack-track/);
  // Adjacent ratios must not merge: real gaps + a hairline per segment.
  assert.match(sheet, /\.mc-stack-track \{[^}]*gap: 3px/);
  assert.match(sheet, /\.mc-seg \{[^}]*box-shadow: inset/);
  assert.match(sheet, /\.mc-bar-row/);
  assert.match(sheet, /\.mc-donut/);
  assert.match(sheet, /\.mc-axis/);
  assert.match(sheet, /--mine-flat/);
  assertNo(sheet, /\.mine-stack|s-work/);
  assert.match(html, /class="mine-nav"/);
  assert.match(html, /data-jump=/);
  assert.match(html, /data-mine-turn/);
  assert.match(html, /data-turn=/);
  assert.match(html, /const jumpMineTo/);
  assert.match(html, /const openMineTurn/);
  // Interaction is not decoration-only: numbers carry the meaning too.
  assert.match(html, /const mineBarPct/);
  assert.match(html, /mine-metric/);
});

function assertNo(source, re, msg) {
  assert.doesNotMatch(source, re, msg || `should not match ${re}`);
}

test('charts are chosen by the data shape, not by taste', () => {
  assert.match(html, /from "\.\/mine-charts\.mjs"/);
  assert.match(html, /const renderChartFor/);
  assert.match(html, /const chartRows/);
  assert.match(html, /renderChartFor\(t\)/);
  // The backend declares the kind next to the data it describes.
  for (const kind of ['"bars"', '"donut"', '"line"', '"columns"', '"stack"']) {
    assert.match(mine, new RegExp(kind));
  }
  assert.match(mine, /chart: dict\[str, Any\] \| None = None/);
  assert.match(mine, /"kind": "donut", "label": "phase", "value": "work"/);
  assert.match(mine, /"kind": "line", "label": "day", "value": "usd"/);
  assert.match(mine, /"kind": "columns", "label": "ts", "value": "work"/);
  // The gauge needs the split behind the ratio.
  assert.match(mine, /"cache": \{/);
  assert.match(mine, /"uncached": input_uncached_total/);
  assert.match(html, /data.series \|\| \{\}\)\.cache/);
  const check = readFileSync(join(root, 'scripts/check-frontend.sh'), 'utf8');
  assert.match(check, /mine-charts\.test\.mjs/);
});

test('the analysis loop can be written back by the agent', () => {
  assert.match(server, /path == "\/api\/mine\/ack"/);
  assert.match(server, /ack_finding/);
  assert.match(server, /store\.execute/);
  assert.match(mine, /def ack_finding/);
  assert.match(mine, /ON CONFLICT \(ack_id\) DO UPDATE/);
  assert.match(mine, /def fetch_acks/);
  assert.match(mine, /def attach_acks/);
  assert.match(mine, /def _reached/);
  assert.match(mine, /analysis_acks/);
  const schema = readFileSync(join(root, 'trae_hooks/schema.sql'), 'utf8');
  assert.match(schema, /CREATE TABLE IF NOT EXISTS analysis_acks/);
  // The brief tells the agent whether its last claim actually landed.
  assert.match(mine, /## 闭环核对/);
  assert.match(mine, /"closed": closed/);
  // UI: ack buttons + state chip + loop counter.
  assert.match(html, /const renderAck/);
  assert.match(html, /const ackMineFinding/);
  assert.match(html, /data-ack-status="applied"/);
  assert.match(html, /mine-ack-chip/);
  assert.match(html, /class="mine-loop"/);
  assert.match(html, /apiUrl\("\/api\/mine\/ack"\)/);
});

test('directions cover user and agent axes', () => {
  for (const id of ['user.cwd', 'user.git', 'user.taste', 'agent.files', 'agent.tools', 'agent.mcp', 'agent.phases']) {
    assert.match(mine, new RegExp(`"id": "${id}"`));
  }
});

test('taste keys keep skill and project names, not bare SKILL.md', () => {
  assert.match(mine, /def taste_keys/);
  assert.match(mine, /skill:/);
  assert.match(mine, /禁止只记 SKILL\.md 文件名/);
});

test('findings come from an attributable loss account, not keywords', () => {
  assert.match(mine, /METRICS: tuple\[dict\[str, Any\], \.\.\.\]/);
  assert.match(mine, /def build_losses/);
  assert.match(mine, /def build_metrics/);
  assert.match(mine, /def norm_path/);
  assert.match(mine, /def _skill_tokens_of/);
  // The five loss kinds and their measured/estimated split.
  for (const id of ['fail_retry', 'reread', 'wait_poll', 'cache_write', 'rework', 'locate', 'idle', 'skill_bloat']) {
    assert.match(mine, new RegExp(`"${id}"`));
  }
  assert.match(mine, /kind.*measured|"measured"/);
  assert.match(mine, /"estimated"/);
  assert.match(mine, /refs/);
  assert.match(mine, /_LOSS_FINDING/);
  // L1 needs money per turn: usage rows are bucketed onto the turn that spent them.
  assert.match(mine, /def _bucket|bisect_right/);
  assert.match(mine, /unit_usd/);
  // Keyword heuristics are gone from findings.
  assert.doesNotMatch(mine, /反复提醒/);
  assert.doesNotMatch(mine, /操作流程：减少口头往返/);
  assert.doesNotMatch(mine, /MCP 面过窄或过散/);
});

test('the agent interface is a contract: brief, metrics, verify, rerun', () => {
  assert.match(mine, /def agent_view/);
  assert.match(mine, /def agent_brief/);
  assert.match(mine, /"view": "agent"/);
  assert.match(mine, /"brief"/);
  assert.match(mine, /"verify"/);
  assert.match(mine, /metric_ids/);
  assert.match(mine, /rerun/);
  assert.match(mine, /同一窗口重跑/);
  assert.match(mine, /if __name__ == "__main__"/);
  assert.match(mine, /--agent/);
  assert.match(mine, /def fetch_baseline/);
  assert.match(mine, /def attach_baseline/);
});

test('per-turn ledger: a prompt closes a turn even without a Stop event', () => {
  assert.match(mine, /A new prompt closes the previous turn even without a Stop event/);
  assert.match(mine, /"turns": turn_rows/);
  assert.match(mine, /"phase": t\["phase"\]/);
  assert.match(mine, /"cost_usd": round\(float\(t\.get\("cost_usd"\)/);
});

test('analysis sheet keeps dynamic: verdict, severity, live refresh', () => {
  assert.match(html, /mine-verdict/);
  assert.match(html, /mine-score/);
  assert.match(html, /mine-sev/);
  assert.match(html, /sev-high/);
  assert.match(html, /scheduleMineRefresh/);
  assert.match(html, /loadMine\(\{ auto: true \}\)/);
  assert.match(html, /clipvault-sessions-overlay/);
  assert.doesNotMatch(html, /setInterval\(/);
});

test('auto refresh preserves the open turn detail and scroll', () => {
  assert.match(html, /let mineOpenTurn = null/);
  assert.match(html, /if \(mineOpenTurn !== null\) \{/);
  assert.match(html, /mineBody\.scrollTop = prevScroll/);
  assert.match(html, /const prevScroll = mineBody\.scrollTop/);
  assert.match(html, /mineDataSig/);
  assert.match(html, /auto && mineDataSig\(data\) === mineSig/);
  assert.match(html, /MINE_AUTO_MIN_MS/);
  assert.match(html, /mineAutoAt/);
  assert.match(html, /mineChipSig/);
  assert.match(html, /minePending/);
  assert.match(html, /is-pending/);
  assert.match(html, /关掉回合明细后更新/);
});

test('analysis sheet does not repaint the covered thread', () => {
  assert.match(html, /if \(mineState\.open\) return;/);
  assert.match(html, /pendingHookIds\.length > 400/);
});

test('baseline is the previous equal-length window, never a guess', () => {
  assert.match(mine, /AND session_id != \?/);
  assert.match(mine, /上一个会话/);
  assert.match(mine, /%Y-%m-%d %H:%M:%S\.%f/);
  assert.match(html, /params\.set\("baseline", "1"\)/);
  assert.match(html, /对照 \$\{escMine\(data\.baseline\.source\)\}|对照 \$\{escMine\(data\.baseline\.source\)\}/);
});
