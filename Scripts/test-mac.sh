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
RBN_TEST_SUITES=(CoreTests UpdaterTests ToolsTests NativeMessagesTests FinderDropTests AppReleaseTests TransferReportTests PlatformTests)
if [[ "${RBN_NATIVE_TESTS_ONLY:-0}" != 1 ]]; then
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
fi

# Native zoom, startup pixels and navigation need the actual macOS WebKit
# engine. Run every native suite so one failure does not hide the others.
RBN_NATIVE_FAILURES=0
for RBN_NATIVE_SUITE in MacInterfaceTests MacStartupTests MacIconTests MacNavigationIntegrationTests MacCompletionTests; do
  RBN_NATIVE_SOURCE="$RBN_PROJECT_ROOT/Tests/$RBN_NATIVE_SUITE.swift"
  [[ -s "$RBN_NATIVE_SOURCE" && ! -L "$RBN_NATIVE_SOURCE" ]] || rbn_fail "來源包缺少測試檔案：$RBN_NATIVE_SOURCE" 2
  RBN_NATIVE_SOURCES=("$RBN_PROJECT_ROOT/Sources/Mac/RcloneWebView.swift")
  RBN_NATIVE_ARGS=("$RBN_PROJECT_ROOT/Resources")
  case "$RBN_NATIVE_SUITE" in
    MacCompletionTests) RBN_NATIVE_SOURCES=("$RBN_PROJECT_ROOT/Sources/Mac/CompletionAttention.swift") ;;
    MacStartupTests) RBN_NATIVE_SOURCES+=("$RBN_PROJECT_ROOT/Sources/Mac/StartupSurface.swift") ;;
    MacIconTests)
      RBN_NATIVE_SOURCES=("$RBN_PROJECT_ROOT/Sources/Mac/AppIconAppearance.swift")
      RBN_NATIVE_ARGS+=("$RBN_APP_PATH")
      ;;
    MacNavigationIntegrationTests)
      if [[ -z "$RBN_TEST_ENGINE" ]]; then
        printf '\nSKIP MacNavigationIntegrationTests: 請提供 rclone 路徑以驗證完整原生導航。\n'
        continue
      fi
      RBN_NATIVE_SOURCES+=("${RBN_CORE_SOURCES[@]}")
      RBN_NATIVE_WORK="$RBN_TEST_RUN/$RBN_NATIVE_SUITE-work"
      /bin/mkdir -p "$RBN_NATIVE_WORK"
      RBN_NATIVE_ARGS+=("$RBN_TEST_ENGINE" "$RBN_NATIVE_WORK")
      ;;
  esac
  printf '\n測試：%s\n' "$RBN_NATIVE_SUITE"
  if ! "$RBN_SWIFTC" -swift-version 5 -parse-as-library -O \
    -no-toolchain-stdlib-rpath \
    -module-name "RcloneBrowserNext$RBN_NATIVE_SUITE" \
    -target "$RBN_TARGET_ARCH-apple-macosx$RBN_MINIMUM_MACOS" \
    -sdk "$RBN_SDK" \
    -module-cache-path "$SWIFT_MODULECACHE_PATH" \
    -Xcc "-fmodules-cache-path=$CLANG_MODULE_CACHE_PATH" \
    "${RBN_NATIVE_SOURCES[@]}" "$RBN_NATIVE_SOURCE" \
    -framework Foundation -framework AppKit -framework WebKit \
    -o "$RBN_TEST_RUN/$RBN_NATIVE_SUITE"; then
    RBN_NATIVE_FAILURES=$((RBN_NATIVE_FAILURES + 1))
    continue
  fi
  if ! /usr/bin/codesign --force --sign - --timestamp=none "$RBN_TEST_RUN/$RBN_NATIVE_SUITE" ||
     ! /usr/bin/codesign --verify --strict "$RBN_TEST_RUN/$RBN_NATIVE_SUITE"; then
    RBN_NATIVE_FAILURES=$((RBN_NATIVE_FAILURES + 1))
    continue
  fi
  if ! "$RBN_TEST_RUN/$RBN_NATIVE_SUITE" "${RBN_NATIVE_ARGS[@]}"; then
    RBN_NATIVE_FAILURES=$((RBN_NATIVE_FAILURES + 1))
  fi
done
printf '\n測試資料與執行結果保留在：%s\n' "$RBN_TEST_RUN"
[[ "$RBN_NATIVE_FAILURES" == 0 ]] || rbn_fail "$RBN_NATIVE_FAILURES 個原生測試套件未通過，請查看上方結果。" 1
