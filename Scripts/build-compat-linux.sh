#!/usr/bin/env bash
set -euo pipefail
RBN_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$RBN_ROOT"
[[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] || { echo 'This build targets x86_64 Linux.' >&2; exit 1; }
RBN_CACHE="$RBN_ROOT/.build-cache/compat"
command -v cargo >/dev/null || { echo 'Install Rust 1.90 or newer before building.' >&2; exit 1; }
command -v pkg-config >/dev/null || { echo 'Install pkg-config and the WebKitGTK development packages.' >&2; exit 1; }
command -v patchelf >/dev/null || { echo 'Install patchelf before building the Linux package.' >&2; exit 1; }
pkg-config --exists gtk+-3.0 webkit2gtk-4.1 || { echo 'Install libgtk-3-dev and libwebkit2gtk-4.1-dev before building.' >&2; exit 1; }
export CARGO_HOME="${CARGO_HOME:-$RBN_CACHE/cargo}"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$RBN_CACHE/target}"
export CARGO_INCREMENTAL=0
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-2}"
export XDG_CACHE_HOME="$RBN_CACHE/xdg"
mkdir -p "$RBN_CACHE/runtime"
python3 Scripts/prepare-compat.py
cargo build --release --locked --manifest-path Sources/Rust/Cargo.toml --bin rbn-engine
cp "$CARGO_TARGET_DIR/release/rbn-engine" "$RBN_CACHE/runtime/rbn-engine"
python3 Scripts/bundle-compat-runtime.py --runtime "$RBN_CACHE/runtime"
(cd Compat/desktop && cargo test --release --locked)
python3 Scripts/collect-compat-notices.py
command -v npm >/dev/null || { echo 'Node.js is needed to run the packaged Tauri build tool.' >&2; exit 1; }
export npm_config_cache="$RBN_CACHE/npm"
mkdir -p "$RBN_CACHE/cli"
cp Compat/cli/package.json Compat/cli/package-lock.json "$RBN_CACHE/cli/"
npm ci --prefix "$RBN_CACHE/cli" --ignore-scripts --no-audit --no-fund
(cd Compat/desktop && "$RBN_CACHE/cli/node_modules/.bin/tauri" build --bundles deb --ci)
mkdir -p Distribution
python3 Scripts/package-compat.py --platform linux --cache "$RBN_CACHE"
