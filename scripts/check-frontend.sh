#!/bin/bash
# Pre-deploy / CI gate for ClipVault web.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
echo "[check-frontend] node --test frontend smoke + notes/masonry/pagination + archive view/reader + clip-link + url-safety + sse-control + search-judgment + notes-editor + notes-calc + markdown-render + ui-metrics + compose + share-links + sessions"
node --test tests/frontend-smoke.test.mjs tests/notes-render.test.mjs tests/masonry.test.mjs tests/pagination.test.mjs tests/archive-view.test.mjs tests/archive-reader.test.mjs tests/clip-link.test.mjs tests/url-safety.test.mjs tests/sse-control.test.mjs tests/search-judgment.test.mjs tests/notes-editor.test.mjs tests/notes-calc.test.mjs tests/markdown-render.test.mjs tests/ui-metrics.test.mjs tests/compose.test.mjs tests/share-links.test.mjs tests/sessions-ui.test.mjs tests/session-render.test.mjs
echo "[check-frontend] swiftc x-article coverage"
swiftc -parse-as-library -O tests/x_article_main.swift ClipFlow/XArticleHTML.swift -o /tmp/clipvault-x-article-html-test
/tmp/clipvault-x-article-html-test
echo "[check-frontend] OK"
