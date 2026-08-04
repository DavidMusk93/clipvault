/**
 * Keepsake / ClipView pagination regression tests (Node, no browser).
 * Mirrors pure helpers in web/index.html (window.ClipViewPagination).
 *
 * Run: node --test tests/pagination.test.mjs
 */

import test from 'node:test';
import assert from 'node:assert/strict';

// --- keep in sync with web/index.html Pagination object ---
const Pagination = {
  mergePage(clips, items, { reset = false } = {}) {
    const incoming = Array.isArray(items) ? items : [];
    if (reset) {
      const seen = new Set();
      const out = [];
      for (const it of incoming) {
        if (!it || it.id == null || seen.has(it.id)) continue;
        seen.add(it.id);
        out.push(it);
      }
      return out;
    }
    const seen = new Set((clips || []).map(c => c.id));
    const out = (clips || []).slice();
    for (const it of incoming) {
      if (!it || it.id == null || seen.has(it.id)) continue;
      seen.add(it.id);
      out.push(it);
    }
    return out;
  },
  canLoadMore({ loading, exhausted, nextCursor }) {
    if (loading || exhausted) return false;
    if (nextCursor == null || nextCursor === '') return false;
    return true;
  },
  applyCap(clips, cap) {
    if (!clips || clips.length <= cap) return { clips: clips || [], removed: [] };
    const removed = clips.slice(cap);
    return { clips: clips.slice(0, cap), removed };
  }
};

function item(id, ts = 1) {
  return { id, timestamp: ts, type: 'text', textContent: id };
}

// --- mergePage ---

test('mergePage reset replaces list and dedupes ids', () => {
  const out = Pagination.mergePage(
    [item('a'), item('b')],
    [item('c'), item('c'), item('d')],
    { reset: true }
  );
  assert.deepEqual(out.map(x => x.id), ['c', 'd']);
});

test('mergePage append skips ids already present (first-scroll dup defense)', () => {
  const page1 = [item('a'), item('b'), item('c')];
  // Simulate lossy cursor re-including page1 tail + new rows
  const page2 = [item('c'), item('d'), item('e')];
  const out = Pagination.mergePage(page1, page2, { reset: false });
  assert.deepEqual(out.map(x => x.id), ['a', 'b', 'c', 'd', 'e']);
});

test('mergePage append onto empty is safe', () => {
  const out = Pagination.mergePage([], [item('a'), item('b')], { reset: false });
  assert.deepEqual(out.map(x => x.id), ['a', 'b']);
});

// --- canLoadMore ---

test('canLoadMore false without cursor (refresh race)', () => {
  assert.equal(
    Pagination.canLoadMore({ loading: false, exhausted: false, nextCursor: null }),
    false
  );
  assert.equal(
    Pagination.canLoadMore({ loading: false, exhausted: false, nextCursor: '' }),
    false
  );
});

test('canLoadMore true only when idle + cursor + not exhausted', () => {
  assert.equal(
    Pagination.canLoadMore({
      loading: false,
      exhausted: false,
      nextCursor: 'abc:uuid'
    }),
    true
  );
  assert.equal(
    Pagination.canLoadMore({
      loading: true,
      exhausted: false,
      nextCursor: 'abc:uuid'
    }),
    false
  );
  assert.equal(
    Pagination.canLoadMore({
      loading: false,
      exhausted: true,
      nextCursor: 'abc:uuid'
    }),
    false
  );
});

// --- applyCap ---

test('applyCap drops oldest tail when newest-first exceeds cap', () => {
  const clips = [item('n0'), item('n1'), item('n2'), item('n3')];
  const { clips: kept, removed } = Pagination.applyCap(clips, 2);
  assert.deepEqual(kept.map(x => x.id), ['n0', 'n1']);
  assert.deepEqual(removed.map(x => x.id), ['n2', 'n3']);
});

// --- cursor precision (documents why bitPattern wire format exists) ---

test('lossy decimal cursor can round UP and re-include boundary row', () => {
  // Live bug: "\(double)" / toFixed short forms → page2 contains page1 last id.
  const ts = 1785815141.2316918;
  const short = Number(ts.toFixed(6)); // 1785815141.231692
  assert.ok(short > ts, 'short decimal rounded up');
  // Exclusive keyset uses timestamp < cursorTs → boundary still qualifies
  assert.ok(ts < short, 'boundary ts still < rounded cursor → duplicate on next page');
});

test('IEEE bitPattern hex round-trips Double exactly (Swift ClipCursor)', () => {
  // Same scheme as DatabaseManager.ClipCursor: String(bitPattern, radix: 16)
  function toBitsHex(ts) {
    const ab = new ArrayBuffer(8);
    new Float64Array(ab)[0] = ts;
    // LE host (macOS arm64/x64): Uint32 words → UInt64 bitPattern numeric value
    const u = new Uint32Array(ab);
    const bits = (BigInt(u[1]) << 32n) | BigInt(u[0]);
    return bits.toString(16);
  }
  function fromBitsHex(hex) {
    const bits = BigInt('0x' + hex);
    const ab = new ArrayBuffer(8);
    const u = new Uint32Array(ab);
    u[0] = Number(bits & 0xffffffffn);
    u[1] = Number((bits >> 32n) & 0xffffffffn);
    return new Float64Array(ab)[0];
  }
  for (const ts of [1785815141.2316918, 1785764185.512909, Math.PI, 1.1]) {
    const hex = toBitsHex(ts);
    assert.equal(fromBitsHex(hex), ts);
  }
});

test('simulated first-scroll: page2 overlapping tail is stripped', () => {
  // Full refresh → page1, then load-more returns overlap (buggy cursor)
  let clips = Pagination.mergePage([], [item('a'), item('b'), item('c')], { reset: true });
  assert.equal(
    Pagination.canLoadMore({
      loading: false,
      exhausted: false,
      nextCursor: 'cursor-c'
    }),
    true
  );
  clips = Pagination.mergePage(clips, [item('c'), item('d')], { reset: false });
  assert.deepEqual(clips.map(x => x.id), ['a', 'b', 'c', 'd']);
  const ids = clips.map(x => x.id);
  assert.equal(new Set(ids).size, ids.length, 'no duplicate ids after merge');
});

test('load-more only yields newly added ids (incremental append contract)', () => {
  const page1 = [item('a'), item('b'), item('c')];
  let clips = Pagination.mergePage([], page1, { reset: true });
  const prevIds = new Set(clips.map(c => c.id));
  // API re-includes 'c' (lossy cursor) plus new 'd','e'
  clips = Pagination.mergePage(clips, [item('c'), item('d'), item('e')], { reset: false });
  const added = clips.filter(c => !prevIds.has(c.id));
  assert.deepEqual(added.map(x => x.id), ['d', 'e']);
  assert.ok(!added.some(x => x.id === 'c'), 'boundary row must not be re-appended to DOM');
});
