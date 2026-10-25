/**
 * One matcher for notes find/replace (source, preview, sidebar reveal).
 *
 * spec = {
 *   query?: string,          // plain-text find/replace box
 *   tokens?: string[],       // legacy sidebar reveal (same highlighting path)
 *   caseSensitive?: boolean, // default false, like the sidebar
 *   wholeWord?: boolean,     // don't match inside `fooBar` / `笔记本文`
 * }
 *
 * Ranges are half-open [from, to) UTF-16 offsets into `text`, sorted and
 * non-overlapping. The editor decorates them directly; preview wraps them in
 * DOM Ranges; replace dispatches them as CodeMirror changes.
 */

export function escapeRegExp(value) {
  return String(value == null ? '' : value).replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

function isWordChar(ch) {
  return !!ch && /[\p{L}\p{N}_]/u.test(ch)
}

function onWordBoundary(text, from, to) {
  return !isWordChar(from > 0 ? text[from - 1] : '') && !isWordChar(to < text.length ? text[to] : '')
}

export function findRanges(text, spec) {
  const source = String(text == null ? '' : text)
  const options = spec || {}
  const tokens = Array.isArray(options.tokens) ? options.tokens.filter(Boolean) : []
  const query = options.query == null ? '' : String(options.query)
  const needles = query ? [query] : tokens
  const out = []
  if (!source || !needles.length) return out

  const pattern = needles.map(escapeRegExp).join('|')
  const flags = 'gu' + (options.caseSensitive ? '' : 'i')
  const re = new RegExp(pattern, flags)
  let match
  while ((match = re.exec(source)) !== null) {
    const from = match.index
    const to = from + match[0].length
    if (!match[0].length) {
      re.lastIndex += 1
      continue
    }
    if (options.wholeWord && !onWordBoundary(source, from, to)) continue
    out.push({ from, to })
  }
  return out
}

/** CodeMirror changes that replace every range in one undoable transaction. */
export function replacementChanges(ranges, replacement) {
  const insert = String(replacement == null ? '' : replacement)
  return (ranges || []).map((r) => ({ from: r.from, to: r.to, insert }))
}
