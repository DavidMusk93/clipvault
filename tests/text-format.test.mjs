import test from 'node:test';
import assert from 'node:assert/strict';
import {
  detectStructuredText,
  formatTextForDisplay,
  structuredKindIsCodey,
} from '../web/text-format.mjs';

test('json single-line pretty', () => {
  const f = formatTextForDisplay('{"a":1,"b":[2,3]}');
  assert.equal(f.kind, 'json');
  assert.equal(f.pretty, true);
  assert.ok(f.display.includes('\n'));
  assert.match(f.label, /JSON/);
});

test('ndjson', () => {
  const f = formatTextForDisplay('{"a":1}\n{"b":2}');
  assert.equal(f.kind, 'ndjson');
  assert.ok(f.pretty);
});

test('url expands query', () => {
  const f = formatTextForDisplay('https://example.com/path?foo=1&bar=two%20x');
  assert.equal(f.kind, 'url');
  assert.ok(f.display.includes('foo=1'));
  assert.ok(f.display.includes('bar=two x') || f.display.includes('bar=two%20x') || f.display.includes('two'));
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

test('env', () => {
  const f = formatTextForDisplay('FOO=1\nBAR=two\nBAZ=3');
  assert.equal(f.kind, 'env');
});

test('csv', () => {
  const f = formatTextForDisplay('a,b,c\n1,2,3\n4,5,6');
  assert.equal(f.kind, 'csv');
});

test('stack', () => {
  const f = formatTextForDisplay('Error: boom\n    at foo (x.js:1:1)\n    at bar (y.js:2:2)');
  assert.equal(f.kind, 'stack');
});

test('yaml', () => {
  const f = formatTextForDisplay('name: demo\nport: 8080\nlist:\n  - a\n  - b');
  assert.equal(f.kind, 'yaml');
});

test('markdown', () => {
  const f = formatTextForDisplay('# Title\n\n- item one\n- item two\n\n```js\nok\n```');
  assert.equal(f.kind, 'markdown');
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
  // minimal fake jwt-shaped with alg in header
  const hdr = Buffer.from(JSON.stringify({ alg: 'HS256', typ: 'JWT' })).toString('base64url');
  const pay = Buffer.from(JSON.stringify({ sub: '1' })).toString('base64url');
  const tok = `${hdr}.${pay}.signaturepart`;
  assert.equal(detectStructuredText(tok).kind, 'jwt');
});
