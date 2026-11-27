#!/bin/bash
# Existing Apple tools + Rust. All products, caches and fixtures stay local.
RBN_SCRIPT_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RBN_PROJECT_ROOT="$(cd -P "$RBN_SCRIPT_ROOT/.." && pwd -P)"
if [[ "${RBN_PROJECT_ROOT##*/}" == 01_原始碼 ]]; then
  RBN_TASK_ROOT="$(cd -P "$RBN_PROJECT_ROOT/.." && pwd -P)"
else
  RBN_TASK_ROOT="$RBN_PROJECT_ROOT"
fi
RBN_BUILD_ROOT="$RBN_TASK_ROOT/.build"
RBN_CACHE_ROOT="$RBN_BUILD_ROOT/mac"
RBN_SWIFT_CACHE_ROOT="$RBN_BUILD_ROOT/swift-shell"
RBN_TMP_ROOT="$RBN_TASK_ROOT/.tmp"
RBN_APP_PATH="$RBN_CACHE_ROOT/products/Rclone Browser Next.app"
RBN_BUNDLE_ID="org.rclone.browser.next.lite"
RBN_EXECUTABLE="RcloneBrowserNext"
RBN_VERSION="0.12.2"
RBN_MINIMUM_MACOS="13.0"
# SDK 15 keeps the released toolbar appearance on macOS 26 and newer.
RBN_DESIGN_SDK="15.0"
RBN_DESIGN_LINK_FLAGS=(-Xlinker -platform_version -Xlinker macos -Xlinker "$RBN_MINIMUM_MACOS" -Xlinker "$RBN_DESIGN_SDK")

rbn_fail() { printf '\n%s\n' "$1" >&2; exit "${2:-1}"; }
rbn_require_mac() {
  [[ "$(/usr/bin/uname -s)" == Darwin ]] || rbn_fail '請在 Mac 執行這個 command。這份來源包不會在 Linux 產生 Mac App。' 3
}
rbn_check_local_directory() {
  local candidate="${1%/}" existing tail='' leaf physical
  case "$candidate" in "$RBN_TASK_ROOT/"*) ;; *) rbn_fail "路徑不在專案資料夾內：$candidate" 6 ;; esac
  existing="$candidate"
  while [[ ! -e "$existing" && ! -L "$existing" ]]; do
    leaf="${existing##*/}"; tail="/$leaf$tail"; existing="${existing%/*}"
  done
  [[ -d "$existing" && ! -L "$existing" ]] || rbn_fail "資料夾不能是符號連結或一般檔案：$existing" 6
  physical="$(cd -P "$existing" && pwd -P)$tail"
  [[ "$physical" == "$candidate" ]] || rbn_fail "資料夾的實際位置不同：$candidate" 6
}
rbn_prepare_local_environment() {
  local candidate
  for candidate in "$RBN_BUILD_ROOT" "$RBN_TMP_ROOT" "$RBN_CACHE_ROOT" \
    "$RBN_SWIFT_CACHE_ROOT/module-cache" "$RBN_SWIFT_CACHE_ROOT/clang-cache" \
    "$RBN_CACHE_ROOT/logs" "$RBN_CACHE_ROOT/staging" "$RBN_CACHE_ROOT/tests" \
    "$RBN_CACHE_ROOT/products" "$RBN_CACHE_ROOT/backups" "$RBN_CACHE_ROOT/distribution"; do
    rbn_check_local_directory "$candidate"; /bin/mkdir -p "$candidate"
  done
  export TMPDIR="$RBN_TMP_ROOT/" TMP="$RBN_TMP_ROOT" TEMP="$RBN_TMP_ROOT"
  export SWIFT_MODULECACHE_PATH="$RBN_SWIFT_CACHE_ROOT/module-cache"
  export CLANG_MODULE_CACHE_PATH="$RBN_SWIFT_CACHE_ROOT/clang-cache"
  export xcrun_nocache=1
}
rbn_require_apple_tools() {
  [[ -x /usr/bin/xcode-select && -x /usr/bin/xcrun ]] || rbn_fail '找不到 Apple Command Line Tools（本腳本不會自動安裝）。' 4
  RBN_SWIFTC="$(/usr/bin/xcrun --no-cache --sdk macosx --find swiftc 2>/dev/null)" || rbn_fail '找不到可用的 Apple Swift 編譯器。' 4
  RBN_SDK="$(/usr/bin/xcrun --no-cache --sdk macosx --show-sdk-path 2>/dev/null)" || rbn_fail '找不到 macOS SDK。' 4
  [[ -x "$RBN_SWIFTC" && -d "$RBN_SDK" ]] || rbn_fail 'Swift 編譯器或 macOS SDK 無法使用。' 4
}
rbn_choose_architecture() {
  RBN_TARGET_ARCH="${RBN_BUILD_ARCH:-}"
  if [[ -z "$RBN_TARGET_ARCH" ]]; then
    if [[ "$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null || true)" == 1 ]]; then RBN_TARGET_ARCH=arm64
    else RBN_TARGET_ARCH="$(/usr/bin/uname -m)"; fi
  fi
  case "$RBN_TARGET_ARCH" in arm64|x86_64) ;; *) rbn_fail "不支援的架構：$RBN_TARGET_ARCH" 5 ;; esac
}
rbn_check_app_stopped() {
  local executable="${1:-$RBN_APP_PATH/Contents/MacOS/$RBN_EXECUTABLE}"
  if /bin/ps -axww -o comm= | /usr/bin/awk -v target="$executable" '$0 == target { running=1 } END { exit !running }'; then
    rbn_fail "這份測試 App 還在執行，請先結束它再建置：$executable" 7
  fi
}
rbn_prepare_rust() {
  local rust_parent="${RBN_TASK_ROOT%/*}" toolchain
  toolchain="$rust_parent/.rustup/toolchains/stable-aarch64-apple-darwin/bin"
  if [[ -n "${RBN_CARGO:-}" ]]; then :
  elif [[ -x "$toolchain/cargo" ]]; then RBN_CARGO="$toolchain/cargo"; export RUSTC="$toolchain/rustc"
  else RBN_CARGO="$(command -v cargo || true)"; fi
  export PATH="$(/usr/bin/dirname "$RBN_CARGO"):$PATH"
  [[ -n "$RBN_CARGO" && -x "$RBN_CARGO" ]] || rbn_fail '找不到既有 Rust Cargo。請先備妥 Rust；本腳本不會安裝工具鏈。' 4
  if [[ -d "$rust_parent/.cargo" ]]; then export CARGO_HOME="$rust_parent/.cargo"; fi
  if [[ -d "$rust_parent/.rustup" ]]; then export RUSTUP_HOME="$rust_parent/.rustup"; fi
  export CARGO_TARGET_DIR="$RBN_BUILD_ROOT" CARGO_INCREMENTAL=0 MACOSX_DEPLOYMENT_TARGET="$RBN_MINIMUM_MACOS"
  RBN_CARGO_FLAGS=(--release --locked --manifest-path "$RBN_PROJECT_ROOT/Sources/Rust/Cargo.toml" -j 2)
  if [[ "${RBN_CARGO_OFFLINE:-0}" == 1 ]]; then RBN_CARGO_FLAGS+=(--offline); fi
  RBN_RUST_OUTPUT="$RBN_BUILD_ROOT/release"
  local host desired
  host="$("${RUSTC:-rustc}" -vV | /usr/bin/awk '$1 == "host:" {print $2}')"
  case "$RBN_TARGET_ARCH" in arm64) desired=aarch64-apple-darwin ;; x86_64) desired=x86_64-apple-darwin ;; esac
  RBN_RUST_TARGET="$desired"
  if [[ "$host" != "$desired" ]]; then
    RBN_CARGO_FLAGS+=(--target "$desired"); RBN_RUST_OUTPUT="$RBN_BUILD_ROOT/$desired/release"
  fi
  # This read-only checker is Jason's existing NTFS lock/temporary-file gate.
  # Missing checker on another machine does not install or copy shared tools.
  local checker='/Volumes/ACASIS/codex/00_整理與交接/NTFS當機共通原因_2026-11-13/ntfs-operation-check.py'
  if [[ -f "$checker" && -x /opt/anaconda3/bin/python ]]; then
    /opt/anaconda3/bin/python -B "$checker" --intent hardlink-lock \
      --path "$CARGO_TARGET_DIR" --path "$RBN_TMP_ROOT" --path "$RBN_CACHE_ROOT" \
      --path "${CARGO_HOME:-$HOME/.cargo}" --path "$SWIFT_MODULECACHE_PATH" --path "$CLANG_MODULE_CACHE_PATH"
  fi
}
rbn_require_python() {
  if [[ -x /opt/anaconda3/bin/python ]]; then RBN_PYTHON=/opt/anaconda3/bin/python
  else RBN_PYTHON="$(command -v python3 || true)"; fi
  [[ -n "$RBN_PYTHON" && -x "$RBN_PYTHON" ]] || rbn_fail '建置與測試需要既有的 Python 3（本腳本不會安裝）。' 4
}
rbn_build_rust_engine() {
  "$RBN_CARGO" build "${RBN_CARGO_FLAGS[@]}" --bin rbn-engine
  [[ -x "$RBN_RUST_OUTPUT/rbn-engine" ]] || rbn_fail 'Rust 引擎建置後不存在。' 2
}
rbn_compile_swift() {
  local output="$1"; shift
  "$RBN_SWIFTC" -swift-version 5 -parse-as-library -O -no-toolchain-stdlib-rpath \
    -target "$RBN_TARGET_ARCH-apple-macosx$RBN_MINIMUM_MACOS" -sdk "$RBN_SDK" \
    -module-cache-path "$SWIFT_MODULECACHE_PATH" -Xcc "-fmodules-cache-path=$CLANG_MODULE_CACHE_PATH" \
    "${RBN_DESIGN_LINK_FLAGS[@]}" "$@" -framework Foundation -framework AppKit -framework WebKit -framework UserNotifications -o "$output"
}
rbn_start_log() {
  local operation="$1"
  RBN_RUN_ID="$(/bin/date +%Y%m%d-%H%M%S)-$$"
  RBN_LOG_PATH="$RBN_CACHE_ROOT/logs/$operation-$RBN_RUN_ID.log"
  [[ ! -e "$RBN_LOG_PATH" && ! -L "$RBN_LOG_PATH" ]] || rbn_fail "記錄檔已存在：$RBN_LOG_PATH" 6
  printf '記錄檔：%s\n' "$RBN_LOG_PATH"
  exec > >(/usr/bin/tee "$RBN_LOG_PATH") 2>&1
}
