#!/bin/bash
set -Eeuo pipefail
umask 022

RBN_ENTRY_ROOT="$(cd -P "$(dirname "$0")" && pwd -P)"
source "$RBN_ENTRY_ROOT/common-mac.sh"
rbn_require_mac
[[ "$#" -le 1 ]] || rbn_fail '用法：Test-on-Mac.command [rclone 的完整路徑]' 5
RBN_TEST_ENGINE="${1:-${RBN_TEST_RCLONE:-}}"
if [[ -n "$RBN_TEST_ENGINE" ]]; then
  [[ "$RBN_TEST_ENGINE" == /* && -x "$RBN_TEST_ENGINE" ]] || rbn_fail '請提供可執行的 rclone 完整路徑。' 5
fi
rbn_prepare_local_environment
rbn_require_apple_tools
rbn_choose_architecture
rbn_collect_core_sources
rbn_start_log test

# Every suite has its own @main. Keep each executable separate and use only
# Apple's already-installed tools. All compiled tests and data stay here.
RBN_TEST_RUN="$(/usr/bin/mktemp -d "$RBN_CACHE_ROOT/tests/run.XXXXXX")"
RBN_TEST_SUITES=(CoreTests UpdaterTests ToolsTests NativeMessagesTests FinderDropTests AppReleaseTests)
for RBN_TEST_SUITE in "${RBN_TEST_SUITES[@]}"; do
  RBN_TEST_SOURCE="$RBN_PROJECT_ROOT/Tests/$RBN_TEST_SUITE.swift"
  [[ -s "$RBN_TEST_SOURCE" && ! -L "$RBN_TEST_SOURCE" ]] || rbn_fail "來源包缺少測試檔案：$RBN_TEST_SOURCE" 2
  RBN_SUITE_WORK="$RBN_TEST_RUN/$RBN_TEST_SUITE-work"
  /bin/mkdir -p "$RBN_SUITE_WORK"
  printf '\n測試：%s\n' "$RBN_TEST_SUITE"
  "$RBN_SWIFTC" -swift-version 5 -parse-as-library -O \
    -no-toolchain-stdlib-rpath \
    -module-name "RcloneBrowserNext$RBN_TEST_SUITE" \
    -target "$RBN_TARGET_ARCH-apple-macosx$RBN_MINIMUM_MACOS" \
    -sdk "$RBN_SDK" \
    -module-cache-path "$SWIFT_MODULECACHE_PATH" \
    -Xcc "-fmodules-cache-path=$CLANG_MODULE_CACHE_PATH" \
    "${RBN_CORE_SOURCES[@]}" "$RBN_TEST_SOURCE" \
    -framework Foundation \
    -o "$RBN_TEST_RUN/$RBN_TEST_SUITE"
  /usr/bin/codesign --force --sign - --timestamp=none "$RBN_TEST_RUN/$RBN_TEST_SUITE"
  /usr/bin/codesign --verify --strict "$RBN_TEST_RUN/$RBN_TEST_SUITE"
  "$RBN_TEST_RUN/$RBN_TEST_SUITE" "$RBN_TEST_ENGINE" "$RBN_SUITE_WORK"
done
printf '\n測試資料與執行結果保留在：%s\n' "$RBN_TEST_RUN"
