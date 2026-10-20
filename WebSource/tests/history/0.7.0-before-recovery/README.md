# Web UI verification — 0.7.0

**163 / 163 cases passed** in one complete execution starting at **2026-10-20T14:17:58.047Z**, in **186.7 seconds**. There were zero failures, skipped cases or flaky cases. The TypeScript check and production build also passed.

[verification.json](verification.json) records the production hashes, source hashes, individual test results, visual evidence and development findings. [VERIFICATION.zh-TW.md](VERIFICATION.zh-TW.md) provides the Traditional Chinese report. The original 0.6.0 receipts are preserved in [history/0.6.0](history/0.6.0).

## What is exercised

The suite opens the shipped `Resources/Web/index.html` through `file://` and uses the same `window.webkit.messageHandlers.rclone`, `__rbnReply` and `__rbnEvent` contract as the native hosts. Deterministic fixtures supply filesystem and engine replies. This suite covers the production interface and its requests; actual rclone transfers and native packaging have separate Core and platform checks.

| Group | Cases | Coverage |
| --- | ---: | --- |
| Original UI and layout cases | 42 | Native bridge, engine setup and updates, serialized settings, Config refresh, file actions, transfer options and 24 language/theme/window layouts |
| Retained 0.4 cases | 20 | System language, saved workspaces, full task editing, Dry Run, network settings, comparison help, location groups, zebra rows and compact dialogs |
| Retained 0.5 cases | 24 | Contained errors, floating notices, sync presets, independent history, side buttons, one-decimal progress and 100,000-file panes |
| Retained 0.6 cases | 54 | Five scales, six themes, icon matching, source-only selection, safe queue clearing, scoped folder sync, reports, pagination and copyable data |
| New 0.7 cases | 23 | Anchored location popups, search and IME handling, Windows paths, supported platform controls, symbolic-link options and precise report details |

## Location popups

Both panes use a searchable list that opens below the location button. The list owns its scrolling. Selecting the last of 60 cloud entries and reopening keeps the selected row visible without moving the popup or the main layout.

The same behavior is checked at **80%, 90%, 100%, 110% and 125%**. A 1060×680 native window at 125% is represented by an **848×544 CSS viewport**. Task and startup-folder dialogs are checked in all three interface languages at that size.

Arrow keys, Enter, Escape, Tab, outside clicks and focus changes are exercised. Chinese/Japanese composition Enter and WebKit keyCode 229 leave selection to the input method. Remote entries remain disabled while the engine is unavailable; local folders remain selectable. Windows drive and UNC paths stop at their roots, and known folders retain their names after trailing-separator normalization.

## Reports and link options

The report distinguishes **data processed**, **successful copy bytes**, **bytes written by copies that failed the size check**, and **job attempts**. Byte details include exact counts alongside readable units. Repeated attempts retain separate records. Checks continue to mean completed comparison operations.

Synthetic regressions exercise a first size mismatch, later confirmed source growth, a cleanup error and a skipped symbolic link. They check the localized explanation, affected path, before/after sizes and expandable original message. An unrelated final error stays visible even when earlier records show source growth. An incomplete or legacy successful-copy total is omitted.

Configuration records preserve the complete request and engine information in expandable JSON. Report pages remain bounded to 100 records and update only when opened, paged or refreshed. Progress events do not trigger report polling or extra directory scans.

The symbolic-link option defaults to `skip`. Selecting `preserve` survives saving defaults, saving a task and reopening its editor in all three languages. This suite verifies the request value; Core fixtures verify its `--links` behavior.

## Compatibility controls

Mac retains remote mounting, the menu-bar icon and completion notifications. Windows and Linux hide those currently unsupported entrances while retaining directory tools, streaming, accounts, tasks, transfers and reports. Windows executable selection saves the drive-qualified parent installation folder. Interface tests exercise these platform flags; desktop installation and runtime validation belong to the platform build checks.

## Visual and resource checks

The final renderer produced **34 synthetic screenshots**: matched Traditional Chinese and English main screens, six themes, both new location menus, report pages and compact forms. All 33 distinct captured scenes stay within the horizontal viewport; one additional PNG is a copy of the Chinese main scene.

All **120 / 120** tested palette pairs pass. Minimum text contrast is **4.90:1** and minimum control-border contrast is **3.50:1**. Linux font inspection found Noto Sans CJK TC for Traditional Chinese, DejaVu Sans for English and DejaVu Sans Mono for paths. Native hosts use the installed system fonts.

For two **100,000-file panes**, 25 progress updates caused **zero full-list map/filter/sort passes**, **zero extra directory-list requests**, and fewer than 100 mounted file rows. The measured browser time was **402.0 ms**.

## Run

From `WebSource`, with the pinned development dependencies installed:

```sh
npm run typecheck
npm run build
npx playwright test --config tests/playwright.config.ts
```

`RBN_TEST_BROWSER` selects an existing Chrome/Chromium executable. `RBN_TEST_OUTPUT` selects the results directory. Keep development browser downloads and caches under the project if installing them. The Mac build uses prebuilt web resources and needs no Node, browser or font download.

```sh
node --experimental-strip-types tests/render-previews.ts
python3 tests/check-contrast.py .build-cache/qa07-final-previews/palette-tokens.json
```

`RBN_PREVIEW_OUTPUT` changes the preview destination. All screenshot scenarios use fictional files and transfer values; the shipped app contains no fixtures.
