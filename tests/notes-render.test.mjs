/**
 * Notes-like rich HTML regression tests.
 * Run: node --test tests/notes-render.test.mjs tests/masonry.test.mjs tests/pagination.test.mjs
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  renderNotesFragment,
  collapseEmptyHtmlBlocks,
  stripHtmlToText,
  notesFragmentUseful,
  NOTES_CSS_POLICY,
} from '../web/notes-render.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const indexHtml = fs.readFileSync(path.join(__dirname, '../web/index.html'), 'utf8');

test('collapseEmptyHtmlBlocks removes empty p/div/li holes', () => {
  const html = `
    <p>Hello</p>
    <p><br></p>
    <p>&nbsp;</p>
    <p> <span></span> </p>
    <p>World</p>
    <br><br><br>
  `;
  const out = collapseEmptyHtmlBlocks(html);
  assert.match(out, /Hello/);
  assert.match(out, /World/);
  assert.equal((out.match(/<p[\s>]/g) || []).length, 2);
  assert.ok(!/<p[^>]*>\s*<br/i.test(out));
});

test('Cocoa-ish spacer soup does not leave blank paragraph stack', () => {
  const cocoa = `
  <html><body>
    <p class="p1"><span class="s1"></span></p>
    <p class="p1"><span class="Apple-converted-space">&nbsp;</span></p>
    <p class="p1">卡片上的事件时间</p>
    <p class="p1"><br></p>
    <p class="p1"><br class="Apple-interchange-newline"></p>
    <p class="p1">第二段正文</p>
  </body></html>`;
  const frag = renderNotesFragment(cocoa);
  assert.ok(notesFragmentUseful(frag));
  const plain = stripHtmlToText(frag);
  assert.match(plain, /卡片上的事件时间/);
  assert.match(plain, /第二段正文/);
  // not a pile of empty lines
  assert.ok(!/\n{4,}/.test(plain));
  const pCount = (frag.match(/<p[\s>]/g) || []).length;
  assert.ok(pCount <= 3, `expected few p tags, got ${pCount}: ${frag}`);
});

test('list structure is preserved', () => {
  const html = '<ul><li>one</li><li>two<ul><li>nested</li></ul></li></ul>';
  const frag = renderNotesFragment(html);
  assert.match(frag, /<ul>/i);
  assert.match(frag, /<li>/i);
  assert.match(frag, /nested/);
});

test('notesFragmentUseful rejects pure empty chrome', () => {
  assert.equal(notesFragmentUseful('<p><br></p><p>&nbsp;</p>'), false);
  assert.equal(notesFragmentUseful('<p>hi</p>'), true);
});

test('index.html CSS: rich text must not soft-wrap (pre + pan)', () => {
  // Product: dont wrap lines — pan instead. Empty holes are JS cleanup, not soft-wrap.
  // Multi-selector block may span >120 chars before white-space; allow a generous window.
  // Prose: normal wrap (blank-line friendly). Mono remains pre (see .is-mono).
  assert.match(
    indexHtml,
    /\.notes-rich p[\s\S]{0,400}?white-space:\s*normal\s*;/,
    'notes-rich p prose uses white-space:normal',
  );
  assert.match(
    indexHtml,
    /\.notes-rich \.is-mono[\s\S]{0,200}?white-space:\s*pre/,
    'notes-rich mono keeps white-space:pre',
  );
  assert.match(indexHtml, /\.notes-rich-inner[\s\S]{0,120}?width:\s*max-content/);
  assert.doesNotMatch(
    indexHtml,
    /\.notes-rich, \.snippet-html \{[\s\S]{0,300}?overflow-wrap:\s*anywhere/,
    'notes container must not force overflow-wrap:anywhere',
  );
  if (NOTES_CSS_POLICY.requireEmptyPHidden) {
    assert.match(indexHtml, /\.notes-rich p:empty/);
  }
  if (NOTES_CSS_POLICY.requireMonoPre) {
    assert.match(indexHtml, /is-mono[\s\S]{0,120}?white-space:\s*pre/);
  }
  if (NOTES_CSS_POLICY.requireNotesInnerMaxContent) {
    assert.match(indexHtml, /\.notes-rich-inner[\s\S]{0,120}?width:\s*max-content/);
  }
});

test('index.html uses notes-render pipeline helpers (sync guard)', () => {
  // Ensure live page still has Notes path hooks
  assert.match(indexHtml, /function renderNotesFragment/);
  assert.match(indexHtml, /notesFragmentUseful/);
  assert.match(indexHtml, /notes-rich/);
});

test('plain text path stays unwrap for is-single (not notes)', () => {
  assert.match(indexHtml, /\.card-body \.text-scroll\.is-single pre code/);
  assert.match(indexHtml, /white-space:\s*pre;\s*\/\* no soft wrap/);
});

test('Chrome dark paint styles are stripped (no black cards)', () => {
  const html = `<html><body>
    <span style="background-color: rgb(0, 0, 0); color: rgb(255, 255, 255)">DSOD-062</span>
    <font bgcolor="#000000" color="#ffffff">code</font>
    <p style="background:black;color:white">x</p>
  </body></html>`;
  const frag = renderNotesFragment(html);
  assert.ok(!/background/i.test(frag), frag);
  assert.ok(!/style=/i.test(frag), frag);
  assert.ok(!/bgcolor/i.test(frag), frag);
  assert.match(frag, /DSOD-062/);
});

test('anchors are neutralized (no navigable href)', () => {
  const html = '<p>see <a href="https://example.com/path">link</a> here</p>';
  const frag = renderNotesFragment(html);
  assert.ok(!/<a\b/i.test(frag), frag);
  assert.match(frag, /url-inert|link|example/i);
});

test('Lark/Chrome table structure survives presentation sanitize', () => {
  const html = `<meta charset="utf-8"><table class="ace-table" style="width:500px">
    <tr style="height:39px"><td style="border:1px solid #ccc">功能</td><td>mr</td></tr>
    <tr><td>对齐采样</td><td><a href="https://example.com/mr">link</a></td></tr>
  </table>`;
  const frag = renderNotesFragment(html);
  assert.match(frag, /<table/i);
  assert.match(frag, /<td/i);
  assert.match(frag, /功能/);
  assert.match(frag, /对齐采样/);
  assert.ok(!/style=/i.test(frag), frag);
  assert.ok(!/<a\b/i.test(frag), frag);
  assert.ok(notesFragmentUseful(frag));
});

test('clipboard images become placeholders (no remote fetch)', () => {
  const html = '<p>pic <img src="https://evil.example/x.png" alt="cover"> done</p>';
  const frag = renderNotesFragment(html);
  assert.ok(!/<img\b/i.test(frag), frag);
  assert.match(frag, /html-img-ph/);
  assert.match(frag, /cover/);
});

test('index.html styles html/rtf tables and headings in notes-rich', () => {
  assert.match(indexHtml, /\.notes-rich table[\s\S]{0,180}?border-collapse:\s*collapse/);
  assert.match(indexHtml, /\.notes-rich th, \.notes-rich td/);
  assert.match(indexHtml, /\.notes-rich h1, \.notes-rich h2/);
  assert.match(indexHtml, /\.notes-rich blockquote/);
  assert.match(indexHtml, /html-img-ph/);
});

const ACTIVE_CONTENT = [
  '<p>x</p><script>alert(1)</script>',
  '<svg onload=alert(1)><image href="https://evil/x.png"></image></svg>',
  '<math><mtext><img src=x onerror=alert(1)></mtext></math>',
  '<iframe src="https://evil.example"></iframe>',
  '<audio src="https://evil.example/a.mp3" controls></audio>',
  '<video src="https://evil.example/v.mp4"></video>',
  '<input type="image" src="https://evil.example/y.png">',
  '<form action="https://evil.example"><button formaction="https://evil.example">go</button></form>',
  '<div onclick="alert(1)">click</div>',
  '<marquee onstart="alert(1)">m</marquee>',
  '<details ontoggle="alert(1)">d</details>',
  '<img src="https://evil.example/z.png" onerror="alert(1)" alt="x">',
];

test('active content is stripped from card fragments', () => {
  for (const input of ACTIVE_CONTENT) {
    const frag = renderNotesFragment(input);
    assert.ok(!/\son[a-z]+\s*=/i.test(frag), `event handler survived: ${frag}`);
    assert.ok(
      !/<(script|svg|math|iframe|audio|video|input|form|button|object|embed|style)\b/i.test(frag),
      `active tag survived: ${frag}`,
    );
    assert.ok(
      !/\b(src|href|srcset|formaction|srcdoc|xlink:href|action)\s*=/i.test(frag),
      `fetch/nav attribute survived: ${frag}`,
    );
  }
});

test('presentational attributes drop, structural attributes survive', () => {
  const frag = renderNotesFragment(
    '<table width="500"><tr><td colspan="2" rowspan="3" bgcolor="#000">cell</td></tr></table>',
  );
  assert.match(frag, /<table/i);
  assert.match(frag, /colspan="2"/i);
  assert.match(frag, /rowspan="3"/i);
  assert.ok(!/width=/i.test(frag), frag);
  assert.ok(!/bgcolor/i.test(frag), frag);
});

test('sanitizer helpers are exported and compose safely', async () => {
  const mod = await import('../web/notes-render.mjs');
  assert.equal(typeof mod.hardenFragment, 'function');
  assert.equal(typeof mod.stripDangerousMarkup, 'function');
  assert.equal(typeof mod.stripEventHandlerAttrs, 'function');
  assert.ok(Array.isArray(mod.UNSAFE_TAGS) && mod.UNSAFE_TAGS.includes('svg'));
  assert.ok(mod.ALLOWED_TAGS instanceof Set && mod.ALLOWED_TAGS.has('table'));
  const cleaned = mod.stripEventHandlerAttrs(
    mod.stripDangerousMarkup('<svg onload=x></svg><p onclick=y>hi</p>'),
  );
  assert.equal(cleaned, '<p>hi</p>');
});

/** Pull `function name(...) { ... }` out of the index.html inline script. */
function extractInlineFunction(src, name) {
  const start = src.indexOf(`function ${name}(`);
  assert.ok(start >= 0, `${name} not found in index.html`);
  const open = src.indexOf('{', start);
  let depth = 0;
  for (let i = open; i < src.length; i++) {
    if (src[i] === '{') depth++;
    else if (src[i] === '}') {
      depth--;
      if (depth === 0) return src.slice(start, i + 1);
    }
  }
  throw new Error(`${name} has unbalanced braces`);
}

test('inline notesFragmentUseful matches the module on every fixture', () => {
  const inline = new Function(
    'stripHtmlToText',
    `${extractInlineFunction(indexHtml, 'notesFragmentUseful')}\nreturn notesFragmentUseful;`,
  )(stripHtmlToText);
  const fixtures = [
    '',
    'plain text',
    '<p>hi</p>',
    '<p><br></p><p>&nbsp;</p>',
    '<pre></pre>',
    '<pre>code</pre>',
    '<td></td>',
    '<td>x</td>',
    '<blockquote></blockquote>',
    '<ul></ul>',
    '<hr>',
    '<table></table>',
    '<table><tr><td>x</td></tr></table>',
    '<span class="html-img-ph">［图］</span>',
  ];
  for (const f of fixtures) {
    assert.equal(inline(f), notesFragmentUseful(f), `inline/module drift on ${JSON.stringify(f)}`);
  }
});

test('index.html mirrors the sanitizer vocabulary (sync guard)', async () => {
  const mod = await import('../web/notes-render.mjs');
  const m = indexHtml.match(/const NOTES_UNSAFE_TAGS = \[([\s\S]*?)\];/);
  assert.ok(m, 'NOTES_UNSAFE_TAGS array missing from index.html');
  const tags = [...m[1].matchAll(/'([a-z]+)'/g)].map((x) => x[1]);
  assert.deepEqual(tags, mod.UNSAFE_TAGS, 'inline UNSAFE_TAGS drifted from notes-render.mjs');
  assert.match(indexHtml, /function hardenNotesFragment/);
  assert.match(indexHtml, /function stripDangerousMarkup/);
  assert.match(indexHtml, /function stripEventHandlerAttrs/);
  assert.match(indexHtml, /hardenNotesFragment\(root\)/);
  assert.match(indexHtml, /stripEventHandlerAttrs\(stripDangerousMarkup\(root\.innerHTML/);
});
