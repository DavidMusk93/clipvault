/**
 * Chart shapes must follow the data: these assert the rules, not the pixels.
 * Run via scripts/check-frontend.sh.
 */
import assert from 'node:assert/strict';
import test from 'node:test';

import {
  CHART_PALETTE, PHASE_COLORS, SEV_COLORS, chartFor, colorAt, columns, donut,
  fmtCompact, fmtValue, lineChart, rankBars, stackBar,
} from '../web/mine-charts.mjs';

test('stackBar keeps adjacent ratios visually separate', () => {
  const html = stackBar([
    { label: '工作', value: 618, color: '#0071e3' },
    { label: '失败', value: 310, color: '#c2410c' },
    { label: '等待', value: 0.4, color: 'gray' },
  ], { unit: 's' });
  assert.equal((html.match(/class="mc-seg"/g) || []).length, 3);
  // The gap lives in CSS (.mc-stack-track gap), so assert the contract there too.
  assert.match(html, /mc-stack-track/);
  // A tiny slice still gets a visible minimum width.
  const widths = [...html.matchAll(/flex:0 0 ([\d.]+)%/g)].map((m) => Number(m[1]));
  assert.equal(widths.length, 3);
  assert.ok(widths.every((w) => w > 0), String(widths));
  // Numbers ride along with the colour.
  assert.match(html, /工作/);
  assert.match(html, /618s/);
  assert.match(html, /%/);
});

test('stackBar never renders an empty track as if it were data', () => {
  assert.match(stackBar([], {}), /mc-empty/);
  assert.match(stackBar([{ label: 'x', value: 0 }], {}), /mc-empty/);
});

test('donut is a ring gauge that always states the number', () => {
  const html = donut([
    { label: '缓存读', value: 9000, color: '#2f8f83' },
    { label: '未缓存输入', value: 1000, color: '#c47a2c' },
  ], { unit: 'tok', center: '90%', centerSub: '缓存命中' });
  assert.equal((html.match(/<circle/g) || []).length, 2);
  assert.match(html, /90%/);
  assert.match(html, /缓存命中/);
  // dashes never overflow the circumference per slice
  const dash = html.match(/stroke-dasharray="([\d.]+) ([\d.]+)"/g) || [];
  assert.equal(dash.length, 2);
  for (const d of dash) {
    const [a, b] = d.match(/([\d.]+) ([\d.]+)"/).slice(1).map(Number);
    assert.ok(a > 0 && b >= 0);
  }
});

test('rankBars scales to the max and prints the exact value', () => {
  const html = rankBars([
    { label: 'fail_retry', value: 310, color: '#c2410c', sub: '实测', jump: 'loss-fail_retry' },
    { label: 'reread', value: 129, sub: '实测', jump: 'loss-reread' },
  ], { unit: 's' });
  const widths = [...html.matchAll(/width:([\d.]+)%/g)].map((m) => Number(m[1]));
  assert.equal(widths[0], 100);
  assert.ok(widths[1] > 0 && widths[1] < 100);
  assert.match(html, /310s/);
  assert.match(html, /129s/);
  // ranked rows are jumps, so they are buttons, not decoration
  assert.equal((html.match(/<button/g) || []).length, 2);
  assert.match(html, /data-jump="loss-fail_retry"/);
});

test('lineChart refuses < 3 points and draws grid + endpoints otherwise', () => {
  assert.equal(lineChart([{ label: 'a', value: 1 }, { label: 'b', value: 2 }]), '');
  const html = lineChart([
    { label: '09-25', value: 0.26 }, { label: '09-28', value: 0.31 }, { label: '09-30', value: 0.62 },
  ], { unit: 'USD', title: '每天成本', color: '#2f8f83' });
  assert.match(html, /<path d="M/);
  assert.match(html, /09-25/);
  assert.match(html, /09-30/);
  assert.match(html, /0\.62/); // last value in the head
  assert.equal((html.match(/<circle/g) || []).length, 3);
});

test('columns show shape across many points and flag failures', () => {
  const rows = Array.from({ length: 40 }, (_, i) => ({
    label: `#${i + 1}`, value: i % 7 === 0 ? 0.5 : 30 + i, flag: i % 9 === 0, jump: i + 1,
  }));
  const html = columns(rows, { unit: 's', title: '每回合墙钟', total: 1200 });
  assert.equal((html.match(/<rect/g) || []).length, 40);
  assert.match(html, /data-mine-turn="1"/);
  assert.match(html, /每回合墙钟/);
  assert.ok((html.match(/<circle/g) || []).length >= 4, 'failed turns get a red cap');
});

test('chartFor picks by declared kind and defaults to nothing', () => {
  assert.match(chartFor('bars', [{ label: 'a', value: 1 }]), /mc-bars/);
  assert.match(chartFor('donut', [{ label: 'a', value: 1 }]), /mc-donut/);
  assert.equal(chartFor('line', [{ label: 'a', value: 1 }]), '');
  assert.match(chartFor('columns', [{ label: 'a', value: 1 }]), /mc-cols/);
  assert.match(chartFor('stack', [{ label: 'a', value: 1 }]), /mc-stack/);
  assert.equal(chartFor('nope', [{ label: 'a', value: 1 }]), '');
});

test('formatting is shared and unit-aware', () => {
  assert.equal(fmtValue(0.0111, 'USD'), '$0.0111');
  assert.equal(fmtValue(0.208, 'USD'), '$0.208');
  assert.equal(fmtValue(90.34, '%'), '90.3%');
  assert.equal(fmtValue(618, 's'), '618s');
  assert.equal(fmtValue(6439, 's'), '1.8h');
  assert.equal(fmtValue(54566528, 'tok'), '54.6Mtok');
  assert.equal(fmtValue(3, ''), '3');
  assert.equal(fmtCompact(12345), '12.3k');
  assert.equal(fmtCompact(999), '999');
});

test('palette and semantic colours are stable and finite', () => {
  assert.ok(CHART_PALETTE.length >= 8);
  assert.equal(colorAt(0), CHART_PALETTE[0]);
  assert.equal(colorAt(CHART_PALETTE.length + 2), CHART_PALETTE[2]);
  assert.equal(PHASE_COLORS.review, '#6e56cf');
  assert.equal(SEV_COLORS.high, '#c2410c');
  // every colour is a hex string the SVG can take
  for (const c of [...CHART_PALETTE, ...Object.values(PHASE_COLORS), ...Object.values(SEV_COLORS)]) {
    assert.match(c, /^#[0-9a-f]{6}$/i);
  }
});

test('chart markup escapes hostile labels', () => {
  const html = rankBars([{ label: '<img src=x onerror=1>', value: 1 }]);
  assert.doesNotMatch(html, /<img/);
  assert.match(html, /&lt;img/);
  assert.doesNotMatch(stackBar([{ label: '"><script>', value: 1 }]), /<script>/);
});
