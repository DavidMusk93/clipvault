/**
 * ClipVault archive reader chrome — lives IN the view document.
 * TOC is derived at runtime. Learning traces (resume / highlight / comment)
 * persist via same-origin SQLite APIs. Archive HTML is never mutated on disk.
 */
(function () {
  "use strict";

  var SCROLL_MS = 2400;
  var ICO_NOTE =
    "M3.1 3.15h9.8c.6 0 1.1.5 1.1 1.1v5.35c0 .6-.5 1.1-1.1 1.1H7.15L4.2 13.1v-2.4h-.1c-.6 0-1.1-.5-1.1-1.1V4.25c0-.6.5-1.1 1.1-1.1z";

  function archiveId() {
    var root = document.documentElement;
    if (root && root.getAttribute("data-archive-id")) return root.getAttribute("data-archive-id");
    try {
      return new URLSearchParams(location.search).get("id") || "";
    } catch (_) {
      return "";
    }
  }

  function articleRoot() {
    return document.querySelector("main.cv-article") || document.body;
  }

  function headingText(el) {
    return String(el.textContent || "").replace(/\s+/g, " ").trim();
  }

  function collectHeadings(root) {
    var nodes = root.querySelectorAll("h1, h2, h3, h4");
    var out = [];
    for (var i = 0; i < nodes.length; i++) {
      var el = nodes[i];
      var text = headingText(el);
      if (!text || text.length > 96) continue;
      if (el.closest(".cv-toc, .cv-bar, .cv-reader-ui")) continue;
      if (!el.id) el.id = "cv-h-" + (out.length + 1);
      out.push({ el: el, id: el.id, text: text, level: Number(el.tagName.charAt(1)) });
    }
    return out;
  }

  function scrollMax() {
    var se = document.scrollingElement || document.documentElement;
    return Math.max(0, se.scrollHeight - window.innerHeight);
  }

  function currentY() {
    return window.scrollY || document.documentElement.scrollTop || 0;
  }

  function currentRatio() {
    var max = scrollMax();
    return max <= 0 ? 0 : currentY() / max;
  }

  function nearestHeading(headings, y) {
    var hit = null;
    for (var i = 0; i < headings.length; i++) {
      var top = headings[i].el.getBoundingClientRect().top + currentY();
      if (top <= y + 72) hit = headings[i];
    }
    return hit;
  }

  function apiGet(id) {
    return fetch("/api/archive/reader?id=" + encodeURIComponent(id), { credentials: "same-origin" }).then(function (r) {
      return r.json();
    });
  }

  function apiPost(id, kind, payload) {
    return fetch("/api/archive/reader", {
      method: "POST",
      credentials: "same-origin",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ id: id, kind: kind, payload: payload || {} }),
    }).then(function (r) {
      return r.json();
    });
  }

  function injectCSS() {
    if (document.getElementById("cv-reader-css")) return;
    var css = document.createElement("style");
    css.id = "cv-reader-css";
    css.textContent = [
      ".cv-reader-ui{font-family:-apple-system,BlinkMacSystemFont,'SF Pro Text',system-ui,sans-serif;}",
      ".cv-progress{position:fixed;top:0;left:0;height:2px;width:0;z-index:40;",
      "background:#0071e3;pointer-events:none;transition:width .12s linear;}",
      ".cv-toc-fab,.cv-note-fab{position:fixed;z-index:42;height:40px;padding:0 14px;border:0;border-radius:999px;",
      "cursor:pointer;display:inline-flex;align-items:center;gap:6px;color:#fff;font:inherit;font-size:13px;font-weight:600;",
      "letter-spacing:-.01em;box-shadow:0 8px 24px rgba(0,0,0,.18);",
      "backdrop-filter:blur(16px) saturate(160%);-webkit-backdrop-filter:blur(16px) saturate(160%);}",
      ".cv-toc-fab{right:16px;bottom:18px;background:rgba(29,29,31,.88);}",
      ".cv-note-fab{right:16px;bottom:66px;background:rgba(0,113,227,.92);}",
      ".cv-toc-fab:hover{background:rgba(29,29,31,.96);}",
      ".cv-toc-fab .cv-toc-count,.cv-note-fab .cv-toc-count{opacity:.78;font-weight:500;}",
      ".cv-toc-panel{position:fixed;right:16px;bottom:114px;z-index:42;width:min(320px,calc(100vw - 28px));",
      "max-height:min(68vh,560px);display:none;flex-direction:column;",
      "background:rgba(255,255,255,.96);color:#1d1d1f;border-radius:16px;",
      "border:.5px solid rgba(60,60,67,.12);overflow:hidden;box-shadow:0 18px 48px rgba(0,0,0,.18);}",
      ".cv-toc-panel.open{display:flex;}",
      ".cv-toc-head{padding:12px 14px 8px;display:flex;align-items:center;justify-content:space-between;gap:8px;}",
      ".cv-toc-head strong{font-size:13px;letter-spacing:-.02em;}",
      ".cv-toc-filter{margin:0 12px 8px;height:32px;border-radius:8px;border:.5px solid rgba(60,60,67,.16);",
      "padding:0 10px;font:inherit;font-size:13px;background:#f5f5f7;outline:none;}",
      ".cv-toc-list{overflow:auto;padding:4px 8px 10px;-webkit-overflow-scrolling:touch;}",
      ".cv-toc-item,.cv-hl-item{display:block;width:100%;text-align:left;border:0;background:transparent;",
      "border-radius:10px;padding:8px 10px;font:inherit;font-size:13px;line-height:1.35;color:#1d1d1f;cursor:pointer;}",
      ".cv-toc-item[data-level='3']{padding-left:20px;font-size:12.5px;color:#6e6e73;}",
      ".cv-toc-item:hover,.cv-hl-item:hover{background:rgba(120,120,128,.12);}",
      ".cv-toc-item.is-active{background:rgba(0,113,227,.12);color:#003d82;font-weight:600;}",
      ".cv-hl-item{font-size:12.5px;}",
      ".cv-hl-item em{display:block;font-style:normal;color:#6e6e73;margin-top:3px;}",
      ".cv-resume{position:fixed;left:50%;bottom:18px;transform:translateX(-50%);z-index:41;",
      "height:34px;padding:0 12px;border-radius:999px;border:0;display:none;align-items:center;",
      "background:rgba(255,255,255,.94);color:#1d1d1f;font:inherit;font-size:12.5px;font-weight:600;",
      "box-shadow:0 8px 24px rgba(0,0,0,.14);max-width:min(72vw,420px);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}",
      ".cv-resume.show{display:inline-flex;}",
      "main.cv-article ::selection{background:rgba(255,214,10,.38);color:inherit;}",
      "mark.cv-hl{background:rgba(255,214,10,.38);color:inherit;border-radius:2px;",
      "padding:0 .04em;cursor:pointer;box-decoration-break:clone;-webkit-box-decoration-break:clone;}",
      "mark.cv-hl.has-note{box-shadow:inset 0 -1.5px 0 #0071e3;}",
      ".cv-selbar{position:fixed;z-index:50;left:0;top:0;display:flex;align-items:stretch;",
      "height:28px;opacity:0;pointer-events:none;transform:translate3d(0,4px,0) scale(.98);",
      "transform-origin:50% 100%;isolation:isolate;user-select:none;-webkit-user-select:none;",
      "transition:opacity .14s cubic-bezier(.22,1,.36,1),transform .18s cubic-bezier(.22,1,.36,1);",
      "background:rgba(250,250,252,.96);color:#1d1d1f;",
      "-webkit-backdrop-filter:blur(40px) saturate(180%);backdrop-filter:blur(40px) saturate(180%);",
      "border-radius:8px;border:.5px solid rgba(0,0,0,.08);",
      "box-shadow:0 0 0 .5px rgba(255,255,255,.7) inset,0 1px 1px rgba(0,0,0,.04),0 8px 24px rgba(0,0,0,.10);}",
      ".cv-selbar.open{opacity:1;pointer-events:auto;transform:translate3d(0,0,0) scale(1);}",
      ".cv-selbar.is-below{transform-origin:50% 0;}",
      ".cv-selbar.is-below.open{transform:translate3d(0,0,0) scale(1);}",
      ".cv-selbar:not(.is-below):not(.open){transform:translate3d(0,4px,0) scale(.98);}",
      ".cv-selbar.is-below:not(.open){transform:translate3d(0,-4px,0) scale(.98);}",
      ".cv-selbar button{appearance:none;border:0;background:transparent;color:#1d1d1f;",
      "font:inherit;font-size:12px;font-weight:510;letter-spacing:-.01em;",
      "padding:0 11px;height:28px;display:inline-flex;align-items:center;gap:5px;cursor:pointer;}",
      ".cv-selbar button:first-of-type{border-radius:8px 0 0 8px;}",
      ".cv-selbar button:last-of-type{border-radius:0 8px 8px 0;}",
      ".cv-selbar button:active{background:rgba(0,0,0,.06);}",
      ".cv-selbar .cv-swatch{width:8px;height:8px;border-radius:99px;flex-shrink:0;",
      "background:#ffd60a;box-shadow:inset 0 0 0 .5px rgba(0,0,0,.18);}",
      ".cv-selbar .cv-ico{width:13px;height:13px;display:block;flex-shrink:0;color:#3a3a3c;}",
      ".cv-selbar .cv-div{width:.5px;background:rgba(60,60,67,.18);margin:7px 0;flex-shrink:0;}",
      ".cv-selbar .cv-caret{position:absolute;left:50%;width:8px;height:8px;bottom:-4px;",
      "background:rgba(250,250,252,.96);border-right:.5px solid rgba(0,0,0,.06);border-bottom:.5px solid rgba(0,0,0,.06);",
      "transform:translateX(-50%) rotate(45deg);pointer-events:none;border-radius:1px;}",
      ".cv-selbar.is-below .cv-caret{top:-3px;bottom:auto;border:0;",
      "border-left:.5px solid rgba(0,0,0,.06);border-top:.5px solid rgba(0,0,0,.06);}",
      "@media (hover:hover) and (pointer:fine){.cv-selbar button:hover{background:rgba(0,0,0,.04);}}",
      ".cv-note{position:fixed;z-index:51;left:0;top:0;display:flex;flex-direction:column;gap:10px;",
      "width:min(320px,calc(100vw - 20px));padding:12px 14px 14px;",
      "opacity:0;pointer-events:none;transform:translate3d(0,8px,0) scale(.97);transform-origin:20% 0;",
      "transition:opacity .2s cubic-bezier(.22,1,.36,1),transform .24s cubic-bezier(.22,1,.36,1);",
      "background:rgba(255,255,255,.92);color:#1d1d1f;",
      "-webkit-backdrop-filter:blur(28px) saturate(180%);backdrop-filter:blur(28px) saturate(180%);",
      "border-radius:18px;border:.5px solid rgba(60,60,67,.12);",
      "box-shadow:0 12px 40px rgba(0,0,0,.18),0 0 0 .5px rgba(255,255,255,.4) inset;}",
      ".cv-note.open{opacity:1;pointer-events:auto;transform:translate3d(0,0,0) scale(1);}",
      ".cv-note .cv-grabber{width:36px;height:5px;border-radius:999px;background:rgba(60,60,67,.22);",
      "margin:0 auto 2px;display:none;flex-shrink:0;}",
      ".cv-note .cv-note-head{display:flex;align-items:center;justify-content:space-between;gap:8px;}",
      ".cv-note .cv-note-head strong{font-size:17px;font-weight:600;letter-spacing:-.02em;}",
      ".cv-note .cv-quote{font-size:12px;line-height:1.4;color:#6e6e73;letter-spacing:-.01em;",
      "padding-left:8px;border-left:2px solid #ffd60a;max-height:3.2em;overflow:hidden;}",
      ".cv-note textarea{width:100%;min-height:96px;box-sizing:border-box;border:.5px solid rgba(60,60,67,.18);",
      "border-radius:14px;padding:12px 14px;font:inherit;font-size:15px;letter-spacing:-.01em;line-height:1.4;",
      "resize:vertical;outline:none;background:rgba(120,120,128,.08);color:#1d1d1f;}",
      ".cv-note textarea:focus{background:#fff;border-color:rgba(0,113,227,.45);box-shadow:0 0 0 4px rgba(0,113,227,.18);}",
      ".cv-note .cv-note-actions{display:flex;gap:10px;padding-top:2px;}",
      ".cv-note .cv-note-actions button{flex:1;height:44px;border:0;border-radius:12px;",
      "font:inherit;font-size:16px;font-weight:600;letter-spacing:-.02em;cursor:pointer;}",
      ".cv-note .cv-note-actions button:active{transform:scale(.98);}",
      ".cv-note .cv-ok{background:#0071e3;color:#fff;}",
      ".cv-note .cv-ok:disabled{opacity:.4;cursor:not-allowed;}",
      ".cv-note .cv-ghost{background:rgba(120,120,128,.14);color:#1d1d1f;font-weight:500;}",
      ".cv-note .cv-danger{align-self:flex-start;border:0;background:transparent;color:#d70015;",
      "font:inherit;font-size:13px;font-weight:510;letter-spacing:-.01em;padding:0;min-height:0;cursor:pointer;}",
      ".cv-note.is-sheet{left:8px!important;right:8px;width:auto;top:auto!important;bottom:12px;",
      "transform-origin:50% 100%;max-width:none;border-radius:20px 20px 18px 18px;}",
      ".cv-note.is-sheet .cv-grabber{display:block;}",
      "main.cv-article h1,main.cv-article h2,main.cv-article h3,main.cv-article h4{scroll-margin-top:16px;}",
      "@media (prefers-reduced-motion:reduce){.cv-selbar,.cv-note{transition:opacity .15s ease;transform:none!important;}}",
      "@media (prefers-reduced-transparency:reduce){.cv-selbar,.cv-note,.cv-selbar .cv-caret{background:#fff;backdrop-filter:none;-webkit-backdrop-filter:none;}}",
      "@media (max-width:640px){.cv-toc-fab{right:12px;bottom:14px;}.cv-note-fab{right:12px;bottom:60px;}.cv-toc-panel{right:12px;bottom:106px;}}",
    ].join("");
    document.head.appendChild(css);
  }

  function el(tag, cls, text) {
    var node = document.createElement(tag);
    if (cls) node.className = cls;
    if (text != null) node.textContent = text;
    return node;
  }

  function ico(path) {
    return (
      '<svg class="cv-ico" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.35" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="' +
      path +
      '"/></svg>'
    );
  }

  /**
   * Place a floating chrome next to a selection/highlight.
   * Never cover the rect: prefer above, flip below if needed, then clamp.
   */
  function placeNearRect(node, rect, opts) {
    opts = opts || {};
    var gap = opts.gap != null ? opts.gap : 10;
    var prefer = opts.prefer || "above";
    var pad = 10;
    var bounds = opts.bounds || rect;
    var w = node.offsetWidth || opts.fallbackW || 168;
    var h = node.offsetHeight || opts.fallbackH || 38;
    var vw = window.innerWidth;
    var vh = window.innerHeight;
    var cx = rect.left + rect.width / 2;
    var left;
    var top;
    var below = false;
    if (opts.allowSide) {
      var colEl = document.querySelector("main.cv-article") || document.body;
      var col = colEl.getBoundingClientRect();
      if (vw - col.right >= 200) {
        left = Math.min(col.right + 12, vw - w - pad);
        top = Math.min(vh - h - pad, Math.max(pad, bounds.top));
        node.classList.remove("is-below");
        node.style.left = Math.round(left) + "px";
        node.style.top = Math.round(top) + "px";
        return { left: left, top: top, below: false, side: true, w: w, h: h };
      }
    }
    left = Math.min(vw - w - pad, Math.max(pad, cx - w / 2));
    var need = h + gap;
    var aboveOk = bounds.top >= need + pad;
    var belowOk = vh - bounds.bottom >= need + pad;
    if (prefer === "below") below = belowOk || !aboveOk;
    else below = aboveOk ? false : belowOk ? true : bounds.top < vh - bounds.bottom;
    top = below ? bounds.bottom + gap : bounds.top - h - gap;
    top = Math.min(vh - h - pad, Math.max(pad, top));
    var overlaps = !(top + h <= bounds.top - 2 || top >= bounds.bottom + 2);
    if (overlaps) {
      if (vh - bounds.bottom >= bounds.top) {
        below = true;
        top = Math.min(vh - h - pad, bounds.bottom + gap);
      } else {
        below = false;
        top = Math.max(pad, bounds.top - h - gap);
      }
    }
    node.classList.toggle("is-below", below);
    node.style.left = Math.round(left) + "px";
    node.style.top = Math.round(top) + "px";
    var caret = node.querySelector(".cv-caret");
    if (caret) {
      caret.style.left = Math.min(w - 14, Math.max(14, cx - left)) + "px";
    }
    return { left: left, top: top, below: below, w: w, h: h };
  }

  function lineRect(target, which) {
    if (target && target.getClientRects) {
      var rs = target.getClientRects();
      if (rs && rs.length) return which === "last" ? rs[rs.length - 1] : rs[0];
    }
    return target.getBoundingClientRect();
  }

  function contextSlice(range, before) {
    var root = articleRoot();
    var idx = buildIndex(root);
    var abs = rangeToAbs(idx, range);
    if (!abs) return "";
    if (before) return idx.text.slice(Math.max(0, abs.start - 24), abs.start);
    return idx.text.slice(abs.end, abs.end + 24);
  }

  function buildIndex(root) {
    var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode: function (n) {
        if (!n.nodeValue) return NodeFilter.FILTER_REJECT;
        if (n.parentElement && n.parentElement.closest(".cv-reader-ui, .cv-selbar, .cv-note")) {
          return NodeFilter.FILTER_REJECT;
        }
        return NodeFilter.FILTER_ACCEPT;
      },
    });
    var parts = [];
    var acc = "";
    while (walker.nextNode()) {
      var t = walker.currentNode;
      parts.push({ node: t, start: acc.length, end: acc.length + t.nodeValue.length });
      acc += t.nodeValue;
    }
    return { text: acc, parts: parts };
  }

  function rangeToAbs(index, range) {
    function pos(node, offset) {
      for (var i = 0; i < index.parts.length; i++) {
        if (index.parts[i].node === node) return index.parts[i].start + offset;
      }
      return -1;
    }
    var s = pos(range.startContainer, range.startOffset);
    var e = pos(range.endContainer, range.endOffset);
    if (s < 0 || e < 0 || e <= s) return null;
    return { start: s, end: e };
  }

  function locateQuote(index, quote, prefix, suffix) {
    if (!quote) return null;
    var from = 0;
    while (from < index.text.length) {
      var i = index.text.indexOf(quote, from);
      if (i < 0) {
        var collapsed = index.text.replace(/\s+/g, " ");
        var q2 = quote.replace(/\s+/g, " ");
        i = collapsed.indexOf(q2);
        if (i < 0) return null;
        return null;
      }
      var pre = index.text.slice(Math.max(0, i - (prefix || "").length), i);
      var suf = index.text.slice(i + quote.length, i + quote.length + (suffix || "").length);
      var preOk = !prefix || pre.slice(-prefix.length) === prefix || prefix.slice(-pre.length) === pre;
      var sufOk = !suffix || suf.slice(0, suffix.length) === suffix || suffix.slice(0, suf.length) === suf;
      if (preOk && sufOk) return { start: i, end: i + quote.length };
      from = i + 1;
    }
    return null;
  }

  function wrapAbs(index, start, end, hid, hasNote) {
    var toWrap = [];
    for (var i = 0; i < index.parts.length; i++) {
      var p = index.parts[i];
      var a = Math.max(start, p.start);
      var b = Math.min(end, p.end);
      if (b <= a) continue;
      toWrap.push({ node: p.node, from: a - p.start, to: b - p.start });
    }
    toWrap.reverse().forEach(function (w) {
      var node = w.node;
      if (w.to < node.nodeValue.length) node.splitText(w.to);
      var mid = w.from > 0 ? node.splitText(w.from) : node;
      var mark = document.createElement("mark");
      mark.className = "cv-hl" + (hasNote ? " has-note" : "");
      mark.dataset.hlId = hid;
      mid.parentNode.insertBefore(mark, mid);
      mark.appendChild(mid);
    });
  }

  function clearMarks(root) {
    var marks = root.querySelectorAll("mark.cv-hl");
    marks.forEach(function (m) {
      var parent = m.parentNode;
      while (m.firstChild) parent.insertBefore(m.firstChild, m);
      parent.removeChild(m);
      parent.normalize();
    });
  }

  function applyHighlights(root, highlights) {
    clearMarks(root);
    (highlights || []).forEach(function (h) {
      if (!h || !h.quote || !h.id) return;
      var idx = buildIndex(root);
      var loc = locateQuote(idx, h.quote, h.prefix || "", h.suffix || "");
      if (!loc) return;
      wrapAbs(idx, loc.start, loc.end, h.id, !!(h.comment && String(h.comment).trim()));
    });
  }

  function serializeSelection(root) {
    var sel = window.getSelection();
    if (!sel || sel.isCollapsed || !sel.rangeCount) return null;
    var range = sel.getRangeAt(0);
    if (!root.contains(range.commonAncestorContainer)) return null;
    var quote = range.toString().replace(/\s+/g, " ").trim();
    if (quote.length < 2 || quote.length > 800) return null;
    return {
      quote: quote,
      prefix: contextSlice(range, true),
      suffix: contextSlice(range, false),
      headingId: nearestHeadingId(range.startContainer),
    };
  }

  function nearestHeadingId(node) {
    var el = node && node.nodeType === 1 ? node : node && node.parentElement;
    while (el && el !== document.body) {
      if (/^H[1-4]$/.test(el.tagName) && el.id) return el.id;
      el = el.parentElement;
    }
    return "";
  }

  function mount(headings, id, initial) {
    injectCSS();
    var state = initial || {};
    var highlights = state.highlights || [];
    var root = articleRoot();
    applyHighlights(root, highlights);

    var ui = el("div", "cv-reader-ui");
    var bar = el("div", "cv-progress");
    var fab = el("button", "cv-toc-fab");
    fab.type = "button";
    fab.innerHTML = "目录 <span class=\"cv-toc-count\">" + headings.length + "</span>";
    if (headings.length < 3) fab.style.display = "none";
    var noteFab = el("button", "cv-note-fab");
    noteFab.type = "button";
    var panel = el("div", "cv-toc-panel");
    var head = el("div", "cv-toc-head");
    var titleEl = el("strong", "", "章节");
    head.appendChild(titleEl);
    panel.appendChild(head);
    var filter = null;
    if (headings.length > 16) {
      filter = el("input", "cv-toc-filter");
      filter.type = "search";
      filter.placeholder = "筛选章节";
      panel.appendChild(filter);
    }
    var list = el("div", "cv-toc-list");
    var buttons = [];
    headings.forEach(function (h) {
      var b = el("button", "cv-toc-item", h.text);
      b.type = "button";
      b.dataset.target = h.id;
      b.dataset.level = String(h.level);
      b.addEventListener("click", function () {
        var target = document.getElementById(h.id);
        if (target) target.scrollIntoView({ behavior: "smooth", block: "start" });
        closePanel();
      });
      list.appendChild(b);
      buttons.push(b);
    });
    panel.appendChild(list);
    var resume = el("div", "cv-resume");
    var selbar = el("div", "cv-selbar");
    selbar.setAttribute("role", "toolbar");
    selbar.setAttribute("aria-label", "选区操作");
    var caret = el("i", "cv-caret");
    var hlBtn = document.createElement("button");
    hlBtn.type = "button";
    hlBtn.className = "cv-hl-btn";
    hlBtn.innerHTML = '<i class="cv-swatch" aria-hidden="true"></i><span>划线</span>';
    var div = el("i", "cv-div");
    var cmtBtn = document.createElement("button");
    cmtBtn.type = "button";
    cmtBtn.innerHTML = ico(ICO_NOTE) + "<span>评论</span>";
    selbar.appendChild(caret);
    selbar.appendChild(hlBtn);
    selbar.appendChild(div);
    selbar.appendChild(cmtBtn);
    var note = el("div", "cv-note");
    var grabber = el("div", "cv-grabber");
    var head = el("div", "cv-note-head");
    head.appendChild(el("strong", "", "评论"));
    var quote = el("p", "cv-quote");
    var ta = document.createElement("textarea");
    ta.placeholder = "写下一句想法（可选）…";
    ta.rows = 3;
    ta.maxLength = 4000;
    var delBtn = el("button", "cv-danger", "删除划线");
    var actions = el("div", "cv-note-actions");
    var cancelBtn = el("button", "cv-ghost", "取消");
    var saveBtn = el("button", "cv-ok", "提交");
    delBtn.type = cancelBtn.type = saveBtn.type = "button";
    actions.appendChild(cancelBtn);
    actions.appendChild(saveBtn);
    note.appendChild(grabber);
    note.appendChild(head);
    note.appendChild(quote);
    note.appendChild(ta);
    note.appendChild(delBtn);
    note.appendChild(actions);
    ui.appendChild(bar);
    ui.appendChild(panel);
    ui.appendChild(noteFab);
    ui.appendChild(fab);
    ui.appendChild(resume);
    ui.appendChild(selbar);
    ui.appendChild(note);
    document.body.appendChild(ui);

    var panelMode = "toc";
    function setNoteCount() {
      noteFab.innerHTML = "笔记 <span class=\"cv-toc-count\">" + highlights.length + "</span>";
      noteFab.style.display = highlights.length ? "inline-flex" : "none";
    }
    setNoteCount();

    function closePanel() {
      panel.classList.remove("open");
    }
    function renderNotesList() {
      list.innerHTML = "";
      if (!highlights.length) {
        list.appendChild(el("div", "cv-hl-item", "还没有划线"));
        return;
      }
      highlights.forEach(function (h) {
        var b = el("button", "cv-hl-item", h.quote || "划线");
        b.type = "button";
        if (h.comment) {
          var em = el("em", "", h.comment);
          b.appendChild(em);
        }
        b.addEventListener("click", function () {
          var mark = root.querySelector('mark.cv-hl[data-hl-id="' + h.id + '"]');
          if (mark) mark.scrollIntoView({ behavior: "smooth", block: "center" });
          openNote(h, mark);
          closePanel();
        });
        list.appendChild(b);
      });
    }
    function openPanel(mode) {
      panelMode = mode || "toc";
      titleEl.textContent = panelMode === "notes" ? "笔记" : "章节";
      if (filter) filter.style.display = panelMode === "toc" ? "" : "none";
      if (panelMode === "notes") renderNotesList();
      else {
        list.innerHTML = "";
        buttons.forEach(function (b) {
          list.appendChild(b);
        });
      }
      panel.classList.add("open");
    }
    fab.addEventListener("click", function (e) {
      e.stopPropagation();
      if (panel.classList.contains("open") && panelMode === "toc") closePanel();
      else openPanel("toc");
    });
    noteFab.addEventListener("click", function (e) {
      e.stopPropagation();
      if (panel.classList.contains("open") && panelMode === "notes") closePanel();
      else openPanel("notes");
    });
    document.addEventListener("keydown", function (e) {
      if (e.key === "Escape") {
        closePanel();
        hideSel();
        note.classList.remove("open");
      }
    });
    document.addEventListener("click", function (e) {
      if (!ui.contains(e.target)) {
        closePanel();
        hideSel();
      }
    });
    if (filter) {
      filter.addEventListener("input", function () {
        var q = filter.value.trim().toLowerCase();
        buttons.forEach(function (b) {
          b.hidden = !!(q && b.textContent.toLowerCase().indexOf(q) < 0);
        });
      });
    }

    function markActive() {
      var hit = nearestHeading(headings, currentY() + 8);
      buttons.forEach(function (b) {
        b.classList.toggle("is-active", !!(hit && b.dataset.target === hit.id));
      });
      bar.style.width = Math.min(100, currentRatio() * 100).toFixed(2) + "%";
    }

    var lastSentY = -9999;
    var saveTimer = 0;
    function persistScroll(force) {
      var y = Math.round(currentY());
      if (!force && Math.abs(y - lastSentY) < 80) return;
      lastSentY = y;
      var hit = nearestHeading(headings, y + 8);
      apiPost(id, "scroll_checkpoint", {
        y: y,
        ratio: Number(currentRatio().toFixed(4)),
        headingId: hit ? hit.id : "",
        headingText: hit ? hit.text : "",
      }).catch(function () {});
    }
    function onScroll() {
      markActive();
      if (saveTimer) clearTimeout(saveTimer);
      saveTimer = setTimeout(function () {
        persistScroll(false);
      }, SCROLL_MS);
    }
    window.addEventListener("scroll", onScroll, { passive: true });
    window.addEventListener("pagehide", function () {
      persistScroll(true);
    });
    document.addEventListener("visibilitychange", function () {
      if (document.visibilityState === "hidden") persistScroll(true);
    });
    markActive();

    function applyPos(pos) {
      if (!pos) return;
      var y = 0;
      if (pos.headingId && document.getElementById(pos.headingId)) {
        y = document.getElementById(pos.headingId).getBoundingClientRect().top + currentY() - 12;
      } else if (typeof pos.y === "number") {
        y = pos.y;
      } else if (typeof pos.ratio === "number") {
        y = pos.ratio * scrollMax();
      }
      if (y < 80) return;
      window.scrollTo(0, y);
      lastSentY = Math.round(y);
      markActive();
      if (pos.headingText) {
        resume.textContent = "已回到 · " + pos.headingText;
        resume.classList.add("show");
        setTimeout(function () {
          resume.classList.remove("show");
        }, 2200);
      }
    }
    applyPos(state.pos);

    var pendingSel = null;
    var editing = null;
    function hideSel() {
      selbar.classList.remove("open");
      pendingSel = null;
    }
    function showSel(rangeOrRect) {
      var first = rangeOrRect && rangeOrRect.getClientRects ? lineRect(rangeOrRect, "first") : rangeOrRect;
      var bounds = rangeOrRect && rangeOrRect.getBoundingClientRect ? rangeOrRect.getBoundingClientRect() : first;
      if (!first || first.width < 2 || first.height < 2) return;
      placeNearRect(selbar, first, {
        prefer: "above",
        gap: 12,
        bounds: bounds,
        fallbackW: 148,
        fallbackH: 28,
      });
      selbar.classList.add("open");
    }
    document.addEventListener("pointerup", function (e) {
      if (ui.contains(e.target)) return;
      setTimeout(function () {
        pendingSel = serializeSelection(root);
        if (!pendingSel) {
          hideSel();
          return;
        }
        var sel = window.getSelection();
        if (!sel || !sel.rangeCount) return;
        showSel(sel.getRangeAt(0));
      }, 0);
    });

    function refreshFromState(next) {
      if (!next) return;
      state = next;
      highlights = next.highlights || [];
      applyHighlights(root, highlights);
      setNoteCount();
    }

    function addHighlight(withComment) {
      if (!pendingSel) return;
      var payload = pendingSel;
      hideSel();
      window.getSelection().removeAllRanges();
      apiPost(id, "highlight_add", payload).then(function (res) {
        if (!res || !res.ok) return;
        refreshFromState(res.state);
        if (withComment) {
          var listNow = (res.state && res.state.highlights) || [];
          var last = listNow[listNow.length - 1];
          if (last) openNote(last, root.querySelector('mark.cv-hl[data-hl-id="' + last.id + '"]'));
        }
      });
    }
    hlBtn.addEventListener("click", function (e) {
      e.stopPropagation();
      addHighlight(false);
    });
    cmtBtn.addEventListener("click", function (e) {
      e.stopPropagation();
      addHighlight(true);
    });

    function openNote(h, anchor) {
      editing = h;
      hideSel();
      quote.textContent = String(h.quote || "").replace(/\s+/g, " ").trim();
      quote.hidden = !quote.textContent;
      ta.value = h.comment || "";
      if (anchor && anchor.scrollIntoView) {
        try {
          anchor.scrollIntoView({ block: "center", behavior: "instant" });
        } catch (_) {
          anchor.scrollIntoView(true);
        }
      }
      var host = anchor || noteFab;
      if (window.innerWidth <= 640) {
        note.classList.add("is-sheet");
        note.style.left = "";
        note.style.top = "";
      } else {
        note.classList.remove("is-sheet");
        placeNearRect(note, lineRect(host, "last"), {
          prefer: "below",
          gap: 14,
          bounds: host.getBoundingClientRect(),
          allowSide: true,
          fallbackW: 320,
          fallbackH: 260,
        });
      }
      note.classList.add("open");
      ta.focus();
    }
    root.addEventListener("click", function (e) {
      var m = e.target.closest && e.target.closest("mark.cv-hl");
      if (!m) return;
      e.preventDefault();
      e.stopPropagation();
      var hid = m.dataset.hlId;
      var h = highlights.filter(function (x) {
        return x.id === hid;
      })[0];
      if (h) openNote(h, m);
    });
    saveBtn.addEventListener("click", function () {
      if (!editing) return;
      apiPost(id, "comment", { id: editing.id, comment: ta.value }).then(function (res) {
        if (res && res.ok) refreshFromState(res.state);
        note.classList.remove("open");
        editing = null;
      });
    });
    delBtn.addEventListener("click", function () {
      if (!editing) return;
      apiPost(id, "highlight_delete", { id: editing.id }).then(function (res) {
        if (res && res.ok) refreshFromState(res.state);
        note.classList.remove("open");
        editing = null;
      });
    });
    cancelBtn.addEventListener("click", function () {
      note.classList.remove("open");
      editing = null;
    });
  }

  function previewMount() {
    injectCSS();
    var scene = "both";
    try {
      scene = new URLSearchParams(location.search).get("scene") || "both";
    } catch (_) {}
    var mark = document.getElementById("cv-preview-sel");
    var noteMark = document.getElementById("cv-preview-note");
    var ui = el("div", "cv-reader-ui");
    var selbar = el("div", "cv-selbar open");
    selbar.innerHTML =
      '<i class="cv-caret"></i><button type="button" class="cv-hl-btn">' +
      '<i class="cv-swatch" aria-hidden="true"></i><span>划线</span></button><i class="cv-div"></i><button type="button">' +
      ico(ICO_NOTE) +
      "<span>评论</span></button>";
    var note = el("div", "cv-note open");
    note.innerHTML =
      '<div class="cv-grabber"></div>' +
      '<div class="cv-note-head"><strong>评论</strong></div>' +
      '<p class="cv-quote">dependencies between distant positions</p>' +
      '<textarea rows="3" maxlength="4000">这里记下为什么这段值得留。</textarea>' +
      '<button class="cv-danger" type="button">删除划线</button>' +
      '<div class="cv-note-actions"><button class="cv-ghost" type="button">取消</button>' +
      '<button class="cv-ok" type="button">提交</button></div>';
    if (scene !== "note") ui.appendChild(selbar);
    if (scene !== "sel" && noteMark) ui.appendChild(note);
    document.body.appendChild(ui);
    if (scene !== "note" && mark) {
      placeNearRect(selbar, lineRect(mark, "first"), {
        prefer: "above",
        gap: 12,
        bounds: mark.getBoundingClientRect(),
      });
    }
    if (scene !== "sel" && noteMark) {
      try {
        noteMark.scrollIntoView({ block: "center", behavior: "instant" });
      } catch (_) {}
      if (window.innerWidth <= 640) {
        note.classList.add("is-sheet");
      } else {
        placeNearRect(note, lineRect(noteMark, "last"), {
          prefer: "below",
          gap: 14,
          bounds: noteMark.getBoundingClientRect(),
          allowSide: true,
        });
      }
    }
  }

  function boot() {
    if (document.documentElement.hasAttribute("data-cv-preview")) {
      previewMount();
      return;
    }
    var root = articleRoot();
    var id = archiveId();
    if (!root || !id) return;
    var headings = collectHeadings(root);
    apiGet(id)
      .then(function (res) {
        mount(headings, id, (res && res.ok && res.state) || {});
      })
      .catch(function () {
        mount(headings, id, {});
      });
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", boot);
  else boot();
})();
