/* ClipVault metrics: floating debug toggle. Key names only. No content. */
(function () {
  const SLOW = 80;
  const KEY = {
    notes: ['notes_preview_ms', 'notes_md_compile', 'notes_cls', 'notes_longtask', 'notes_inp'],
    sessions: [
      'trae_sessions_skip', 'trae_sessions_paint', 'trae_sessions_md',
      'trae_sessions_ttfp', 'trae_sessions_net', 'trae_sessions_error',
      'trae_sessions_cls', 'trae_sessions_longtask',
    ],
  };

  function esc(s) {
    return String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }
  function inFamily(name, family) {
    return (KEY[family] || []).includes(String(name || ''));
  }
  function isSlow(ev) {
    const name = ev && ev.name || '';
    const dur = Number(ev && ev.dur_ms);
    if (/_cls$/.test(name)) return Number.isFinite(dur) && dur >= SLOW;
    if (name === 'trae_sessions_error') return true;
    if (name === 'trae_sessions_skip') return true;
    if (/longtask$/.test(name)) return Number.isFinite(dur) && dur >= 50;
    return Number.isFinite(dur) && dur >= SLOW;
  }
  function round(n) {
    if (n == null || !Number.isFinite(n)) return '—';
    return String(Math.round(n));
  }
  function aggregate(rows) {
    const map = new Map();
    for (const ev of rows) {
      const name = ev && ev.name;
      if (!name) continue;
      let a = map.get(name);
      if (!a) a = { name, n: 0, sum: 0, durN: 0, max: 0, last: null, slow: 0 };
      a.n += 1;
      a.last = ev;
      if (ev.dur_ms != null && Number.isFinite(ev.dur_ms)) {
        a.sum += ev.dur_ms;
        a.durN += 1;
        if (ev.dur_ms > a.max) a.max = ev.dur_ms;
      }
      if (isSlow(ev)) a.slow += 1;
      map.set(name, a);
    }
    for (const a of map.values()) a.avg = a.durN ? a.sum / a.durN : null;
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
  function slimPayload(p) {
    if (!p || typeof p !== 'object') return '';
    const keep = ['kind', 'phase', 'reason', 'compiled', 'reused', 'n', 'ratio'];
    const bits = [];
    for (const k of keep) {
      if (p[k] == null || p[k] === '') continue;
      bits.push(k + '=' + p[k]);
    }
    return bits.length ? ' ' + bits.join(' ') : '';
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
          title: '预览 ' + round(prev.max) + 'ms',
          why: share != null && share >= 0.55 ? 'compile 占大头' : 'paint 占大头',
        });
      }
      const p = lastPayload(rows, 'notes_md_compile');
      const compiled = Number(p.compiled);
      const reused = Number(p.reused);
      const total = (Number.isFinite(compiled) ? compiled : 0) + (Number.isFinite(reused) ? reused : 0);
      if (total >= 4 && reused / total < 0.25) {
        items.push({ level: 'warn', title: '复用 ' + reused + '/' + total, why: 'LRU 未命中' });
      }
      const cls = byName.get('notes_cls');
      if (cls && cls.max >= SLOW) {
        const kind = cls.last && cls.last.payload && cls.last.payload.kind;
        items.push({ level: 'slow', title: 'CLS ' + round(cls.max), why: kind || (cls.last && cls.last.payload && cls.last.payload.phase) || '' });
      }
      const lt = byName.get('notes_longtask');
      if (lt && lt.max >= 50) items.push({ level: 'warn', title: 'longtask ' + round(lt.max) + 'ms', why: '' });
    }
    if (family === 'sessions') {
      const skip = byName.get('trae_sessions_skip');
      const paint = byName.get('trae_sessions_paint');
      const reasons = countField(rows, 'trae_sessions_skip', 'reason');
      if (skip && skip.n && (!paint || skip.n >= Math.max(1, paint.n))) {
        items.push({
          level: 'slow',
          title: 'skip ' + skip.n + (paint ? ' / paint ' + paint.n : ''),
          why: reasons[0] ? reasons[0][0] + ' ×' + reasons[0][1] : '',
        });
      }
      if (paint && paint.max >= SLOW) {
        const kinds = countField(rows, 'trae_sessions_paint', 'kind');
        items.push({ level: 'slow', title: 'paint ' + round(paint.max) + 'ms', why: kinds[0] ? kinds[0][0] : '' });
      }
      const md = byName.get('trae_sessions_md');
      if (md && paint && paint.max >= 40 && md.max / Math.max(paint.max, 1) >= 0.5) {
        items.push({ level: 'warn', title: 'md ' + round(md.max) + ' / paint ' + round(paint.max), why: '' });
      }
      const err = byName.get('trae_sessions_error');
      if (err && err.n) {
        const why = countField(rows, 'trae_sessions_error', 'reason');
        items.push({ level: 'slow', title: 'error ×' + err.n, why: why[0] ? why[0][0] : '' });
      }
      const ttfp = byName.get('trae_sessions_ttfp');
      if (ttfp && ttfp.max >= 400) items.push({ level: 'warn', title: 'ttfp ' + round(ttfp.max) + 'ms', why: '' });
      const cls = byName.get('trae_sessions_cls');
      if (cls && cls.max >= SLOW) items.push({ level: 'slow', title: 'CLS ' + round(cls.max), why: '' });
    }
    return items;
  }

  function create(opts) {
    const mount = opts && opts.mount;
    if (!mount) return null;
    const family = opts.family === 'sessions' ? 'sessions' : 'notes';
    const getLocal = opts.getLocal || (() => []);
    const keys = KEY[family];
    const state = { open: false, timer: 0 };

    const wrap = document.createElement('div');
    wrap.className = 'cv-metrics-float';
    wrap.innerHTML =
      '<div class="cv-metrics-pop" hidden>' +
        '<div data-slot="att"></div>' +
        '<div data-slot="table"></div>' +
        '<ul class="cv-metrics-log" data-slot="log"></ul>' +
      '</div>' +
      '<button type="button" class="cv-debug-fab" aria-label="调试" aria-pressed="false">' +
        '<span class="cv-debug-fab-dot" aria-hidden="true"></span>调试' +
        '<span class="cv-debug-n" hidden></span>' +
      '</button>';
    mount.appendChild(wrap);
    const fab = wrap.querySelector('.cv-debug-fab');
    const pop = wrap.querySelector('.cv-metrics-pop');
    const $ = (sel) => wrap.querySelector(sel);

    function localRows() {
      return (getLocal() || []).filter((e) => inFamily(e && e.name, family));
    }
    function paint() {
      const rows = localRows();
      const byName = aggregate(rows);
      const items = diagnose(family, rows, byName);
      const att = $('[data-slot="att"]');
      att.innerHTML = items.length
        ? items.map((it) => `<div class="cv-att is-${esc(it.level)}">${esc(it.title)}${it.why ? ' · ' + esc(it.why) : ''}</div>`).join('')
        : '';
      const tableRows = keys.map((name) => byName.get(name)).filter((r) => r && r.n);
      const table = $('[data-slot="table"]');
      if (!tableRows.length) {
        table.innerHTML = '<p class="cv-metrics-empty">无关键打点</p>';
      } else {
        table.innerHTML = `<table><thead><tr><th>name</th><th>n</th><th>avg</th><th>max</th></tr></thead><tbody>${
          tableRows.map((r) => {
            const slow = r.max >= SLOW || r.slow > 0;
            return `<tr class="${slow ? 'is-slow' : ''}"><td>${esc(r.name)}</td><td>${r.n}</td><td>${round(r.avg)}</td><td>${round(r.max)}</td></tr>`;
          }).join('')
        }</tbody></table>`;
      }
      const uniq = [];
      const sig = new Set();
      for (const ev of rows.slice().reverse()) {
        const s = String(ev.name) + String(ev.ts);
        if (sig.has(s)) continue;
        sig.add(s);
        uniq.push(ev);
        if (uniq.length >= 8) break;
      }
      const log = $('[data-slot="log"]');
      log.innerHTML = uniq.length ? uniq.map((ev) => {
        const dur = ev.dur_ms != null ? ' ' + round(ev.dur_ms) + 'ms' : '';
        return `<li class="${isSlow(ev) ? 'is-slow' : ''}">${esc(ev.name)}${esc(dur)}${esc(slimPayload(ev.payload))}</li>`;
      }).join('') : '';
      paintBadge();
    }
    function slowCount() {
      return localRows().reduce((n, ev) => n + (isSlow(ev) ? 1 : 0), 0);
    }
    function paintBadge() {
      const n = slowCount();
      fab.classList.toggle('is-slow', n > 0);
      const badge = fab.querySelector('.cv-debug-n');
      if (badge) {
        badge.textContent = n ? String(n) : '';
        badge.hidden = !n;
      }
    }
    function setOpen(open) {
      state.open = !!open;
      pop.hidden = !state.open;
      fab.classList.toggle('is-on', state.open);
      fab.setAttribute('aria-pressed', state.open ? 'true' : 'false');
      if (state.open) paint();
      else paintBadge();
    }
    function toggle() { setOpen(!state.open); }
    function noteIncoming() {
      paintBadge();
      if (!state.open) return;
      if (state.timer) return;
      state.timer = setTimeout(() => { state.timer = 0; paint(); }, 200);
    }

    fab.addEventListener('click', (e) => {
      e.preventDefault();
      e.stopPropagation();
      toggle();
    });

    return { setOpen, toggle, noteIncoming, paintBadge, slowCount, family };
  }

  globalThis.ClipMetricsPanel = { create, inFamily, isSlow };
})();
