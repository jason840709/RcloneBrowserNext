#!/bin/bash
set -euo pipefail

RBN_WEB_TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
if ! command -v node >/dev/null 2>&1; then
  printf '%s\n' '這是選用的介面開發測試，需要既有的 Node.js。一般 Mac App 建構不需要 Node.js。' >&2
  exit 2
fi
if [[ ! -f "$RBN_WEB_TEST_ROOT/WebSource/node_modules/playwright/cli.js" ]]; then
  printf '%s\n' '尚未安裝介面開發相依套件；請先閱讀 Tests/Web/README.md。' >&2
  exit 2
fi

export npm_config_cache="$RBN_WEB_TEST_ROOT/.build-cache/npm"
export PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-$RBN_WEB_TEST_ROOT/.build-cache/test-browsers}"
export RBN_TEST_OUTPUT="${RBN_TEST_OUTPUT:-$RBN_WEB_TEST_ROOT/.build-cache/web-test-results}"
export TMPDIR="$RBN_WEB_TEST_ROOT/.build-cache/web-test-tmp"
mkdir -p "$TMPDIR" "$RBN_TEST_OUTPUT" "$npm_config_cache"
cd "$RBN_WEB_TEST_ROOT/WebSource"
node node_modules/typescript/bin/tsc --noEmit
node node_modules/vite/bin/vite.js build
node node_modules/playwright/cli.js test --config tests/playwright.config.ts "$@"
