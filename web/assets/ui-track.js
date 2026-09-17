/* ClipVault UI interaction tracking — local ui-metrics only. No content.
 *
 * A delegated listener turns clicks / form changes / shortcuts into one
 * bounded vocabulary so UI decisions can be driven by real usage instead of
 * guesswork:
 *
 *   ui_interact { zone, action, target, via, kind?, n? }
 *
 * `target` is a DOM handle (data-ui / id / action-attribute / class / tag),
 * never element text. The page owns the sink (its own metrics emitter) — this
 * file never posts on its own. Deriving `action` from existing data-* action
 * attributes means card / chip / panel handlers need no per-button edits.
 */
(function () {
  const NAME = 'ui_interact';
  const MAX = 40;

  // Existing action attributes -> verb. Order matters (first match wins).
  const ACT_VERB = [
    ['data-pin', 'pin'], ['data-restore', 'restore'], ['data-del', 'delete'],
    ['data-copy-plain', 'copy'], ['data-ocr-copy', 'copy-ocr'], ['data-events-open', 'events'],
    ['data-link', 'link'], ['data-eval', 'eval'], ['data-share-id', 'share'],
    ['data-mode', 'mode'], ['data-cmd', 'format'], ['data-link-tab', 'link-tab'],
    ['data-type', 'filter'], ['data-view', 'view'], ['data-related-jump', 'jump'],
    ['data-related-more', 'jump-more'], ['data-copy-sid', 'copy-id'],
    ['data-scope', 'scope'], ['data-dir', 'dir'], ['data-eid', 'thread-open'],
    ['data-expand-all', 'expand-all'], ['data-restore-version', 'restore-version'],
  ];

  let sink = null;
  let defZone = 'ui';
  let installed = false;

  const short = (v) => String(v == null ? '' : v).replace(/\s+/g, ' ').trim().slice(0, MAX);

  function actAttr(el) {
    for (const [attr] of ACT_VERB) {
      if (el.hasAttribute && el.hasAttribute(attr)) return attr;
    }
    return '';
  }

  function targetOf(el) {
    const marked = el.getAttribute && el.getAttribute('data-ui');
    if (marked) return short(marked);
    if (el.id) return short(el.id);
    const attr = actAttr(el);
    if (attr) return short(attr);
    const cls = (el.getAttribute('class') || '').trim().split(/\s+/).filter(Boolean).slice(0, 2).join('.');
    if (cls) return short(cls);
    return short((el.tagName || '').toLowerCase());
  }

  function zoneOf(el) {
    const z = el.closest && el.closest('[data-ui-zone]');
    return z ? short(z.getAttribute('data-ui-zone')) : defZone;
  }

  function actionOf(el, fallback) {
    const attr = actAttr(el);
    for (const [a, verb] of ACT_VERB) {
      if (a === attr) return verb;
    }
    const marked = el.closest && el.closest('[data-ui-action]');
    if (marked) return short(marked.getAttribute('data-ui-action'));
    return fallback;
  }

  function fire(zone, action, target, via, extra) {
    if (!sink) return;
    const payload = { zone: short(zone), action: short(action), target: short(target), via: short(via) };
    if (extra && Number.isFinite(extra.n)) payload.n = extra.n;
    if (extra && extra.kind) payload.kind = short(extra.kind);
    sink(NAME, { payload });
  }

  const CLICKABLE = '[data-ui],button,a,[role="button"],[role="tab"],[role="menuitem"],summary,input[type="checkbox"],input[type="radio"]';

  function onClick(ev) {
    if (ev.button != null && ev.button !== 0) return;
    const el = ev.target && ev.target.closest ? ev.target.closest(CLICKABLE) : null;
    if (!el) return;
    fire(zoneOf(el), actionOf(el, 'click'), targetOf(el), 'click');
  }

  function onChange(ev) {
    const el = ev.target;
    if (!el || !el.matches || !el.matches('input,select,textarea')) return;
    const kind = (el.getAttribute('type') || el.tagName || '').toLowerCase();
    fire(zoneOf(el), actionOf(el, 'input'), targetOf(el), 'change', { kind });
  }

  // Only app shortcuts, so browser/OS combos do not flood the store.
  const SHORTCUTS = new Set(['s', 'm', 'k', 'enter', 'escape']);

  function onKey(ev) {
    const key = short(ev.key).toLowerCase();
    if (!SHORTCUTS.has(key)) return;
    const mod = ev.metaKey || ev.ctrlKey;
    if (!mod && key !== 'escape') return;
    const el = ev.target && ev.target.closest ? ev.target.closest('[data-ui]') : null;
    const combo = [ev.metaKey ? 'cmd' : '', ev.ctrlKey ? 'ctrl' : '', ev.altKey ? 'alt' : '', ev.shiftKey ? 'shift' : '', key]
      .filter(Boolean).join('+');
    fire(el ? zoneOf(el) : defZone, el ? actionOf(el, 'shortcut') : 'shortcut', el ? targetOf(el) : combo, 'key');
  }

  function install(nextSink, opts) {
    if (typeof nextSink !== 'function') return;
    sink = nextSink;
    if (opts && opts.zone) defZone = short(opts.zone);
    if (installed) return;
    installed = true;
    document.addEventListener('click', onClick, true);
    document.addEventListener('change', onChange, true);
    document.addEventListener('keydown', onKey, true);
  }

  globalThis.ClipUiTrack = {
    install,
    track(zone, action, target, extra) {
      fire(zone || defZone, action, target, (extra && extra.via) || 'api', extra);
    },
  };
})();
