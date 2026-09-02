#!/bin/bash
# Pre-deploy / CI gate for ClipVault web.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
echo "[check-frontend] node --test frontend smoke + notes/masonry/pagination + archive view/reader + clip-link + url-safety + sse-control + search-judgment"
node --test tests/frontend-smoke.test.mjs tests/notes-render.test.mjs tests/masonry.test.mjs tests/pagination.test.mjs tests/archive-view.test.mjs tests/archive-reader.test.mjs tests/clip-link.test.mjs tests/url-safety.test.mjs tests/sse-control.test.mjs tests/search-judgment.test.mjs
echo "[check-frontend] OK"
