#!/bin/bash
# Real locked-file and card-filesystem regressions. All fixtures are private.
set -Eeuo pipefail
umask 022
RBN_ENTRY_ROOT="$(cd -P "$(dirname "$0")" && pwd -P)"
source "$RBN_ENTRY_ROOT/common-mac.sh"
rbn_require_mac
[[ "$#" == 1 && "$1" == /* && -x "$1" ]] || rbn_fail '請提供可執行的 rclone 完整路徑。' 5
RBN_TEST_ENGINE="$1"
rbn_prepare_local_environment
rbn_require_apple_tools
rbn_choose_architecture
rbn_collect_core_sources
rbn_start_log local-recovery
RBN_TEST_RUN="$(/usr/bin/mktemp -d "$RBN_CACHE_ROOT/tests/local-recovery.XXXXXX")"
RBN_TEST_APP="$RBN_APP_PATH/Contents/MacOS/$RBN_EXECUTABLE"
[[ -x "$RBN_TEST_APP" ]] || rbn_fail '請先建立 Mac App，再驗證內建修復入口。' 5
RBN_TEST_FAILURES=0
for RBN_TEST_SUITE in MacLocalCopyTests MacPartialRecoveryTests; do
  RBN_TEST_SOURCE="$RBN_PROJECT_ROOT/Tests/$RBN_TEST_SUITE.swift"
  [[ -s "$RBN_TEST_SOURCE" && ! -L "$RBN_TEST_SOURCE" ]] || rbn_fail "缺少測試：$RBN_TEST_SOURCE" 2
  RBN_SUITE_WORK="$RBN_TEST_RUN/$RBN_TEST_SUITE-work"
  /bin/mkdir -p "$RBN_SUITE_WORK"
  printf '\n測試：%s\n' "$RBN_TEST_SUITE"
  if ! "$RBN_SWIFTC" -swift-version 5 -parse-as-library -O -no-toolchain-stdlib-rpath \
      -module-name "RcloneBrowserNext$RBN_TEST_SUITE" \
      -target "$RBN_TARGET_ARCH-apple-macosx$RBN_MINIMUM_MACOS" -sdk "$RBN_SDK" \
      -module-cache-path "$SWIFT_MODULECACHE_PATH" \
      -Xcc "-fmodules-cache-path=$CLANG_MODULE_CACHE_PATH" \
      "${RBN_CORE_SOURCES[@]}" "$RBN_TEST_SOURCE" -framework Foundation \
      -o "$RBN_TEST_RUN/$RBN_TEST_SUITE"; then
    RBN_TEST_FAILURES=$((RBN_TEST_FAILURES + 1)); continue
  fi
  /usr/bin/codesign --force --sign - --timestamp=none "$RBN_TEST_RUN/$RBN_TEST_SUITE"
  /usr/bin/codesign --verify --strict "$RBN_TEST_RUN/$RBN_TEST_SUITE"
  if ! "$RBN_TEST_RUN/$RBN_TEST_SUITE" "$RBN_TEST_ENGINE" "$RBN_SUITE_WORK" "$RBN_TEST_APP" \
      | /usr/bin/tee "$RBN_CACHE_ROOT/logs/$RBN_TEST_SUITE-$RBN_TARGET_ARCH.log"; then
    RBN_TEST_FAILURES=$((RBN_TEST_FAILURES + 1))
  fi
done
[[ "$RBN_TEST_FAILURES" == 0 ]] || rbn_fail "$RBN_TEST_FAILURES 個本機複製或修復套件未通過。" 1
