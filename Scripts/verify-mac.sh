#!/bin/bash
set -Eeuo pipefail

RBN_ENTRY_ROOT="$(cd -P "$(dirname "$0")" && pwd -P)"
source "$RBN_ENTRY_ROOT/common-mac.sh"
rbn_require_mac
[[ "$#" -le 1 ]] || rbn_fail '驗證只接受一個 App 路徑。' 5
RBN_VERIFY_APP="${1:-$RBN_APP_PATH}"
case "$RBN_VERIFY_APP" in
  "$RBN_APP_PATH"|"$RBN_CACHE_ROOT/staging/build."*"/Rclone Browser Next.app") ;;
  *) rbn_fail '只能驗證這個專案建立的 App。' 6 ;;
esac
rbn_prepare_local_environment
rbn_require_apple_tools

[[ -d "$RBN_VERIFY_APP" && ! -L "$RBN_VERIFY_APP" ]] || rbn_fail '找不到 App，請先執行 Build-on-Mac.command。' 2
RBN_VERIFY_PARENT="$(/usr/bin/dirname "$RBN_VERIFY_APP")"
[[ ! -L "$RBN_VERIFY_PARENT" ]] || rbn_fail 'App 的父資料夾不能是符號連結。' 6
RBN_VERIFY_PHYSICAL_PARENT="$(cd -P "$RBN_VERIFY_PARENT" && pwd -P)"
case "$RBN_VERIFY_PHYSICAL_PARENT" in
  "$RBN_PROJECT_ROOT"|"$RBN_CACHE_ROOT/staging/build."*) ;;
  *) rbn_fail 'App 的實際位置不在這個專案內。' 6 ;;
esac
[[ -z "$(/usr/bin/find "$RBN_VERIFY_APP" -type l -print -quit)" ]] || rbn_fail '這份 App 含有非預期的符號連結。' 6
RBN_VERIFY_PLIST="$RBN_VERIFY_APP/Contents/Info.plist"
RBN_VERIFY_BINARY="$RBN_VERIFY_APP/Contents/MacOS/$RBN_EXECUTABLE"
[[ -s "$RBN_VERIFY_PLIST" && -x "$RBN_VERIFY_BINARY" ]] || rbn_fail 'App 缺少 Info.plist 或可執行的主程式。' 2
for RBN_VERIFY_RESOURCE in Resources/Web/index.html Resources/AppIcon.icns; do
  [[ -s "$RBN_VERIFY_APP/Contents/$RBN_VERIFY_RESOURCE" ]] || rbn_fail "App 缺少資源：$RBN_VERIFY_RESOURCE" 2
done
for RBN_FORBIDDEN_RESOURCE in Frameworks Resources/rclone Resources/app.asar; do
  [[ ! -e "$RBN_VERIFY_APP/Contents/$RBN_FORBIDDEN_RESOURCE" ]] || rbn_fail "App 不應附帶這項資源：$RBN_FORBIDDEN_RESOURCE" 2
done

/usr/bin/plutil -lint "$RBN_VERIFY_PLIST"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$RBN_VERIFY_PLIST")" == "$RBN_EXECUTABLE" ]] || rbn_fail '主程式名稱與 Info.plist 不一致。' 2
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$RBN_VERIFY_PLIST")" == "$RBN_BUNDLE_ID" ]] || rbn_fail 'App 識別碼與來源不一致。' 2
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$RBN_VERIFY_PLIST")" == "$RBN_VERSION" ]] || rbn_fail 'App 版本與來源不一致。' 2
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$RBN_VERIFY_PLIST")" == "$RBN_MINIMUM_MACOS" ]] || rbn_fail 'Info.plist 的最低 macOS 版本不符。' 2

RBN_ACTUAL_ARCH="$(/usr/bin/xcrun --no-cache lipo -archs "$RBN_VERIFY_BINARY")"
case "$RBN_ACTUAL_ARCH" in arm64|x86_64) ;; *) rbn_fail "App 架構不符：$RBN_ACTUAL_ARCH" 2 ;; esac
[[ -z "${RBN_EXPECTED_ARCH:-}" || "$RBN_ACTUAL_ARCH" == "$RBN_EXPECTED_ARCH" ]] || rbn_fail 'App 與這次指定的架構不同。' 2
RBN_LOAD_COMMANDS="$(/usr/bin/xcrun --no-cache otool -l "$RBN_VERIFY_BINARY")"
RBN_BINARY_MINIMUM="$(printf '%s\n' "$RBN_LOAD_COMMANDS" | /usr/bin/awk '
  $1 == "cmd" && $2 == "LC_BUILD_VERSION" { modern = 1; next }
  modern && $1 == "minos" { print $2; exit }
  $1 == "cmd" && $2 == "LC_VERSION_MIN_MACOSX" { legacy = 1; next }
  legacy && $1 == "version" { print $2; exit }
')"
case "$RBN_BINARY_MINIMUM" in 13.0|13.0.0) ;; *) rbn_fail "主程式的最低 macOS 版本不符：$RBN_BINARY_MINIMUM" 2 ;; esac

RBN_LINKED_LIBRARIES="$(/usr/bin/xcrun --no-cache otool -L "$RBN_VERIFY_BINARY")"
while IFS= read -r RBN_LIBRARY; do
  [[ -n "$RBN_LIBRARY" ]] || continue
  case "$RBN_LIBRARY" in
    /System/Library/*|/usr/lib/*|@rpath/libswift*.dylib) ;;
    *) rbn_fail "App 依賴專案外的非系統程式庫：$RBN_LIBRARY" 2 ;;
  esac
done < <(printf '%s\n' "$RBN_LINKED_LIBRARIES" | /usr/bin/awk 'NR > 1 { print $1 }')
while IFS= read -r RBN_RPATH; do
  [[ -n "$RBN_RPATH" ]] || continue
  case "$RBN_RPATH" in
    /usr/lib/swift|/System/Library/*) ;;
    *) rbn_fail "App 的程式庫搜尋路徑不屬於系統：$RBN_RPATH" 2 ;;
  esac
done < <(printf '%s\n' "$RBN_LOAD_COMMANDS" | /usr/bin/awk '
  $1 == "cmd" && $2 == "LC_RPATH" { reading_path = 1; next }
  reading_path && $1 == "path" { print $2; reading_path = 0 }
')

/usr/bin/codesign --verify --deep --strict --verbose=2 "$RBN_VERIFY_APP"
RBN_SIGNATURE_DETAILS="$(/usr/bin/codesign -d --verbose=4 "$RBN_VERIFY_APP" 2>&1)"
printf '%s\n' "$RBN_SIGNATURE_DETAILS" | /usr/bin/grep -q 'Sealed Resources version=2' || rbn_fail 'App 的資源封存未完成。' 2
printf '\n驗證通過：版本 %s；架構 %s；最低 macOS %s。\n' "$RBN_VERSION" "$RBN_ACTUAL_ARCH" "$RBN_BINARY_MINIMUM"
printf '%s\n' '主程式、Info.plist、Web 資源與本機簽章完整。這項檢查不等同 Developer ID 簽章或 Apple 公證。'
printf '主程式 SHA-256：'
/usr/bin/shasum -a 256 "$RBN_VERIFY_BINARY" | /usr/bin/awk '{print $1}'
