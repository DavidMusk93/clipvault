import { EditorView, keymap, lineNumbers, highlightActiveLine, highlightActiveLineGutter, drawSelection } from '@codemirror/view'
import { EditorState, Prec } from '@codemirror/state'
import { defaultKeymap, history, historyKeymap, indentWithTab } from '@codemirror/commands'
import { markdown } from '@codemirror/lang-markdown'
import { syntaxHighlighting, defaultHighlightStyle, bracketMatching, indentOnInput } from '@codemirror/language'
import { marked } from 'marked'
import DOMPurify from 'dompurify'
import { renderMarkdownBlocks } from '../../markdown-render.mjs'

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
    fontFamily: '"JetBrains Mono", ui-monospace, SFMono-Regular, Menlo, Consolas, monospace',
    lineHeight: '1.6',
    fontVariantLigatures: 'none',
    overflow: 'auto',
  },
  '.cm-content': {
    padding: '12px 18px 56px 8px',
    caretColor: '#1d1d1f',
  },
  '.cm-gutters': {
    background: 'transparent',
    border: 'none',
    color: 'rgba(60,60,67,0.36)',
  },
  '.cm-activeLine': { backgroundColor: 'rgba(196,122,44,0.07)' },
  '.cm-activeLineGutter': { backgroundColor: 'transparent' },
  '.cm-lineNumbers .cm-gutterElement': { minWidth: '2.2em', padding: '0 8px 0 4px' },
})

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
  }

  function renderPreview(md) {
    const text = String(md || '')
    if (text === lastHash) return
    lastHash = text
    const t = performance.now()
    const r = renderMarkdownBlocks(text, { marked, purify: DOMPurify })
    previewInner.innerHTML = r.ok ? r.html : ''
    const dur = performance.now() - t
    metric('notes_preview_ms', { dur_ms: dur, payload: { chars: text.length } })
    if (dur > 16) metric('notes_input_to_preview', { dur_ms: dur })
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
      syntaxHighlighting(defaultHighlightStyle, { fallback: true }),
      EditorView.lineWrapping,
      notesTheme,
      pasteDrop,
      Prec.high(keymap.of([
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
  view.scrollDOM.addEventListener('scroll', () => {
    if (mode !== 'split' || syncing) return
    syncPreviewToSource(view)
  }, { passive: true })

  function syncPreviewToSource(v) {
    const box = v.scrollDOM.getBoundingClientRect()
    const pos = v.posAtCoords({ x: box.left + 24, y: box.top + 12 })
    if (pos == null) return
    const line = v.state.doc.lineAt(pos).number
    const nodes = previewInner.querySelectorAll('[data-source-line]')
    let best = null
    for (const n of nodes) {
      const ln = Number(n.getAttribute('data-source-line'))
      if (ln <= line) best = n
      else break
    }
    if (!best) return
    syncing = true
    const top = best.offsetTop - 12
    previewEl.scrollTop = Math.max(0, top)
    requestAnimationFrame(() => { syncing = false })
  }

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
      lastHash = ''
      schedulePreview(next)
      const clear = () => { if (g === gen) applying = false }
      queueMicrotask(clear)
      requestAnimationFrame(clear)
    },
    destroy() {
      clearTimeout(previewTimer)
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
