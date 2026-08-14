/**
 * Trae session surface — JSON / Markdown / code for hook events.
 * Reuse ClipVault formatters. No DIY markdown grammar.
 * Copy path must keep raw source (this module only produces display HTML).
 */
import { renderMarkdownToHtml } from './markdown-render.mjs';
import { formatTextForDisplay, resolveBeautifiers } from './text-format.mjs';

export function asObj(value) {
  if (value == null || value === '') return null;
  if (typeof value === 'object') return value;
  try {
    return JSON.parse(value);
  } catch {
    return null;
  }
}

export function prettyJson(value) {
  if (value == null || value === '') return '';
  if (typeof value === 'string') {
    const obj = asObj(value);
    return obj ? JSON.stringify(obj, null, 2) : value;
  }
  return JSON.stringify(value, null, 2);
}

/** IM role for a hook event. Taste: docs/design-taste.md 「Trae 会话 IM 角色色」 */
export const IM_ROLES = {
  user: { label: '你', align: 'end' },
  assistant: { label: '助手', align: 'start' },
  tool: { label: '工具', align: 'start' },
  system: { label: '系统', align: 'center' },
};

export function roleFromEvent(event) {
  const name = String(event?.hook_event || '');
  if (name === 'UserPromptSubmit') return 'user';
  if (name === 'Stop') return 'assistant';
  if (name === 'PreToolUse' || name === 'PostToolUse') return 'tool';
  return 'system';
}

/**
 * Chronological IM rows. Drop PreToolUse when PostToolUse shares tool_use_id.
 * @param {object[]} events
 */
export function imMessagesFromEvents(events) {
  const list = [...(events || [])].sort((a, b) => {
    const ta = String(a.ts || '');
    const tb = String(b.ts || '');
    if (ta < tb) return -1;
    if (ta > tb) return 1;
    return String(a.event_id || '').localeCompare(String(b.event_id || ''));
  });
  const posted = new Set(
    list
      .filter((e) => e.hook_event === 'PostToolUse' && e.tool_use_id)
      .map((e) => e.tool_use_id),
  );
  return list
    .filter((e) => !(e.hook_event === 'PreToolUse' && e.tool_use_id && posted.has(e.tool_use_id)))
    .map((event) => {
      const role = roleFromEvent(event);
      return { role, ...IM_ROLES[role], event };
    });
}

export function toolCommand(input) {
  const obj = asObj(input) || {};
  return obj.cmd || obj.command || obj.command_line || '';
}

/** Structured blocks for one hook event. Each has raw text + render hint. */
export function blocksFromEvent(event) {
  const blocks = [];
  const resp = asObj(event.tool_response);
  const cmd = toolCommand(event.tool_input);
  if (event.prompt) blocks.push({ key: 'prompt', hint: 'markdown', text: String(event.prompt) });
  if (event.last_assistant_message) {
    blocks.push({ key: 'assistant', hint: 'markdown', text: String(event.last_assistant_message) });
  }
  if (event.notification_message) {
    blocks.push({ key: 'message', hint: 'markdown', text: String(event.notification_message) });
  }
  if (cmd) blocks.push({ key: 'command', hint: 'code', text: cmd });
  else if (event.tool_input) {
    blocks.push({ key: 'tool_input', hint: 'json', text: prettyJson(event.tool_input) });
  }
  if (resp) {
    const bits = [];
    if (resp.exit_code != null) bits.push('exit ' + resp.exit_code);
    if (resp.status) bits.push(String(resp.status));
    if (resp.wall_time_seconds != null) bits.push(resp.wall_time_seconds + 's');
    if (bits.length) blocks.push({ key: 'result', hint: 'meta', text: bits.join(' · ') });
    const out = resp.output || resp.stdout || resp.stderr || '';
    if (out) blocks.push({ key: 'output', hint: 'auto', text: String(out) });
    const rest = { ...resp };
    delete rest.output;
    delete rest.stdout;
    delete rest.stderr;
    delete rest.exit_code;
    delete rest.status;
    delete rest.wall_time_seconds;
    if (Object.keys(rest).length) {
      blocks.push({ key: 'tool_response', hint: 'json', text: prettyJson(rest) });
    }
  } else if (event.tool_response) {
    blocks.push({ key: 'tool_response', hint: 'json', text: prettyJson(event.tool_response) });
  }
  if (!blocks.length && event.cwd) blocks.push({ key: 'cwd', hint: 'meta', text: String(event.cwd) });
  return blocks;
}

function escapeHtml(text) {
  return String(text ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function highlightCode(source, lang, hljs) {
  const src = String(source ?? '');
  if (hljs && typeof hljs.highlight === 'function') {
    try {
      const hit = lang && hljs.getLanguage && hljs.getLanguage(lang)
        ? hljs.highlight(src, { language: lang })
        : hljs.highlightAuto(src);
      return `<pre class="hljs"><code>${hit.value}</code></pre>`;
    } catch (_) {
      /* fall through */
    }
  }
  return `<pre><code>${escapeHtml(src)}</code></pre>`;
}

/**
 * @param {string} text
 * @param {'auto'|'json'|'markdown'|'code'|'meta'} hint
 * @param {{ marked?: any, purify?: any, hljs?: any, jsBeautify?: any }} engines
 */
export function renderValue(text, hint = 'auto', engines = {}) {
  const raw = String(text ?? '');
  if (hint === 'meta') {
    return { kind: 'meta', html: `<pre class="meta-line">${escapeHtml(raw)}</pre>` };
  }
  if (hint === 'code') {
    return { kind: 'code', html: highlightCode(raw, 'bash', engines.hljs) };
  }
  if (hint === 'json') {
    return {
      kind: 'json',
      html: highlightCode(prettyJson(raw) || raw, 'json', engines.hljs),
    };
  }
  if (hint === 'markdown') {
    const md = renderMarkdownToHtml(raw, engines);
    if (md.ok && md.html) {
      return { kind: 'markdown', html: `<div class="md-preview">${md.html}</div>` };
    }
    return { kind: 'plain', html: `<pre>${escapeHtml(raw)}</pre>` };
  }

  const formatted = formatTextForDisplay(raw, {
    beautifiers: {
      ...resolveBeautifiers({
        marked: engines.marked,
        jsBeautify: engines.jsBeautify,
      }),
      marked: engines.marked,
      purify: engines.purify,
    },
  });
  if (formatted.kind === 'markdown') {
    const md = renderMarkdownToHtml(formatted.display || raw, engines);
    if (md.ok && md.html) {
      return { kind: 'markdown', html: `<div class="md-preview">${md.html}</div>` };
    }
  }
  if (formatted.kind === 'json' || formatted.kind === 'ndjson') {
    return {
      kind: 'json',
      html: highlightCode(formatted.display || prettyJson(raw), 'json', engines.hljs),
    };
  }
  if (formatted.html) {
    return { kind: formatted.kind, html: `<div class="md-preview">${formatted.html}</div>` };
  }
  const lang = formatted.lang && formatted.lang !== 'plaintext' ? formatted.lang : '';
  return {
    kind: formatted.kind || 'plain',
    html: highlightCode(formatted.display || raw, lang, engines.hljs),
  };
}

export function renderEventBlocks(event, engines = {}) {
  return blocksFromEvent(event).map((block) => ({
    key: block.key,
    ...renderValue(block.text, block.hint, engines),
  }));
}
