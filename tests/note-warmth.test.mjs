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
  assert.deepEqual([0, 4, 8, 12].map(i => warmth.family(i)), ['素纸', '雾青', '雾蓝', '雾紫']);
  for (const editCount of [undefined, null, -2, NaN, Infinity, 'invalid']) {
    assert.equal(warmth.level({ editCount }), 0);
  }
  assert.equal(warmth.ratio(0), '0');
  assert.equal(warmth.ratio(15), '0.9375');
  assert.equal(warmth.ratio(8), '0.5');
  assert.equal(warmth.ratio(-4), '0');
  assert.equal(warmth.ratio(99), '0.9375');
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
  assert.match(row.title, /编辑 450 次 · 第 16\/16 档 · 雾紫/);
  assert.equal(row.style.getPropertyValue('--edit-ratio'), '0.9375');
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

test('note surfaces stay pale while hue families, chroma and the spine separate levels', () => {
  const papers = [...html.matchAll(/--edit-paper: (#[0-9A-F]{6});/g)].map(m => m[1]);
  assert.equal(papers.length, 16);
  assert.equal(new Set(papers).size, 16);
  const spines = [...html.matchAll(/--edit-spine: (#[0-9A-F]{6});/g)].map(m => m[1]);
  assert.equal(new Set(spines).size, 4, 'one full-strength spine per hue family');
  const taste = readFileSync(join(root, 'docs/design-taste.md'), 'utf8');
  let previous = Infinity;
  const chroma = papers.map(paper => {
    const rgb = paper.slice(1).match(/../g).map(v => parseInt(v, 16));
    return Math.max(...rgb) - Math.min(...rgb);
  });
  papers.forEach((paper, i) => {
    const L = luminance(paper);
    assert.ok(L < previous, `paper must get deeper: ${paper}`);
    previous = L;
    assert.ok(L >= 0.73, 'long-edited notes must retain a pale surface');
    for (const ink of ['#595D65', '#805200']) {
      assert.ok((L + 0.05) / (luminance(ink) + 0.05) >= 4.5, `secondary text / tag contrast: ${ink}`);
    }
    assert.ok((L + 0.05) / (luminance('#1D1D1F') + 0.05) >= 7, 'title contrast >= 7:1');
    if (i >= 4 && i % 4 !== 0) assert.ok(chroma[i] > chroma[i - 1], `chroma must rise inside a family: ${paper}`);
    assert.ok((L + 0.05) / (luminance(spines[Math.floor(i / 4)]) + 0.05) >= 3, 'spine contrast >= 3:1');
    assert.ok(taste.includes(paper));
  });
  const familyPeaks = [3, 7, 11, 15].map(i => chroma[i]);
  assert.deepEqual([...familyPeaks].sort((a, b) => a - b), familyPeaks, 'each family peaks more chromatic than the last');
  assert.ok((luminance('#F7E2A8') + 0.05) / (luminance('#3A2E0B') + 0.05) >= 7, 'search hits stay legible inside tags too');
});

test('the spine is the ordinal channel: one discrete tick per level', () => {
  for (let level = 0; level < 15; level++) {
    assert.ok(parseFloat(warmth.ratio(level)) < parseFloat(warmth.ratio(level + 1)));
  }
  assert.match(html, /\.note-row\.note-warmth::after/);
  assert.match(html, /width: calc\(\(100% - 20px\) \* var\(--edit-ratio, 0\)\)/);
  assert.match(html, /el\.style\.setProperty\('--edit-ratio', this\.ratio\(level\)\)/);
});
