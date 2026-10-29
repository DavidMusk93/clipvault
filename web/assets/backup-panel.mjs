/**
 * Backup drawer — one reading of "is my data safe, and has it been?".
 *
 * Four questions, in the order a person asks them, each answered once:
 *   1. Status card    — is it backed up, how long ago, how many places are healthy;
 *                       the auto switch and 立即备份 live next to the answer.
 *   2. 运行记录        — every real run on one time axis, two lanes (本机 / ostore);
 *                       height = duration, red = failed, live band = running now.
 *                       Scrub reads a run without reflow; click pins it.
 *   3. 备份位置        — four destinations, one row shape (icon · name · status · switch);
 *                       the row expands in place, ostore carries live progress.
 *   4. 恢复            — restore points, newest first; diagnostics stay folded.
 *
 * Rules (docs/design-taste.md · 备份面板):
 *   - colour is information: green ok, red failure, blue running; never decoration;
 *   - numbers always next to marks; no chart without the count it draws;
 *   - SSE drives repaints (`backup_status` → `paint(status)`); nothing polls the API.
 *     A 30 s local tick only re-words relative times ("3 分钟前").
 *   - repaint is incremental: a section's HTML is only swapped when it changed, so
 *     the 2 s ostore progress pings never collapse an open row or steal focus.
 *
 * Everything except `mountBackupPanel` is a pure function so
 * `tests/backup-panel.test.mjs` can pin the reading without a browser.
 */

export const HISTORY_LIMIT = 200;
export const HISTORY_METRICS = ['backup_cycle', 'backup_local_run', 'backup_ostore_run'];
export const WINDOWS = [
  { days: 1, label: '24 小时' },
  { days: 7, label: '7 天' },
];
/** Pointer must be this close (px) to a mark for the scrub to read it. */
export const SNAP_PX = 10;

const esc = (s) =>
  String(s ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');

const num = (v) => (typeof v === 'number' && Number.isFinite(v) ? v : 0);

export function fmtCount(n) {
  if (n == null || !Number.isFinite(Number(n))) return '—';
  return Number(n).toLocaleString('en-US');
}

export function fmtBytes(n) {
  if (n == null || !Number.isFinite(Number(n))) return '—';
  const v = Number(n);
  if (v < 1024) return v + ' B';
  if (v < 1048576) return (v / 1024).toFixed(1) + ' KB';
  if (v < 1073741824) return (v / 1048576).toFixed(1) + ' MB';
  return (v / 1073741824).toFixed(2) + ' GB';
}

/** Run duration, human scale: 820 ms · 1.6 秒 · 6 分 28 秒 · 1 小时 4 分. */
export function fmtDur(ms) {
  if (ms == null || !Number.isFinite(Number(ms))) return '—';
  const v = Math.max(0, Number(ms));
  if (v < 1000) return Math.round(v) + ' ms';
  if (v < 60000) return (v / 1000).toFixed(v < 10000 ? 1 : 0) + ' 秒';
  const s = Math.round(v / 1000);
  if (s < 3600) return Math.floor(s / 60) + ' 分 ' + (s % 60) + ' 秒';
  return Math.floor(s / 3600) + ' 小时 ' + Math.round((s % 3600) / 60) + ' 分';
}

/** Relative freshness — the first thing the status card says. */
export function relTime(unix, nowMs = Date.now()) {
  if (unix == null || !Number.isFinite(Number(unix))) return null;
  const sec = Math.max(0, nowMs / 1000 - Number(unix));
  if (sec < 45) return '刚刚';
  if (sec < 3600) return Math.max(1, Math.round(sec / 60)) + ' 分钟前';
  if (sec < 86400) return Math.round(sec / 3600) + ' 小时前';
  return Math.round(sec / 86400) + ' 天前';
}

function clockParts(ms, timeZone) {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone, month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit', hour12: false,
  }).formatToParts(new Date(ms));
  const get = (t) => (parts.find((p) => p.type === t) || {}).value || '';
  return { month: get('month'), day: get('day'), hour: get('hour').replace(/^24$/, '00'), minute: get('minute') };
}

/** Short clock for marks and ticks; date only when the window spans days. */
export function clock(ms, { withDate = false, timeZone } = {}) {
  const p = clockParts(ms, timeZone);
  const hm = p.hour + ':' + p.minute;
  return withDate ? p.month + '/' + p.day + ' ' + hm : hm;
}

// ---------------------------------------------------------------- status card

/** Destinations as one list: three cloud folders + ostore, one shape. */
export function destinations(s) {
  const dests = (s && s.destinations && s.destinations.length) ? s.destinations : [
    { id: 'icloud', type: 'icloud', label: 'iCloud Drive', enabled: true, available: !!s?.cloudDocsAvailable, rootPath: s?.cloudDocsPath, hint: s?.cloudDocsAvailable ? null : '请开启 iCloud 云盘' },
    { id: 'gdrive', type: 'gdrive', label: 'Google Drive', enabled: true, available: !!s?.googleDriveAvailable, rootPath: s?.googleDrivePath, hint: s?.googleDriveAvailable ? null : '请安装并登录 Google Drive for Desktop' },
  ];
  const rows = dests.map((d) => {
    const phase = String(d.lastPhase || '');
    const quark = d.type === 'quark' || d.id === 'quark';
    let tone = 'ok';
    let state = '正常';
    if (!d.enabled) { tone = 'off'; state = '已关闭'; }
    else if (!d.available) { tone = 'bad'; state = '未就绪'; }
    else if (d.lastError) { tone = 'bad'; state = '失败'; }
    else if (quark && phase === 'ok:staging_cloud_listed') { tone = 'ok'; state = '云端可见'; }
    else if (quark && phase.startsWith('ok')) { tone = 'warn'; state = '本地暂存'; }
    return {
      id: String(d.id || d.type || d.label),
      kind: 'folder',
      icon: d.type === 'icloud' || d.id === 'icloud' ? 'cloud' : d.type === 'gdrive' || d.id === 'gdrive' ? 'add_to_drive' : quark ? 'cloud_sync' : 'folder',
      label: d.label || d.id,
      enabled: !!d.enabled,
      configured: true,
      tone,
      state,
      lastSuccessUnix: d.lastSuccessUnix ?? null,
      error: d.lastError || null,
      path: d.rootPath || null,
      hint: d.hint || null,
      // 夸克 only stages locally: say it on the row, not only behind a click.
      note: quark && d.hint ? '本地暂存；云端完整性尚未验证' : null,
    };
  });
  rows.push(ostoreDestination(s?.ostore));
  return rows;
}

export function ostoreDestination(os) {
  const configured = !!os?.configured;
  const enabled = configured && os.enabled !== false;
  let tone = 'ok';
  let state = '正常';
  if (!configured) { tone = 'off'; state = '未配置'; }
  else if (!enabled) { tone = 'off'; state = '已关闭'; }
  else if (os.inProgress) { tone = 'busy'; state = '上传中'; }
  else if (os.phase === 'error') { tone = 'bad'; state = '上次失败'; }
  else if (!os.lastSuccessUnix) { tone = 'idle'; state = '等待首次上传'; }
  const total = num(os?.total);
  const done = num(os?.uploaded) + num(os?.skipped) + num(os?.failed);
  return {
    id: 'ostore',
    kind: 'ostore',
    icon: 'dns',
    label: 'ostore 远程冷备',
    enabled,
    configured,
    tone,
    state,
    lastSuccessUnix: os?.lastSuccessUnix ?? null,
    error: os?.phase === 'error' ? (os?.lastError || os?.lastRun?.error || null) : null,
    path: os?.baseURL || null,
    hint: configured ? null : '在数据目录 config/ostore-backup.json 写入 {"baseURL":"https://…","token":"…"} 后重启服务',
    note: null,
    queued: !!os?.queued,
    progress: os?.inProgress && total > 0 ? { done, total } : null,
  };
}

export function overview(s, nowMs = Date.now()) {
  const rows = destinations(s);
  const active = rows.filter((r) => r.enabled);
  const healthy = active.filter((r) => r.tone === 'ok' || r.tone === 'busy').length;
  const attention = active.length - healthy;
  const last = s?.lastSuccessUnix ?? null;
  let tone = 'ok';
  let icon = 'check';
  let title = '已备份';
  if (s?.inProgress) { tone = 'busy'; icon = 'sync'; title = '正在备份'; }
  else if (!active.some((r) => r.kind === 'folder' && r.tone !== 'bad')) { tone = 'bad'; icon = 'cloud_off'; title = '没有可用的备份位置'; }
  else if (s?.lastError) { tone = 'bad'; icon = 'priority_high'; title = '备份需要关注'; }
  else if (last == null && !s?.lastSuccessAt) { tone = 'idle'; icon = 'cloud_upload'; title = '尚无成功备份'; }
  const when = last != null ? relTime(last, nowMs) : null;
  const bits = [];
  bits.push(when ? '上次成功 ' + when : '等待首次成功');
  bits.push(active.length ? healthy + ' / ' + active.length + ' 个位置正常' : '未启用任何位置');
  return { tone, icon, title, detail: bits.join(' · '), attention, error: s?.lastError || null, lastSuccessUnix: last };
}

// ---------------------------------------------------------------- destinations

export function destRowHtml(d, { open = false, nowMs = Date.now(), formatTime = String } = {}) {
  const when = d.lastSuccessUnix != null ? relTime(d.lastSuccessUnix, nowMs) : null;
  const status = [`<span class="bk-state" data-tone="${d.tone}"><i class="bk-dot"></i>${esc(d.state)}</span>`];
  if (d.progress) status.push(`<span class="bk-num">${fmtCount(d.progress.done)} / ${fmtCount(d.progress.total)}</span>`);
  else if (when && d.enabled) status.push(`<span title="${esc(formatTime(d.lastSuccessUnix))}">${esc(when)}</span>`);
  if (d.queued) status.push('<span>已排队下一轮</span>');
  const switchTitle = d.kind === 'ostore' ? '启用 ostore 远程冷备' : '启用 ' + d.label;
  const input = d.kind === 'ostore'
    ? `<input type="checkbox" data-ostore="1"${d.enabled ? ' checked' : ''}${d.configured ? '' : ' disabled'} aria-label="${esc(switchTitle)}"/>`
    : `<input type="checkbox" data-dest="${esc(d.id)}"${d.enabled ? ' checked' : ''} aria-label="${esc(switchTitle)}"/>`;
  const pct = d.progress ? Math.min(100, (d.progress.done * 100) / Math.max(1, d.progress.total)) : null;
  return `<li class="bk-dest${open ? ' is-open' : ''}" data-dest-row="${esc(d.id)}" data-tone="${d.tone}">`
    + `<span class="bk-dest-icon material-symbols-outlined" aria-hidden="true">${esc(d.icon)}</span>`
    + `<button type="button" class="bk-dest-main" data-dest-toggle="${esc(d.id)}" aria-expanded="${open}" aria-controls="bkDestMore-${esc(d.id)}">`
    + `<span class="bk-dest-name">${esc(d.label)}<span class="bk-chevron material-symbols-outlined" aria-hidden="true">chevron_right</span></span>`
    + `<span class="bk-dest-status">${status.join('<span class="bk-sep">·</span>')}</span>`
    + (d.note ? `<span class="bk-dest-note">${esc(d.note)}</span>` : '')
    + `</button>`
    + `<label class="switch" title="${esc(switchTitle)}">${input}<span></span></label>`
    + (pct != null ? `<span class="bk-progress" role="progressbar" aria-label="${esc(d.label)} 本轮进度" aria-valuemin="0" aria-valuemax="${d.progress.total}" aria-valuenow="${d.progress.done}"><span style="width:${pct.toFixed(1)}%"></span></span>` : '')
    + `<div class="bk-dest-more" id="bkDestMore-${esc(d.id)}"${open ? '' : ' hidden'}>`
    + `<dl class="bk-kv"><dt>位置</dt><dd class="bk-path">${esc(d.path || '—')}</dd>`
    + (when ? `<dt>上次成功</dt><dd>${esc(formatTime(d.lastSuccessUnix))}</dd>` : '<dt>上次成功</dt><dd>尚未成功</dd>')
    + (d.error ? `<dt>错误</dt><dd class="bk-err">${esc(d.error)}</dd>` : '')
    + `</dl>`
    + (d.hint ? `<p class="bk-hint">${esc(d.hint)}</p>` : '')
    + (d.kind === 'ostore' ? '<div id="bkOstoreStats" class="bk-ostore"></div>' : '')
    + `</div></li>`;
}

/**
 * ostore object composition: what this run (or, after a restart, the persisted last
 * run) did with every object. Proportional segments, legend in HTML with numbers.
 */
export function ostoreStatsHtml(os, { formatTime = String } = {}) {
  if (!os || !os.configured) {
    return '<p class="bk-hint">未配置：在数据目录 config/ostore-backup.json 写入 {"baseURL":"https://…","token":"…"} 后重启服务。</p>';
  }
  const live = num(os.total) > 0;
  const sample = live ? os : os.lastRun;
  const out = [];
  if (sample && num(sample.total) > 0) {
    const total = num(sample.total);
    const segs = [
      { key: 'uploaded', label: '已上传', value: num(sample.uploaded) },
      { key: 'skipped', label: '已跳过', value: num(sample.skipped), hint: '远端已有相同内容' },
      { key: 'pending', label: '未完成', value: Math.max(0, total - num(sample.uploaded) - num(sample.skipped) - num(sample.failed)) },
      { key: 'failed', label: '失败', value: num(sample.failed) },
    ];
    const title = live && os.inProgress ? '本轮对象' : live ? '本轮对象' : '上次运行对象';
    out.push(`<div class="bk-compose" data-compose>`
      + `<div class="bk-compose-head"><span>${title}</span><span class="bk-num">共 ${fmtCount(total)} 个</span></div>`
      + `<div class="bk-compose-bar" aria-hidden="true">${segs.filter((x) => x.value > 0).map((x) => `<span data-seg="${x.key}" style="flex:${x.value}"></span>`).join('')}</div>`
      + `<ul class="bk-compose-legend">${segs.filter((x) => x.value > 0 || x.key === 'uploaded').map((x) => `<li data-seg-key="${x.key}" tabindex="0"${x.hint ? ` title="${esc(x.hint)}"` : ''}><i data-seg="${x.key}"></i>${x.label}<b class="bk-num">${fmtCount(x.value)}</b><span class="bk-num">${((x.value * 100) / total).toFixed(1)}%</span></li>`).join('')}</ul>`
      + `</div>`);
  }
  const kv = [];
  const row = (k, v) => kv.push(`<dt>${k}</dt><dd>${v}</dd>`);
  if (live || os.inProgress) {
    row('本轮对象', '上传 ' + fmtCount(num(os.uploaded)) + ' · 跳过 ' + fmtCount(num(os.skipped))
      + ' · 未完成 ' + fmtCount(num(os.pending)) + (num(os.failed) ? ' · 失败 ' + fmtCount(num(os.failed)) : '')
      + (live ? ' / 共 ' + fmtCount(num(os.total)) : ''));
    row('本轮字节', fmtBytes(num(os.uploadedBytes)) + ' 上传 · ' + fmtBytes(num(os.skippedBytes)) + ' 跳过');
    const elapsed = os.inProgress && os.startedUnix ? Math.max(0, Date.now() / 1000 - os.startedUnix) : null;
    row('耗时', os.durationSeconds != null ? fmtDur(os.durationSeconds * 1000) : elapsed != null ? '进行中 ' + fmtDur(elapsed * 1000) : '—');
  }
  if (num(os.manifestObjects)) row('本地清单', fmtCount(os.manifestObjects) + ' 对象 · ' + fmtBytes(num(os.manifestBytes)));
  if (num(os.remoteObjects)) row('远端对象', fmtCount(os.remoteObjects) + ' 对象 · ' + fmtBytes(num(os.remoteBytes)));
  const run = os.lastRun;
  if (run) {
    const bits = [
      run.finishedUnix ? formatTime(run.finishedUnix) : '—',
      run.phase === 'ok' ? '成功' : '失败',
      '上传 ' + fmtCount(num(run.uploaded)),
      '跳过 ' + fmtCount(num(run.skipped)),
    ];
    if (num(run.failed)) bits.push('失败 ' + fmtCount(run.failed));
    if (run.durationSeconds != null) bits.push(fmtDur(run.durationSeconds * 1000));
    row('上次运行', bits.map((b) => esc(String(b))).join(' · ') + (run.error ? `<span class="bk-err"> · ${esc(run.error)}</span>` : ''));
  }
  if (kv.length) out.push(`<dl class="bk-kv">${kv.join('')}</dl>`);
  return out.join('');
}

// ---------------------------------------------------------------- history

export function runLabel(run) {
  if (run.lane === 'ostore') return run.persisted ? 'ostore 上传（留存的上次运行）' : 'ostore 上传';
  if (run.kind === 'manual') return '手动本机备份';
  if (run.kind === 'safety') return '恢复前安全备份';
  return '自动本机备份';
}

/**
 * Real runs in the window, oldest first.
 * - `backup_cycle` carries manual runs (with older history); the newer
 *   `backup_local_run{kind:manual}` duplicate is dropped.
 * - Before per-run ostore metrics existed only the last run was persisted; it is
 *   added once (when no metric sits within 5 s of it), never extrapolated.
 * - The finished run that matches `ostore.lastRun` inherits its error text.
 */
export function historyRuns(datasets, ostore, fromMs) {
  const events = [];
  for (const ev of datasets.flat()) {
    if (!ev || !Number.isFinite(ev.ts) || !Number.isFinite(ev.dur_ms) || ev.dur_ms < 0) continue;
    if (ev.name === 'backup_local_run' && ev.payload?.kind === 'manual') continue;
    if (ev.ts < fromMs) continue;
    const lane = ev.name === 'backup_ostore_run' ? 'ostore' : 'local';
    events.push({
      lane,
      kind: ev.name === 'backup_cycle' ? 'manual' : ev.payload?.kind || (lane === 'ostore' ? 'ostore' : 'automatic'),
      ts: ev.ts,
      durMs: ev.dur_ms,
      ok: ev.ok === true ? true : ev.ok === false ? false : null,
      payload: ev.payload || null,
      persisted: false,
      error: null,
    });
  }
  const last = ostore?.lastRun;
  if (last && Number.isFinite(last.finishedUnix)) {
    const at = last.finishedUnix * 1000;
    const twin = events.find((e) => e.lane === 'ostore' && Math.abs(e.ts - at) < 5000);
    if (twin) twin.error = last.error || null;
    else if (Number.isFinite(last.durationSeconds) && at >= fromMs) {
      events.push({
        lane: 'ostore', kind: 'ostore', ts: at, durMs: last.durationSeconds * 1000,
        ok: last.phase === 'ok', persisted: true, error: last.error || null,
        payload: { applied: last.uploaded, reused: last.skipped, bytes: last.uploadedBytes, miss: last.failed, n: last.total },
      });
    }
  }
  return events.sort((a, b) => a.ts - b.ts);
}

export function laneStats(runs) {
  const n = runs.length;
  const fails = runs.filter((r) => r.ok === false).length;
  const durs = runs.map((r) => r.durMs).sort((a, b) => a - b);
  const p50 = n ? durs[Math.floor((n - 1) / 2)] : null;
  return { n, fails, p50, max: n ? durs[n - 1] : null };
}

export function describeRun(run, { timeZone, withDate = true } = {}) {
  const result = run.ok === true ? '成功' : run.ok === false ? '失败' : '结果未知';
  const bits = [runLabel(run), clock(run.ts, { withDate, timeZone }), result, '耗时 ' + fmtDur(run.durMs)];
  if (run.lane === 'ostore' && run.payload) {
    bits.push('上传 ' + fmtCount(run.payload.applied ?? null) + ' · 跳过 ' + fmtCount(run.payload.reused ?? null)
      + ' · ' + (run.payload.bytes != null ? fmtBytes(run.payload.bytes) : '—'));
  }
  return bits.join(' · ');
}

/**
 * Tick marks on the display clock: every 6 h for a day, every midnight for a week.
 * Walks whole hours (UTC hour edges are local hour edges for whole-hour zones) and
 * asks the display time zone which of them are boundaries.
 */
export function axisTicks(fromMs, toMs, { days = 1, timeZone } = {}) {
  const ticks = [];
  for (let t = Math.ceil(fromMs / 3600000) * 3600000; t < toMs; t += 3600000) {
    const q = clockParts(t, timeZone);
    const h = Number(q.hour);
    if (days > 1 ? h !== 0 : h % 6 !== 0) continue;
    const x = (t - fromMs) / (toMs - fromMs);
    if (x < 0.08 || x > 0.88) continue; // keep clear of the edge labels
    ticks.push({ x, label: days > 1 ? q.month + '/' + q.day : q.hour + ':00' });
  }
  return ticks;
}

const LANES = [
  { key: 'local', label: '本机' },
  { key: 'ostore', label: 'ostore' },
];

/**
 * The history chart. Marks sit at their real time; height = duration on a per-lane
 * scale (lanes differ by ~100x). A running ostore upload is a live band from its
 * start to now. Returns HTML plus the ordered run list the scrub indexes into.
 */
export function historyHtml(runs, { fromMs, toMs, days = 1, live = null, pin = null, timeZone } = {}) {
  const span = Math.max(1, toMs - fromMs);
  const xOf = (ms) => Math.min(100, Math.max(0, ((ms - fromMs) / span) * 100));
  const facts = [];
  const lanes = LANES.map((lane) => {
    const list = runs.map((r, i) => ({ r, i })).filter(({ r }) => r.lane === lane.key);
    const st = laneStats(list.map(({ r }) => r));
    const max = Math.max(1, st.max || 1);
    facts.push(`<span class="bkh-fact" data-mark="${lane.key}" tabindex="0"><span>${lane.label}</span><b class="bk-num">${fmtCount(st.n)} 次</b>`
      + (st.n ? `<span class="bk-num">中位 ${esc(fmtDur(st.p50))}</span>` : '')
      + (st.fails ? `</span><span class="bkh-fact is-fail" data-mark="fail-${lane.key}" tabindex="0"><b class="bk-num">${fmtCount(st.fails)} 次失败</b>` : '')
      + `</span>`);
    const marks = list.map(({ r, i }) => {
      const h = Math.round(4 + (r.durMs / max) * 28);
      const state = r.ok === true ? 'ok' : r.ok === false ? 'fail' : 'unknown';
      return `<i class="bkh-mark${pin === i ? ' is-pin' : ''}${r.persisted ? ' is-persisted' : ''}" data-i="${i}" data-state="${state}" style="left:${xOf(r.ts).toFixed(3)}%;height:${h}px"></i>`;
    }).join('');
    const band = lane.key === 'ostore' && live && Number.isFinite(live.startMs)
      ? `<i class="bkh-live" style="left:${xOf(live.startMs).toFixed(3)}%;width:${Math.max(0.6, xOf(toMs) - xOf(live.startMs)).toFixed(3)}%" title="ostore 正在上传"></i>`
      : '';
    const empty = !list.length && !band ? '<span class="bkh-empty">此时间范围暂无运行</span>' : '';
    return `<div class="bkh-lane" data-lane="${lane.key}"><span class="bkh-lane-label">${lane.label}</span>`
      + `<div class="bkh-track">${band}${marks}${empty}</div></div>`;
  });
  const ticks = axisTicks(fromMs, toMs, { days, timeZone }).map((t) => `<span style="left:${(t.x * 100).toFixed(2)}%">${esc(t.label)}</span>`).join('');
  const start = days > 1 ? days + ' 天前' : '24 小时前';
  const valueText = pin != null && runs[pin] ? describeRun(runs[pin], { timeZone }) : '无运行记录';
  return `<div class="bkh-facts"><div class="bkh-facts-list">${facts.join('')}</div><div class="bkh-readout" aria-hidden="true"></div></div>`
    + `<div class="bkh-plot" role="slider" tabindex="0" aria-label="备份运行记录，左右键逐次查看" aria-valuemin="0" aria-valuemax="${Math.max(0, runs.length - 1)}" aria-valuenow="${pin ?? 0}" aria-valuetext="${esc(valueText)}">`
    + lanes.join('')
    + `<i class="bkh-guide" aria-hidden="true"></i></div>`
    + `<div class="bkh-axis" aria-hidden="true"><span class="is-edge">${start}</span>${ticks}<span class="is-edge is-now">现在</span></div>`;
}

export function runDetailHtml(run, { timeZone } = {}) {
  if (!run) return '<p class="bk-hint">此时间范围暂无运行记录。</p>';
  const state = run.ok === true ? 'ok' : run.ok === false ? 'bad' : 'off';
  const result = run.ok === true ? '成功' : run.ok === false ? '失败' : '结果未知';
  const kv = [`<dt>耗时</dt><dd>${esc(fmtDur(run.durMs))}</dd>`];
  if (run.lane === 'ostore' && run.payload) {
    kv.push(`<dt>上传</dt><dd>${fmtCount(run.payload.applied ?? null)} 个 · ${run.payload.bytes != null ? fmtBytes(run.payload.bytes) : '—'}</dd>`);
    kv.push(`<dt>跳过</dt><dd>${fmtCount(run.payload.reused ?? null)} 个（远端已有）</dd>`);
    if (num(run.payload.miss)) kv.push(`<dt>失败对象</dt><dd>${fmtCount(run.payload.miss)} 个</dd>`);
  }
  if (run.error) kv.push(`<dt>错误</dt><dd class="bk-err">${esc(run.error)}</dd>`);
  return `<div class="bkh-detail-head"><span class="bk-state" data-tone="${state}"><i class="bk-dot"></i>${result}</span>`
    + `<b>${esc(runLabel(run))}</b><time class="bk-num">${esc(clock(run.ts, { withDate: true, timeZone }))}</time></div>`
    + `<dl class="bk-kv">${kv.join('')}</dl>`;
}

// ---------------------------------------------------------------- restore + diagnostics

export function restorePoints(s) {
  const list = [];
  if (s?.latest) list.push(s.latest);
  (s?.snapshots || []).forEach((x) => list.push(x));
  return list;
}

export function snapshotsHtml(s, { nowMs = Date.now(), formatTime = String } = {}) {
  const list = restorePoints(s);
  if (!list.length) return '<li class="bk-snap is-empty">暂无可恢复的时间点。开启自动备份或点「立即备份」。</li>';
  return list.map((snap) => {
    const at = snap.createdAtUnix ?? snap.createdAt ?? null;
    const origin = snap.origin === 'peer' ? '其他机器' : snap.origin === 'legacy' ? '旧共享 latest' : snap.isLatest ? '本机最新' : '本机快照';
    const title = snap.origin === 'peer' ? (snap.host || snap.id) : snap.isLatest ? '最新备份' : (typeof at === 'number' ? formatTime(at) : snap.id);
    const when = typeof at === 'number' ? relTime(at, nowMs) : at ? formatTime(at) : '';
    const meta = [origin, snap.host && snap.origin !== 'self' ? snap.host : null, when, fmtBytes(snap.byteSize), snap.itemCount != null ? fmtCount(snap.itemCount) + ' 条' : null].filter(Boolean);
    return `<li class="bk-snap" title="${esc(snap.id)}${snap.sha256 ? ' · sha256 ' + esc(String(snap.sha256).slice(0, 16)) + '…' : ''}">`
      + `<span class="bk-snap-icon material-symbols-outlined" aria-hidden="true">${snap.isLatest ? 'history' : snap.origin === 'peer' ? 'devices' : 'schedule'}</span>`
      + `<span class="bk-snap-main"><b>${esc(title)}</b><span class="bk-num">${meta.map(esc).join(' · ')}</span></span>`
      + `<button type="button" class="bk-tinted" data-restore="${esc(snap.id)}">恢复</button></li>`;
  }).join('');
}

export function quarkSummary(qd) {
  if (!qd || !(qd.appInstalled || qd.stagingPath)) return null;
  const bits = [];
  if (qd.appInstalled) bits.push('客户端已装');
  if (qd.stagingHasArtifact) bits.push('本机制品就绪');
  if (qd.cloudListedClipVaultBackups) bits.push('云端列表可见 ClipVault-Backups');
  else bits.push('云端列表未见（仍只算本机暂存）');
  if (qd.accountConfigFound && !qd.anyCategoryBackupEnabled) bits.push('电脑备份分类均为关');
  return bits.join(' · ') + (qd.stagingPath ? ' · ' + qd.stagingPath : '');
}

export function diagnosticsHtml(s, { formatTime = String } = {}) {
  let phase = s?.lastPhase || '—';
  if (s?.inProgress) phase = '进行中 · ' + phase;
  if (s?.dirty) phase += ' · dirty';
  const snaps = (s?.snapshotCount != null ? s.snapshotCount : (s?.snapshots || []).length)
    + ' / keep ' + (s?.config && s.config.keepSnapshots != null ? s.config.keepSnapshots : '—');
  const last = s?.lastSuccessUnix != null ? formatTime(s.lastSuccessUnix) : s?.lastSuccessAt ? formatTime(s.lastSuccessAt) : '尚未成功';
  const lastSnap = s?.lastSnapshotUnix != null ? formatTime(s.lastSnapshotUnix) : s?.lastSnapshotAt ? formatTime(s.lastSnapshotAt) : '—';
  const quark = quarkSummary(s?.quarkDiscovery);
  const rows = [
    ['策略', 'bkPolicy', s?.policy || '—'],
    ['历史快照', 'bkSnapCount', snaps],
    ['上次历史快照', 'bkLastSnap', lastSnap],
    ['主目录', 'bkRoot', (s?.hostId ? s.hostId + ' · ' : '') + (s?.backupRootPath || '—')],
    ['上次成功', 'bkLast', last],
    quark ? ['夸克状态', 'bkQuarkDiscover', quark] : null,
    ['状态', 'bkPhase', phase],
    ['错误', 'bkErr', s?.lastError || '—'],
  ].filter(Boolean);
  return rows.map(([k, id, v]) => `<dt>${k}</dt><dd id="${id}">${esc(v)}</dd>`).join('');
}

// ---------------------------------------------------------------- mount

const SHELL = `
<section class="bk-card bk-hero" aria-label="备份概览" data-tone="idle">
  <div class="bk-hero-top">
    <span class="bk-hero-icon material-symbols-outlined" id="bkHeroIcon" aria-hidden="true">cloud_upload</span>
    <div class="bk-hero-text">
      <h3 id="bkOverviewTitle">正在读取备份状态…</h3>
      <p id="bkOverviewDetail">请稍候</p>
    </div>
  </div>
  <p class="bk-hero-error" id="bkOverviewError" hidden></p>
  <div class="bk-hero-actions">
    <button type="button" class="bk-primary" id="bkRunNow"><span class="material-symbols-outlined" aria-hidden="true">backup</span><span>立即备份</span></button>
    <span class="bk-action-status" id="bkActionStatus" role="status" aria-live="polite"></span>
    <label class="bk-auto"><span>自动备份</span><span class="switch" title="自动备份"><input type="checkbox" id="backupEnabled" aria-label="启用自动备份"/><span></span></span></label>
  </div>
</section>

<div class="bk-section-head"><h3>运行记录</h3>
  <div class="bk-segmented" role="radiogroup" aria-label="时间范围">
    ${WINDOWS.map((w, i) => `<button type="button" role="radio" data-history-days="${w.days}" aria-checked="${i === 0}">${w.label}</button>`).join('')}
  </div>
</div>
<section class="bk-card bkh" id="bkHistory" aria-label="备份运行记录">
  <div id="bkHistoryChart" class="bkh-chart"><p class="bk-hint">正在读取历史…</p></div>
  <div class="bkh-detail" id="bkHistoryDetail" aria-live="polite"></div>
</section>
<p class="bk-foot" id="bkHistoryCoverage"></p>

<div class="bk-section-head"><h3>备份位置</h3><span class="bk-section-aside" id="bkDestSummary"></span></div>
<ul class="bk-card bk-list" id="bkDestList"></ul>

<div class="bk-section-head"><h3>恢复</h3><span class="bk-section-aside">恢复前会自动再备份一份</span></div>
<ul class="bk-card bk-list" id="bkSnaps"></ul>

<details class="bk-diag"><summary>诊断信息</summary><dl class="bk-kv" id="bkDiag"></dl></details>
`;

/**
 * @param {{
 *   root: HTMLElement,
 *   api?: string,
 *   fetch?: typeof fetch,
 *   toast?: (msg: string) => void,
 *   confirm?: (msg: string) => boolean,
 *   formatTime?: (unix: number|string) => string,
 *   timeZone?: () => string|undefined,
 *   refreshStatus: () => Promise<void>|void,
 *   onRestored?: () => Promise<void>|void,
 *   now?: () => number,
 * }} opts
 */
export function mountBackupPanel(opts) {
  const root = opts.root;
  const doc = root.ownerDocument;
  const win = doc.defaultView;
  const api = opts.api || '';
  const http = opts.fetch || ((...a) => win.fetch(...a));
  const toast = opts.toast || (() => {});
  const ask = opts.confirm || ((m) => win.confirm(m));
  const formatTime = opts.formatTime || ((v) => String(v));
  const tz = () => (opts.timeZone ? opts.timeZone() : undefined);
  const now = opts.now || (() => Date.now());

  root.innerHTML = SHELL;
  const $ = (id) => root.querySelector('#' + id);
  const openRows = new Set();
  const painted = { dest: '', snaps: '', diag: '' };
  let status = null;
  let historyMarker = null;
  let days = 1;
  let runs = [];
  let pin = null;
  let historyReq = 0;
  let window_ = { fromMs: 0, toMs: 1 };
  let tick = 0;
  let running = false;

  // ---- status (SSE-driven; paint is cheap and idempotent)
  function paint(s) {
    status = s;
    const t = now();
    const ov = overview(s, t);
    const hero = root.querySelector('.bk-hero');
    hero.dataset.tone = running ? 'busy' : ov.tone;
    $('bkHeroIcon').textContent = running ? 'sync' : ov.icon;
    $('bkOverviewTitle').textContent = running ? '正在备份' : ov.title;
    const detail = $('bkOverviewDetail');
    detail.textContent = ov.detail;
    detail.title = ov.lastSuccessUnix != null ? '上次成功 ' + formatTime(ov.lastSuccessUnix) : '';
    const err = $('bkOverviewError');
    err.hidden = !ov.error;
    err.textContent = ov.error || '';
    const auto = $('backupEnabled');
    if (!auto.disabled) auto.checked = !!s.enabled;

    const rows = destinations(s);
    const active = rows.filter((r) => r.enabled).length;
    $('bkDestSummary').textContent = active + ' / ' + rows.length + ' 已启用';
    const destHtml = rows.map((d) => destRowHtml(d, { open: openRows.has(d.id), nowMs: t, formatTime })).join('');
    const list = $('bkDestList');
    if (destHtml !== painted.dest) {
      // Keep keyboard focus on the same control across a progress ping.
      const focus = doc.activeElement && list.contains(doc.activeElement)
        ? (doc.activeElement.dataset.destToggle ? `[data-dest-toggle="${doc.activeElement.dataset.destToggle}"]` : null)
        : null;
      list.innerHTML = destHtml;
      painted.dest = destHtml;
      if (focus) list.querySelector(focus)?.focus();
    }
    const stats = $('bkOstoreStats');
    if (stats) {
      const html = ostoreStatsHtml(s.ostore, { formatTime });
      if (stats.innerHTML !== html) stats.innerHTML = html;
    }

    const snapHtml = snapshotsHtml(s, { nowMs: t, formatTime });
    if (snapHtml !== painted.snaps) { $('bkSnaps').innerHTML = snapHtml; painted.snaps = snapHtml; }
    const diagHtml = diagnosticsHtml(s, { formatTime });
    if (diagHtml !== painted.diag) { $('bkDiag').innerHTML = diagHtml; painted.diag = diagHtml; }

    const os = s.ostore;
    const marker = String(s.lastSuccessUnix || '') + ':' + String(os?.lastRun?.finishedUnix || '') + ':' + String(os?.phase || '') + ':' + String(!!os?.inProgress);
    if (historyMarker !== null && marker !== historyMarker) refreshHistory();
    historyMarker = marker;
  }

  // ---- history
  async function refreshHistory() {
    const req = ++historyReq;
    const toMs = now();
    const fromMs = toMs - days * 86400000;
    const coverage = $('bkHistoryCoverage');
    try {
      const responses = await Promise.all(HISTORY_METRICS.map((name) =>
        http(api + '/api/ui-metrics/recent?name=' + name + '&limit=' + HISTORY_LIMIT + '&from=' + fromMs)));
      if (responses.some((r) => !r.ok)) throw new Error('metrics');
      const datasets = await Promise.all(responses.map((r) => r.json()));
      if (datasets.some((d) => !d || d.ok === false || !Array.isArray(d.events))) throw new Error('metrics');
      if (req !== historyReq) return;
      runs = historyRuns(datasets.map((d) => d.events), status?.ostore, fromMs);
      window_ = { fromMs, toMs };
      pin = runs.length ? runs.length - 1 : null;
      const limited = datasets.some((d) => d.events.length >= HISTORY_LIMIT);
      coverage.textContent = (limited ? '每类最多显示最近 ' + HISTORY_LIMIT + ' 次，更早的可能未显示。' : '')
        + '高度 = 耗时，两行各自刻度。手动备份含既有历史；自动备份与 ostore 逐轮记录从新版本开始，ostore 另含此前留存的最后一轮。';
      drawHistory();
    } catch (_) {
      if (req !== historyReq) return;
      $('bkHistoryChart').innerHTML = '<p class="bk-hint">历史记录读取失败，稍后会随状态更新重试。</p>';
      $('bkHistoryDetail').innerHTML = '';
    }
  }

  function drawHistory() {
    const os = status?.ostore;
    const live = os?.inProgress && os.startedUnix ? { startMs: os.startedUnix * 1000 } : null;
    $('bkHistoryChart').innerHTML = historyHtml(runs, { ...window_, days, live, pin, timeZone: tz() });
    showDetail(pin);
  }

  function showDetail(i) {
    $('bkHistoryDetail').innerHTML = runDetailHtml(i != null ? runs[i] : null, { timeZone: tz() });
  }

  function setPin(i) {
    pin = i;
    const chart = $('bkHistoryChart');
    chart.querySelectorAll('.bkh-mark.is-pin').forEach((m) => m.classList.remove('is-pin'));
    if (i != null) chart.querySelector(`.bkh-mark[data-i="${i}"]`)?.classList.add('is-pin');
    const plot = chart.querySelector('.bkh-plot');
    if (plot && i != null && runs[i]) {
      plot.setAttribute('aria-valuenow', String(i));
      plot.setAttribute('aria-valuetext', describeRun(runs[i], { timeZone: tz() }));
    }
    showDetail(i);
  }

  /** Pointer → nearest run (px), within SNAP_PX. Crosshair follows the pointer 1:1. */
  function scrubAt(clientX) {
    const chart = $('bkHistoryChart');
    const plot = chart.querySelector('.bkh-plot');
    const track = chart.querySelector('.bkh-track');
    if (!plot || !track) return;
    const tr = track.getBoundingClientRect();
    const pr = plot.getBoundingClientRect();
    const x = Math.min(tr.width, Math.max(0, clientX - tr.left));
    const ms = window_.fromMs + (x / Math.max(1, tr.width)) * (window_.toMs - window_.fromMs);
    let best = null;
    let bestPx = SNAP_PX + 1;
    runs.forEach((r, i) => {
      const px = Math.abs(((r.ts - window_.fromMs) / (window_.toMs - window_.fromMs)) * tr.width - x);
      if (px < bestPx) { bestPx = px; best = i; }
    });
    chart.classList.add('is-scrub');
    const guide = chart.querySelector('.bkh-guide');
    if (guide) guide.style.transform = `translateX(${(tr.left - pr.left + x).toFixed(1)}px)`;
    chart.querySelectorAll('.bkh-mark.is-cursor').forEach((m) => m.classList.remove('is-cursor'));
    const readout = chart.querySelector('.bkh-readout');
    let text = clock(ms, { withDate: days > 1, timeZone: tz() }) + ' · 无运行';
    if (best != null) {
      chart.querySelector(`.bkh-mark[data-i="${best}"]`)?.classList.add('is-cursor');
      text = describeRun(runs[best], { timeZone: tz(), withDate: days > 1 });
    }
    chart.dataset.cursor = best == null ? '' : String(best);
    if (readout) {
      readout.textContent = text;
      const w = readout.offsetWidth || 0;
      const left = Math.min(Math.max(0, tr.left - pr.left + x - w / 2), Math.max(0, pr.width - w));
      readout.style.transform = `translateX(${left.toFixed(1)}px)`;
    }
  }

  function endScrub() {
    const chart = $('bkHistoryChart');
    chart.classList.remove('is-scrub');
    chart.dataset.cursor = '';
    chart.querySelectorAll('.bkh-mark.is-cursor').forEach((m) => m.classList.remove('is-cursor'));
  }

  const chartEl = $('bkHistoryChart');
  chartEl.addEventListener('pointermove', (e) => {
    if (e.target.closest?.('.bkh-plot')) scrubAt(e.clientX);
    else endScrub();
  });
  chartEl.addEventListener('pointerleave', endScrub);
  chartEl.addEventListener('click', (e) => {
    if (!e.target.closest?.('.bkh-plot')) return;
    const i = chartEl.dataset.cursor;
    if (i !== '' && i != null) setPin(Number(i));
  });
  chartEl.addEventListener('keydown', (e) => {
    if (!e.target.classList?.contains('bkh-plot') || !runs.length) return;
    let next = pin ?? runs.length - 1;
    if (e.key === 'ArrowLeft') next = Math.max(0, next - 1);
    else if (e.key === 'ArrowRight') next = Math.min(runs.length - 1, next + 1);
    else if (e.key === 'Home') next = 0;
    else if (e.key === 'End' || e.key === 'Escape') next = runs.length - 1;
    else return;
    e.preventDefault();
    setPin(next);
  });
  // Fact hover: highlight the marks the number counts.
  const markOn = (e) => {
    const f = e.target.closest?.('[data-mark]');
    if (f) chartEl.dataset.mark = f.dataset.mark;
  };
  const markOff = (e) => {
    if (e.target.closest?.('[data-mark]')) chartEl.dataset.mark = '';
  };
  chartEl.addEventListener('pointerover', markOn);
  chartEl.addEventListener('pointerout', markOff);
  chartEl.addEventListener('focusin', markOn);
  chartEl.addEventListener('focusout', markOff);

  root.querySelectorAll('[data-history-days]').forEach((b) => b.addEventListener('click', () => {
    days = Number(b.dataset.historyDays) || 1;
    root.querySelectorAll('[data-history-days]').forEach((x) => x.setAttribute('aria-checked', String(x === b)));
    refreshHistory();
  }));

  // ---- destinations: expand in place, switches write config
  const destList = $('bkDestList');
  destList.addEventListener('click', (e) => {
    const t = e.target.closest?.('[data-dest-toggle]');
    if (!t) return;
    const id = t.dataset.destToggle;
    const open = !openRows.has(id);
    if (open) openRows.add(id); else openRows.delete(id);
    const li = t.closest('.bk-dest');
    li.classList.toggle('is-open', open);
    t.setAttribute('aria-expanded', String(open));
    const more = li.querySelector('.bk-dest-more');
    if (more) more.hidden = !open;
    // Cached HTML must match the DOM, or the next ping would undo the click.
    painted.dest = '';
  });
  destList.addEventListener('change', async (e) => {
    const input = e.target;
    if (!input.matches?.('input[data-dest], input[data-ostore]')) return;
    const on = input.checked;
    const ostore = input.hasAttribute('data-ostore');
    const id = input.getAttribute('data-dest');
    const label = ostore ? 'ostore 远程冷备' : (destinations(status).find((d) => d.id === id)?.label || id);
    input.disabled = true;
    try {
      const res = await http(api + '/api/backup/config', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(ostore ? { ostoreEnabled: on } : { destinationId: id, destinationEnabled: on }),
      });
      const result = await res.json();
      if (!res.ok || result.ok === false) throw new Error(result.message || '设置未保存');
      toast((on ? '已启用 ' : '已关闭 ') + label);
    } catch (error) {
      input.checked = !on;
      toast('设置失败：' + (error.message || '请重试'));
    } finally {
      input.disabled = false;
      painted.dest = '';
      opts.refreshStatus();
    }
  });
  // Composition legend: hover/focus a number → its segment stands out.
  const segOn = (e) => {
    const li = e.target.closest?.('[data-seg-key]');
    const box = li?.closest('[data-compose]');
    if (box) box.dataset.focus = li.dataset.segKey;
  };
  const segOff = (e) => {
    const box = e.target.closest?.('[data-compose]');
    if (box) box.dataset.focus = '';
  };
  destList.addEventListener('pointerover', segOn);
  destList.addEventListener('pointerout', segOff);
  destList.addEventListener('focusin', segOn);
  destList.addEventListener('focusout', segOff);

  // ---- auto switch + run now
  $('backupEnabled').addEventListener('change', async (e) => {
    const input = e.target;
    const enabled = input.checked;
    input.disabled = true;
    try {
      const res = await http(api + '/api/backup/config', {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ enabled }),
      });
      const result = await res.json();
      if (!res.ok || result.ok === false) throw new Error(result.message || '设置未保存');
      toast(enabled ? '已开启自动备份' : '已关闭自动备份');
    } catch (error) {
      input.checked = !enabled;
      toast('设置失败：' + (error.message || '请重试'));
    } finally {
      input.disabled = false;
      opts.refreshStatus();
    }
  });

  $('bkRunNow').addEventListener('click', async (e) => {
    const button = e.currentTarget;
    const note = $('bkActionStatus');
    const label = button.querySelector('span:last-child');
    running = true;
    button.disabled = true;
    label.textContent = '备份中…';
    note.textContent = '';
    if (status) paint(status);
    const t0 = now();
    try {
      const r = await http(api + '/api/backup/run', { method: 'POST' });
      const j = await r.json();
      if (!r.ok || !j.ok) throw new Error(j.message || '备份失败');
      note.dataset.tone = 'ok';
      note.textContent = '完成 · ' + fmtDur(now() - t0);
      toast(j.message || '本机备份完成');
    } catch (error) {
      note.dataset.tone = 'bad';
      note.textContent = '失败：' + (error.message || '请重试');
      toast(note.textContent);
    } finally {
      running = false;
      button.disabled = false;
      label.textContent = '立即备份';
      await opts.refreshStatus();
      refreshHistory();
    }
  });

  // ---- restore
  $('bkSnaps').addEventListener('click', async (e) => {
    const b = e.target.closest?.('[data-restore]');
    if (!b) return;
    const id = b.getAttribute('data-restore');
    if (!ask('从这个时间点恢复将替换当前数据库。\n恢复前会自动再备份一份安全快照。\n\n确认恢复：' + id + ' ?')) return;
    b.disabled = true;
    try {
      const r = await http(api + '/api/backup/restore', {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ id }),
      });
      const j = await r.json();
      toast(j.message || (j.ok ? '恢复完成' : '恢复失败'));
      if (j.ok && opts.onRestored) await opts.onRestored();
    } catch (error) {
      toast('恢复失败：' + (error.message || '请重试'));
    } finally {
      b.disabled = false;
      opts.refreshStatus();
    }
  });

  return {
    paint,
    refreshHistory,
    /** Drawer opened: fresh history, and a local tick that re-words "N 分钟前". */
    open() {
      refreshHistory();
      if (!tick) tick = win.setInterval(() => { if (status) { painted.dest = ''; painted.snaps = ''; paint(status); } }, 30000);
    },
    close() {
      if (tick) { win.clearInterval(tick); tick = 0; }
      endScrub();
    },
    get runs() { return runs; },
  };
}
