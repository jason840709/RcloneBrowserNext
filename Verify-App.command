#!/bin/bash
set -uo pipefail
RBN_COMMAND_ROOT="$(cd -P "$(dirname "$0")" && pwd -P)"
if /bin/bash "$RBN_COMMAND_ROOT/Scripts/verify-mac.sh" "$@"; then
  exit 0
else
  RBN_COMMAND_STATUS="$?"
  if [[ -t 0 ]]; then
    printf '\n按 Return 關閉這個視窗。'
    read -r RBN_COMMAND_REPLY || true
  fi
  exit "$RBN_COMMAND_STATUS"
fi
