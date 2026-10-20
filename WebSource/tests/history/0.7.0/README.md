# Web UI verification — 0.7.0

**163 / 163 cases passed**, with no failures, skipped cases or retries, in the complete execution beginning **2026-10-20T15:01:11.525Z**. Duration: **200.8 seconds**. TypeScript checking and the production build passed before that run.

[verification.json](verification.json) binds these results to the shipped web resources and source hashes. Earlier [0.6.0 results](history/0.6.0/verification.json) and the [prior 0.7.0 candidate results](history/0.7.0-before-recovery/verification.json) retain their original hashes and measurements.

## Coverage

The tests load the shipped `Resources/Web/index.html` through `file://` and supply deterministic replies through the native bridge contract. They exercise the interface and its requests. Core and platform checks cover actual rclone transfers and native packaging separately.

- Both location menus stay below their buttons after choosing the last of 60 cloud locations. Scrolling stays inside the list. Keyboard, search, Chinese/Japanese composition, dismissal and focus behavior are covered.
- Five interface scales, all three languages, compact task/settings dialogs, six themes and large virtualized file lists remain covered by the retained regressions.
- Report tests cover processed bytes, successful-copy bytes, failed size-check writes, retry counts, source growth, cleanup failures, pagination and exports. Repeated events remain separate records.
- Saved tasks retain transfer options, selections and symbolic-link policy. Queue clearing preserves active or unacknowledged work and distinguishes completed-only removal.
- macOS exposes mounting, menu-bar presence and completion notifications. Windows and Linux hide the unsupported controls while retaining file operations, account setup, directory tools, streaming and reports.

## Copy follow-up

The prior independent reader reviewed every entry in the three-language inventory. This follow-up implements that review: concurrent transfer/check counts are explicit; Move explains when the source is removed; references name the actual controls; saved-state, history and mounting labels match their implementations. Proxy settings and stdin have concrete explanations.

The completed-only queue action was checked against `Jobs.tsx` and kept: it removes only successful completed records, so a broader “finished records” label would be inaccurate. The review response also aligns mounting requirements and the notification label with the Mac host.

## Visual checks

The final suite produced 77 screenshots. Five existing captures were inspected directly: the preset menu, network settings, the 125% long location menu, the report breakdown and the compact Japanese startup-location menu. No additional standalone preview or contrast run was needed for this follow-up. Earlier contrast and preview evidence remains attached to its original candidate in history.

The 100,000-file-pane regression processed 25 progress updates with zero full-list map/filter/sort passes. The final measured browser time was 410.4 ms.

## Run

From `WebSource`, with the pinned dependencies installed:

```sh
npm run typecheck
npm run build
npx playwright test --config tests/playwright.config.ts
```

`RBN_TEST_BROWSER` selects an existing Chromium executable; `RBN_TEST_OUTPUT` selects the results directory. Local CJK fonts were provided through `FONTCONFIG_FILE` for the Linux test browser. The shipped Mac application uses system WebKit and does not need these development dependencies.
