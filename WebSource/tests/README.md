# Web UI verification — 0.8.0

**176 / 176 cases passed**, with no failures, skipped cases or retries, in the complete run beginning **2026-10-20T17:19:35.055Z**. Duration: **174.9 seconds**. The 13 new 0.8.0 cases also passed in a separate targeted run. TypeScript checking and the production build passed before testing.

[verification.json](verification.json) records the tested production files, source hashes, individual outcomes and screenshot hashes. The production files and source stayed unchanged throughout both completed runs. The completed [0.7.0 record](history/0.7.0/verification.json) is preserved with its original results; earlier [0.6.0](history/0.6.0/verification.json) and [pre-recovery 0.7.0](history/0.7.0-before-recovery/verification.json) records remain available.

## 0.8.0 coverage

- Side buttons navigate the pane under the pointer, with the active pane as fallback. Left/right panes and location tabs retain independent back/forward history. Tests exercise down-only, up-only, native/DOM copies, long presses, rapid presses, editable fields and open dialogs. A missing release followed by another button press no longer consumes a new forward command.
- Folder loading keeps the previous successful table visible. Row actions, selection, drag/context actions and transfer start are blocked while those rows belong to the prior location. The newest successful reply replaces the listing; a late reply cannot replace a newer folder. Empty folders retain their existing view during navigation, and failures show the requested target's error and retry action.
- The saved theme applies before the native bridge initializes and remains stable across the first animation frames. Cases cover native light/dark themes, a cached theme, an invalid native hint and unavailable storage.
- The five standard display choices remain 80%, 90%, 100%, 110% and 125%. Effective WebView zoom is `(displayedScale - 10) / 100`, so 100% uses 0.90 and 110% uses 1.00. A migrated current value of 120% or 135% appears as a sixth sorted choice; selecting a standard value removes that extra choice. Only 100% is marked as the default.

## Retained coverage and visuals

The full suite also covers six themes, three languages, minimum-window dialogs, location-menu anchoring and scrolling, saved tasks, transfer options, reports, queue actions and platform-specific controls. It loads the shipped `Resources/Web/index.html` via `file://` with deterministic native-bridge replies. AppKit input routing, native window rendering, real transfers and platform packaging have separate native/platform checks.

The suite produced **79 screenshots**; **6 captures were inspected directly**, covering migrated scale choices and representative compact/default-scale layouts. The two 100,000-file panes processed 25 progress updates with **zero full-list map/filter/sort passes**, measured at **397.9 ms** in this run.

## Run

From `WebSource`, with the pinned dependencies installed:

```sh
npm run typecheck
npm run build
npx playwright test --config tests/playwright.config.ts
```

`RBN_TEST_BROWSER` selects an existing Chromium executable; `RBN_TEST_OUTPUT` selects the result directory. This run used Chrome Headless Shell 156.0.8078.4 (Playwright revision 1248) and project-local Noto CJK fonts through `FONTCONFIG_FILE`. The browser archive source and hashes are recorded in the JSON receipt. These development dependencies are not bundled with the desktop app.
