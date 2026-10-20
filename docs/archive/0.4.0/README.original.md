# Rclone Browser Next

A dual-pane macOS file manager for [rclone](https://rclone.org/), by **Jason Chen**.

[繁體中文](README.zh-TW.md) · [Build on Mac](docs/BUILD_MAC.zh-TW.md) · [Development](docs/DEVELOPMENT.md)

Browse local folders, cloud storage and NAS/server remotes in either pane. Copy, move or sync in either direction; inspect a Dry Run before changing files. Save complete tasks and edit their transfer options later.

The app uses Swift, AppKit and the system WKWebView. It does not bundle Electron, Chromium, Qt or rclone. The included web interface is prebuilt, so building the Mac app needs only an existing Xcode or Apple Command Line Tools installation. Build caches and generated files stay inside the project folder.

## Build and run

Requires **macOS 13 or later**, on Apple Silicon or Intel.

1. Download a source release and extract the whole folder.
2. Double-click `Build-on-Mac.command`. It creates `Rclone Browser Next.app` beside the script and verifies its local signature.
3. Open Settings and choose the folder containing your `rclone` executable, or select an existing executable. Use **Account setup (Config)** to add your remotes.

The local build script does not install development tools, Node.js, Homebrew or rclone. If Apple Command Line Tools are missing, it explains the requirement and stops.

Source builds use an ad-hoc signature on your Mac. They are not Apple Developer ID signed or notarized. CI app bundles are build artifacts with the same limitation. The source release is the preferred distribution while Developer ID signing is unavailable.

## Features

- Local, cloud and NAS/server locations; standard Mac folders and mounted volumes.
- Copy, move, sync, selection transfer, Dry Run, progress, logs, cancellation and saved tasks.
- Full task editing: comparison, skip rules, deletion timing, filters, bandwidth and advanced transfer options.
- Metadata-based NAS comparison that can avoid reading a mounted file solely to calculate a local hash.
- Remember the current folders and transfer setup for the next launch; restoring it never starts a transfer.
- Neutral light/dark surfaces with purple or blue accents; dark purple is the default.
- Traditional Chinese, English and Japanese; the default follows the first system language. Chinese maps to Traditional Chinese, Japanese to Japanese, other languages to English.
- Proxy and rclone connection settings, including timeouts, request rate, IPv4/IPv6 and HTTP/2 compatibility.
- Separate update checks for the external rclone installation and for this app's GitHub releases.
- Quit confirmation with orderly shutdown of running and queued work.

See [the feature map](docs/FEATURE_MATRIX.zh-TW.md) for the relationship to the original Rclone Browser and [NAS comparison](docs/NAS_COMPARISON.zh-TW.md) for the comparison tradeoffs.

## Development and checks

`Test-on-Mac.command /absolute/path/to/rclone` compiles the Swift test suites and runs integration tests against that executable. Test files stay inside the project. Without an executable, tests that require real rclone are reported as skipped.

UI development uses the pinned dependencies in `WebSource/package-lock.json`; ordinary app builds use `Resources/Web` and require no JavaScript toolchain. See [Development](docs/DEVELOPMENT.md) for the isolated install and test commands.

The included macOS workflow is configured to compile the app and run the core suites on Apple Silicon and Intel. It downloads a pinned rclone fixture into its checkout, validates the official SHA-256 and preserves build ZIPs. The workflow has not run for this source delivery; see the [validation record](docs/VALIDATION.zh-TW.md) for the checks actually performed. CI results would not establish performance on a particular NAS or cloud account.

The public GitHub project has not yet been created for this delivery. Until a full release is published at the configured repository, the app update check reports that no published release is available. The separate rclone engine updater remains usable.

Native app/engine update downloads support system proxies, manual HTTP CONNECT and SOCKS5. A manual proxy address beginning with `https://` is rejected with an explanation; rclone transfers still support that proxy scheme. rclone-specific connection settings do not change the app's native update requests.

## Credits and license

Author: **Jason Chen**. MIT license; see [LICENSE](LICENSE).

The workflows and feature inventory were studied from [Rclone Browser](https://github.com/kapitainsky/RcloneBrowser) and [RcloneBrowser2](https://github.com/downer08tutti/RcloneBrowser2). This Swift/AppKit host is a separate implementation. ForkLift informed the dual-pane interaction design; its code and private resources are not distributed here. rclone remains a separately installed project. The app icon was supplied by Jason Chen. Third-party web notices are included in `Resources/Web/THIRD_PARTY_NOTICES.txt`.
