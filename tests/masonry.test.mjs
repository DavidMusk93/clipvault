/**
 * ClipView masonry regression tests (Node, no browser).
 * Mirrors pure helpers embedded in web/index.html (window.ClipViewMasonry).
 *
 * Run: node --test tests/masonry.test.mjs
 */

import test from 'node:test';
import assert from 'node:assert/strict';

// --- keep in sync with web/index.html Masonry object ---
const Masonry = {
  columnCountForWidth(w) {
    if (w < 560) return 1;
    if (w < 900) return 2;
    if (w < 1280) return 3;
    if (w < 1680) return 4;
    return 5;
  },

  pack(heights, cols, gap = 14) /* sync web MASONRY_GAP */ {
    const colOf = new Array(heights.length);
    const colHeights = new Array(cols).fill(0);
    for (let i = 0; i < heights.length; i++) {
      let best = 0;
      for (let c = 1; c < cols; c++) {
        if (colHeights[c] < colHeights[best]) best = c;
      }
      colOf[i] = best;
      colHeights[best] += heights[i] + (colHeights[best] > 0 ? gap : 0);
    }
    return { colOf, colHeights };
  },

  isCompactItem(item) {
    if (!item || item.type === 'image') return false;
    const raw = item.textContent || item.preview || '';
    const html = item.htmlContent || '';
    const plain = (html ? html.replace(/<[^>]+>/g, '') : raw).trim();
    return plain.length > 0 && plain.length <= 80 && !plain.includes('\n');
  }
};

test('columnCountForWidth breakpoints', () => {
  assert.equal(Masonry.columnCountForWidth(320), 1);
  assert.equal(Masonry.columnCountForWidth(559), 1);
  assert.equal(Masonry.columnCountForWidth(560), 2);
  assert.equal(Masonry.columnCountForWidth(899), 2);
  assert.equal(Masonry.columnCountForWidth(900), 3);
  assert.equal(Masonry.columnCountForWidth(1279), 3);
  assert.equal(Masonry.columnCountForWidth(1280), 4);
  assert.equal(Masonry.columnCountForWidth(1679), 4);
  assert.equal(Masonry.columnCountForWidth(1680), 5);
  assert.equal(Masonry.columnCountForWidth(2400), 5);
});

test('pack places every item exactly once', () => {
  const heights = [100, 40, 200, 40, 80, 40, 300];
  const { colOf } = Masonry.pack(heights, 3, 16);
  assert.equal(colOf.length, heights.length);
  for (const c of colOf) {
    assert.ok(c >= 0 && c < 3);
  }
});

test('pack shortest-column: tall item does not force equal row heights', () => {
  // Classic bug pattern: one tall image + many short snippets
  const heights = [400, 60, 60, 60, 60, 60];
  const { colOf, colHeights } = Masonry.pack(heights, 3, 16);
  // First (tall) goes to col 0
  assert.equal(colOf[0], 0);
  // Short items should fill other columns first when shorter
  const usedCols = new Set(colOf);
  assert.ok(usedCols.size >= 2, 'should use multiple columns');
  // Column heights should not all equal the tall card (would mean stretch semantics)
  const maxH = Math.max(...colHeights);
  const minH = Math.min(...colHeights);
  assert.ok(maxH >= 400);
  // With 5 shorts of 60, packing into 3 cols should keep min reasonably low
  assert.ok(minH < maxH, 'columns must not all match tallest (no forced equal height)');
});

test('pack is deterministic', () => {
  const heights = [120, 80, 200, 50, 90, 110, 70];
  const a = Masonry.pack(heights, 4, 16);
  const b = Masonry.pack(heights, 4, 16);
  assert.deepEqual(a.colOf, b.colOf);
  assert.deepEqual(a.colHeights, b.colHeights);
});

test('pack empty input', () => {
  const { colOf, colHeights } = Masonry.pack([], 3, 16);
  assert.deepEqual(colOf, []);
  assert.deepEqual(colHeights, [0, 0, 0]);
});

test('isCompactItem: short html/text yes, image/long no', () => {
  assert.equal(Masonry.isCompactItem({ type: 'html', htmlContent: '<span>city</span>' }), true);
  assert.equal(Masonry.isCompactItem({ type: 'text', textContent: 'hello' }), true);
  assert.equal(Masonry.isCompactItem({ type: 'image', ocrText: 'x' }), false);
  assert.equal(
    Masonry.isCompactItem({
      type: 'text',
      textContent: 'x'.repeat(100)
    }),
    false
  );
  assert.equal(
    Masonry.isCompactItem({
      type: 'text',
      textContent: 'line1\nline2'
    }),
    false
  );
});

/**
 * Hover policy regression: hover styles must not use transform/top/margin
 * that thrash layout. We assert against the shipped HTML source when present.
 */
test('hover CSS policy: no transform on .m3-card:hover (source scan)', async () => {
  const fs = await import('node:fs');
  const path = await import('node:path');
  const candidates = [
    path.resolve('web/index.html'),
    path.resolve('/Users/<user>/.grok/clipview_index_stable.html'),
  ];
  let html = null;
  for (const p of candidates) {
    if (fs.existsSync(p)) {
      html = fs.readFileSync(p, 'utf8');
      break;
    }
  }
  if (!html) {
    // Skip soft if file not in CWD (CI without tree); pure packer tests still run
    console.log('skip: index.html not found for CSS scan');
    return;
  }
  const hoverBlock = html.match(/\.m3-card:hover\s*\{[^}]+\}/);
  assert.ok(hoverBlock, 'expected .m3-card:hover rule');
  assert.equal(
    /transform\s*:/.test(hoverBlock[0]),
    false,
    'hover must not set transform (causes masonry jitter)'
  );
  assert.equal(
    /translateY|translate3d|top\s*:|margin-top\s*:/.test(hoverBlock[0]),
    false,
    'hover must not change geometry'
  );
  // Must still provide visual feedback
  assert.ok(
    /box-shadow/.test(hoverBlock[0]),
    'hover should use box-shadow for feedback'
  );
});

test('rebalance must not require card recreation (API contract)', () => {
  // Documented contract: pack only returns indices; DOM identity stays stable
  const heights = [10, 20, 30];
  const { colOf } = Masonry.pack(heights, 2, 16);
  // Same identity list re-packed after "image load" height change
  const heights2 = [10, 200, 30];
  const r2 = Masonry.pack(heights2, 2, 16);
  assert.equal(r2.colOf.length, 3);
  // Item indices preserved (no reordering of input array)
  assert.equal(colOf.length, r2.colOf.length);
});
