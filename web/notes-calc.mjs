/**
 * Notes editor helpers: checkpoint stamps + inline arithmetic.
 * No eval(). Parser is numbers / + - * / % ^ / parentheses only.
 */

const LIST_PREFIX = /^(\s*)([-*+]|\d+[.)]|[a-z][.)]|[ivxlcdm]+[.)])(\s+)/i
const FENCE = /^\s*(```|~~~)/
const HR = /^\s*---\s*$/
const STAMP = /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}\s*$/

export function formatCheckpoint(d = new Date()) {
  const p = (n) => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`
}

export function isHrLine(text) {
  return HR.test(String(text || ''))
}

export function isStampLine(text) {
  return STAMP.test(String(text || '').trim())
}

/** prevLines = lines strictly before the current one. */
export function inFence(prevLines) {
  let n = 0
  for (const t of prevLines) {
    if (FENCE.test(t)) n++
  }
  return n % 2 === 1
}

export function formatNum(n) {
  if (!Number.isFinite(n)) return null
  const r = Math.round(n)
  if (Math.abs(n - r) < 1e-12) return String(Object.is(r, -0) ? 0 : r)
  const s = parseFloat(n.toPrecision(10))
  if (!Number.isFinite(s)) return null
  return String(Object.is(s, -0) ? 0 : s)
}

/**
 * Evaluate a compact arithmetic expression.
 * @returns {string|null} formatted result, or null if not a safe expression
 */
export function tryEval(src) {
  const raw = String(src || '')
    .replace(/×/g, '*')
    .replace(/÷/g, '/')
    .replace(/\s+/g, '')
  if (!raw || raw.length > 80) return null
  const ops = raw.replace(/^-/, '')
  if (!/[+\-*/^%]/.test(ops)) return null

  let i = 0
  const peek = () => raw[i] || ''
  const eat = () => raw[i++] || ''

  function num() {
    const m = raw.slice(i).match(/^(\d+(\.\d*)?|\.\d+)([eE][+-]?\d+)?/)
    if (!m) return null
    i += m[0].length
    const v = Number(m[0])
    return Number.isFinite(v) ? v : null
  }

  function unary() {
    if (peek() === '+' || peek() === '-') {
      const op = eat()
      const v = unary()
      if (v == null) return null
      return op === '-' ? -v : v
    }
    if (peek() === '(') {
      eat()
      const v = expr()
      if (v == null || peek() !== ')') return null
      eat()
      return v
    }
    return num()
  }

  function power() {
    const left = unary()
    if (left == null) return null
    if (peek() !== '^') return left
    eat()
    const right = power()
    if (right == null) return null
    const v = Math.pow(left, right)
    return Number.isFinite(v) ? v : null
  }

  function term() {
    let left = power()
    if (left == null) return null
    while (peek() === '*' || peek() === '/' || peek() === '%') {
      const op = eat()
      const right = power()
      if (right == null) return null
      if (op === '/' && right === 0) return null
      if (op === '%') left = left % right
      else if (op === '*') left = left * right
      else left = left / right
      if (!Number.isFinite(left)) return null
    }
    return left
  }

  function expr() {
    let left = term()
    if (left == null) return null
    while (peek() === '+' || peek() === '-') {
      const op = eat()
      const right = term()
      if (right == null) return null
      left = op === '+' ? left + right : left - right
      if (!Number.isFinite(left)) return null
    }
    return left
  }

  const v = expr()
  if (v == null || i !== raw.length) return null
  return formatNum(v)
}

/**
 * Expression immediately before a just-typed '=' at caretCol.
 * caretCol is the index after '='.
 */
export function extractCalcExpr(line, caretCol) {
  const s = String(line || '')
  if (caretCol < 1 || caretCol > s.length) return null
  if (s[caretCol - 1] !== '=') return null
  const prev = s[caretCol - 2] || ''
  if ('=<>!:'.includes(prev)) return null
  const before = s.slice(0, caretCol)
  if (((before.match(/`/g) || []).length) % 2 === 1) return null

  const list = LIST_PREFIX.exec(s)
  const min = list ? list[0].length : 0
  if (caretCol - 1 < min) return null

  let i = caretCol - 2
  while (i >= min && s[i] === ' ') i--
  const exprEnd = i + 1
  while (i >= min && /[0-9+\-*/^%×÷().eE\s]/.test(s[i])) i--
  if (i >= min && /[\p{L}_]/u.test(s[i]) && s[i + 1] !== ' ') return null
  const expr = s.slice(Math.max(min, i + 1), exprEnd).trim()
  if (!expr) return null
  return expr
}

export function hrStampBlock(d) {
  return `---\n${formatCheckpoint(d)}\n\n`
}
