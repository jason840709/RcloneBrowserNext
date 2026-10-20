# Development

Rclone Browser Next uses a Swift core, an AppKit host and a bundled React interface inside the system WKWebView. The host owns executable selection, filesystem dialogs, confirmations and process lifecycle. The renderer calls a narrow native bridge; it cannot run a shell or navigate to arbitrary pages.

## Repository layout

| Path | Responsibility |
|---|---|
| `Sources/Core/EngineModels.swift` | Validated endpoints, transfer options, network options and command arguments |
| `Sources/Core/RcloneEngine.swift` | rclone subprocesses, directory operations, jobs, settings and tasks |
| `Sources/Core/EngineStorage.swift` | Atomic settings, task and history persistence |
| `Sources/Core/RcloneUpdater.swift` | External engine download, validation, replacement and rollback |
| `Sources/Core/AppReleaseChecker.swift` | Public GitHub release checks for the app |
| `Sources/Core/LanguageResolver.swift` | One native/system language policy shared with bootstrap |
| `Sources/Core/RcloneTools.swift` | Tree, export, links, mount and stream sessions |
| `Sources/Core/NativeMessages.swift` | Known native/error translations with paths and backend diagnostics preserved |
| `Sources/Mac/AppMain.swift` | AppKit lifecycle, menus, WebKit bridge and native confirmations |
| `WebSource/renderer` | Dual-pane UI, settings, transfer editor, jobs and tasks |
| `WebSource/shared/types.ts` | Renderer/native JSON contracts |
| `Resources/Web` | Prebuilt production interface used by normal app builds |
| `Scripts` | Local build/verification/test scripts and an explicitly separate CI fixture installer |

## Build the Mac app

Use an existing Xcode or Apple Command Line Tools installation on macOS 13+. The normal build does not fetch dependencies:

```bash
/bin/bash Build-on-Mac.command --no-launch
/bin/bash Verify-App.command
/bin/bash Test-on-Mac.command /absolute/path/to/rclone
```

Run from the extracted project folder. `RBN_BUILD_ARCH=arm64` or `RBN_BUILD_ARCH=x86_64` selects an architecture when cross-building with Apple's SDK. Tests require a rclone executable that the testing host can actually run.

The complete bundle is assembled before ad-hoc signing. Existing app builds are backed up only after the new bundle compiles and verifies. The external rclone executable is never copied into `Contents/Resources`.

## Develop the web interface

The following is an optional developer workflow and requires an existing compatible Node.js. All dependency and browser caches stay inside the checkout. No global npm installs or shell profile changes are required.

```bash
cd WebSource
export npm_config_cache="$PWD/.build-cache/npm"
export PLAYWRIGHT_BROWSERS_PATH="$PWD/.build-cache/browsers"
export TMPDIR="$PWD/.build-cache/tmp/"
mkdir -p "$npm_config_cache" "$PLAYWRIGHT_BROWSERS_PATH" "$TMPDIR"
npm ci
npm run typecheck
npm run build
npx --no-install playwright install chromium
npx --no-install playwright test --config tests/playwright.config.ts
```

Use the exact lockfile dependencies. `vite build` writes the production bundle to `Resources/Web`. The native app never starts a development server and never loads the interface from the internet. The UI tests open the production `file://` bundle with a synthetic native bridge fixture. Do not use real account names, file listings, configuration files or user screenshots in fixtures.

## Settings and migration

Settings schema 4 adds system language, `savedWorkspace`, `networkOptions` and unlimited job scheduling. Existing manual languages/themes are preserved. For legacy settings without the schema marker, the old default concurrency value 2 becomes 0 (unlimited); other saved non-default limits remain intact. A value 2 explicitly saved in schema 4 remains 2.

`RBNLanguageResolver.resolve` maps the first preferred system language: Chinese variants to `zh-TW`, Japanese to `ja`, all others to `en`. Explicit supported language selections override the system value. Bootstrap supplies `resolvedLanguage` so native dialogs and renderer text agree.

`savedWorkspace` stores `left`, `right`, `direction`, `mode` and the complete transfer `options`. It does not enqueue or run a job. Editing default startup folders updates the corresponding saved-workspace locations when present; clearing the saved startup configuration clears both sources of defaults.

Saved task requests retain source/destination semantics and optional left/right direction metadata. Editing a task preserves its ID and creation timestamp unless the user saves a copy. Dry Run is applied to the submitted run; it must not silently change the stored task's normal operation.

Settings changes are validated and persisted before success is reported. Connection-affecting settings cannot change during active transfer, mount, stream, account setup or engine replacement. Renderer refreshes must consume the successful settings snapshot, not a stale form draft.

## rclone arguments and network settings

Commands use separate argv elements and a `--` delimiter before user endpoints. Secrets used to unlock rclone config stay in memory and environment variables, not in tasks, logs or renderer responses. Parent `RCLONE_*` variables are filtered so they cannot silently override selected transfer semantics.

Structured network options map to `--bind`, `--contimeout`, `--timeout`, `--tpslimit`, `--tpslimit-burst`, `--user-agent` and `--disable-http2`. Transfer-specific options explicitly set on a task override corresponding shared defaults. Empty per-transfer timeouts inherit the network defaults. Legacy task timeouts remain explicit; legacy global TPS/HTTP2 extra arguments migrate into structured network settings.

User-supplied source addresses are validated as IPv4 or IPv6. Do not interpret interface names as addresses or invent a DNS-selection flag. The HTTPS app/engine update clients use the selected manual proxy, but rclone's bind/TPS settings do not configure Foundation URLSession.

See [rclone's documented flags](https://rclone.org/flags/) and the pinned integration fixture version in `Scripts/ci-rclone.sh`.

## Shutdown and updates

The native host reserves termination before showing the quit dialog. New transfer/tool starts cannot enter during confirmation. Cancellation releases the reservation; approval stops tools and queued/running jobs before replying to AppKit that termination may continue. Active engine replacement is allowed to finish before quitting.

The engine updater and app release checker are separate components. The app checker fetches only the configured public repository's `releases/latest` JSON endpoint. It validates full stable release metadata, caps the body size, rejects redirects and unexpected release links, and reports 404 as no available published release. It needs no GitHub credential. It opens a verified release page only after a user action and does not self-replace the app.

Release tags use `vMAJOR.MINOR.PATCH`. Update `RBNProject.version`, `Resources/Info.plist`, `Scripts/common-mac.sh`, both web package version fields and release documentation together.

## Verification

Swift suites exercise models, settings migration, task roundtrips, queue/cancel behavior, real local/alias rclone transfers, updater validation/rollback, auxiliary process cleanup and app-release responses. A pinned rclone integration fixture is separate from ordinary app installation.

The GitHub workflow builds and tests on standard public `macos-15` (Apple Silicon) and `macos-15-intel` runners. It uses the same build scripts, checks the finished bundle and uploads ZIPs that preserve the bundle's metadata. Workflow results are build/integration evidence; they do not imply validation against every cloud backend, Finder drag interaction, third-party mount driver or real NAS.

Read [the release verification record](VALIDATION.zh-TW.md) for completed checks and material limits. Changes to UI layout require inspection of the actual production bundle in all four themes, including resized columns, narrow windows, task dialogs and overflow states.

## Public-source hygiene

Publish only application sources, required resources, synthetic tests, build scripts, lockfiles and release documentation. Exclude account configuration, credentials, user screenshots, reference app binaries, caches, generated app bundles and historical private research inventories. Check the source archive manifest before release.

The source is MIT licensed. Preserve third-party web license notices. The v2 app icon is supplied by Jason Chen; ForkLift resources are not redistributed.
