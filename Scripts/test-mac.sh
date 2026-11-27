#!/bin/bash
set -Eeuo pipefail
umask 022
RBN_ENTRY_ROOT="$(cd -P "$(dirname "$0")" && pwd -P)"
source "$RBN_ENTRY_ROOT/common-mac.sh"
rbn_require_mac
[[ "$#" -le 1 ]] || rbn_fail '用法：Test-on-Mac.command [rclone 的完整路徑]' 5
RBN_TEST_ENGINE="${1:-${RBN_TEST_RCLONE:-}}"
[[ "$RBN_TEST_ENGINE" == /* && -x "$RBN_TEST_ENGINE" ]] || rbn_fail '完整測試需要合成資料專用的 rclone 完整路徑。' 5
rbn_prepare_local_environment
rbn_require_apple_tools
rbn_choose_architecture
rbn_require_python
rbn_prepare_rust
rbn_start_log test
RBN_TEST_WORK_ROOT="${RBN_TEST_WORK_ROOT:-$RBN_CACHE_ROOT/tests}"
rbn_check_local_directory "$RBN_TEST_WORK_ROOT"
/bin/mkdir -p "$RBN_TEST_WORK_ROOT"
RBN_TEST_RUN="$(/usr/bin/mktemp -d "$RBN_TEST_WORK_ROOT/run.XXXXXX")"
export RBN_TEST_RCLONE="$RBN_TEST_ENGINE" RBN_TEST_ROOT="$RBN_TEST_RUN/rust-fixtures"
/bin/mkdir -p "$RBN_TEST_ROOT"
"$RBN_PYTHON" -B "$RBN_PROJECT_ROOT/Tests/support/verify-native-assertions.py" --output "$RBN_TEST_RUN/assertion-sources.json"
RBN_CORE_MAPPING_COMPLETE=1
if [[ "${RBN_NATIVE_TESTS_ONLY:-0}" != 1 ]]; then
  # The original 12 Swift core suites remain reference sources. Their Rust
  # counterparts, including real-rclone ignored cases, use one shared runner.
  "$RBN_PYTHON" -B "$RBN_SCRIPT_ROOT/test-rust.py" --rclone "$RBN_TEST_ENGINE" --output "$RBN_TEST_RUN/rust-results.json"
  if [[ -f "$RBN_PROJECT_ROOT/Tests/rust-test-map.json" ]]; then
    /bin/cp -X "$RBN_PROJECT_ROOT/Tests/rust-test-map.json" "$RBN_TEST_RUN/rust-test-map.review.json"
  else
    RBN_CORE_MAPPING_COMPLETE=0
    printf '%s\n' '案例對照表仍待整合；上方執行結果不代表 12 組逐案映射已完成。'
  fi
fi
rbn_build_rust_engine
export RBN_ENGINE_PATH="$RBN_RUST_OUTPUT/rbn-engine"
RBN_LOCAL_RECOVERY_FAILED=0
if ! /bin/bash "$RBN_SCRIPT_ROOT/test-local-recovery-mac.sh" "$RBN_TEST_ENGINE"; then
  RBN_LOCAL_RECOVERY_FAILED=1
fi
# Collect every native UI result even when a recovery case fails. The overall
# gate remains failed; no failed or unexecuted assertion is counted as passed.
RBN_NATIVE_FAILURES=0
RBN_TEST_SUPPORT=("$RBN_PROJECT_ROOT/Sources/Mac/EngineClient.swift" "$RBN_PROJECT_ROOT/Tests/support/LegacyModelOracle.swift" "$RBN_PROJECT_ROOT/Tests/support/LegacyDefaultSettings.swift" "$RBN_PROJECT_ROOT/Tests/support/RustNativeTestSupport.swift")
for RBN_NATIVE_SUITE in MacInterfaceTests MacStartupTests MacIconTests MacNavigationIntegrationTests MacCompletionTests MacWindowInteractionTests MacEngineTransportTests; do
  RBN_NATIVE_SOURCE="$RBN_PROJECT_ROOT/Tests/$RBN_NATIVE_SUITE.swift"
  [[ -s "$RBN_NATIVE_SOURCE" && ! -L "$RBN_NATIVE_SOURCE" ]] || rbn_fail "缺少測試檔案：$RBN_NATIVE_SOURCE" 2
  RBN_NATIVE_SOURCES=("$RBN_PROJECT_ROOT/Sources/Mac/RcloneWebView.swift" "$RBN_PROJECT_ROOT/Sources/Mac/WindowTitlebar.swift")
  RBN_NATIVE_ARGS=("$RBN_PROJECT_ROOT/Resources")
  case "$RBN_NATIVE_SUITE" in
    MacCompletionTests) RBN_NATIVE_SOURCES=("$RBN_PROJECT_ROOT/Sources/Mac/CompletionAttention.swift") ;;
    MacStartupTests) RBN_NATIVE_SOURCES+=("$RBN_PROJECT_ROOT/Sources/Mac/StartupSurface.swift" "${RBN_TEST_SUPPORT[@]}") ;;
    MacIconTests)
      RBN_NATIVE_SOURCES=("$RBN_PROJECT_ROOT/Sources/Mac/AppIconAppearance.swift")
      RBN_NATIVE_ARGS+=("$RBN_APP_PATH") ;;
    MacEngineTransportTests)
      RBN_NATIVE_SOURCES=("$RBN_PROJECT_ROOT/Sources/Mac/EngineClient.swift")
      RBN_NATIVE_WORK="$RBN_TEST_RUN/MacEngineTransportTests-work"
      /bin/mkdir -p "$RBN_NATIVE_WORK"
      RBN_NATIVE_ARGS=("$RBN_NATIVE_WORK") ;;
    MacNavigationIntegrationTests)
      RBN_NATIVE_SOURCES+=("${RBN_TEST_SUPPORT[@]}")
      RBN_NATIVE_WORK="$RBN_TEST_RUN/$RBN_NATIVE_SUITE-work"
      /bin/mkdir -p "$RBN_NATIVE_WORK"
      RBN_NATIVE_ARGS+=("$RBN_TEST_ENGINE" "$RBN_NATIVE_WORK") ;;
  esac
  printf '\n測試：%s\n' "$RBN_NATIVE_SUITE"
  if ! rbn_compile_swift "$RBN_TEST_RUN/$RBN_NATIVE_SUITE" "${RBN_NATIVE_SOURCES[@]}" "$RBN_NATIVE_SOURCE"; then
    RBN_NATIVE_FAILURES=$((RBN_NATIVE_FAILURES + 1)); continue
  fi
  if ! /usr/bin/codesign --force --sign - --timestamp=none "$RBN_TEST_RUN/$RBN_NATIVE_SUITE" ||
     ! /usr/bin/codesign --verify --strict "$RBN_TEST_RUN/$RBN_NATIVE_SUITE"; then
    RBN_NATIVE_FAILURES=$((RBN_NATIVE_FAILURES + 1)); continue
  fi
  if ! "$RBN_TEST_RUN/$RBN_NATIVE_SUITE" "${RBN_NATIVE_ARGS[@]}" | /usr/bin/tee "$RBN_TEST_RUN/$RBN_NATIVE_SUITE.log"; then
    RBN_NATIVE_FAILURES=$((RBN_NATIVE_FAILURES + 1))
  fi
done
printf '\n測試資料與執行結果保留在：%s\n' "$RBN_TEST_RUN"
[[ "$RBN_NATIVE_FAILURES" == 0 ]] || rbn_fail "$RBN_NATIVE_FAILURES 個原生測試套件未通過。" 1

[[ "$RBN_CORE_MAPPING_COMPLETE" == 1 ]] || rbn_fail 'Rust 核心案例對照表尚未完成，不能將完整 Mac 驗收標為通過。' 1

[[ "$RBN_LOCAL_RECOVERY_FAILED" == 0 ]] || rbn_fail '本機複製或復原測試未通過；原生介面結果已另行保留。' 1
