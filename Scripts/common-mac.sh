#!/bin/bash
# Shared helpers for the local Mac build. Requires only macOS and Apple's tools.

RBN_SCRIPT_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RBN_PROJECT_ROOT="$(cd -P "$RBN_SCRIPT_ROOT/.." && pwd -P)"
RBN_CACHE_ROOT="$RBN_PROJECT_ROOT/.build-cache"
RBN_APP_PATH="$RBN_PROJECT_ROOT/Rclone Browser Next.app"
RBN_BUNDLE_ID="org.rclone.browser.next.lite"
RBN_EXECUTABLE="RcloneBrowserNext"
RBN_VERSION="0.9.5"
RBN_MINIMUM_MACOS="13.0"

rbn_fail() {
  printf '\n%s\n' "$1" >&2
  exit "${2:-1}"
}

rbn_require_mac() {
  [[ "$(/usr/bin/uname -s)" == Darwin ]] || \
    rbn_fail '請在 Mac 執行這個 command。這份來源包不會在 Linux 產生 Mac App。' 3
}

rbn_check_local_directory() {
  local candidate="$1"
  case "$candidate" in
    "$RBN_PROJECT_ROOT/"*) ;;
    *) rbn_fail "路徑不在專案資料夾內：$candidate" 6 ;;
  esac
  [[ ! -L "$candidate" ]] || rbn_fail "請先移除這個資料夾的符號連結：$candidate" 6
  [[ ! -e "$candidate" || -d "$candidate" ]] || rbn_fail "這個位置應該是資料夾：$candidate" 6
}

rbn_prepare_local_environment() {
  local candidate
  for candidate in "$RBN_CACHE_ROOT" "$RBN_CACHE_ROOT/tmp" \
    "$RBN_CACHE_ROOT/modules" "$RBN_CACHE_ROOT/modules/swift" \
    "$RBN_CACHE_ROOT/modules/clang" "$RBN_CACHE_ROOT/logs" \
    "$RBN_CACHE_ROOT/staging" "$RBN_CACHE_ROOT/tests"; do
    rbn_check_local_directory "$candidate"
    /bin/mkdir -p "$candidate"
  done
  export TMPDIR="$RBN_CACHE_ROOT/tmp/"
  export SWIFT_MODULECACHE_PATH="$RBN_CACHE_ROOT/modules/swift"
  export CLANG_MODULE_CACHE_PATH="$RBN_CACHE_ROOT/modules/clang"
  # xcrun also accepts this environment setting for child tool invocations.
  export xcrun_nocache=1
}

rbn_require_apple_tools() {
  [[ -x /usr/bin/xcode-select && -x /usr/bin/xcrun ]] || \
    rbn_fail '找不到 Apple Command Line Tools。請先備妥既有的 Xcode 或 Command Line Tools，再重新執行；這個腳本不會安裝或升級它們。' 4
  local developer_path
  developer_path="$(/usr/bin/xcode-select -p 2>/dev/null)" || \
    rbn_fail '這台 Mac 尚未設定 Apple Command Line Tools。請先備妥 Xcode 或 Command Line Tools，再重新執行；這個腳本不會代為安裝。' 4
  [[ -d "$developer_path" ]] || rbn_fail "Apple 開發工具路徑不存在：$developer_path" 4
  RBN_SWIFTC="$(/usr/bin/xcrun --no-cache --sdk macosx --find swiftc 2>/dev/null)" || \
    rbn_fail '找不到可用的 Apple Swift 編譯器。請檢查目前選用的 Xcode／Command Line Tools。' 4
  RBN_SDK="$(/usr/bin/xcrun --no-cache --sdk macosx --show-sdk-path 2>/dev/null)" || \
    rbn_fail '找不到 macOS SDK。請檢查目前選用的 Xcode／Command Line Tools。' 4
  [[ -x "$RBN_SWIFTC" && -d "$RBN_SDK" ]] || rbn_fail 'Swift 編譯器或 macOS SDK 無法使用。' 4
}

rbn_choose_architecture() {
  RBN_TARGET_ARCH="${RBN_BUILD_ARCH:-}"
  if [[ -z "$RBN_TARGET_ARCH" ]]; then
    if [[ "$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null || true)" == 1 ]]; then
      RBN_TARGET_ARCH=arm64
    else
      RBN_TARGET_ARCH="$(/usr/bin/uname -m)"
    fi
  fi
  case "$RBN_TARGET_ARCH" in
    arm64|x86_64) ;;
    *) rbn_fail "不支援的架構：$RBN_TARGET_ARCH（可用 arm64 或 x86_64）。" 5 ;;
  esac
}

rbn_check_app_stopped() {
  if /bin/ps -axo comm= | /usr/bin/awk '
    /(^|\/)RcloneBrowserNext$/ { running = 1 }
    END { exit !running }
  '; then
    rbn_fail 'Rclone Browser Next 還在執行。請先結束 App，等傳輸工作停止後再建置。' 7
  fi
}

rbn_collect_core_sources() {
  RBN_CORE_SOURCES=()
  local source_path
  for source_path in "$RBN_PROJECT_ROOT"/Sources/Core/*.swift; do
    [[ -f "$source_path" && ! -L "$source_path" ]] || continue
    RBN_CORE_SOURCES+=("$source_path")
  done
  [[ "${#RBN_CORE_SOURCES[@]}" -gt 0 ]] || rbn_fail '來源包缺少 Sources/Core 的 Swift 檔案。' 2
}

rbn_start_log() {
  local operation="$1"
  RBN_RUN_ID="$(/bin/date +%Y%m%d-%H%M%S)-$$"
  RBN_LOG_PATH="$RBN_CACHE_ROOT/logs/$operation-$RBN_RUN_ID.log"
  [[ ! -e "$RBN_LOG_PATH" && ! -L "$RBN_LOG_PATH" ]] || rbn_fail "記錄檔已存在：$RBN_LOG_PATH" 6
  printf '記錄檔：%s\n' "$RBN_LOG_PATH"
  exec > >(/usr/bin/tee "$RBN_LOG_PATH") 2>&1
}
