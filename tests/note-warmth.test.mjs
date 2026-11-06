import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import { JSDOM } from 'jsdom';
import { root } from './helpers/src.mjs';

const html = readFileSync(join(root, 'web/index.html'), 'utf8');
const start = html.indexOf('    const NoteWarmth = {');
const end = html.indexOf('    window.ClipVaultNoteWarmth = NoteWarmth;');
const warmth = new Function(html.slice(start, end) + '\nreturn NoteWarmth;')();

test('note warmth follows edit boundaries and caps color, not the readout', () => {
  const starts = [0, 1, 2, 3, 5, 8, 12, 18, 27, 40, 60, 90, 135, 200, 300, 450];
  assert.deepEqual(warmth.steps, starts);
  for (const [expected, editCount] of starts.entries()) {
    assert.equal(warmth.level({ editCount }), expected);
    assert.equal(warmth.label({ editCount }), `编辑 ${editCount} 次`);
    if (expected > 0) assert.equal(warmth.level({ editCount: editCount - 1 }), expected - 1);
  }
  assert.equal(warmth.level({ editCount: 9999 }), 15);
  assert.equal(warmth.label({ editCount: 9999 }), '编辑 9999 次');
  assert.equal(warmth.range(0), '0 次编辑');
  assert.equal(warmth.range(3), '3–4 次编辑');
  assert.equal(warmth.range(15), '≥450 次编辑');
  assert.deepEqual([0, 4, 8, 12].map(i => warmth.family(i)), ['奶油', '蜂蜜', '暖杏', '珊瑚']);
  for (const editCount of [undefined, null, -2, NaN, Infinity, 'invalid']) {
    assert.equal(warmth.level({ editCount }), 0);
  }
  assert.equal(warmth.count({ editCount: 3.9 }), 3);
  assert.equal(warmth.count({ copyCount: 3000, userRating: 5, pinned: true }), 0);
});

test('warmth preserves note title, pin controls and focus through count changes', (t) => {
  const dom = new JSDOM('<button class="note-row"><span class="nt">work</span><span class="note-pin">pin</span></button>');
  t.after(() => dom.window.close());
  const row = dom.window.document.querySelector('button');
  const title = row.querySelector('.nt');
  const pin = row.querySelector('.note-pin');
  row.focus();
  warmth.apply(row, { editCount: 0 });
  assert.equal(row.dataset.editLevel, '0');
  warmth.apply(row, { editCount: 450 });
  assert.equal(row.dataset.editLevel, '15');
  assert.equal(row.dataset.editCount, '450');
  assert.match(row.title, /编辑 450 次 · 第 16\/16 档 · 珊瑚/);
  assert.strictEqual(row.querySelector('.nt'), title);
  assert.strictEqual(row.querySelector('.note-pin'), pin);
  assert.strictEqual(dom.window.document.activeElement, row);
  warmth.apply(row, {});
  assert.equal(row.dataset.editLevel, '0');
  assert.doesNotThrow(() => warmth.apply(null, { editCount: 1 }));
});

function luminance(hex) {
  const channels = hex.match(/[0-9a-f]{2}/gi).map(n => parseInt(n, 16) / 255)
    .map(v => v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4);
  return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722;
}

test('note palette deepens monotonically and retains readable ink', () => {
  const papers = [...html.matchAll(/--edit-paper: (#[0-9A-F]{6});/g)].map(m => m[1]);
  assert.equal(papers.length, 16);
  assert.equal(new Set(papers).size, 16);
  const taste = readFileSync(join(root, 'docs/design-taste.md'), 'utf8');
  let previous = Infinity;
  for (const paper of papers) {
    assert.ok(luminance(paper) < previous, `paper must get deeper: ${paper}`);
    previous = luminance(paper);
    assert.ok((previous + 0.05) / (luminance('#50382D') + 0.05) >= 4.5, 'readout and excerpt contrast >= 4.5:1');
    assert.ok((previous + 0.05) / (luminance('#1D1D1F') + 0.05) >= 7, 'title contrast >= 7:1');
    assert.ok(taste.includes(paper));
  }
});
