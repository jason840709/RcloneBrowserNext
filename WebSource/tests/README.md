# Web UI contract tests — 0.4.0

The suite opens the actual, prebuilt `Resources/Web/index.html` through `file://`. It exercises the production IIFE, React views and `renderer/bridge.ts`. The fixture exists only in `tests/native-fixture.ts`: it implements `window.webkit.messageHandlers.rclone`, records the real `{id, method, args}` messages, and replies through `__rbnReply` / `__rbnEvent`. The shipped app has no fixture, simulated filesystem, Electron runtime or remote web dependency.

## Result and coverage

The full suite passed **62 / 62 tests** on 2026-10-20, with no skipped, failed or flaky cases. After the final comparison-help and unpublished-release changes, **3 / 3 targeted tests** passed again against the rebuilt production resources. Those checks cover all seven comparison explanations in all three languages, tooltip interaction and compact-window bounds, app release states, and the production file/IPC contract. Exact final-run statistics and resource hashes are in `verification.json`.

The 62-test suite consists of:

- **18 retained behavior tests:** native IPC and escaped filenames; missing host; local browsing without rclone; immediate rclone-location saves and reprobes; update retry and skipped-version checks; serialized settings patches, stale-reply rejection and rollback; proxies, player, extra arguments and startup locations; native menu / Config refresh; column resizing and native persistence; appearance toggles; independent location tabs; comparison modes, synchronization controls, filters and retries; Move + skip-newer recovery; Finder-drop preparation without automatic transfer; tree, export, public link, mount, streaming and clipboard entrances; invalid startup-location recovery; keyboard and reduced-motion behavior. Related assertions are grouped within tests.
- **20 new 0.4 tests:** system language resolution and retained manual overrides; Remember and complete workspace restoration without selection or automatic execution; startup-folder edits overriding remembered positions; complete task save/edit round trips and distinct Dry Run / Run requests; selection preservation or explicit reset when the source changes; partial network patches, atomic custom-IP edits and inherited task timeouts; contextual help; categorized native locations; separate About, engine and app update entrances; four-theme pixel checks for narrow columns, full-width zebra rows and blank space; sync deletion limits; and compact task-editor/network layouts in all three languages.
- **24 main-window layout cases:** 繁體中文, English and 日本語 × purple-light, purple-dark, blue-light and blue-dark × 1060 × 680 / 1440 × 900. They check reachable primary controls, no page overflow and live transfer counters/progress.

The minimum content size matches the native window's `contentMinSize`. Screenshots use Linux Chrome and a locally provided CJK font. Mac builds use macOS system fonts; these are not native macOS screenshots. The test launcher removes Playwright's `--hide-scrollbars` default, so scrollbar width, gutter space and column overflow are exercised with visible scrollbars.

## Run

From `WebSource`, with the pinned development dependencies installed:

```sh
npm run typecheck
npm run build
npx playwright test --config tests/playwright.config.ts
```

Use an existing compatible Chrome/Chromium by setting `RBN_TEST_BROWSER` to its executable path. Alternatively, keep Playwright's optional browser download in the project:

```sh
PLAYWRIGHT_BROWSERS_PATH="$PWD/.build-cache/playwright" npx playwright install chromium --only-shell
PLAYWRIGHT_BROWSERS_PATH="$PWD/.build-cache/playwright" npx playwright test --config tests/playwright.config.ts
```

`RBN_TEST_OUTPUT` redirects temporary test output to another project-local folder. For Linux screenshots, set `FONTCONFIG_FILE` to a project-local fontconfig file with CJK font and cache directories. Development browser, fonts, caches and `node_modules` are excluded from app/release packaging. The normal Mac build uses the prebuilt web resources and does **not** install Node, npm, Playwright, a browser or fonts.

The final targeted run is reproducible with:

```sh
npx playwright test --config tests/playwright.config.ts -g 'production file bundle|comparison tips|distinct app release checks'
```

## Reproduce visual previews and palette checks

With Node 24 or another Node version that supports TypeScript stripping:

```sh
node --experimental-strip-types tests/render-previews.ts
python tests/check-contrast.py .build-cache/qa04/palette-tokens.json
```

`render-previews.ts` writes all four themes at both viewport sizes, settings and transfer screens, the task list/editor and the comparison tooltip under `.build-cache/qa04` (or `RBN_PREVIEW_OUTPUT`). Its `cleanPreview` option removes adversarial fixture filenames solely for presentation; ordinary tests retain them. Every example location, account and task is fictional. User-provided Mac screenshots, account names and paths are not copied into fixtures or public resources.

`check-contrast.py` verifies 80 foreground/background pairs extracted from the computed production CSS: body and secondary text, placeholders, primary-button states, selected text, notices and control borders. The 0.4 palettes use neutral gray/white surfaces with purple or blue accents; the new-install default is purple-dark. This scoped palette check is not a complete WCAG audit.

## Limits

These checks validate frontend behavior and the native wire contract with deterministic responses. They do **not** run AppKit or WKWebView on macOS, exercise Gatekeeper/signing, access cloud accounts, transfer actual files, mount a FUSE filesystem, play media, or download/update the real rclone engine. Core, updater and native acceptance checks are documented separately in the project verification notes.
