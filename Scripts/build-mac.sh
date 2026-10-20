#!/bin/bash
set -Eeuo pipefail
umask 022

RBN_ENTRY_ROOT="$(cd -P "$(dirname "$0")" && pwd -P)"
source "$RBN_ENTRY_ROOT/common-mac.sh"
rbn_require_mac

RBN_NO_LAUNCH=0
if [[ "${1:-}" == --no-launch ]]; then RBN_NO_LAUNCH=1; shift; fi
[[ "$#" -eq 0 ]] || rbn_fail '可用參數：--no-launch（建置完成後不開啟 App）。' 5

rbn_prepare_local_environment
rbn_require_apple_tools
rbn_choose_architecture
rbn_check_app_stopped
rbn_collect_core_sources
rbn_start_log build

RBN_LOCK_PATH="$RBN_CACHE_ROOT/build.lock"
[[ ! -L "$RBN_LOCK_PATH" ]] || rbn_fail "建置鎖定位置是符號連結：$RBN_LOCK_PATH" 6
/bin/mkdir "$RBN_LOCK_PATH" 2>/dev/null || \
  rbn_fail '這個資料夾已有建置工作。若前次工作已確定結束，可移除 .build-cache/build.lock 後重試。' 7
RBN_STAGE_ROOT=''
RBN_OLD_APP_BACKUP=''
RBN_REPLACEMENT_STARTED=0
RBN_REPLACEMENT_FINISHED=0

rbn_finish_build() {
  local status="$?"
  trap - EXIT
  if [[ "$status" -ne 0 ]]; then
    printf '\n建置未完成。請查看：%s\n' "$RBN_LOG_PATH" >&2
    if [[ "$RBN_REPLACEMENT_STARTED" == 1 && "$RBN_REPLACEMENT_FINISHED" == 0 && -n "$RBN_OLD_APP_BACKUP" ]]; then
      if [[ ! -e "$RBN_APP_PATH" && ! -L "$RBN_APP_PATH" && -d "$RBN_OLD_APP_BACKUP" ]]; then
        /bin/mv "$RBN_OLD_APP_BACKUP" "$RBN_APP_PATH" || \
          printf '上一份 App 仍保留在：%s\n' "$RBN_OLD_APP_BACKUP" >&2
      fi
    fi
  fi
  if [[ -n "$RBN_STAGE_ROOT" ]]; then
    case "$RBN_STAGE_ROOT" in
      "$RBN_CACHE_ROOT/staging/build."*)
        [[ -L "$RBN_STAGE_ROOT" ]] || /bin/rm -rf -- "$RBN_STAGE_ROOT"
        ;;
    esac
  fi
  /bin/rmdir "$RBN_LOCK_PATH" 2>/dev/null || true
  exit "$status"
}
trap rbn_finish_build EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

RBN_MAC_SOURCES=()
for RBN_SOURCE_PATH in "$RBN_PROJECT_ROOT"/Sources/Mac/*.swift; do
  [[ -f "$RBN_SOURCE_PATH" && ! -L "$RBN_SOURCE_PATH" ]] || continue
  RBN_MAC_SOURCES+=("$RBN_SOURCE_PATH")
done
[[ "${#RBN_MAC_SOURCES[@]}" -gt 0 ]] || rbn_fail '來源包缺少 Sources/Mac 的 Swift 檔案。' 2
for RBN_REQUIRED_FILE in "$RBN_PROJECT_ROOT/Resources/Info.plist" \
  "$RBN_PROJECT_ROOT/Resources/AppIcon.icns" \
  "$RBN_PROJECT_ROOT/Resources/Web/index.html"; do
  [[ -s "$RBN_REQUIRED_FILE" && ! -L "$RBN_REQUIRED_FILE" ]] || rbn_fail "來源包缺少必要檔案：$RBN_REQUIRED_FILE" 2
done
[[ -z "$(/usr/bin/find "$RBN_PROJECT_ROOT/Resources/Web" -type l -print -quit)" ]] || \
  rbn_fail 'Web 資源含有符號連結，請改用完整的來源包。' 6
[[ ! -L "$RBN_APP_PATH" ]] || rbn_fail "App 位置是符號連結，請先移開：$RBN_APP_PATH" 6
[[ ! -e "$RBN_APP_PATH" || -d "$RBN_APP_PATH" ]] || rbn_fail "App 位置已被其他檔案占用：$RBN_APP_PATH" 6

RBN_STAGE_ROOT="$(/usr/bin/mktemp -d "$RBN_CACHE_ROOT/staging/build.XXXXXX")"
RBN_STAGE_APP="$RBN_STAGE_ROOT/Rclone Browser Next.app"
/bin/mkdir -p "$RBN_STAGE_APP/Contents/MacOS" "$RBN_STAGE_APP/Contents/Resources"

printf '\n正在建立 Rclone Browser Next %s（%s）\n' "$RBN_VERSION" "$RBN_TARGET_ARCH"
printf 'macOS：%s\n' "$(/usr/bin/sw_vers -productVersion)"
printf '目標版本：macOS %s 以上\n' "$RBN_MINIMUM_MACOS"
"$RBN_SWIFTC" --version

"$RBN_SWIFTC" \
  -swift-version 5 \
  -parse-as-library \
  -O \
  -whole-module-optimization \
  -no-toolchain-stdlib-rpath \
  -module-name RcloneBrowserNext \
  -target "$RBN_TARGET_ARCH-apple-macosx$RBN_MINIMUM_MACOS" \
  -sdk "$RBN_SDK" \
  -module-cache-path "$SWIFT_MODULECACHE_PATH" \
  -Xcc "-fmodules-cache-path=$CLANG_MODULE_CACHE_PATH" \
  "${RBN_CORE_SOURCES[@]}" "${RBN_MAC_SOURCES[@]}" \
  -framework Foundation \
  -framework AppKit \
  -framework WebKit \
  -framework UserNotifications \
  -o "$RBN_STAGE_APP/Contents/MacOS/$RBN_EXECUTABLE"

# Copy file contents without bringing downloaded extended attributes into a
# newly built product. Do not clear quarantine on the source folder or system.
/bin/cp -X "$RBN_PROJECT_ROOT/Resources/Info.plist" "$RBN_STAGE_APP/Contents/Info.plist"
/bin/cp -X "$RBN_PROJECT_ROOT/Resources/AppIcon.icns" "$RBN_STAGE_APP/Contents/Resources/AppIcon.icns"
/bin/cp -R -X "$RBN_PROJECT_ROOT/Resources/Web" "$RBN_STAGE_APP/Contents/Resources/Web"
if [[ -f "$RBN_PROJECT_ROOT/LICENSE" && ! -L "$RBN_PROJECT_ROOT/LICENSE" ]]; then
  /bin/cp -X "$RBN_PROJECT_ROOT/LICENSE" "$RBN_STAGE_APP/Contents/Resources/LICENSE.txt"
fi
/usr/bin/find "$RBN_STAGE_APP" -type d -exec /bin/chmod 755 {} +
/usr/bin/find "$RBN_STAGE_APP" -type f -exec /bin/chmod 644 {} +
/bin/chmod 755 "$RBN_STAGE_APP/Contents/MacOS/$RBN_EXECUTABLE"
/usr/bin/plutil -lint "$RBN_STAGE_APP/Contents/Info.plist"

# There is one native executable and no bundled frameworks or rclone binary.
# Sign the finished bundle, including Info.plist and all Web resources.
/usr/bin/codesign --force --sign - --timestamp=none \
  --identifier "$RBN_BUNDLE_ID" "$RBN_STAGE_APP"
RBN_EXPECTED_ARCH="$RBN_TARGET_ARCH" /bin/bash "$RBN_SCRIPT_ROOT/verify-mac.sh" "$RBN_STAGE_APP"

# Keep the previous App until its replacement has compiled and verified.
rbn_check_app_stopped
if [[ -e "$RBN_APP_PATH" ]]; then
  RBN_BACKUP_ROOT="$RBN_PROJECT_ROOT/Backups"
  rbn_check_local_directory "$RBN_BACKUP_ROOT"
  /bin/mkdir -p "$RBN_BACKUP_ROOT"
  RBN_BACKUP_DIRECTORY="$(/usr/bin/mktemp -d "$RBN_BACKUP_ROOT/build-$RBN_RUN_ID.XXXXXX")"
  RBN_OLD_APP_BACKUP="$RBN_BACKUP_DIRECTORY/Rclone Browser Next.app"
  /bin/mv "$RBN_APP_PATH" "$RBN_OLD_APP_BACKUP"
  RBN_REPLACEMENT_STARTED=1
fi
/bin/mv "$RBN_STAGE_APP" "$RBN_APP_PATH"
RBN_REPLACEMENT_FINISHED=1

RBN_DISTRIBUTION_ROOT="$RBN_PROJECT_ROOT/Distribution"
rbn_check_local_directory "$RBN_DISTRIBUTION_ROOT"
/bin/mkdir -p "$RBN_DISTRIBUTION_ROOT"
RBN_ZIP_PATH="$RBN_DISTRIBUTION_ROOT/Rclone_Browser_Next_${RBN_VERSION}_macOS_${RBN_TARGET_ARCH}_${RBN_RUN_ID}.zip"
[[ ! -e "$RBN_ZIP_PATH" && ! -L "$RBN_ZIP_PATH" ]] || rbn_fail "壓縮檔已存在：$RBN_ZIP_PATH" 6
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$RBN_APP_PATH" "$RBN_ZIP_PATH"
RBN_ZIP_HASH="$(/usr/bin/shasum -a 256 "$RBN_ZIP_PATH" | /usr/bin/awk '{print $1}')"
printf '%s  %s\n' "$RBN_ZIP_HASH" "$(/usr/bin/basename "$RBN_ZIP_PATH")" > "$RBN_ZIP_PATH.sha256"

printf '\n已建立：%s\n' "$RBN_APP_PATH"
printf 'App 大小：'
/usr/bin/du -sk "$RBN_APP_PATH" | /usr/bin/awk '{printf "%.2f MiB（磁碟用量）\n", $1 / 1024}'
printf '備份 ZIP：%s\n' "$RBN_ZIP_PATH"
[[ -z "$RBN_OLD_APP_BACKUP" ]] || printf '上一份 App：%s\n' "$RBN_OLD_APP_BACKUP"
printf '%s\n' 'rclone 另由 App 內設定選擇；這次建置沒有下載任何套件。'
if [[ "$RBN_NO_LAUNCH" == 0 ]]; then
  /usr/bin/open "$RBN_APP_PATH"
fi
