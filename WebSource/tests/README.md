# Production Web verification — 0.9.0

The final production run passed **189 / 189 cases**, with no failures, skips, retries or flaky outcomes. It began at **2026-10-21T01:56:29.695Z** and took **173.3 seconds**. TypeScript and Vite production build checks passed. Production resources and recorded source hashes match before and after the run.

The [JSON receipt](verification.json) contains all results, production/source hashes, inspected screenshots and a large-list update audit. The [Traditional Chinese report](VERIFICATION.zh-TW.md) describes the changes and scope.

## New coverage

Eight cases cover the compact three-language toolbar, paired theme ordering, keyboard/hover information, separate workspace/task persistence semantics, neutral naturally wrapping descriptions, and explicit bandwidth caps without the infinity shorthand. A separate focused run passed all eight. Existing minimum-window hit tests also found and verified a fix for English transfer buttons being clipped when an active job shortened the workspace.

The full suite retains navigation, loading continuity, stale-response handling, scale choices, six themes, three languages, task editing, reports, queue actions, platform controls and large-list virtualization. Native AppKit/WKWebView startup geometry and bundle signatures are validated separately; see the [release validation](../../docs/VALIDATION.zh-TW.md) for completed CI results. This browser run does not exercise a physical mouse or the user's Dock.

## Reproduce

From `WebSource`, install the pinned dependencies and run:

```sh
npm run typecheck
npm run build
npx playwright test --config tests/playwright.config.ts --reporter=json
```

`RBN_TEST_BROWSER` selects an existing Chromium executable and `RBN_TEST_OUTPUT` selects the result directory. This run used Chrome Headless Shell 156.0.8078.4, Playwright 1.64.1 and local Noto CJK TC/JP fonts through `FONTCONFIG_FILE`. Browser archive and font hashes are recorded in the receipt. These development dependencies are not shipped in the app.

The unchanged [0.8.1 receipt](history/0.8.1/verification.json) and earlier historical receipts remain available.
