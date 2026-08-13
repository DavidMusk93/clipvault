import test from 'node:test';
import assert from 'node:assert/strict';
import {
  detectStructuredText,
  formatTextForDisplay,
  formatUrlParts,
  structuredKindIsCodey,
} from '../web/text-format.mjs';

test('json single-line pretty', () => {
  const f = formatTextForDisplay('{"a":1,"b":[2,3]}');
  assert.equal(f.kind, 'json');
  assert.equal(f.pretty, true);
  assert.ok(f.display.includes('\n'));
  assert.match(f.label, /JSON/);
});

test('pretty can be disabled', () => {
  const f = formatTextForDisplay('{"a":1}', { enabled: false });
  assert.equal(f.pretty, false);
  assert.equal(f.display, '{"a":1}');
});

test('ndjson', () => {
  const f = formatTextForDisplay('{"a":1}\n{"b":2}');
  assert.equal(f.kind, 'ndjson');
  assert.ok(f.pretty);
});

test('url dual surface: openHref single-line + display parses query', () => {
  // LOCK: never drop either side (2026-08 thrash).
  // openHref = full canonical one line; display = multi-line # query parse.
  const raw = 'https://example.com/path?foo=1&bar=two%20x#frag';
  const f = formatTextForDisplay(raw);
  assert.equal(f.kind, 'url');
  assert.equal(f.openHref, 'https://example.com/path?foo=1&bar=two%20x#frag');
  assert.ok(!f.openHref.includes('\n'), 'openHref must be single-line');
  assert.ok(f.display.includes('# query'), 'pretty must expand query section');
  assert.ok(f.display.includes('foo = 1'), 'pretty must list query keys');
  assert.ok(f.display.includes('bar = two x'), 'pretty must decode query values');
  assert.ok(f.display.includes('# hash'), 'pretty must expand hash section');
  assert.ok(f.display.includes('\n'), 'parsed display is multi-line');
  const parts = formatUrlParts('https://example.com/a?x=1');
  assert.equal(parts.openHref, 'https://example.com/a?x=1');
  assert.match(parts.display, /# query/);
  assert.match(parts.display, /x = 1/);
});

test('form body', () => {
  const f = formatTextForDisplay('name=Ada&city=Paris');
  assert.equal(f.kind, 'form');
  assert.ok(f.display.includes('\n'));
});

test('xml indent', () => {
  const f = formatTextForDisplay('<root><a>1</a><b>2</b></root>');
  assert.equal(f.kind, 'xml');
  assert.ok(f.display.includes('\n'));
});

test('sql break', () => {
  const f = formatTextForDisplay('SELECT id, name FROM users WHERE active = 1 ORDER BY id LIMIT 10');
  assert.equal(f.kind, 'sql');
  assert.ok(f.display.includes('\n'));
});

test('sql uses sqlFormat engine when provided', () => {
  const f = formatTextForDisplay('SELECT id, name FROM users WHERE x = 1 ORDER BY id', {
    beautifiers: {
      jsBeautify: null,
      htmlBeautify: null,
      sqlFormat: (s) => 'SELECT\n  id\nFROM\n  t\nWHERE\n  x = 1',
    },
  });
  assert.equal(f.kind, 'sql');
  assert.equal(f.engine, 'sql-formatter');
  assert.ok(f.display.includes('FROM'));
});

test('json uses jsBeautify when provided', () => {
  const f = formatTextForDisplay('{"z":1,"a":2}', {
    beautifiers: {
      jsBeautify: (s) => '{\n  "beautified": true\n}',
      htmlBeautify: null,
      sqlFormat: null,
    },
  });
  assert.equal(f.engine, 'js-beautify');
  assert.match(f.display, /beautified/);
});

test('env', () => {
  assert.equal(formatTextForDisplay('FOO=1\nBAR=two\nBAZ=3').kind, 'env');
});

test('csv', () => {
  assert.equal(formatTextForDisplay('a,b,c\n1,2,3\n4,5,6').kind, 'csv');
});

test('stack', () => {
  assert.equal(
    formatTextForDisplay('Error: boom\n    at foo (x.js:1:1)\n    at bar (y.js:2:2)').kind,
    'stack'
  );
});

test('yaml', () => {
  assert.equal(formatTextForDisplay('name: demo\nport: 8080\nlist:\n  - a\n  - b').kind, 'yaml');
});

test('markdown', () => {
  assert.equal(
    formatTextForDisplay('# Title\n\n- item one\n- item two\n\n```js\nok\n```').kind,
    'markdown'
  );
});

test('prose stays plain', () => {
  const f = formatTextForDisplay('hello world this is just a sentence');
  assert.equal(f.kind, 'plain');
  assert.equal(f.pretty, false);
});

test('structuredKindIsCodey', () => {
  assert.equal(structuredKindIsCodey('json'), true);
  assert.equal(structuredKindIsCodey('url'), false);
});

test('detect order jwt over base64-ish', () => {
  const hdr = Buffer.from(JSON.stringify({ alg: 'HS256', typ: 'JWT' })).toString('base64url');
  const pay = Buffer.from(JSON.stringify({ sub: '1' })).toString('base64url');
  assert.equal(detectStructuredText(`${hdr}.${pay}.signaturepart`).kind, 'jwt');
});
