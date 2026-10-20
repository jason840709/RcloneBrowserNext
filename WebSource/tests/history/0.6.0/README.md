# Web UI contract tests — 0.6.0

The suite opens the prebuilt `Resources/Web/index.html` through `file://`. It exercises the production IIFE, React views and native bridge messages. `tests/native-fixture.ts` supplies deterministic replies through the same `window.webkit.messageHandlers.rclone`, `__rbnReply` and `__rbnEvent` interface used by the Mac host. The shipped app contains no fixture, simulated filesystem, development browser, Electron runtime or remote web dependency.

## Final result

**140 / 140 cases passed** in one complete execution on **2026-10-20, starting at 12:10:08.621 UTC**, in **165.7 seconds**. There were **zero failures, skipped cases or flaky cases**. The final production resources were not changed between this execution and the final screenshots.

[verification.json](verification.json) records execution statistics, development findings, production byte sizes and SHA-256 hashes, preview hashes, palette checks and font evidence. [VERIFICATION.zh-TW.md](VERIFICATION.zh-TW.md) describes the changes and limits in Traditional Chinese.

| Coverage group | Cases | Main coverage |
| --- | ---: | --- |
| Retained behavior | 18 | Native IPC and escaped filenames; engine setup and updates; serialized settings patches and rollback; Config refresh; resizing; copy/move/sync options; filters; tool actions; Finder-drop preparation; input and reduced-motion behavior |
| Retained revision 0.4 | 20 | System language and manual overrides; remembered workspaces; complete task snapshots and editing; Dry Run versus Run; network patches; tooltips; local/NAS/cloud groups; native menu entrances; zebra stripes; compact multilingual dialogs |
| Main-window layout matrix | 24 | Three languages × four existing themes × 1060×680 / 1440×900, with reachable primary controls and live job metrics |
| Retained revision 0.5 | 24 | Contained error/empty states; floating notices; safe sync defaults; preset hide/restore; independent tab history; keyboard behavior; one-decimal progress; rolling averages; 100,000-file panes; comparison advice |
| Initial revision 0.6 | 26 | Five scales and immediate save/rollback; all six themes; matching brand icons; 125% minimum-window dialogs; snapshot-based Jobs clearing; stopping/retained rows; late-event tombstones; interrupted-history retention; icon geometry and ICNS structure |
| Additional revision 0.6 | 28 | Source-only selection; cross-tab clearing on direction/swap; folder-only sync scope; task and drop restoration; six preset values; solid scrollbar tracks; selectable-data exceptions; plain empty Jobs; toast hit testing; native/DOM side-button pairing; report categories, pagination, escaping, refresh and three-language compact layouts |

The retained preset assertions now reflect the explicitly requested **7 transfers / 10 checks for cloud destinations**. The former blanket native-history flag expectation was updated to require a working DOM fallback. The simulated available-app release is deliberately `0.6.0 → 0.7.0`; it is not a claim about a published release.

### Development findings

Earlier development runs are preserved in the manifest and are not added to the 140-case total:

- The first scale/theme/trash run passed **23 / 25**. A real toast obstruction was fixed: success/info text now passes pointer hits through, while its close button remains interactive; root notices appear above the bottom status area. A separate SVG test was corrected to normalize a `<title>` element with optional attributes before comparing geometry.
- The next focused run passed **26 / 26**.
- The first additional-requirements run passed **25 / 26**. Its route-copy assertion inspected the nonselectable wrapper instead of the deliberately selectable path span. The final test verifies the span and its full selected text.
- The final complete run passed all **140** cases after these changes, including two extra report refresh/language regressions.

## Contracts that matter

### Scaling and appearance

The five scale values are **80, 90, 100, 110 and 125**, with **100** as the middle/default value. The frontend saves `interfaceScale`; the real host applies `WKWebView.pageZoom`. The frontend does not add CSS zoom or transform scaling. The test host models the resulting CSS viewport, including **848×544 CSS pixels for a 1060×680 native window at 125%**. Settings, transfer forms, task editors and report actions remain reachable by local scrolling.

All six themes use neutral gray/white surfaces. Purple, blue and low-saturation green are accents. The title icon and “Next” text follow the chosen family. The purple v2 SVG remains unchanged; blue/green SVG and ICNS variants preserve its geometry and repaired eyes. `tools/generate-theme-icons.py` reproduces the two native variants from the bundled canonical SVG inputs using Inkscape and Python, without editing the original shapes.

### Transfer scope and presets

Only the source pane has checkboxes. A destination row can still receive focus for rename/delete/share tools without becoming part of a transfer selection. Reversing direction or swapping locations clears selections across every tab. Finder drops and saved tasks restore only their explicitly requested source selection.

Sync accepts a selection of folders, whose names are preserved under the current destination. File or mixed selections and `deleteExcluded` with a nonempty selection are rejected by the interface. The tests verify the request payload and warning state; actual filesystem deletion boundaries are covered by separate Core tests.

Six presets set complete one-way sync options without starting a transfer:

| Destination group | Presets | Transfers | Checkers | Per-file parallel chunks |
| --- | --- | ---: | ---: | --- |
| Local/NAS | local-local, local-nas, cloud-local | 1 | 10 | Disabled |
| Cloud | local-cloud, nas-cloud, cloud-cloud | 7 | 10 | Backend default |

### Jobs clearing

`clearJobs({ids, mode})` receives a snapshot of IDs, with `mode` set to `finished` or `stop-and-clear`. Finished clears terminal records without stopping active jobs. All/Active with running work offers stop-and-clear, clear successful jobs only, or cancel. New jobs arriving after the dialog opened are not included. Cancelling records remain until the host confirms process exit; retained IDs stay visible. Removed IDs are held as session tombstones so a late terminal event cannot restore them. A stop does not promise to undo completed changes or remove every backend's partial data.

### Side buttons

Native epoch timestamps are paired with DOM mousedown timestamps for the nearest unmatched gesture. The DOM path remains available when a driver bypasses native monitoring. The suite covers native-first, DOM-first, delayed native delivery, rapid repeated presses, mouseup/auxclick duplication and auxclick-only presses. Back/Forward keys, Alt arrows and Cmd/Control brackets use the active pane while preserving input editing. Native coordinate conversion and physical hardware behavior are outside this frontend suite.

### Per-file reports and resource use

Opening job details loads at most **100 records per page** through `getJobReport`. Cursors are opaque byte offsets. Comparison, skip, completed-action and error pages use the independent report API; they do not depend on the short raw-log tail. Full JSONL and raw comparison exports use the native save flow. Raw errors and commands remain available.

Counts retain their meaning:

- `stats.transfers / totalTransfers` and `checks / totalChecks` remain distinct. Their totals can change during scanning, failure or retry.
- Skip records are `matchedEvents + skippedEvents`, not a unique-file count. Matching includes configured skip rules and does not prove full content identity.
- The Errors category includes JSON `errorEvents` and `comparisonErrorEvents`. A comparison error signal is not itself a final transfer failure; the main error number remains `stats.errors`.
- Unknown legacy reports show an unknown skip value rather than deriving it from checks. Dry Run identifies simulated progress separately.

Progress events do not poll the report. A manual refresh can use a writer summary newer than `job.report`, and comparison explanations change language without reloading the ledger. Tests keep 100 rows mounted per page, preserve unusual/newline filenames as text, and confirm no executable markup appears.

For two **100,000-file panes**, 25 progress events produced **zero full-size map/filter/sort passes**, **zero extra directory-list requests**, and fewer than 100 rendered file rows. The measured **626.2 ms** is a Linux browser observation, not a macOS CPU or NAS throughput benchmark.

## Run

From `WebSource`, with its pinned development dependencies installed:

```sh
npm run typecheck
npm run build
npx playwright test --config tests/playwright.config.ts
```

Use an existing compatible Chrome/Chromium through `RBN_TEST_BROWSER`. If a development browser needs downloading, keep it within the project:

```sh
PLAYWRIGHT_BROWSERS_PATH="$PWD/.build-cache/playwright" npx playwright install chromium --only-shell
PLAYWRIGHT_BROWSERS_PATH="$PWD/.build-cache/playwright" npx playwright test --config tests/playwright.config.ts
```

`RBN_TEST_OUTPUT` redirects temporary results. Linux screenshots can use a project-local `FONTCONFIG_FILE`, fonts and cache. App/release packaging excludes these development files and `node_modules`. The normal Mac build uses prebuilt web resources and does not install Node, npm, Playwright, Chrome or extra fonts.

## Visual evidence

```sh
node --experimental-strip-types tests/render-previews.ts
python3 tests/check-contrast.py .build-cache/qa06-final-previews/palette-tokens.json
```

`render-previews.ts` writes **32 PNGs** under `.build-cache/qa06-final-previews` or `RBN_PREVIEW_OUTPUT`: six themes; matching Traditional Chinese and English main screens; visible floating notices; six-preset menus; report summary/comparison/errors; and compact green-theme settings, transfer, task and report layouts. It moves the pointer away before screenshots and checks that at most one report tab is selected. Notifications wait for completed opacity transitions.

Every path, remote, filename and statistic is fictional. The bilingual main screens use the same coherent example: **4 of 16 transfers**, **256 MiB of 1 GiB**, **16 MiB/s**, **48 seconds estimated remaining**, four successful-copy records and twelve skip records. Error examples explicitly add two error records and set the raw error count to two. No user screenshot filenames or accounts are copied into public documentation.

All **120 / 120** tested foreground/background pairs pass: minimum text contrast **4.90:1**, minimum control-border contrast **3.50:1**. This is a scoped palette check, not a full accessibility audit. Font evidence identifies **Noto Sans CJK TC** for Traditional Chinese, **DejaVu Sans** for English and **DejaVu Sans Mono** for paths; no Times fallback is present. Mac uses its system fonts.

## Limits

These checks validate frontend behavior and native wire messages using deterministic host responses. They do not execute AppKit/WKWebView, use a physical side-button mouse, verify Gatekeeper/signing, authenticate a real cloud account, transfer real NAS data, mount FUSE or play media. The project separately records Core, updater and actual Mac build/host validation. A frontend pass does not assert native hardware or network performance.
