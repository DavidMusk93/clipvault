/**
 * ClipVault archive reader chrome — lives IN the view document.
 * TOC is derived at runtime. Learning traces (resume / highlight / comment)
 * persist via same-origin SQLite APIs. Archive HTML is never mutated on disk.
 */
(function () {
  "use strict";

  var SCROLL_MS = 2400;

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
      "mark.cv-hl{background:rgba(255,214,10,.55);color:inherit;border-radius:2px;padding:0 .08em;cursor:pointer;}",
      "mark.cv-hl.has-note{box-shadow:inset 0 -2px 0 #0071e3;}",
      ".cv-selbar{position:fixed;z-index:50;display:none;gap:6px;padding:4px;",
      "background:rgba(29,29,31,.92);border-radius:12px;box-shadow:0 10px 28px rgba(0,0,0,.22);}",
      ".cv-selbar.open{display:flex;}",
      ".cv-selbar button{border:0;background:transparent;color:#fff;font:inherit;font-size:12.5px;font-weight:600;",
      "padding:6px 10px;border-radius:8px;cursor:pointer;}",
      ".cv-selbar button:hover{background:rgba(255,255,255,.12);}",
      ".cv-note{position:fixed;z-index:51;display:none;flex-direction:column;gap:8px;width:min(320px,calc(100vw - 24px));",
      "padding:12px;background:#fff;border-radius:14px;border:.5px solid rgba(60,60,67,.12);box-shadow:0 16px 40px rgba(0,0,0,.18);}",
      ".cv-note.open{display:flex;}",
      ".cv-note textarea{min-height:72px;border:.5px solid rgba(60,60,67,.16);border-radius:10px;padding:8px 10px;",
      "font:inherit;font-size:13px;resize:vertical;outline:none;}",
      ".cv-note .cv-note-actions{display:flex;justify-content:flex-end;gap:8px;}",
      ".cv-note button{border:0;border-radius:8px;padding:6px 10px;font:inherit;font-size:12.5px;font-weight:600;cursor:pointer;}",
      ".cv-note .cv-ok{background:#0071e3;color:#fff;}",
      ".cv-note .cv-ghost{background:rgba(120,120,128,.12);}",
      ".cv-note .cv-danger{background:rgba(215,0,21,.1);color:#d70015;margin-right:auto;}",
      "main.cv-article h1,main.cv-article h2,main.cv-article h3,main.cv-article h4{scroll-margin-top:16px;}",
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
    var hlBtn = el("button", "", "划线");
    var cmtBtn = el("button", "", "评论");
    hlBtn.type = "button";
    cmtBtn.type = "button";
    selbar.appendChild(hlBtn);
    selbar.appendChild(cmtBtn);
    var note = el("div", "cv-note");
    var ta = document.createElement("textarea");
    ta.placeholder = "写下你的想法…";
    var actions = el("div", "cv-note-actions");
    var delBtn = el("button", "cv-danger", "删除划线");
    var cancelBtn = el("button", "cv-ghost", "取消");
    var saveBtn = el("button", "cv-ok", "保存");
    delBtn.type = cancelBtn.type = saveBtn.type = "button";
    actions.appendChild(delBtn);
    actions.appendChild(cancelBtn);
    actions.appendChild(saveBtn);
    note.appendChild(ta);
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
    function showSel(rect) {
      selbar.classList.add("open");
      var left = Math.min(window.innerWidth - 160, Math.max(8, rect.left + rect.width / 2 - 70));
      var top = Math.max(8, rect.top - 44);
      selbar.style.left = left + "px";
      selbar.style.top = top + "px";
    }
    document.addEventListener("mouseup", function () {
      setTimeout(function () {
        pendingSel = serializeSelection(root);
        if (!pendingSel) {
          hideSel();
          return;
        }
        var sel = window.getSelection();
        if (!sel.rangeCount) return;
        showSel(sel.getRangeAt(0).getBoundingClientRect());
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
      ta.value = h.comment || "";
      note.classList.add("open");
      var r = (anchor || noteFab).getBoundingClientRect();
      note.style.left = Math.min(window.innerWidth - 340, Math.max(8, r.left)) + "px";
      note.style.top = Math.min(window.innerHeight - 180, Math.max(8, r.bottom + 8)) + "px";
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

  function boot() {
    var root = articleRoot();
    var id = archiveId();
    if (!root || !id) return;
    var headings = collectHeadings(root);
    apiGet(id)
      .then(function (res) {
        var state = (res && res.ok && res.state) || {};
        if (headings.length >= 3) mount(headings, id, state);
        else {
          injectCSS();
          if (state.pos && typeof state.pos.y === "number" && state.pos.y > 80) {
            window.scrollTo(0, state.pos.y);
          }
          applyHighlights(root, state.highlights || []);
          var t = 0;
          window.addEventListener(
            "scroll",
            function () {
              if (t) clearTimeout(t);
              t = setTimeout(function () {
                apiPost(id, "scroll_checkpoint", { y: Math.round(currentY()), ratio: Number(currentRatio().toFixed(4)) });
              }, SCROLL_MS);
            },
            { passive: true }
          );
        }
      })
      .catch(function () {
        if (headings.length >= 3) mount(headings, id, {});
      });
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", boot);
  else boot();
})();
