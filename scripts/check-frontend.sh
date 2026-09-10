#!/bin/bash
# Pre-deploy / CI gate for ClipVault web + Swift snippets.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
SRC="$ROOT/Sources/ClipVault"
# gates: tests/frontend-smoke.test.mjs tests/notes-render.test.mjs tests/masonry.test.mjs tests/pagination.test.mjs tests/archive-view.test.mjs tests/archive-reader.test.mjs tests/clip-link.test.mjs tests/url-safety.test.mjs tests/sse-control.test.mjs tests/search-judgment.test.mjs tests/notes-editor.test.mjs tests/notes-calc.test.mjs tests/markdown-render.test.mjs tests/ui-metrics.test.mjs tests/compose.test.mjs tests/share-links.test.mjs tests/sessions-ui.test.mjs tests/session-render.test.mjs tests/session-load.test.mjs
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
echo "[check-frontend] OK"
