#!/bin/bash
# Pre-deploy / CI gate for ClipVault web + Swift snippets.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
SRC="$ROOT/Sources/ClipVault"
# gates: tests/frontend-smoke.test.mjs tests/ui-track.test.mjs tests/notes-render.test.mjs tests/masonry.test.mjs tests/day-groups.test.mjs tests/day-rhythm.test.mjs tests/pagination.test.mjs tests/search-relevance.test.mjs tests/archive-view.test.mjs tests/archive-reader.test.mjs tests/wall-resume.test.mjs tests/wall-feedback.test.mjs tests/wall-live-update.test.mjs tests/lightbox-vt.test.mjs tests/clip-link.test.mjs tests/url-safety.test.mjs tests/sse-control.test.mjs tests/sse-election.test.mjs tests/search-judgment.test.mjs tests/notes-editor.test.mjs tests/notes-calc.test.mjs tests/notes-title.test.mjs tests/markdown-render.test.mjs tests/ui-metrics.test.mjs tests/compose.test.mjs tests/share-links.test.mjs tests/sessions-ui.test.mjs tests/session-render.test.mjs tests/session-load.test.mjs tests/metrics-panel.test.mjs tests/wall-clock.test.mjs tests/wall-integrity.test.mjs tests/wall-lifecycle.test.mjs tests/session-thread.test.mjs tests/session-mine.test.mjs tests/mine-charts.test.mjs tests/list-html-sql.test.mjs tests/metrics-sql.test.mjs tests/html-hydrate.test.mjs tests/notes-render-dom.test.mjs tests/metrics-plane.test.mjs + swiftc http_byte_sink_main.swift + swiftc single_instance_main.swift + cargo test http-front
# jsdom is a dev-only dep. The macos CI job is a bare runner (no `npm ci` step),
# so install it here rather than letting the jsdom-backed DOM gates report as
# skipped — a skipped gate is not a passing gate. Tests still guard the import so
# a bare `node --test` never dies on `Cannot find package 'jsdom'`.
if [ ! -d "$ROOT/node_modules/jsdom" ]; then
  if command -v npm >/dev/null 2>&1; then
    echo "[check-frontend] npm ci (web test deps: jsdom)"
    ( cd "$ROOT" && npm ci --no-audit --no-fund )
  else
    echo "WARN: npm not found; jsdom-backed DOM gates will report as skipped" >&2
  fi
fi
echo "[check-frontend] node --test tests/*.test.mjs"
node --test tests/*.test.mjs
echo "[check-frontend] swiftc x-article coverage"
swiftc -parse-as-library -O tests/x_article_main.swift "$SRC/Archive/XArticleHTML.swift" -o /tmp/clipvault-x-article-html-test
/tmp/clipvault-x-article-html-test
echo "[check-frontend] swiftc compose merge"
swiftc -parse-as-library -O tests/compose_merge_main.swift "$SRC/Store/ComposeMerge.swift" -o /tmp/clipvault-compose-merge-test
/tmp/clipvault-compose-merge-test
echo "[check-frontend] swiftc compose notes normalize"
swiftc -parse-as-library -O tests/compose_notes_main.swift "$SRC/Store/ComposeNotes.swift" -o /tmp/clipvault-compose-notes-test
/tmp/clipvault-compose-notes-test
echo "[check-frontend] swiftc wall clock (capture vs sync)"
swiftc -parse-as-library -O tests/wall_clock_main.swift "$SRC/Store/WallClockPolicy.swift" -o /tmp/clipvault-wall-clock-test
/tmp/clipvault-wall-clock-test
echo "[check-frontend] swiftc blob CAS keys"
swiftc -parse-as-library -O tests/blob_cas_main.swift "$SRC/Store/BlobCAS.swift" -o /tmp/clipvault-blob-cas-test
/tmp/clipvault-blob-cas-test
echo "[check-frontend] swiftc origin byte sink (fd/kevent lifetime)"
swiftc -parse-as-library -O tests/http_byte_sink_main.swift "$SRC/HTTP/HTTPByteSink.swift" -o /tmp/clipvault-http-byte-sink-test
/tmp/clipvault-http-byte-sink-test
echo "[check-frontend] swiftc single-instance lock (one owner per data home)"
swiftc -parse-as-library -O tests/single_instance_main.swift "$SRC/App/SingleInstanceLock.swift" -o /tmp/clipvault-single-instance-test
/tmp/clipvault-single-instance-test
echo "[check-frontend] cargo test clipvault-http (bind retry)"
if command -v cargo >/dev/null 2>&1; then
  ( cd "$ROOT/http-front" && cargo test --quiet )
else
  echo "WARN: cargo not found; skipping clipvault-http gate" >&2
fi
echo "[check-frontend] python session mine"
python3 tests/session_mine_main.py
echo "[check-frontend] python session metrics"
python3 tests/session_metrics_main.py
echo "[check-frontend] vite session-app (types + tests + build)"
export PATH="$HOME/.local/node/bin:$PATH"
if command -v npm >/dev/null 2>&1; then
  ( cd "$ROOT/web/session-app" && npm ci --no-audit --no-fund >/dev/null && npm run check && npm test && npm run build )
else
  echo "WARN: npm not found; skipping session-app gate" >&2
fi
echo "[check-frontend] OK"
