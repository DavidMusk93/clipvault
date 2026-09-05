import { EditorView, keymap, lineNumbers, highlightActiveLine, highlightActiveLineGutter, drawSelection } from '@codemirror/view'
import { EditorState, Prec } from '@codemirror/state'
import { defaultKeymap, history, historyKeymap, indentWithTab } from '@codemirror/commands'
import { markdown } from '@codemirror/lang-markdown'
import { HighlightStyle, syntaxHighlighting, bracketMatching, indentOnInput } from '@codemirror/language'
import { tags as t } from '@lezer/highlight'
import { marked } from 'marked'
import DOMPurify from 'dompurify'
import { renderMarkdownBlocks, mapLineToScrollTop, mapScrollTopToLine } from '../../markdown-render.mjs'

const MODE_KEY = 'clipvault.notes.mode'
const SPLIT_KEY = 'clipvault.notes.split'
const MODES = ['source', 'split', 'preview']

const notesTheme = EditorView.theme({
  '&': {
    height: '100%',
    background: 'transparent',
    fontSize: '14.5px',
    color: '#1d1d1f',
  },
  '&.cm-focused': { outline: 'none' },
  '.cm-scroller': {
    fontFamily: '"JetBrains Mono", ui-monospace, "SF Mono", SFMono-Regular, Menlo, Consolas, monospace',
    lineHeight: '1.62',
    fontVariantLigatures: 'none',
    overflow: 'auto',
  },
  '.cm-content': {
    padding: '16px 20px 56px 8px',
    caretColor: '#1d1d1f',
  },
  '.cm-gutters': {
    background: 'transparent',
    border: 'none',
    color: 'rgba(60,60,67,0.28)',
  },
  '.cm-activeLine': { backgroundColor: 'rgba(0,0,0,0.035)' },
  '.cm-activeLineGutter': { backgroundColor: 'transparent' },
  '.cm-lineNumbers .cm-gutterElement': { minWidth: '2.2em', padding: '0 10px 0 6px' },
  '.cm-selectionBackground': { background: 'rgba(0, 113, 227, 0.16)' },
  '&.cm-focused .cm-selectionBackground': { background: 'rgba(0, 113, 227, 0.2)' },
  '.cm-cursor': { borderLeftColor: '#1d1d1f' },
})

/* Xcode Light — headings stay ink, code tokens stay quiet. */
const appleLight = HighlightStyle.define([
  { tag: t.heading, color: '#1d1d1f', fontWeight: '650' },
  { tag: t.strong, fontWeight: '650' },
  { tag: t.emphasis, fontStyle: 'italic' },
  { tag: t.strikethrough, textDecoration: 'line-through', color: '#86868b' },
  { tag: t.link, color: '#0071e3' },
  { tag: t.url, color: '#6e6e73' },
  { tag: t.comment, color: '#6e6e73', fontStyle: 'italic' },
  { tag: t.keyword, color: '#9b2393' },
  { tag: t.string, color: '#c41a16' },
  { tag: t.number, color: '#1c00cf' },
  { tag: t.bool, color: '#1c00cf' },
  { tag: t.typeName, color: '#0b84d2' },
  { tag: t.className, color: '#0b84d2' },
  { tag: t.atom, color: '#0b84d2' },
  { tag: t.meta, color: '#6e6e73' },
  { tag: t.processingInstruction, color: '#86868b' },
  { tag: t.punctuation, color: '#86868b' },
  { tag: t.operator, color: '#4a4a4a' },
  { tag: t.contentSeparator, color: '#d2d2d7' },
  { tag: t.monospace, color: '#1d1d1f' },
])

function loadMode() {
  try {
    const v = localStorage.getItem(MODE_KEY)
    if (MODES.includes(v)) return v
  } catch (_) {}
  return window.matchMedia && window.matchMedia('(max-width: 820px)').matches ? 'source' : 'split'
}

function loadSplit() {
  try {
    const n = Number(localStorage.getItem(SPLIT_KEY))
    if (Number.isFinite(n) && n > 0.22 && n < 0.78) return n
  } catch (_) {}
  return 0.46
}

function wrapSelection(view, left, right) {
  const sel = view.state.selection.main
  const text = view.state.sliceDoc(sel.from, sel.to)
  const insert = left + text + (right ?? left)
  view.dispatch(view.state.replaceSelection(insert))
  view.focus()
}

function prefixLines(view, prefix) {
  const sel = view.state.selection.main
  const fromLine = view.state.doc.lineAt(sel.from)
  const toLine = view.state.doc.lineAt(sel.to)
  const changes = []
  for (let n = fromLine.number; n <= toLine.number; n++) {
    const line = view.state.doc.line(n)
    if (line.text.startsWith(prefix)) continue
    changes.push({ from: line.from, insert: prefix })
  }
  if (changes.length) view.dispatch({ changes })
  view.focus()
}

/** Nested ordered: 1. / a. / i. (Google Docs). 4 spaces per level so GFM nests. */
const LIST_ITEM = /^(\s*)([-*+]|\d+[.)]|[a-z][.)]|[ivxlcdm]+[.)])(\s+)(.*)$/i

function toRoman(n) {
  const map = [[10, 'x'], [9, 'ix'], [5, 'v'], [4, 'iv'], [1, 'i']]
  let s = ''
  for (const [v, sym] of map) {
    while (n >= v) { s += sym; n -= v }
  }
  return s || 'i'
}

function fromRoman(raw) {
  const map = { i: 1, v: 5, x: 10, l: 50, c: 100 }
  let n = 0
  let prev = 0
  for (const ch of String(raw).toLowerCase().split('').reverse()) {
    const v = map[ch] || 0
    n += v < prev ? -v : v
    prev = v
  }
  return n
}

function olMarker(depth, index) {
  const d = ((depth % 3) + 3) % 3
  if (d === 0) return `${index + 1}.`
  if (d === 1) return `${String.fromCharCode(97 + (index % 26))}.`
  return `${toRoman(index + 1)}.`
}

function nextOlMarker(marker, indentCols) {
  const body = marker.replace(/[.)]$/, '')
  const depth = Math.floor((indentCols || 0) / 4)
  const d = ((depth % 3) + 3) % 3
  if (d === 1 || (/^[a-z]$/i.test(body) && d !== 2)) {
    const c = body.toLowerCase().charCodeAt(0) + 1
    return c > 122 ? 'a.' : `${String.fromCharCode(c)}.`
  }
  if (d === 2 || /^[ivxlcdm]+$/i.test(body)) return `${toRoman(fromRoman(body) + 1)}.`
  const n = Number(body)
  return `${(Number.isFinite(n) ? n : 0) + 1}.`
}

function listDepth(indent) {
  return Math.min(6, Math.floor(indent.replace(/\t/g, '    ').length / 4))
}

function lastSiblingOlMarker(doc, beforeLineNum, targetDepth) {
  for (let n = beforeLineNum; n >= 1; n--) {
    const text = doc.line(n).text
    if (!text.trim()) continue
    const p = LIST_ITEM.exec(text)
    if (!p) return null
    const d = listDepth(p[1])
    if (d > targetDepth) continue
    if (d < targetDepth) return null
    if (/^[-*+]$/.test(p[2])) return null
    return p[2]
  }
  return null
}

function indentList(view, dir) {
  const sel = view.state.selection.main
  const fromLine = view.state.doc.lineAt(sel.from)
  const toLine = view.state.doc.lineAt(sel.to)
  const rows = []
  for (let n = fromLine.number; n <= toLine.number; n++) {
    const line = view.state.doc.line(n)
    const m = LIST_ITEM.exec(line.text)
    if (m) rows.push({ line, m })
  }
  if (!rows.length) return false
  let olNext = null
  const changes = []
  for (const { line, m } of rows) {
    const depth = listDepth(m[1])
    const next = Math.max(0, Math.min(6, depth + dir))
    const rest = m[4]
    const isUl = /^[-*+]$/.test(m[2])
    const spaces = '    '.repeat(next)
    let marker
    if (isUl) {
      marker = m[2]
      olNext = null
    } else {
      if (olNext == null) {
        const prev = lastSiblingOlMarker(view.state.doc, fromLine.number - 1, next)
        olNext = prev ? nextOlMarker(prev, next * 4) : olMarker(next, 0)
      }
      marker = olNext
      olNext = nextOlMarker(marker, next * 4)
    }
    changes.push({
      from: line.from,
      to: line.to,
      insert: `${spaces}${marker} ${rest}`,
    })
  }
  view.dispatch({ changes, userEvent: dir > 0 ? 'indent' : 'dedent' })
  return true
}

function continueList(view) {
  const sel = view.state.selection.main
  if (!sel.empty) return false
  const head = sel.head
  const line = view.state.doc.lineAt(head)
  const m = LIST_ITEM.exec(line.text)
  if (!m) return false
  const markerEnd = line.from + m[1].length + m[2].length + m[3].length
  if (head < markerEnd) return false
  const after = view.state.sliceDoc(head, line.to)
  const indentCols = m[1].replace(/\t/g, '    ').length
  if (!m[4].trim() && !after.trim()) {
    const depth = Math.floor(indentCols / 4)
    if (depth > 0) return indentList(view, -1)
    view.dispatch({
      changes: { from: line.from, to: line.to, insert: '' },
      userEvent: 'delete.list',
    })
    return true
  }
  const isUl = /^[-*+]$/.test(m[2])
  const marker = isUl ? m[2] : nextOlMarker(m[2], indentCols)
  const insert = `\n${m[1]}${marker} ${after}`
  const caret = head + 1 + m[1].length + marker.length + 1
  view.dispatch({
    changes: { from: head, to: line.to, insert },
    selection: { anchor: caret },
    userEvent: 'input',
  })
  return true
}

function insertBlock(view, text) {
  const sel = view.state.selection.main
  const line = view.state.doc.lineAt(sel.from)
  const needsNl = line.from !== sel.from && !line.text.endsWith('\n')
  view.dispatch(view.state.replaceSelection((needsNl ? '\n' : '') + text))
  view.focus()
}

async function mount(root, opts) {
  opts = opts || {}
  const upload = typeof opts.uploadImage === 'function' ? opts.uploadImage : null
  const onUpdate = typeof opts.onUpdate === 'function' ? opts.onUpdate : null
  const onMetric = typeof opts.onMetric === 'function' ? opts.onMetric : null
  const t0 = performance.now()

  root.replaceChildren()
  root.classList.add('notes-work')

  const sourceEl = document.createElement('div')
  sourceEl.className = 'notes-source'
  sourceEl.id = 'notesSource'
  const splitEl = document.createElement('div')
  splitEl.className = 'notes-splitter'
  splitEl.tabIndex = 0
  splitEl.setAttribute('role', 'separator')
  splitEl.setAttribute('aria-orientation', 'vertical')
  const previewEl = document.createElement('div')
  previewEl.className = 'notes-preview'
  previewEl.id = 'notesPreview'
  const previewInner = document.createElement('div')
  previewInner.className = 'notes-preview-inner'
  previewEl.appendChild(previewInner)
  root.append(sourceEl, splitEl, previewEl)

  let applying = false
  let gen = 0
  let lastMd = String(opts.markdown || '')
  let lastHash = ''
  let previewTimer = 0
  let mode = loadMode()
  let split = loadSplit()
  let syncing = false

  function metric(name, extra) {
    if (onMetric) onMetric(name, extra || {})
  }

  function applyMode() {
    root.dataset.mode = mode
    if (mode === 'split') {
      root.style.gridTemplateColumns = `${split}fr 5px ${1 - split}fr`
    } else {
      root.style.gridTemplateColumns = ''
    }
    try { localStorage.setItem(MODE_KEY, mode) } catch (_) {}
    if (mode !== 'preview') view.requestMeasure()
    if (mode === 'split') queueSyncFromSource()
  }

  function enhancePreview(root) {
    root.querySelectorAll('pre').forEach((pre) => {
      if (pre.parentElement && pre.parentElement.classList.contains('notes-code')) return
      const code = pre.querySelector('code') || pre
      const cls = code.className || ''
      const lang = (cls.match(/language-([\w+-]+)/) || cls.match(/lang-([\w+-]+)/) || [])[1] || ''
      const hljs = globalThis.hljs
      if (hljs && code.textContent) {
        try {
          if (lang && typeof hljs.getLanguage === 'function' && hljs.getLanguage(lang)) {
            code.innerHTML = hljs.highlight(code.textContent, { language: lang, ignoreIllegals: true }).value
            code.classList.add('hljs')
          } else if (typeof hljs.highlightElement === 'function') {
            hljs.highlightElement(code)
          }
        } catch (_) {}
      }
      const wrap = document.createElement('div')
      wrap.className = 'notes-code'
      pre.parentNode.insertBefore(wrap, pre)
      if (lang) {
        const lab = document.createElement('div')
        lab.className = 'notes-code-lang'
        lab.textContent = lang
        wrap.appendChild(lab)
      }
      wrap.appendChild(pre)
    })
    tagifyPreview(root)
  }

  function tagifyPreview(root) {
    const re = /(^|[^\w#])#([\p{L}\p{N}_/-]{1,32})/gu
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode(n) {
        const p = n.parentElement
        if (!p || p.closest('pre, code, a, .notes-tag')) return NodeFilter.FILTER_REJECT
        if (!n.nodeValue || n.nodeValue.indexOf('#') < 0) return NodeFilter.FILTER_REJECT
        return NodeFilter.FILTER_ACCEPT
      },
    })
    const nodes = []
    while (walker.nextNode()) nodes.push(walker.currentNode)
    for (const node of nodes) {
      const s = node.nodeValue
      re.lastIndex = 0
      if (!re.test(s)) continue
      re.lastIndex = 0
      const frag = document.createDocumentFragment()
      let last = 0
      let m
      while ((m = re.exec(s))) {
        const hashAt = m.index + m[1].length
        if (hashAt > last) frag.append(s.slice(last, hashAt))
        const span = document.createElement('span')
        span.className = 'notes-tag'
        span.dataset.tag = m[2]
        span.textContent = '#' + m[2]
        frag.append(span)
        last = hashAt + m[2].length + 1
      }
      if (last < s.length) frag.append(s.slice(last))
      node.parentNode.replaceChild(frag, node)
    }
  }

  function renderPreview(md, force) {
    const text = String(md || '')
    if (!force && text === lastHash) return
    lastHash = text
    const t = performance.now()
    if (!text.trim()) {
      previewInner.innerHTML = ''
      return
    }
    const r = renderMarkdownBlocks(text, { marked, purify: DOMPurify })
    previewInner.innerHTML = r.ok ? r.html : ''
    enhancePreview(previewInner)
    const dur = performance.now() - t
    metric('notes_preview_ms', { dur_ms: dur, payload: { chars: text.length } })
    if (dur > 16) metric('notes_input_to_preview', { dur_ms: dur })
    if (mode === 'split') queueSyncFromSource()
  }

  function schedulePreview(md) {
    lastMd = md
    clearTimeout(previewTimer)
    const delay = md.length > 50000 ? 200 : (md.length > 20000 ? 120 : 64)
    const run = () => renderPreview(lastMd)
    previewTimer = setTimeout(() => {
      if (md.length > 20000 && typeof requestIdleCallback === 'function') {
        requestIdleCallback(run, { timeout: 400 })
      } else {
        run()
      }
    }, delay)
  }

  function insertImage(file) {
    if (!upload || !file) return
    upload(file).then((url) => {
      if (!url) return
      insertBlock(view, `![](${url})\n`)
    }).catch(() => {})
  }

  const pasteDrop = EditorView.domEventHandlers({
    paste(event) {
      const files = [...(event.clipboardData?.files || [])]
      const img = files.find((f) => /^image\//.test(f.type))
      if (img) {
        event.preventDefault()
        insertImage(img)
        return true
      }
    },
    drop(event) {
      const files = [...(event.dataTransfer?.files || [])]
      const img = files.find((f) => /^image\//.test(f.type))
      if (img) {
        event.preventDefault()
        insertImage(img)
        return true
      }
    },
  })

  const state = EditorState.create({
    doc: lastMd,
    extensions: [
      lineNumbers(),
      highlightActiveLine(),
      highlightActiveLineGutter(),
      drawSelection(),
      history(),
      indentOnInput(),
      bracketMatching(),
      markdown(),
      syntaxHighlighting(appleLight, { fallback: true }),
      EditorView.lineWrapping,
      notesTheme,
      pasteDrop,
      Prec.highest(keymap.of([
        { key: 'Tab', run: (v) => indentList(v, 1) },
        { key: 'Shift-Tab', run: (v) => indentList(v, -1) },
        { key: 'Enter', run: continueList },
        { key: 'Shift-Enter', run: continueList },
        { key: 'Mod-b', run: (v) => { wrapSelection(v, '**'); return true } },
        { key: 'Mod-i', run: (v) => { wrapSelection(v, '*'); return true } },
        { key: 'Mod-e', run: (v) => { wrapSelection(v, '`'); return true } },
      ])),
      keymap.of([...defaultKeymap, ...historyKeymap, indentWithTab]),
      EditorView.updateListener.of((update) => {
        if (!update.docChanged) return
        const md = update.state.doc.toString()
        lastMd = md
        schedulePreview(md)
        if (!applying && onUpdate) onUpdate(md)
      }),
    ],
  })

  const view = new EditorView({ state, parent: sourceEl })
  let unlockTimer = 0
  function lockSync() {
    syncing = true
    clearTimeout(unlockTimer)
    unlockTimer = setTimeout(() => { syncing = false }, 80)
  }
  function yInScroller(el, scroller) {
    const a = el.getBoundingClientRect()
    const b = scroller.getBoundingClientRect()
    return a.top - b.top + scroller.scrollTop
  }
  function previewAnchors() {
    const out = []
    for (const n of previewInner.querySelectorAll('[data-source-line]')) {
      const line = Number(n.getAttribute('data-source-line'))
      if (!Number.isFinite(line) || line < 1) continue
      out.push({ line, y: yInScroller(n, previewEl) })
    }
    return out
  }
  function sourceLineAtTop(v) {
    try {
      if (v.viewport && Number.isFinite(v.viewport.from)) {
        return v.state.doc.lineAt(v.viewport.from).number
      }
    } catch (_) {}
    const src = v.scrollDOM
    const maxSrc = Math.max(1, src.scrollHeight - src.clientHeight)
    return 1 + (src.scrollTop / maxSrc) * Math.max(0, v.state.doc.lines - 1)
  }
  function syncPreviewToSource(v) {
    if (mode !== 'split' || syncing) return
    const src = v.scrollDOM
    const maxSrc = Math.max(0, src.scrollHeight - src.clientHeight)
    const maxPr = Math.max(0, previewEl.scrollHeight - previewEl.clientHeight)
    if (maxPr <= 0) return
    const r = maxSrc > 0 ? src.scrollTop / maxSrc : 0
    const top = r <= 0 ? 0 : r >= 1
      ? maxPr
      : mapLineToScrollTop(sourceLineAtTop(v), previewAnchors(), v.state.doc.lines, maxPr)
    if (Math.abs(previewEl.scrollTop - top) < 1) return
    lockSync()
    previewEl.scrollTop = top
  }
  function syncSourceToPreview() {
    if (mode !== 'split' || syncing) return
    const maxPr = Math.max(0, previewEl.scrollHeight - previewEl.clientHeight)
    const maxSrc = Math.max(0, view.scrollDOM.scrollHeight - view.scrollDOM.clientHeight)
    if (maxSrc <= 0) return
    const r = maxPr > 0 ? previewEl.scrollTop / maxPr : 0
    let next
    if (r <= 0) next = 0
    else if (r >= 1) next = maxSrc
    else {
      const line = mapScrollTopToLine(previewEl.scrollTop, previewAnchors(), view.state.doc.lines, maxPr)
      const n = Math.max(1, Math.min(view.state.doc.lines, Math.round(line)))
      next = view.lineBlockAt(view.state.doc.line(n).from).top
    }
    next = Math.max(0, Math.min(maxSrc, next))
    if (Math.abs(view.scrollDOM.scrollTop - next) < 2) return
    lockSync()
    view.scrollDOM.scrollTop = next
  }
  function queueSyncFromSource() {
    requestAnimationFrame(() => syncPreviewToSource(view))
  }
  view.scrollDOM.addEventListener('scroll', () => syncPreviewToSource(view), { passive: true })
  previewEl.addEventListener('scroll', syncSourceToPreview, { passive: true })
  previewEl.addEventListener('load', (e) => {
    if (e.target && e.target.tagName === 'IMG' && mode === 'split') queueSyncFromSource()
  }, true)

  previewEl.addEventListener('click', (e) => {
    const tag = e.target.closest && e.target.closest('.notes-tag')
    if (!tag || typeof opts.onTag !== 'function') return
    opts.onTag(tag.dataset.tag || tag.textContent.replace(/^#/, ''))
  })

  splitEl.addEventListener('pointerdown', (e) => {
    if (mode !== 'split') return
    e.preventDefault()
    splitEl.setPointerCapture(e.pointerId)
    const rect = root.getBoundingClientRect()
    const move = (ev) => {
      const r = (ev.clientX - rect.left) / rect.width
      split = Math.min(0.78, Math.max(0.22, r))
      root.style.gridTemplateColumns = `${split}fr 5px ${1 - split}fr`
    }
    const up = () => {
      splitEl.removeEventListener('pointermove', move)
      splitEl.removeEventListener('pointerup', up)
      try { localStorage.setItem(SPLIT_KEY, String(split)) } catch (_) {}
      metric('notes_split_resize', { payload: { ratio: Math.round(split * 100) / 100 } })
    }
    splitEl.addEventListener('pointermove', move)
    splitEl.addEventListener('pointerup', up)
  })

  applyMode()
  schedulePreview(lastMd)
  metric('notes_editor_mount', { dur_ms: performance.now() - t0 })

  const api = {
    getMarkdown() { return view.state.doc.toString() },
    setMarkdown(md) {
      gen += 1
      const g = gen
      applying = true
      const next = String(md || '')
      view.dispatch({
        changes: { from: 0, to: view.state.doc.length, insert: next },
      })
      lastMd = next
      renderPreview(next, true)
      const clear = () => { if (g === gen) applying = false }
      queueMicrotask(clear)
      requestAnimationFrame(clear)
    },
    destroy() {
      clearTimeout(previewTimer)
      clearTimeout(unlockTimer)
      view.destroy()
      root.replaceChildren()
    },
    setMode(next) {
      if (!MODES.includes(next) || next === mode) return
      mode = next
      applyMode()
      metric('notes_mode', { payload: { mode } })
    },
    getMode() { return mode },
    cycleMode() {
      const i = MODES.indexOf(mode)
      api.setMode(MODES[(i + 1) % MODES.length])
    },
    command(name) {
      if (mode === 'preview') return
      switch (name) {
        case 'h1': prefixLines(view, '# '); break
        case 'h2': prefixLines(view, '## '); break
        case 'h3': prefixLines(view, '### '); break
        case 'bold': wrapSelection(view, '**'); break
        case 'italic': wrapSelection(view, '*'); break
        case 'code': wrapSelection(view, '`'); break
        case 'ul': prefixLines(view, '- '); break
        case 'ol': prefixLines(view, '1. '); break
        case 'quote': prefixLines(view, '> '); break
        case 'link': wrapSelection(view, '[', '](url)'); break
        case 'hr': insertBlock(view, '\n---\n'); break
        case 'table': insertBlock(view, '\n| 列 | 列 |\n| --- | --- |\n|  |  |\n'); break
        case 'codeblock': insertBlock(view, '\n```\n\n```\n'); break
        default: break
      }
    },
    focus() { view.focus() },
  }
  return api
}

globalThis.ClipNotesEditor = { mount }
