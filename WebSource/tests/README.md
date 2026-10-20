# Web UI contract tests — 0.5.0

The suite opens the actual, prebuilt `Resources/Web/index.html` through `file://`. It exercises the production IIFE, React views and `renderer/bridge.ts`. The fixture exists only in `tests/native-fixture.ts`: it implements `window.webkit.messageHandlers.rclone`, records the real `{id, method, args}` messages, and replies through `__rbnReply` / `__rbnEvent`. The shipped app has no fixture, simulated filesystem, Electron runtime or remote web dependency.

## Result and coverage

**86 unique cases were verified on 2026-10-20**, composed of two executions against the same unchanged production bundle:

| Execution | Cases | Passed | Failed | Duration |
| --- | ---: | ---: | ---: | ---: |
| First complete run | 81 | 78 | 3 stale expectations | 99.2 s |
| Targeted follow-up | 8 | 8 | 0 | 16.6 s |

The three initially failing expectations were corrected: the new default comparison tooltip, the intentionally fictional app release transition `0.5.0 → 0.6.0`, and the correct `19.1 MiB/s` formatting for 20,000,000 bytes/s. No production code was changed or rebuilt between these executions. The follow-up contains those three corrected cases plus five new regressions. The union is **78 + 3 + 5 = 86**, not 89 independent cases. Neither run had skipped or flaky cases; the first run is deliberately recorded as 78/81, rather than rewritten as fully passing.

`verification.json` records exact execution statistics, the correction list, aggregate composition, raw result hashes, and the production resource hashes. `VERIFICATION.zh-TW.md` explains the findings and limitations in Traditional Chinese.

The current source suite contains the 62 retained cases and 24 revision 0.5 cases:

- **18 retained behavior cases:** native IPC and escaped filenames; missing host; local browsing without rclone; immediate rclone-location saves and reprobes; update retry and skipped-version checks; serialized settings patches, stale-reply rejection and rollback; proxies, player, extra arguments and startup locations; native menu / Config refresh; column resizing and native persistence; appearance toggles; independent location tabs; comparison modes, synchronization controls, filters and retries; Move + skip-newer recovery; Finder-drop preparation without automatic transfer; tree, export, public link, mount, streaming and clipboard entrances; invalid startup-location recovery; keyboard and reduced-motion behavior. Related assertions are grouped within tests.
- **20 retained revision 0.4 cases:** system language resolution and retained manual overrides; Remember and complete workspace restoration without automatic execution; startup-folder edits overriding remembered positions; complete task save/edit round trips and distinct Dry Run / Run requests; selection preservation or explicit reset when the source changes; partial network patches, atomic custom-IP edits and inherited task timeouts; contextual help; categorized native locations; separate About, engine and app update entrances; four-theme pixel checks for narrow columns and full-width zebra rows; sync deletion limits; compact task-editor/network layouts in all three languages.
- **24 main-window layout cases:** 繁體中文, English and 日本語 × purple-light, purple-dark, blue-light and blue-dark × 1060 × 680 / 1440 × 900. They check reachable primary controls, no page overflow and live transfer counters/progress.
- **24 revision 0.5 cases:** contained empty/error states and recovery; no phantom task controls; fixed-overlay notification geometry, lifetime, dismissal animation, reduced motion and portal races; new unlimited/during/no-local-hash defaults; all three preset requests with full resets and no automatic start; hide/restore persistence; native and DOM side-button routing without duplicates; independent per-tab back/forward history and keyboard behavior; connected tabs and role/path geometry in compact and wide dark/light layouts; one-decimal progress, rolling and completed averages, zero-byte file fallback; a 100,000-file-per-pane progress-update guard; safe initial operation-menu keyboard focus; and the NAS-to-cloud explanation in all three languages.

The large-list guard rendered fewer than 100 file rows across two 100,000-file panes. Its 25 progress updates caused **zero repeated full-size array map/filter/sort passes and zero extra directory-list calls**. The measured 679.1 ms is a synthetic Linux browser observation, not a macOS CPU or actual NAS throughput benchmark.

The minimum content size matches the native window's `contentMinSize`. Screenshots use Linux Chrome and a locally provided CJK font. Mac builds use macOS system fonts; these are not native macOS screenshots. The launcher removes Playwright's `--hide-scrollbars` default, so scrollbar width, gutter space and column overflow are exercised with visible scrollbars.

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

The eight-case follow-up is reproducible with:

```sh
npx playwright test --config tests/playwright.config.ts -g 'comparison tips work|application menu exposes|job progress shows|fresh task-saved|opening the operation menu|NAS-to-cloud advice'
```

## Reproduce visual previews and palette checks

With Node 24 or another Node version that supports TypeScript stripping:

```sh
node --experimental-strip-types tests/render-previews.ts
python tests/check-contrast.py .build-cache/qa05/palette-tokens.json
```

`render-previews.ts` writes 33 PNGs under `.build-cache/qa05` (or `RBN_PREVIEW_OUTPUT`): all four themes at both viewport sizes, settings and transfer screens, the task list/editor, a comparison tooltip, and dark/light critical states for errors, empty Tasks, floating notices, operation presets, connected tabs and NAS advice. Notification stills wait for completed opacity transitions.

Its `cleanPreview` option removes adversarial fixture filenames solely for presentation; ordinary tests retain them. Every example location, account, task and available app version is fictional. User-provided Mac screenshots, account names and paths are not copied into fixtures or public resources.

`check-contrast.py` verifies 80 foreground/background pairs extracted from the computed production CSS: body and secondary text, placeholders, primary-button states, selected text, notices and control borders. All 80 pass, with a minimum text ratio of 4.90:1 and minimum control-border ratio of 3.50:1. Palettes use neutral gray/white surfaces with purple or blue accents; the new-install default is purple-dark. This scoped palette check is not a complete WCAG audit.

## Limits

These checks validate frontend behavior and the native wire contract with deterministic responses. They do **not** run AppKit or WKWebView on macOS, exercise a physical side-button mouse or Gatekeeper/signing, access cloud accounts, transfer actual files, mount a FUSE filesystem, play media, or download/update the real rclone engine. Core, updater and native acceptance checks are documented separately in the project verification notes.
