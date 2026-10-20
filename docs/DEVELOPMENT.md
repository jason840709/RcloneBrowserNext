# Development

Rclone Browser Next uses a Swift core, an AppKit host and a bundled React interface inside the system WKWebView. The host owns executable selection, filesystem dialogs, confirmations and process lifecycle. The renderer calls a narrow native bridge; it cannot run a shell or navigate to arbitrary pages.

## Repository layout

| Path | Responsibility |
|---|---|
| `Sources/Core/EngineModels.swift` | Validated endpoints, transfer options, network options and command arguments |
| `Sources/Core/RcloneEngine.swift` | rclone subprocesses, directory operations, jobs, settings and tasks |
| `Sources/Core/TransferReport.swift` | Bounded transfer-report summaries, comparison events, file results and paged/exportable reports |
| `Sources/Core/EngineStorage.swift` | Atomic settings, task and history persistence |
| `Sources/Core/RcloneUpdater.swift` | External engine download, validation, replacement and rollback |
| `Sources/Core/AppReleaseChecker.swift` | Public GitHub release checks for the app |
| `Sources/Core/LanguageResolver.swift` | One native/system language policy shared with bootstrap |
| `Sources/Core/RcloneTools.swift` | Tree, export, links, mount and stream sessions |
| `Sources/Core/NativeMessages.swift` | Known native/error translations with paths and backend diagnostics preserved |
| `Sources/Mac/AppMain.swift` | AppKit lifecycle, menus, WebKit bridge and native confirmations |
| `Sources/Mac/RcloneWebView.swift` | Finder drops and window-scoped auxiliary mouse-button events, translated from native points to zoomed CSS coordinates |
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

Settings schema 6 adds whole-interface scale and green themes. `hiddenBuiltinPresets` accepts `local-local`, `local-nas`, `nas-cloud`, `local-cloud`, `cloud-cloud` and `cloud-local`; hiding a preset does not delete its definition. Fresh transfer comparison defaults are `comparison: default`, `localHashPolicy: none`, `deleteMode: during`, and `maxDelete: -1`. Legacy default values are migrated once; saved tasks and remembered workspaces retain their original transfer semantics, including sparse older snapshots that relied on old defaults.

Schema 4 introduced system language, `savedWorkspace`, `networkOptions` and unlimited job scheduling. Existing manual languages/themes are preserved. For legacy settings before schema 4, the old default concurrency value 2 becomes 0 (unlimited); other saved non-default limits remain intact. A value 2 explicitly saved in schema 4 or later remains 2.

`RBNLanguageResolver.resolve` maps the first preferred system language: Chinese variants to `zh-TW`, Japanese to `ja`, all others to `en`. Explicit supported language selections override the system value. Bootstrap supplies `resolvedLanguage` so native dialogs and renderer text agree.

`savedWorkspace` stores `left`, `right`, `direction`, `mode` and the complete transfer `options`. It does not enqueue or run a job. Editing default startup folders updates the corresponding saved-workspace locations when present; clearing the saved startup configuration clears both sources of defaults.

Saved task requests retain source/destination semantics and optional left/right direction metadata. Editing a task preserves its ID and creation timestamp unless the user saves a copy. Dry Run is applied to the submitted run; it must not silently change the stored task's normal operation.

Settings changes are validated and persisted before success is reported. Connection-affecting settings cannot change during active transfer, mount, stream, account setup or engine replacement. Renderer refreshes must consume the successful settings snapshot, not a stale form draft.

## Navigation and progress

Folder history belongs to each pane tab, not the WKWebView document. A window-local AppKit monitor and responder fallback handle auxiliary button 3/4, consume both down/up phases, and forward a `navigateHistory` native event with CSS-coordinate position and the original event's epoch-millisecond time. The bridge dispatches `rbn:navigate-history`. The renderer ignores navigation while a dialog is open and routes it to the pointed-at pane or the active pane. A delayed DOM fallback remains available for mouse drivers that do not reach the native handler. Native/DOM copies of one press are paired by timestamp; repeated presses are not discarded just because their directions match. No global input or Accessibility permission is requested.

The progress estimator consumes the same `--stats=1s` JSON counters as the existing job pipeline. Its bounded rolling window covers at most 60 seconds. This is logical-byte throughput: rclone's `BytesNoNetwork` path can increase `bytes` while leaving its native `speed` at zero. Preserve fast local/server-side copy rather than changing transfer flags for the display. Finished jobs retain an overall mean; missing or stale data must not produce fabricated ETA. The estimator starts no filesystem scan, checksum, timer, poller or child process of its own.

Presets are complete transfer-option snapshots applied by an explicit user action. They never enqueue a job or switch endpoints. Local/NAS destination presets use one file transfer, ten checkers and `--multi-thread-streams=0`. Cloud destination presets use seven transfers and ten checkers, including NAS-to-cloud and cloud-to-cloud. Limiting parallel writes does not guarantee physical allocation or a universally optimal throughput. Core validation remains authoritative for every request sent by the UI.

Transfer selections belong to the source only and are separate from the destination's file-action focus. Changing direction or swapping panes clears selections in every tab. Selected-folder Sync uses anchored scope filters and rejects selected files or `deleteExcluded`; unselected destination contents remain outside its scope. Combining a selection with include rules requires a metadata-only intersection listing. For Sync, both ends contribute matching paths so destination-only files within scope can still be deleted.

When `modifyWindow` is empty and the chosen comparison uses modification times, the macOS core uses `statfs` to identify local volumes. Known timestamp resolution is FAT 2 s, HFS 1 s and exFAT 10 ms. Missing destinations use their nearest existing ancestor's volume; other filesystem errors are not guessed away. Both ends contribute to the effective tolerance. APFS, unknown formats and mounted SMB do not acquire an arbitrary wider window. Explicit user values win, and automatically detected values are not persisted into Tasks. See [the source review](RESEARCH_0.6.0.md).

## Per-file reports

Each transfer has separate stdout and stderr pipes. rclone writes `--combined=-` comparison output to stdout and structured JSON logs/statistics to stderr. A named `--combined` output file is deliberately avoided: rclone recreates that file at the beginning of a high-level retry. The app retains all attempts in its own append-only raw comparison log.

`TransferReportWriter` maintains bounded counters and six buffered ledgers: all events, successful actions, errors, skipped events, comparison events and the raw comparison stream. JSON comparison candidates never count as completed transfers. A `=` line means the selected comparison or skip rule decided no copy was needed; it is not a promise of byte-for-byte equality. Checks, transfer counters, event totals and unique file counts remain distinct. Unknown unique skipped/failed counts remain `null`.

Comparison callbacks write directly to the captured report writer. They do not take the engine state lock, publish a job snapshot or notify the renderer per line. The existing one-second statistics path refreshes counters; the final state waits for both pipes to drain. Buffered writes use a cached typed JSON encoder. Explicit page reads flush visible buffered data without forcing a disk sync; final closure syncs the ledgers.

`getJobReport` reads one category with a byte-offset cursor and a bounded page size. It never loads an entire report into memory. The UI fetches a page when opened, changed or explicitly refreshed, without a report polling loop. Existing jobs without report files remain viewable with their original logs.

`exportJobReport` is a native-host operation. After the user chooses a destination with NSSavePanel, the engine produces an immutable snapshot of the complete prefix, excluding a partial JSON record. The host copies that snapshot to the chosen destination and removes only the temporary snapshot in `defer`. The internal `getJobReportPath` API is not exposed to the renderer. Original report ledgers are removed only when their UUID-scoped job history is cleared.

The report tests cover retries, general and file-specific errors, copied-then-delete-failed moves, Dry Run, escaping, large pagination, active snapshots, partial records and symlink refusal. A 100,000-event synthetic local writer measurement took 1.562 seconds; this isolates report overhead and is not an end-to-end NAS throughput result. See [the research record](RESEARCH_0.6.0.md).

## rclone arguments and network settings

Commands use separate argv elements and a `--` delimiter before user endpoints. Secrets used to unlock rclone config stay in memory and environment variables, not in tasks, logs or renderer responses. Parent `RCLONE_*` variables are filtered so they cannot silently override selected transfer semantics.

Structured network options map to `--bind`, `--contimeout`, `--timeout`, `--tpslimit`, `--tpslimit-burst`, `--user-agent` and `--disable-http2`. Transfer-specific options explicitly set on a task override corresponding shared defaults. Empty per-transfer timeouts inherit the network defaults. Legacy task timeouts remain explicit; legacy global TPS/HTTP2 extra arguments migrate into structured network settings.

User-supplied source addresses are validated as IPv4 or IPv6. Do not interpret interface names as addresses or invent a DNS-selection flag. The HTTPS app/engine update clients use the selected manual proxy, but rclone's bind/TPS settings do not configure Foundation URLSession.

See [rclone's documented flags](https://rclone.org/flags/) and the pinned integration fixture version in `Scripts/ci-rclone.sh`.

## Shutdown and updates

The native host reserves termination before showing the quit dialog. New transfer/tool starts cannot enter during confirmation. Cancellation releases the reservation; approval stops tools and queued/running jobs before replying to AppKit that termination may continue. Active engine replacement is allowed to finish before quitting.

Transfer cancellation first sends SIGINT and allows ten seconds for rclone's registered exit handlers, then escalates to SIGTERM and, two seconds later, SIGKILL only if needed. The second signal can interrupt cleanup. Jobs remain `cancelling` until the child actually exits; cancellation metadata reports escalation, without claiming destination cleanup was verified. Bulk cleanup takes a fixed ID list, marks targeted active and queued jobs before stopping any, and persists history before deleting its own job logs. It never deletes destination paths. See [the pinned rclone source review](RESEARCH_0.6.0.md).

The host applies the saved `interfaceScale` with `WKWebView.pageZoom`. Do not add CSS `zoom` or transform scaling to the production renderer, which would double-apply it. AppKit controls retain system sizing. Runtime icons are cached by purple, blue or green family and assigned through `NSApplication.applicationIconImage`; the signed bundle is never mutated for a theme change.

The engine updater and app release checker are separate components. The app checker fetches only the configured public repository's `releases/latest` JSON endpoint. It validates full stable release metadata, caps the body size, rejects redirects and unexpected release links, and reports 404 as no available published release. It needs no GitHub credential. It opens a verified release page only after a user action and does not self-replace the app.

Release tags use `vMAJOR.MINOR.PATCH`. Update `RBNProject.version`, `Resources/Info.plist`, `Scripts/common-mac.sh`, both web package version fields and release documentation together.

## Verification

Swift suites exercise models, settings migration, task roundtrips, queue/cancel behavior, real local/alias rclone transfers, updater validation/rollback, auxiliary process cleanup and app-release responses. `MacInterfaceTests` also loads a local document in the actual WKWebView, checks all five zoom levels and native-to-DOM pane targeting, and decodes all three ICNS files with AppKit. A pinned rclone integration fixture is separate from ordinary app installation.

The GitHub workflow builds and tests on standard public `macos-15` (Apple Silicon) and `macos-15-intel` runners. It uses the same build scripts, checks the finished bundle and uploads ZIPs that preserve the bundle's metadata. Workflow results are build/integration evidence; they do not imply validation against every cloud backend, Finder drag interaction, third-party mount driver or real NAS.

Read [the release verification record](VALIDATION.zh-TW.md) for completed checks and material limits. Changes to UI layout require inspection of the actual production bundle in all six themes and at the largest interface scale, including resized columns, narrow windows, task dialogs and overflow states.

## Public-source hygiene

Publish only application sources, required resources, synthetic tests, build scripts, lockfiles and release documentation. Exclude account configuration, credentials, user screenshots, reference app binaries, caches, generated app bundles and historical private research inventories. Check the source archive manifest before release.

The source is MIT licensed. Preserve third-party web license notices. The v2 app icon is supplied by Jason Chen; ForkLift resources are not redistributed.
