/**
 * Browser DOM-path gate for renderNotesFragment.
 *
 * The shipped renderer uses DOMParser, which Node lacks — the other test files
 * only exercise the regex fallback. jsdom supplies a real DOMParser so the
 * `hardenFragment` allowlist (unwrap unknown tags, drop event handlers/active content)
 * is actually executed.
 *
 * Run: node --test tests/notes-render-dom.test.mjs
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { renderNotesFragment } from '../web/notes-render.mjs';

// jsdom is a dev-only dependency (npm ci). Skip cleanly when absent so
// `./scripts/check-frontend.sh` still passes without an npm install.
let RealDOMParser = null;
let skip = false;
try {
  const { JSDOM } = await import('jsdom');
  RealDOMParser = new JSDOM('<!doctype html><html><body></body></html>').window.DOMParser;
} catch {
  skip = 'jsdom not installed — run `npm ci`';
}

/** Run `fn` with a real DOMParser installed, then restore it. */
function withDomParser(fn) {
  const prev = globalThis.DOMParser;
  globalThis.DOMParser = RealDOMParser;
  try {
    return fn();
  } finally {
    globalThis.DOMParser = prev;
  }
}

/** Run `fn` with DOMParser absent (regex fallback). */
function withoutDomParser(fn) {
  const prev = globalThis.DOMParser;
  globalThis.DOMParser = undefined;
  try {
    return fn();
  } finally {
    globalThis.DOMParser = prev;
  }
}

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

test('DOM path removes active content before serialization', { skip }, () => {
  withDomParser(() => {
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
});

test('DOM path unwraps unknown-but-harmless tags and keeps their text', { skip }, () => {
  withDomParser(() => {
    const frag = renderNotesFragment('<section><article><p>kept <span>inline</span></p></article></section>');
    assert.ok(!/<(section|article)\b/i.test(frag), frag);
    assert.match(frag, /kept/);
    assert.match(frag, /inline/);
  });
});

test('DOM path keeps table structure but drops presentation attributes', { skip }, () => {
  withDomParser(() => {
    const frag = renderNotesFragment(
      '<table width="500"><tr><td colspan="2" rowspan="3" style="border:1px" bgcolor="#000">cell</td></tr></table>',
    );
    assert.match(frag, /<table/i);
    assert.match(frag, /colspan="2"/i);
    assert.match(frag, /rowspan="3"/i);
    assert.ok(!/width=/i.test(frag), frag);
    assert.ok(!/bgcolor/i.test(frag), frag);
    assert.ok(!/style=/i.test(frag), frag);
  });
});

test('DOM path neutralizes anchors to inert spans', { skip }, () => {
  withDomParser(() => {
    const frag = renderNotesFragment('<p>see <a href="https://example.com/x">link</a></p>');
    assert.ok(!/<a\b/i.test(frag), frag);
    assert.match(frag, /url-inert/);
    assert.match(frag, /link/);
  });
});

test('both render paths agree on the adversarial corpus', { skip }, () => {
  for (const input of ACTIVE_CONTENT) {
    const domFrag = withDomParser(() => renderNotesFragment(input));
    const regexFrag = withoutDomParser(() => renderNotesFragment(input));
    for (const [path, frag] of [['dom', domFrag], ['regex', regexFrag]]) {
      assert.ok(!/\son[a-z]+\s*=/i.test(frag), `${path} handler: ${frag}`);
      assert.ok(
        !/\b(src|href|srcset|formaction|srcdoc|xlink:href|action)\s*=/i.test(frag),
        `${path} attr: ${frag}`,
      );
    }
  }
});
