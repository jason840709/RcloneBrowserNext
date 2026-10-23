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

Settings schema 7 rebases the interface size: displayed 100 uses native zoom 0.90; displayed 110 uses 1.00. The host computes `(interfaceScale - 10) / 100`. The five standard choices remain 80, 90, 100, 110 and 125. On loading a pre-schema-7 settings file, an explicitly stored old scale is increased by 10 once, preserving its rendered size. Values 120 and 135 retain the old 110 and 125 choices; the appearance picker includes one of these only while it is the current value. Fresh settings and older files without an explicit scale use the new 100 default. The migration is persisted before the native host reads preferences. Schema 6 introduced whole-interface scale and green themes. `hiddenBuiltinPresets` accepts `local-local`, `local-nas`, `nas-cloud`, `local-cloud`, `cloud-cloud` and `cloud-local`; hiding a preset does not delete its definition. Fresh transfer comparison defaults are `comparison: default`, `localHashPolicy: none`, `deleteMode: during`, and `maxDelete: -1`. Legacy default values are migrated once; saved tasks and remembered workspaces retain their original transfer semantics, including sparse older snapshots that relied on old defaults.

Schema 4 introduced system language, `savedWorkspace`, `networkOptions` and unlimited job scheduling. Existing manual languages/themes are preserved. For legacy settings before schema 4, the old default concurrency value 2 becomes 0 (unlimited); other saved non-default limits remain intact. A value 2 explicitly saved in schema 4 or later remains 2.

`RBNLanguageResolver.resolve` maps the first preferred system language: Chinese variants to `zh-TW`, Japanese to `ja`, all others to `en`. Explicit supported language selections override the system value. Bootstrap supplies `resolvedLanguage` so native dialogs and renderer text agree.

`savedWorkspace` stores `left`, `right`, `direction`, `mode` and the complete transfer `options`. It does not enqueue or run a job. Editing default startup folders updates the corresponding saved-workspace locations when present; clearing the saved startup configuration clears both sources of defaults.

The file toolbar groups Save workspace and Save task beside one shared information tooltip. Workspace saving replaces the next-launch snapshot without selections; named tasks retain their own selection scope. Neither save action starts a transfer. In Appearance, the three columns are purple, green and blue, with the light row above the dark row. Transfer descriptions use the available column width and normal line wrapping. A speed-limit summary appears only when a nonzero limit is configured; parallel file counts remain in the transfer options and preset descriptions.

Saved task requests retain source/destination semantics and optional left/right direction metadata. Editing a task preserves its ID and creation timestamp unless the user saves a copy. Dry Run is applied to the submitted run; it must not silently change the stored task's normal operation.

Settings changes are validated and persisted before success is reported. Connection-affecting settings cannot change during active transfer, mount, stream, account setup or engine replacement. Renderer refreshes must consume the successful settings snapshot, not a stale form draft.

Account setup defaults to a short form with browser authorization. Detailed setup batches ordinary fields and folds advanced options. Native `AccountSetupPolicy` answers only schema-backed fields and reviewed OAuth questions; validation, unknown required choices and repeated states return to the UI. Quick create explicitly authorizes an atomic save after completion; editing and detailed setup retain explicit Save. Both share the same staged-config and external-edit checks. See [Account configuration](ACCOUNT_CONFIGURATION.md) for the protocol, password representation and browser lifecycle.

## Navigation and progress

Each folder request has a generation number and an identity for native cancellation. Keep the previous successful path and listing mounted while a newer request is loading; disable the listing's selection, opening, drag and file-action controls. Commit the path, listing and history only for the latest successful result. Cancellation preserves the previous successful state. A failed request shows its error card for the requested path and does not expose the previous listing as that path's files.

### Session listing cache and cancellation (0.9.4)

Each pane owns a separate least-recently-used cache of remote listings, shared by its tabs and accounts for the current session. Native local endpoints bypass this cache and are read afresh on navigation. The limits are 64 directory listings, 50,000 total entries and an estimated 16 MiB per pane; the byte budget estimates cache data, not total JavaScript heap usage. Evict the least recently used listings to stay within all limits. Do not persist listing data to settings, apply a five-minute TTL, poll folders, or schedule background network refreshes.

Explicit Refresh invalidates **all** cached locations in the invoking pane, across every depth, tab and account, and then fetches the current location afresh. Preserve history and the opposite pane's cache. This is lazy invalidation, not an eager recursive scan of the remote. Advance request/cache generations so an older in-flight result cannot refill an invalidated entry or replace the displayed path. Cache hits and successful network reads use the same navigation commit rules.

File mutations invalidate related locations in both panes. A non-Dry-Run transfer reaching completed, failed or cancelled also invalidates affected destination locations because a partial run may have changed files; a move includes its source. Account and connection changes clear both panes. Browsing state must remain separate from transfer preflight and comparison semantics.

The loading control stays in the centre of the listing with the previous rows visible underneath. Hover and keyboard focus reveal its cancel symbol; reduced motion uses a static indicator. Native cancellation targets the associated listing child, waits for its exit and leaves other listings and transfers alone. Renderer generation checks remain necessary even after native cancellation, because completion can race a navigation or refresh. Local enumeration must also stop cooperatively without committing a partial result.

Remote browsing uses a single `lsjson --no-mimetype` listing after engine availability is established. `lsjson` resolves and validates its remote; an additional `listremotes` existence check is unnecessary for each browse request. Keep endpoint validation, size, modification time and command error handling. Do not add `--no-modtime` or `--http-no-head`: the latter makes HTTP object size/time unknown. Transfer preflight remains unchanged. These changes remove overhead; they do not promise a fixed first-load time for any provider.

The original application's [lazy tree cache](https://github.com/kapitainsky/RcloneBrowser/blob/45bf7411839b0919c488a3e3a0a5272b50c9fc7b/src/item_model.cpp#L192-L211) and [single-folder refresh](https://github.com/kapitainsky/RcloneBrowser/blob/45bf7411839b0919c488a3e3a0a5272b50c9fc7b/src/item_model.cpp#L130-L137) informed the cache design. The all-depth per-pane invalidation and explicit listing cancellation are Next behaviour. rclone's pinned [`lsjson` implementation](https://github.com/rclone/rclone/blob/be8d6044eacb843b74d335db0c5fbe09222031fe/fs/operations/lsjson.go#L174-L186) preserves size and modification time when MIME type lookup is disabled; its [HTTP no-head path](https://github.com/rclone/rclone/blob/be8d6044eacb843b74d335db0c5fbe09222031fe/backend/http/http.go#L717-L723) does not.

### History and transfer progress

Folder history belongs to each pane tab, not the WKWebView document. The main `RcloneBrowserWindow.sendEvent` route, window-local AppKit monitor and responder fallback share one handler for auxiliary buttons 3/4. It handles both down and up phases, forwards a `navigateHistory` native event with CSS coordinates, the original event's epoch-millisecond time and its phase, and consumes repeated delivery of the same event. A matching release ends a handled press; a release without a preceding down is also a navigation request. The bridge dispatches `rbn:navigate-history`. The renderer ignores navigation while a dialog is open and routes it to the pointed-at pane or the active pane. The DOM fallback schedules navigation on mousedown and also accepts mouseup-only or auxclick-only delivery. A 50 ms pairing window lets a native copy win without waiting for a release. Native/DOM copies of one press are paired by timestamp; repeated presses are not discarded just because their directions match. No global input or Accessibility permission is requested.

The progress estimator consumes the same `--stats=1s` JSON counters as the existing job pipeline. Its bounded rolling window covers at most 60 seconds. This is logical-byte throughput: rclone's `BytesNoNetwork` path can increase `bytes` while leaving its native `speed` at zero. Preserve fast local/server-side copy rather than changing transfer flags for the display. Finished jobs retain an overall mean; missing or stale data must not produce fabricated ETA. The estimator starts no filesystem scan, checksum, timer, poller or child process of its own.

Presets are complete transfer-option snapshots applied by an explicit user action. They never enqueue a job or switch endpoints. Local/NAS destination presets use one file transfer, ten checkers and `--multi-thread-streams=0`. Cloud destination presets use seven transfers and ten checkers, including NAS-to-cloud and cloud-to-cloud. Limiting parallel writes does not guarantee physical allocation or a universally optimal throughput. Core validation remains authoritative for every request sent by the UI.

Transfer selections belong to the source only and are separate from the destination's file-action focus. Changing direction or swapping panes clears selections in every tab. Selected-folder Sync uses anchored scope filters and rejects selected files or `deleteExcluded`; unselected destination contents remain outside its scope. Combining a selection with include rules requires a metadata-only intersection listing. For Sync, both ends contribute matching paths so destination-only files within scope can still be deleted.

When `modifyWindow` is empty and the chosen comparison uses modification times, the macOS core uses `fstatfs` through an `O_EVTONLY` descriptor to identify local volumes. Known timestamp resolution is FAT 2 s, HFS 1 s and exFAT 10 ms. Missing destinations use their nearest existing ancestor's volume; other filesystem errors are not guessed away. Both ends contribute to the effective tolerance. APFS, unknown formats and mounted SMB do not acquire an arbitrary wider window. Explicit user values win, and automatically detected values are not persisted into Tasks. See [the source review](RESEARCH_0.6.0.md).

## Per-file reports

Each transfer has separate stdout and stderr pipes. rclone writes `--combined=-` comparison output to stdout and structured JSON logs/statistics to stderr. A named `--combined` output file is deliberately avoided: rclone recreates that file at the beginning of a high-level retry. The app retains all attempts in its own append-only raw comparison log.

`TransferReportWriter` maintains bounded counters and six buffered ledgers: all events, successful actions, errors, skipped events, comparison events and the raw comparison stream. JSON comparison candidates never count as completed transfers. A `=` line records that the selected comparison or skip rule determined no copy was needed. Checks, transfer counters, event totals and unique file counts remain distinct. Unknown unique skipped/failed counts remain `null`.

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

The native host reserves termination before deciding whether to show the quit dialog. An empty queue or a queue containing only successful jobs quits directly. Failed, cancelled, interrupted and unfinished jobs require confirmation, as do active tools. New transfer/tool starts cannot enter during confirmation. Cancellation releases the reservation; approval stops tools and queued/running jobs before replying to AppKit that termination may continue. Active engine replacement is allowed to finish before quitting. Compatibility hosts use the same core quit summary.

Transfer cancellation first sends SIGINT and allows ten seconds for rclone's registered exit handlers, then escalates to SIGTERM and, two seconds later, SIGKILL only if needed. The second signal can interrupt cleanup. Jobs remain `cancelling` until the child actually exits; cancellation metadata reports escalation, without claiming destination cleanup was verified. Bulk cleanup takes a fixed ID list, marks targeted active and queued jobs before stopping any, and persists history before deleting its own job logs. It never deletes destination paths. See [the pinned rclone source review](RESEARCH_0.6.0.md).

Before loading HTML, the host reads saved appearance, sets the native window and WebView backgrounds, injects `window.__rbnInitialAppearance` at document start and applies the rebased `interfaceScale` with `WKWebView.pageZoom`. The synchronous `appearance-bootstrap.js` selects the native theme before the stylesheet or React runs, then falls back to the saved Web theme or purple-dark. Do not add CSS `zoom` or transform scaling to the production renderer, which would double-apply it. AppKit controls retain system sizing.

`RBNStartupSurface` places an opaque native loading view above the live WebView before the window opens. The WebView keeps drawing under that view. Handoff waits for mounted React content, the loading image to decode, animation frames and a WebKit snapshot with the expected theme canvas. A generation token rejects replies from earlier loads; a timeout and native retry button cover a failed load or WebContent-process termination.

Both loading stages use the same `startup-{purple,green,blue}.png` raster from `Resources/Web`, generated from the existing small SVG profile. Their centered layout is 64 px of artwork, a 20 px gap, a 29 px title row, another 20 px gap and a 23 px status row. Fonts are 22 px medium and 14 px regular; native points multiply all dimensions by the current WebKit pageZoom. Keep the matching `.startup` CSS and `RBNStartupCover` layout together. Do not substitute ICNS on one side: its optical profile changes with the chosen representation. Native tests compare actual DOM/native bounds, fonts, colors and decoded artwork at standard and migrated scales.

`RcloneBrowserWindow` holds the actual browser view independently of its containing startup view. Mouse buttons 3/4 and horizontal `NSEvent.swipe` events reach the same pane-history bridge. Native `goBack(_:)` and `goForward(_:)` responder commands use the active pane. The renderer applies editable-field and dialog guards to these commands and maintains each pane's own location history. Apple's [gesture event guide](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/HandlingTouchEvents/HandlingTouchEvents.html) describes swipe routing and its distinction from scrolling.

Runtime icons are cached by purple, blue or green family. `RBNAppIconAppearance.apply` assigns the selected image through Apple's [NSApplication.applicationIconImage](https://developer.apple.com/documentation/appkit/nsapplication/applicationiconimage), without a filesystem path or write. Finder and the stopped app's Dock item use the fixed purple bundle icon. The attempted `NSWorkspace.setIcon` implementation was removed after its custom file metadata made strict signature verification fail on macOS 15 and 26. Apple's [QA1940](https://developer.apple.com/library/archive/qa/qa1940/_index.html) explains the resource-fork and Finder-information restriction. Theme changes leave the installed bundle and its metadata untouched; there is no runtime re-signing or system icon-cache reset.

The engine updater and app release checker are separate components. The app checker fetches only the configured public repository's `releases/latest` JSON endpoint. It validates full stable release metadata, caps the body size, rejects redirects and unexpected release links, and reports 404 as no available published release. It needs no GitHub credential. It opens a verified release page only after a user action and does not self-replace the app.

Release tags use `vMAJOR.MINOR.PATCH`. Update `RBNProject.version`, `Resources/Info.plist` (marketing and build versions), `Scripts/common-mac.sh`, WebSource package and lockfile versions, the status-bar version, Compat CLI package and lockfile, Compat Cargo package and lockfile, `tauri.conf.json` and release documentation together. Change only the app's own package version in lockfiles. The workflow publishes a new version pushed to `main` after the platform and native-interface checks pass. A `work/0.9.4` push runs the same checks without publishing a release.

## Verification

Swift suites exercise models, settings migration, task roundtrips, queue/cancel behavior, real local/alias rclone transfers, updater validation/rollback, auxiliary process cleanup and app-release responses. `MacInterfaceTests` also loads a local document in the actual WKWebView, checks the standard and migrated zoom levels and native-to-DOM pane targeting, sends real `NSEvent` objects through the app's window handler into JavaScript, verifies theme injection before page scripts, and decodes all three ICNS files with AppKit. A pinned rclone integration fixture is separate from ordinary app installation.

Build the signed app before running the native suites. `MacStartupTests` combines the production Web bundle with the actual native cover and WebKit snapshots. `MacIconTests` applies each colour to the test application's `applicationIconImage`, checks its colour and transparency, and compares the full alpha masks of all eleven ICNS representations across the three families. A copied signed app must retain every `Contents` byte, its top-level entries, its fixed purple bundle icon and a valid `codesign --verify --deep --strict` result after each colour change and runtime reset. The test reads AppKit's runtime image and the bundle resources; it does not measure Finder's cached presentation or a physical Dock. `MacNavigationIntegrationTests` connects native events to the production React bundle and real rclone folders; it requires an explicit rclone executable.

The GitHub workflow runs the full suites on standard public `macos-15` (Apple Silicon) and `macos-15-intel` runners, with an additional native-interface job on `macos-26`. It uses the same build scripts, checks the finished bundle and uploads ZIPs that preserve the bundle's metadata. Native input tests use constructed AppKit events; physical-device observations are recorded separately.

For 0.9.4, release gates must cover cache hits and limits, all-depth refresh isolation, mutations and transfer invalidation, cancellation before and during a listing, late responses, and path/history preservation. Run real listing-process cancellation on Mac, Windows and Linux; a mocked bridge response alone cannot prove that a child exited. Include the navigation cases in the explicit WebKit spec list as well as the complete Chromium suite. Windows installation verification includes the published 0.9.3 baseline alongside 0.9.0, 0.9.0-r1 and 0.9.2. Keep evidence tied to the candidate installer and exact source commit.

Read [the release verification record](VALIDATION.zh-TW.md) for required checks, recorded results and material limits. Changes to UI layout require inspection of the actual production bundle in all six themes and at the largest interface scale, including resized columns, narrow windows, task dialogs and overflow states.

## Public-source hygiene

Publish only application sources, required resources, synthetic tests, build scripts, lockfiles and release documentation. Exclude account configuration, credentials, user screenshots, reference app binaries, caches, generated app bundles and historical private research inventories. Check the source archive manifest before release.

The source is MIT licensed. Preserve third-party web license notices. The v2 app icon is supplied by Jason Chen; ForkLift resources are not redistributed.

## Unified 0.9.1 release

The current Windows build uses `Scripts/package-compat.py`, inherits the shared Tauri version, and keeps r1 filesystem code in the main source tree. The old one-off Windows publication/frozen-Mac workflows and scripts are available at tag `windows-v0.9.0-r1`, not active in this version. `Scripts/verify-version.py` checks all current version entries and the unchanged Windows filesystem blobs. `Scripts/windows/verify-candidate.py` remains the strict installed-product gate, now used by the common workflow.

After changing WebSource, regenerate `Resources/Web` with the pinned npm lockfile, stage the source and generated resources, then run `python3 Scripts/update-source-manifest.py`. The source ZIP includes these resources so a normal local Mac build still requires only Apple tools. Publish only when the CI for the exact source commit is green; do not reuse older platform binaries under a new version name.
