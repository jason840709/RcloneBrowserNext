#!/bin/bash
# Runs the original locked-file/card assertions against Rust, including images.
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
rbn_require_python
rbn_prepare_rust
rbn_start_log local-recovery
RBN_TEST_WORK_ROOT="${RBN_TEST_WORK_ROOT:-$RBN_CACHE_ROOT/tests}"
rbn_check_local_directory "$RBN_TEST_WORK_ROOT"
/bin/mkdir -p "$RBN_TEST_WORK_ROOT"
RBN_TEST_RUN="$(/usr/bin/mktemp -d "$RBN_TEST_WORK_ROOT/local-recovery.XXXXXX")"
RBN_TEST_APP="$RBN_APP_PATH/Contents/MacOS/$RBN_EXECUTABLE"
[[ -x "$RBN_TEST_APP" ]] || rbn_fail '請先建立 Mac App，再驗證內建修復入口。' 5
export RBN_ENGINE_PATH="$RBN_APP_PATH/Contents/MacOS/rbn-engine"
[[ -x "$RBN_ENGINE_PATH" ]] || rbn_fail '測試 App 缺少 Rust 引擎。' 5
"$RBN_PYTHON" -B "$RBN_PROJECT_ROOT/Tests/support/verify-native-assertions.py"
# Cargo's own artifact report selects the exact library TEST binary. Production
# rbn-engine never accepts the failpoints used by the original Swift driver.
"$RBN_CARGO" test "${RBN_CARGO_FLAGS[@]}" --lib --no-run --message-format=json > "$RBN_TEST_RUN/rust-lib-artifacts.jsonl"
RBN_RUST_TEST_BINARY="$("$RBN_PYTHON" -B - "$RBN_TEST_RUN/rust-lib-artifacts.jsonl" <<'PY'
import json,sys
items=[json.loads(x) for x in open(sys.argv[1]) if x.strip()]
paths={x['executable'] for x in items if x.get('reason')=='compiler-artifact' and x.get('profile',{}).get('test') and x.get('target',{}).get('name')=='rbn_core' and x.get('executable')}
if len(paths)!=1: raise SystemExit('Expected exactly one Rust library test executable')
print(paths.pop())
PY
)"
export RBN_RUST_TEST_BINARY
RBN_TEST_FAILURES=0
RBN_TEST_SUPPORT=("$RBN_PROJECT_ROOT/Sources/Mac/EngineClient.swift" "$RBN_PROJECT_ROOT/Tests/support/LegacyModelOracle.swift" "$RBN_PROJECT_ROOT/Tests/support/LegacyDefaultSettings.swift" "$RBN_PROJECT_ROOT/Tests/support/RustNativeTestSupport.swift" "$RBN_PROJECT_ROOT/Tests/support/RustPartialRecoveryTestSupport.swift")
for RBN_TEST_SUITE in MacLocalCopyTests MacPartialRecoveryTests; do
  RBN_TEST_SOURCE="$RBN_PROJECT_ROOT/Tests/$RBN_TEST_SUITE.swift"
  RBN_SUITE_WORK="$RBN_TEST_RUN/$RBN_TEST_SUITE-work"
  /bin/mkdir -p "$RBN_SUITE_WORK"
  printf '\n測試：%s\n' "$RBN_TEST_SUITE"
  if ! rbn_compile_swift "$RBN_TEST_RUN/$RBN_TEST_SUITE" "${RBN_TEST_SUPPORT[@]}" "$RBN_TEST_SOURCE"; then
    RBN_TEST_FAILURES=$((RBN_TEST_FAILURES + 1)); continue
  fi
  /usr/bin/codesign --force --sign - --timestamp=none "$RBN_TEST_RUN/$RBN_TEST_SUITE"
  /usr/bin/codesign --verify --strict "$RBN_TEST_RUN/$RBN_TEST_SUITE"
  if ! "$RBN_TEST_RUN/$RBN_TEST_SUITE" "$RBN_TEST_ENGINE" "$RBN_SUITE_WORK" "$RBN_TEST_APP" | /usr/bin/tee "$RBN_TEST_RUN/$RBN_TEST_SUITE.log"; then
    RBN_TEST_FAILURES=$((RBN_TEST_FAILURES + 1))
  elif [[ "$RBN_TEST_SUITE" == MacPartialRecoveryTests ]]; then
    if ! "$RBN_PYTHON" -B "$RBN_PROJECT_ROOT/Tests/support/verify-native-assertions.py" --partial-log "$RBN_TEST_RUN/$RBN_TEST_SUITE.log" --output "$RBN_TEST_RUN/partial-original-assertions.json"; then
      RBN_TEST_FAILURES=$((RBN_TEST_FAILURES + 1))
    fi
  fi
done
printf '\n本機複製與修復資料：%s\n' "$RBN_TEST_RUN"
[[ "$RBN_TEST_FAILURES" == 0 ]] || rbn_fail "$RBN_TEST_FAILURES 個本機複製或修復套件未通過。" 1
