/**
 * ClipVault archive reader chrome — lives IN the view document.
 * TOC is derived at runtime. Reading position is browser-local only
 * (IndexedDB, localStorage fallback). Never SQLite.
 */
(function () {
  "use strict";

  var IDB_NAME = "clipvault-reader";
  var IDB_STORE = "progress";
  var LS_PREFIX = "cv.reader.";
  var SAVE_MS = 280;

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
    return String(el.textContent || "")
      .replace(/\s+/g, " ")
      .trim();
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
      out.push({
        el: el,
        id: el.id,
        text: text,
        level: Number(el.tagName.charAt(1)),
      });
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

  function openDB() {
    return new Promise(function (resolve, reject) {
      if (!window.indexedDB) {
        reject(new Error("no idb"));
        return;
      }
      var req = indexedDB.open(IDB_NAME, 1);
      req.onupgradeneeded = function () {
        var db = req.result;
        if (!db.objectStoreNames.contains(IDB_STORE)) db.createObjectStore(IDB_STORE);
      };
      req.onsuccess = function () {
        resolve(req.result);
      };
      req.onerror = function () {
        reject(req.error);
      };
    });
  }

  function idbGet(key) {
    return openDB().then(function (db) {
      return new Promise(function (resolve, reject) {
        var tx = db.transaction(IDB_STORE, "readonly");
        var req = tx.objectStore(IDB_STORE).get(key);
        req.onsuccess = function () {
          resolve(req.result || null);
        };
        req.onerror = function () {
          reject(req.error);
        };
      });
    });
  }

  function idbSet(key, value) {
    return openDB().then(function (db) {
      return new Promise(function (resolve, reject) {
        var tx = db.transaction(IDB_STORE, "readwrite");
        tx.objectStore(IDB_STORE).put(value, key);
        tx.oncomplete = function () {
          resolve();
        };
        tx.onerror = function () {
          reject(tx.error);
        };
      });
    });
  }

  function lsGet(key) {
    try {
      var raw = localStorage.getItem(LS_PREFIX + key);
      return raw ? JSON.parse(raw) : null;
    } catch (_) {
      return null;
    }
  }

  function lsSet(key, value) {
    try {
      localStorage.setItem(LS_PREFIX + key, JSON.stringify(value));
    } catch (_) {}
  }

  function loadProgress(id) {
    if (!id) return Promise.resolve(null);
    return idbGet(id)
      .catch(function () {
        return null;
      })
      .then(function (row) {
        return row || lsGet(id);
      });
  }

  function saveProgress(id, row) {
    if (!id) return;
    lsSet(id, row);
    idbSet(id, row).catch(function () {});
  }

  function injectCSS() {
    if (document.getElementById("cv-reader-css")) return;
    var css = document.createElement("style");
    css.id = "cv-reader-css";
    css.textContent = [
      ".cv-reader-ui{font-family:-apple-system,BlinkMacSystemFont,'SF Pro Text',system-ui,sans-serif;}",
      ".cv-progress{position:fixed;top:0;left:0;height:2px;width:0;z-index:40;",
      "background:#0071e3;pointer-events:none;transition:width .12s linear;}",
      ".cv-toc-fab{position:fixed;right:16px;bottom:18px;z-index:42;height:40px;",
      "padding:0 14px;border:0;border-radius:999px;cursor:pointer;",
      "display:inline-flex;align-items:center;gap:6px;",
      "background:rgba(29,29,31,.88);color:#fff;font:inherit;font-size:13px;font-weight:600;",
      "letter-spacing:-.01em;box-shadow:0 8px 24px rgba(0,0,0,.18);",
      "backdrop-filter:blur(16px) saturate(160%);-webkit-backdrop-filter:blur(16px) saturate(160%);}",
      ".cv-toc-fab:hover{background:rgba(29,29,31,.96);}",
      ".cv-toc-fab .cv-toc-count{opacity:.72;font-weight:500;}",
      ".cv-toc-panel{position:fixed;right:16px;bottom:66px;z-index:42;width:min(320px,calc(100vw - 28px));",
      "max-height:min(68vh,560px);display:none;flex-direction:column;",
      "background:rgba(255,255,255,.96);color:#1d1d1f;border-radius:16px;",
      "border:.5px solid rgba(60,60,67,.12);overflow:hidden;",
      "box-shadow:0 18px 48px rgba(0,0,0,.18);}",
      ".cv-toc-panel.open{display:flex;}",
      ".cv-toc-head{padding:12px 14px 8px;display:flex;align-items:center;justify-content:space-between;gap:8px;}",
      ".cv-toc-head strong{font-size:13px;letter-spacing:-.02em;}",
      ".cv-toc-filter{margin:0 12px 8px;height:32px;border-radius:8px;border:.5px solid rgba(60,60,67,.16);",
      "padding:0 10px;font:inherit;font-size:13px;background:#f5f5f7;outline:none;}",
      ".cv-toc-filter:focus{border-color:rgba(0,113,227,.45);box-shadow:0 0 0 3px rgba(0,113,227,.12);background:#fff;}",
      ".cv-toc-list{overflow:auto;padding:4px 8px 10px;-webkit-overflow-scrolling:touch;}",
      ".cv-toc-item{display:block;width:100%;text-align:left;border:0;background:transparent;",
      "border-radius:10px;padding:8px 10px;font:inherit;font-size:13px;line-height:1.35;",
      "color:#1d1d1f;cursor:pointer;letter-spacing:-.01em;}",
      ".cv-toc-item[data-level='3']{padding-left:20px;font-size:12.5px;color:#6e6e73;}",
      ".cv-toc-item:hover{background:rgba(120,120,128,.12);}",
      ".cv-toc-item.is-active{background:rgba(0,113,227,.12);color:#003d82;font-weight:600;}",
      ".cv-resume{position:fixed;left:50%;bottom:18px;transform:translateX(-50%);z-index:41;",
      "height:34px;padding:0 12px;border-radius:999px;border:0;display:none;align-items:center;",
      "background:rgba(255,255,255,.94);color:#1d1d1f;font:inherit;font-size:12.5px;font-weight:600;",
      "box-shadow:0 8px 24px rgba(0,0,0,.14);max-width:min(72vw,420px);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}",
      ".cv-resume.show{display:inline-flex;}",
      "main.cv-article{scroll-margin-top:12px;}",
      "main.cv-article h1,main.cv-article h2,main.cv-article h3,main.cv-article h4{scroll-margin-top:16px;}",
      "@media (max-width:640px){.cv-toc-fab{right:12px;bottom:14px;}.cv-toc-panel{right:12px;bottom:60px;}}",
    ].join("");
    document.head.appendChild(css);
  }

  function el(tag, cls, text) {
    var node = document.createElement(tag);
    if (cls) node.className = cls;
    if (text != null) node.textContent = text;
    return node;
  }

  function mount(headings, id) {
    injectCSS();
    var ui = el("div", "cv-reader-ui");
    var bar = el("div", "cv-progress");
    var fab = el("button", "cv-toc-fab");
    fab.type = "button";
    fab.setAttribute("aria-expanded", "false");
    fab.innerHTML = "目录 <span class=\"cv-toc-count\">" + headings.length + "</span>";
    var panel = el("div", "cv-toc-panel");
    panel.setAttribute("role", "navigation");
    panel.setAttribute("aria-label", "文章目录");
    var head = el("div", "cv-toc-head");
    head.appendChild(el("strong", "", "章节"));
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
    ui.appendChild(bar);
    ui.appendChild(panel);
    ui.appendChild(fab);
    ui.appendChild(resume);
    document.body.appendChild(ui);

    function closePanel() {
      panel.classList.remove("open");
      fab.setAttribute("aria-expanded", "false");
    }
    function openPanel() {
      panel.classList.add("open");
      fab.setAttribute("aria-expanded", "true");
      if (filter) filter.focus();
      var active = list.querySelector(".is-active");
      if (active) active.scrollIntoView({ block: "nearest" });
    }
    fab.addEventListener("click", function () {
      if (panel.classList.contains("open")) closePanel();
      else openPanel();
    });
    document.addEventListener("keydown", function (e) {
      if (e.key === "Escape") closePanel();
    });
    document.addEventListener("click", function (e) {
      if (!ui.contains(e.target)) closePanel();
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

    var saveTimer = 0;
    function persist() {
      var hit = nearestHeading(headings, currentY() + 8);
      saveProgress(id, {
        y: Math.round(currentY()),
        ratio: Number(currentRatio().toFixed(4)),
        headingId: hit ? hit.id : "",
        headingText: hit ? hit.text : "",
        updatedAt: Date.now(),
      });
    }
    function onScroll() {
      markActive();
      if (saveTimer) clearTimeout(saveTimer);
      saveTimer = setTimeout(persist, SAVE_MS);
    }
    window.addEventListener("scroll", onScroll, { passive: true });
    window.addEventListener("pagehide", persist);
    document.addEventListener("visibilitychange", function () {
      if (document.visibilityState === "hidden") persist();
    });
    markActive();

    function applyProgress(row) {
      if (!row) return;
      var y = 0;
      if (row.headingId && document.getElementById(row.headingId)) {
        var t = document.getElementById(row.headingId);
        y = t.getBoundingClientRect().top + currentY() - 12;
      } else if (typeof row.y === "number" && row.y > 0) {
        y = row.y;
      } else if (typeof row.ratio === "number" && row.ratio > 0) {
        y = row.ratio * scrollMax();
      }
      if (y < 80) return;
      window.scrollTo(0, y);
      markActive();
      if (row.headingText) {
        resume.textContent = "已回到 · " + row.headingText;
        resume.classList.add("show");
        setTimeout(function () {
          resume.classList.remove("show");
        }, 2200);
      }
    }

    loadProgress(id).then(function (row) {
      requestAnimationFrame(function () {
        applyProgress(row);
      });
    });
  }

  function boot() {
    var root = articleRoot();
    if (!root) return;
    var headings = collectHeadings(root);
    var id = archiveId();
    if (headings.length < 3) {
      loadProgress(id).then(function (row) {
        if (!row) return;
        requestAnimationFrame(function () {
          if (typeof row.y === "number" && row.y > 80) window.scrollTo(0, row.y);
        });
      });
      var saveTimer = 0;
      window.addEventListener(
        "scroll",
        function () {
          if (saveTimer) clearTimeout(saveTimer);
          saveTimer = setTimeout(function () {
            saveProgress(id, { y: Math.round(currentY()), ratio: Number(currentRatio().toFixed(4)), headingId: "", headingText: "", updatedAt: Date.now() });
          }, SAVE_MS);
        },
        { passive: true }
      );
      return;
    }
    mount(headings, id);
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", boot);
  else boot();
})();
