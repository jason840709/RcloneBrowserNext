# Web UI verification — 0.8.1

**181 / 181 cases passed**, with no failures, skipped cases or retries, in the complete run beginning **2026-10-20T19:10:20.142Z**. Duration: **166.4 seconds**. TypeScript checking and the production build passed before testing.

This run used **Linux and Chrome Headless Shell 156.0.8078.4** to load the shipped `Resources/Web/index.html` with deterministic native-bridge replies. [verification.json](verification.json) records the production files, source hashes, all individual outcomes and screenshot hashes. The recorded production and source hashes matched before and after the full run.

## Five new navigation cases

The five cases in `revision081-navigation.spec.ts` check the production renderer after a native navigation message reaches its bridge:

- A swipe message changes the pane under the pointer and preserves the independent forward histories of both panes.
- Duplicate delivery navigates once, while two rapid messages with distinct timestamps both navigate.
- A native command message operates on the active pane. Focused path inputs and editable text retain their contents; a mouse swipe can still target the other pane.
- An open operation dialog blocks swipe and command navigation.
- Horizontal wheel scrolling leaves folder history unchanged.

The earlier navigation-focused run passed **16 / 16 cases**, including the five new cases and retained mouse/keyboard regressions. It preceded the final icon/footer bundle rebuild; the complete 181-case run above is the result for the production hashes recorded here.

## Retained behavior and visuals

The full suite retains folder-loading continuity, stale-response protection, independent pane/tab history, six themes, three languages, minimum-window dialogs, location-menu anchoring and scrolling, saved tasks, transfer options, reports, queue actions and platform-specific controls. First-paint cases check the root theme and background color before bridge initialization and across the first animation frames.

The standard display choices remain 80%, 90%, 100%, 110% and 125%. Effective WebView zoom is `(displayedScale - 10) / 100`; 100% uses 0.90 and 110% uses 1.00. A selected legacy 120% or 135% remains available until a standard value is chosen.

The suite produced **79 screenshots**. **6 captures were inspected directly**; the observations and exact hashes are recorded in the receipt. The two 100,000-file panes processed 25 progress updates with **zero full-list map/filter/sort passes**, measured at **404.2 ms** in this run.

## Native macOS verification

Native macOS CI was pending when this Web receipt was generated. `Scripts/test-mac.sh` runs `MacInterfaceTests`, `MacStartupTests`, `MacIconTests` and `MacNavigationIntegrationTests` separately. They cover AppKit input routing, native startup frames, persistent Finder icons, and the actual React/WKWebView/Core-engine navigation chain. Native swipe tests supply an `NSEvent` test double; a physical MX Master 3S and Logi Options+ were not exercised in this Web run.

The completed [0.8.0 record](history/0.8.0/verification.json) is preserved unchanged, alongside [0.7.0](history/0.7.0/verification.json), [0.6.0](history/0.6.0/verification.json) and [pre-recovery 0.7.0](history/0.7.0-before-recovery/verification.json).

## Run

From `WebSource`, with the pinned dependencies installed:

```sh
npm run typecheck
npm run build
npx playwright test --config tests/playwright.config.ts --reporter=json
```

`RBN_TEST_BROWSER` selects an existing Chromium executable; `RBN_TEST_OUTPUT` selects the result directory. This run used Playwright 1.64.1 (browser revision 1248) and project-local Noto CJK TC/JP fonts through `FONTCONFIG_FILE`. Browser archive and font hashes are recorded in the JSON receipt. These development dependencies are not bundled with the desktop app.
