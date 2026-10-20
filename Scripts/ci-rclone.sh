#!/bin/bash
# CI-only fixture. Normal local app builds never call this script or download rclone.
set -Eeuo pipefail
umask 022

RBN_CI_ROOT="$(cd -P "$(dirname "$0")/.." && pwd -P)"
[[ "${CI:-}" == true && "$(/usr/bin/uname -s)" == Darwin ]] || {
  printf '%s\n' 'This fixture installer runs only in macOS CI.' >&2
  exit 2
}
RBN_CI_ARCH="${RBN_BUILD_ARCH:-$(/usr/bin/uname -m)}"
case "$RBN_CI_ARCH" in
  arm64) RBN_CI_RCLONE_ARCH=arm64 ;;
  x86_64) RBN_CI_RCLONE_ARCH=amd64 ;;
  *) printf '%s\n' 'Unsupported CI architecture.' >&2; exit 2 ;;
esac
RBN_CI_VERSION=v1.75.2
RBN_CI_ENGINE="$RBN_CI_ROOT/.build-cache/ci-engine"
RBN_CI_ARCHIVE="rclone-$RBN_CI_VERSION-osx-$RBN_CI_RCLONE_ARCH.zip"
[[ ! -L "$RBN_CI_ROOT/.build-cache" && ! -L "$RBN_CI_ENGINE" ]] || exit 2
/bin/mkdir -p "$RBN_CI_ENGINE"
cd "$RBN_CI_ENGINE"
/usr/bin/curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
  --connect-timeout 20 --max-time 180 \
  "https://downloads.rclone.org/$RBN_CI_VERSION/$RBN_CI_ARCHIVE" --output "$RBN_CI_ARCHIVE"
/usr/bin/curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
  --connect-timeout 20 --max-time 60 \
  "https://downloads.rclone.org/$RBN_CI_VERSION/SHA256SUMS" --output SHA256SUMS
/usr/bin/awk -v wanted="$RBN_CI_ARCHIVE" '$2 == wanted { print; count++ } END { if (count != 1) exit 1 }' SHA256SUMS > selected.sha256
/usr/bin/shasum -a 256 -c selected.sha256
/usr/bin/unzip -q "$RBN_CI_ARCHIVE"
/bin/cp "rclone-$RBN_CI_VERSION-osx-$RBN_CI_RCLONE_ARCH/rclone" rclone
/bin/chmod 755 rclone
/usr/bin/codesign --force --sign - --timestamp=none rclone
./rclone version

