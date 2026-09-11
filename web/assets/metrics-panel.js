/* ClipVault metrics workspace. Local ui-metrics only. No note/session bodies. */
(function () {
  const SLOW = 80;
  const CLS = 80;

  function esc(s) {
    return String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }
  function prefixOf(family) {
    return family === 'sessions' ? 'trae_sessions_' : 'notes_';
  }
  function inFamily(name, family) {
    const n = String(name || '');
    if (family === 'sessions') return n.startsWith('trae_sessions_');
    return n.startsWith('notes_');
  }
  function isSlow(ev) {
    const name = ev && ev.name || '';
    const dur = Number(ev && ev.dur_ms);
    if (/_cls$/.test(name) || name === 'chrome_shift') return Number.isFinite(dur) && dur >= CLS;
    if (name === 'trae_sessions_error') return true;
    if (name === 'trae_sessions_skip' && ev && ev.ok === false) return true;
    if (name === 'notes_longtask' || name === 'trae_sessions_longtask') return Number.isFinite(dur) && dur >= 50;
    return Number.isFinite(dur) && dur >= SLOW;
  }
  function round(n) {
    if (n == null || !Number.isFinite(n)) return '—';
    return String(Math.round(n));
  }
  function pct(vals, p) {
    if (!vals.length) return null;
    const s = vals.slice().sort((a, b) => a - b);
    const i = Math.min(s.length - 1, Math.max(0, Math.ceil((p / 100) * s.length) - 1));
    return s[i];
  }
  function aggregate(rows) {
    const map = new Map();
    for (const ev of rows) {
      const name = ev && ev.name;
      if (!name) continue;
      let a = map.get(name);
      if (!a) a = { name, n: 0, sum: 0, durN: 0, max: 0, last: null, durs: [], slow: 0 };
      a.n += 1;
      a.last = ev;
      if (ev.dur_ms != null && Number.isFinite(ev.dur_ms)) {
        a.sum += ev.dur_ms;
        a.durN += 1;
        a.durs.push(ev.dur_ms);
        if (ev.dur_ms > a.max) a.max = ev.dur_ms;
      }
      if (isSlow(ev)) a.slow += 1;
      map.set(name, a);
    }
    for (const a of map.values()) {
      a.avg = a.durN ? a.sum / a.durN : null;
      a.p95 = pct(a.durs, 95);
    }
    return map;
  }
  function countField(rows, name, key) {
    const out = new Map();
    for (const ev of rows) {
      if (!ev || ev.name !== name || !ev.payload) continue;
      const v = ev.payload[key];
      if (v == null || v === '') continue;
      const k = String(v);
      out.set(k, (out.get(k) || 0) + 1);
    }
    return [...out.entries()].sort((a, b) => b[1] - a[1]);
  }
  function lastPayload(rows, name) {
    for (let i = rows.length - 1; i >= 0; i--) {
      if (rows[i] && rows[i].name === name && rows[i].payload) return rows[i].payload;
    }
    return {};
  }
  function diagnose(family, rows, byName) {
    const items = [];
    if (family === 'notes') {
      const prev = byName.get('notes_preview_ms');
      const compile = byName.get('notes_md_compile');
      if (prev && prev.max >= SLOW) {
        const share = compile && prev.max ? compile.max / prev.max : null;
        items.push({
          level: 'slow',
          name: 'notes_preview_ms',
          title: '预览最慢 ' + round(prev.max) + 'ms（阈值 80）',
          why: share != null && share >= 0.55
            ? 'notes_md_compile 占大头。看复用比；命中低就是整篇重编。'
            : 'paint 占大头。查 React 块数 / highlight，不要先改 marked。',
        });
      }
      const p = lastPayload(rows, 'notes_md_compile');
      const compiled = Number(p.compiled);
      const reused = Number(p.reused);
      const total = (Number.isFinite(compiled) ? compiled : 0) + (Number.isFinite(reused) ? reused : 0);
      if (total >= 4 && reused / total < 0.25) {
        items.push({
          level: 'warn',
          name: 'notes_md_compile',
          title: '编译复用 ' + reused + '/' + total,
          why: 'LRU 几乎不命中。先确认是真改了块，还是 hash 失效。',
        });
      }
      const cls = byName.get('notes_cls');
      if (cls && cls.max >= CLS) {
        items.push({
          level: 'slow',
          name: 'notes_cls',
          title: '笔记 CLS ' + (cls.last && cls.last.payload && cls.last.payload.kind ? cls.last.payload.kind : round(cls.max) + 'ms'),
          why: '看 payload.phase=morph|live 和 kind。未对照同 name 不得称丝滑。',
        });
      }
      const lt = byName.get('notes_longtask');
      if (lt && lt.max >= 50) {
        items.push({
          level: 'warn',
          name: 'notes_longtask',
          title: '输入路径 longtask ' + round(lt.max) + 'ms',
          why: '对照 notes_inp / notes_preview_ms。先补归因再改。',
        });
      }
    }
    if (family === 'sessions') {
      const skip = byName.get('trae_sessions_skip');
      const paint = byName.get('trae_sessions_paint');
      const reasons = countField(rows, 'trae_sessions_skip', 'reason');
      const topReason = reasons[0] ? reasons[0][0] + ' ×' + reasons[0][1] : '';
      if (skip && skip.n && (!paint || skip.n >= Math.max(1, paint.n))) {
        items.push({
          level: 'slow',
          name: 'trae_sessions_skip',
          title: 'skip ' + skip.n + ' 次' + (paint ? ' / paint ' + paint.n : ' / 无 paint'),
          why: '白屏看 skip.reason' + (topReason ? '（' + topReason + '）' : '') + '，不要先改气泡 CSS。',
        });
      }
      if (paint && paint.max >= SLOW) {
        const kinds = countField(rows, 'trae_sessions_paint', 'kind');
        items.push({
          level: 'slow',
          name: 'trae_sessions_paint',
          title: 'paint 最慢 ' + round(paint.max) + 'ms',
          why: 'kind=' + (kinds[0] ? kinds[0][0] : '?') + '。append 仍慢就查 markdown 块；full 慢就查整页调和。',
        });
      }
      const md = byName.get('trae_sessions_md');
      if (md && paint && paint.max >= 40 && md.max / Math.max(paint.max, 1) >= 0.5) {
        items.push({
          level: 'warn',
          name: 'trae_sessions_md',
          title: 'markdown ' + round(md.max) + 'ms / paint ' + round(paint.max) + 'ms',
          why: '渲染 md 占 paint 一半以上。先看 n（块数）再动 DOM。',
        });
      }
      const err = byName.get('trae_sessions_error');
      if (err && err.n) {
        const why = countField(rows, 'trae_sessions_error', 'reason');
        items.push({
          level: 'slow',
          name: 'trae_sessions_error',
          title: 'error ×' + err.n,
          why: why[0] ? 'reason=' + why[0][0] : '拉 recent 看 payload.reason',
        });
      }
      const ttfp = byName.get('trae_sessions_ttfp');
      if (ttfp && ttfp.max >= 400) {
        items.push({
          level: 'warn',
          name: 'trae_sessions_ttfp',
          title: 'ttfp ' + round(ttfp.max) + 'ms',
          why: '对照 trae_sessions_net 与 snapshot cache。首屏只应画 beats。',
        });
      }
      const cls = byName.get('trae_sessions_cls');
      if (cls && cls.max >= CLS) {
        items.push({
          level: 'slow',
          name: 'trae_sessions_cls',
          title: '会话 CLS ' + round(cls.max) + 'ms',
          why: 'payload.kind 是哪块节点。禁止整页 innerHTML。',
        });
      }
    }
    if (!items.length) {
      items.push({
        level: 'ok',
        name: '',
        title: '本窗口没有越过阈值的点',
        why: '用 24 小时表做改前对照。慢了再点 name 看 phase / kind / reason。',
      });
    }
    return items;
  }
  function digest(family, range, byName, items) {
    const lines = [family + ' ' + range, 'name n avg p95 max slow'];
    const rows = [...byName.values()].sort((a, b) => b.max - a.max || b.n - a.n);
    for (const r of rows) {
      lines.push([r.name, r.n, round(r.avg), round(r.p95), round(r.max), r.slow].join(' '));
    }
    lines.push('attention:');
    for (const it of items) lines.push('- ' + it.title + ' :: ' + it.why);
    return lines.join('\n');
  }

  function create(host, opts) {
    if (!host) return null;
    const family = opts && opts.family === 'sessions' ? 'sessions' : 'notes';
    const api = (opts && opts.api) || '';
    const getLocal = (opts && opts.getLocal) || (() => []);
    const state = { range: 'session', filter: '', dayNames: [], dayRecent: [], open: false, timer: 0 };

    host.classList.add('cv-metrics-host');
    host.innerHTML = `
      <div class="cv-metrics">
        <h2 class="cv-metrics-title">指标</h2>
        <p class="cv-metrics-lead">本机 ui-metrics，不含正文。用来发现卡顿/白屏/抖动并对照同一 name，不是装饰。</p>
        <div class="cv-metrics-chrome">
          <div class="cv-metrics-modes" role="tablist" aria-label="时间范围">
            <button type="button" data-range="session" class="is-on">本页</button>
            <button type="button" data-range="day">24 小时</button>
          </div>
          <button type="button" class="cv-metrics-act" data-act="refresh">刷新</button>
          <button type="button" class="cv-metrics-act" data-act="copy">复制摘要</button>
        </div>
        <div data-slot="attention"></div>
        <h3>按 name</h3>
        <div data-slot="table"></div>
        <h3>归因</h3>
        <div data-slot="why"></div>
        <h3>最近事件</h3>
        <div class="cv-metrics-filter" data-slot="filter" hidden></div>
        <ul class="cv-metrics-log" data-slot="log"></ul>
      </div>`;

    const $ = (sel) => host.querySelector(sel);

    async function pullDay() {
      try {
        const sum = await fetch(api + '/api/ui-metrics/summary').then((r) => r.json());
        const rec = await fetch(api + '/api/ui-metrics/recent?limit=120').then((r) => r.json());
        state.dayNames = Array.isArray(sum && sum.names) ? sum.names.filter((n) => inFamily(n.name, family)) : [];
        state.dayRecent = Array.isArray(rec && rec.events) ? rec.events.filter((e) => inFamily(e.name, family)) : [];
      } catch (_) {
        state.dayNames = [];
        state.dayRecent = [];
      }
    }

    function localRows() {
      return (getLocal() || []).filter((e) => inFamily(e && e.name, family));
    }

    function paint() {
      const live = localRows();
      const rows = state.range === 'day' ? (state.dayRecent.length ? state.dayRecent : live) : live;
      const byName = aggregate(rows);
      const items = diagnose(family, rows, byName);
      const att = $('[data-slot="attention"]');
      att.innerHTML = items.map((it) =>
        `<div class="cv-att is-${esc(it.level)}" data-name="${esc(it.name)}"><div class="cv-att-title">${esc(it.title)}</div><div class="cv-att-why">${esc(it.why)}</div></div>`
      ).join('');

      const dayMap = new Map((state.dayNames || []).map((n) => [n.name, n]));
      const tableRows = [...byName.values()].sort((a, b) => b.max - a.max || b.n - a.n);
      const table = $('[data-slot="table"]');
      if (!tableRows.length) {
        table.innerHTML = '<p class="cv-metrics-empty">还没有打点。改预览或滚会话后再回来。</p>';
      } else {
        table.innerHTML = `<table><thead><tr><th>name</th><th>n</th><th>avg</th><th>p95</th><th>max</th><th>24h avg</th></tr></thead><tbody>${
          tableRows.map((r) => {
            const d = dayMap.get(r.name);
            const dayAvg = d && d.avg_ms != null ? round(d.avg_ms) : '—';
            const slow = r.max >= SLOW || r.slow > 0;
            const on = state.filter && state.filter === r.name;
            return `<tr class="${slow ? 'is-slow' : ''} ${on ? 'is-on' : ''}" data-name="${esc(r.name)}"><td class="cv-mono">${esc(r.name)}</td><td>${r.n}</td><td>${round(r.avg)}</td><td>${round(r.p95)}</td><td>${round(r.max)}</td><td>${dayAvg}</td></tr>`;
          }).join('')
        }</tbody></table>`;
      }

      const bits = [];
      if (family === 'notes') {
        const reuse = countField(rows, 'notes_md_compile', 'ratio');
        const last = lastPayload(rows, 'notes_md_compile');
        if (last.compiled != null || last.reused != null) {
          bits.push(`最近编译 compiled=${last.compiled ?? '—'} reused=${last.reused ?? '—'} n=${last.n ?? '—'} ratio=${last.ratio ?? '—'}`);
        }
        const phase = countField(rows, 'notes_cls', 'phase');
        if (phase.length) bits.push('notes_cls phase：' + phase.map(([k, n]) => k + ' ×' + n).join(' · '));
        void reuse;
      } else {
        const skip = countField(rows, 'trae_sessions_skip', 'reason');
        if (skip.length) bits.push('skip.reason：' + skip.map(([k, n]) => k + ' ×' + n).join(' · '));
        const paint = countField(rows, 'trae_sessions_paint', 'kind');
        if (paint.length) bits.push('paint.kind：' + paint.map(([k, n]) => k + ' ×' + n).join(' · '));
        const fsm = countField(rows, 'trae_sessions_fsm', 'phase');
        if (fsm.length) bits.push('fsm：' + fsm.map(([k, n]) => k + ' ×' + n).join(' · '));
        const layout = countField(rows, 'trae_sessions_layout', 'reason');
        if (layout.length) bits.push('layout：' + layout.map(([k, n]) => k + ' ×' + n).join(' · '));
      }
      const why = $('[data-slot="why"]');
      why.innerHTML = bits.length
        ? bits.map((b) => `<p class="cv-metrics-empty">${esc(b)}</p>`).join('')
        : '<p class="cv-metrics-empty">还没有 phase / kind / reason。先补点再改。</p>';

      const filt = $('[data-slot="filter"]');
      if (state.filter) {
        filt.hidden = false;
        filt.innerHTML = `只看 <span class="cv-mono">${esc(state.filter)}</span> · <button type="button" data-act="clear">显示全部</button>`;
      } else {
        filt.hidden = true;
        filt.innerHTML = '';
      }
      const shown = state.filter ? rows.filter((e) => e.name === state.filter) : rows;
      const latest = shown.slice(-40).reverse();
      const log = $('[data-slot="log"]');
      log.innerHTML = latest.length ? latest.map((ev) => {
        const tms = new Date(ev.ts || Date.now()).toLocaleTimeString();
        const dur = ev.dur_ms != null ? ' ' + round(ev.dur_ms) + 'ms' : '';
        const p = ev.payload ? ' ' + JSON.stringify(ev.payload) : '';
        const ok = ev.ok === false ? ' ok=false' : '';
        return `<li class="${isSlow(ev) ? 'is-slow' : ''}" data-name="${esc(ev.name)}">${esc(tms)} ${esc(ev.name)}${esc(dur)}${esc(ok)}${esc(p)}</li>`;
      }).join('') : '<li class="cv-metrics-empty">没有事件</li>';

      state._digest = digest(family, state.range === 'day' ? '24h' : 'session', byName, items);
    }

    host.addEventListener('click', (e) => {
      const btn = e.target.closest('button');
      if (btn && btn.dataset.range) {
        state.range = btn.dataset.range;
        host.querySelectorAll('[data-range]').forEach((b) => b.classList.toggle('is-on', b.dataset.range === state.range));
        if (state.range === 'day') pullDay().then(paint);
        else paint();
        return;
      }
      if (btn && btn.dataset.act === 'refresh') {
        refresh();
        return;
      }
      if (btn && btn.dataset.act === 'copy') {
        const text = state._digest || '';
        if (text && navigator.clipboard) navigator.clipboard.writeText(text).catch(() => {});
        return;
      }
      if (btn && btn.dataset.act === 'clear') {
        state.filter = '';
        paint();
        return;
      }
      const row = e.target.closest('[data-name]');
      if (row && row.dataset.name) {
        state.filter = row.dataset.name;
        paint();
      }
    });

    async function refresh() {
      if (state.range === 'day' || !state.dayNames.length) await pullDay();
      paint();
    }
    function noteIncoming() {
      if (!state.open) return;
      if (state.timer) return;
      state.timer = setTimeout(() => { state.timer = 0; paint(); }, 200);
    }
    function slowCount() {
      return localRows().reduce((n, ev) => n + (isSlow(ev) ? 1 : 0), 0);
    }
    function setOpen(open) {
      state.open = !!open;
      host.hidden = !state.open;
      if (state.open) refresh();
    }
    function paintBadge(el) {
      if (!el) return;
      const n = slowCount();
      el.classList.toggle('is-slow', n > 0);
      const badge = el.querySelector('.cv-debug-n');
      if (badge) {
        badge.textContent = n ? String(n) : '';
        badge.hidden = !n;
      }
    }

    return { refresh, setOpen, noteIncoming, slowCount, paintBadge, family };
  }

  function debugRowHtml() {
    return `<span class="cv-debug-mark" aria-hidden="true"></span>
      <span class="cv-debug-copy"><span class="cv-debug-k">指标</span><span class="cv-debug-s">本页打点 · 对照优化</span></span>
      <span class="cv-debug-n" hidden></span>`;
  }

  globalThis.ClipMetricsPanel = { create, debugRowHtml, inFamily, isSlow, prefixOf };
})();
