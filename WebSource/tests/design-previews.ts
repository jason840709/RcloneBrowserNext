// Design review screenshots from the production bundle with the synthetic host.
// Usage: node tests/design-previews.ts [outputDir] [sceneFilter]
import {chromium, type Page} from '@playwright/test';
import {installHostFixture} from './native-fixture.ts';
import {pathToFileURL} from 'node:url';
import path from 'node:path';
import {mkdir} from 'node:fs/promises';
import type {Theme} from '../shared/types.ts';

const out = path.resolve(process.argv[2] || '.build-cache/design');
const only = process.argv[3] || '';
const appURL = pathToFileURL(path.resolve('../Resources/Web/index.html')).href;
await mkdir(out, {recursive: true});
const browser = await chromium.launch({executablePath: process.env.RBN_TEST_BROWSER, headless: true});
const errors: string[] = [];

async function open(theme: Theme, scheme: 'light'|'dark' = 'light', viewport = {width: 1422, height: 889}, extra: Record<string, unknown> = {}) {
  const page = await browser.newPage({viewport, colorScheme: scheme, reducedMotion: 'reduce', deviceScaleFactor: 2});
  page.on('pageerror', error => errors.push(error.message));
  await installHostFixture(page, {cleanPreview: true, job: true, fileCount: 18, settings: {language: 'zh-TW', theme, autoCheckUpdates: false,
    initialLocations: {left: {remote: null, path: '/Users/test/Documents'}, right: {remote: 'research-drive', path: 'Archive'}}}, ...extra});
  await page.goto(appURL);
  await page.getByTestId('left-pane').locator('.file-name').first().waitFor();
  await page.getByTestId('right-pane').locator('.file-name').first().waitFor();
  return page;
}
async function shot(page: Page, name: string) { await page.mouse.move(2, 2); await page.waitForTimeout(250); await page.screenshot({path: path.join(out, `${name}.png`)}); }
const want = (name: string) => !only || name.includes(only);

if (want('main')) for (const [theme, scheme] of [['purple-auto', 'light'], ['purple-auto', 'dark'], ['green-dark', 'dark'], ['blue-light', 'light']] as const) {
  const page = await open(theme, scheme);
  await page.getByTestId('left-pane').getByRole('checkbox').nth(2).check();
  await page.getByTestId('left-pane').getByRole('checkbox').nth(4).check();
  await shot(page, `main-${theme}-${scheme}`);
  await page.close();
}
if (want('menus')) {
  const page = await open('purple-auto', 'light');
  await page.getByTestId('operation-picker').click(); await shot(page, 'menu-operation');
  await page.keyboard.press('Escape');
  await page.getByTestId('right-pane').locator('.location-trigger').click(); await shot(page, 'menu-location');
  await page.keyboard.press('Escape');
  await page.getByTestId('left-pane').locator('.pane-more-menu summary').click(); await shot(page, 'menu-pane');
  await page.close();
}
if (want('dialogs')) for (const scheme of ['light', 'dark'] as const) {
  const page = await open('purple-auto', scheme);
  await page.locator('.settings-button').click(); await shot(page, `settings-general-${scheme}`);
  await page.locator('.preferences-tabs button').nth(1).click(); await shot(page, `settings-appearance-${scheme}`);
  await page.locator('.preferences-tabs button').nth(2).click(); await shot(page, `settings-network-${scheme}`);
  await page.keyboard.press('Escape'); await page.waitForTimeout(300);
  await page.locator('.options-button').click(); await shot(page, `options-${scheme}`);
  await page.locator('.options-tabs button').nth(1).click(); await shot(page, `options-filters-${scheme}`);
  await page.locator('.options-tabs button').nth(2).click(); await shot(page, `options-advanced-${scheme}`);
  await page.close();
}
if (want('pages')) for (const scheme of ['light', 'dark'] as const) {
  const page = await open('purple-auto', scheme);
  await page.locator('.main-nav button').nth(1).click(); await page.locator('.job-row').first().waitFor();
  await shot(page, `jobs-${scheme}`);
  await page.locator('.job-details summary').first().click(); await page.waitForTimeout(300); await shot(page, `jobs-details-${scheme}`);
  await page.locator('.main-nav button').nth(2).click(); await shot(page, `tasks-${scheme}`);
  await page.close();
}
if (want('hidden')) for (const scheme of ['light', 'dark'] as const) {
  // A server-side copy that has not reported bytes yet (speedState "hidden").
  const page = await open('purple-auto', scheme);
  await page.evaluate(() => { const w = window as any, job = structuredClone(w.__fixture.job);
    job.stats = {...job.stats, speed: 0, eta: null, speedState: 'hidden', transferring: [{name: '訪談錄影.mov', size: 5031000000, bytes: 0, percentage: 0, speed: 0, speedAvg: 0, eta: null}]};
    w.__rbnEvent({type: 'jobUpdate', data: job}); });
  await page.waitForTimeout(300); await shot(page, `hidden-speed-${scheme}`);
  await page.close();
}
await browser.close();
if (errors.length) { console.error(errors.join('\n')); process.exit(1); }
console.log('previews in', out);
