import {expect, test, type Page} from '@playwright/test';
import {fileURLToPath, pathToFileURL} from 'node:url';
import path from 'node:path';
import {installHostFixture} from './native-fixture';
import {translator} from '../renderer/i18n';
import {interfaceScaleZoom} from '../renderer/appearance';
import type {InterfaceScale, Theme} from '../shared/types';

const url = pathToFileURL(path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../Resources/Web/index.html')).href;
const t = translator('zh-TW');
const pane = (page: Page, side: 'left'|'right' = 'left') => page.getByTestId(`${side}-pane`);
const pathInput = (page: Page, side: 'left'|'right' = 'left') => page.getByLabel(`${t(side)} ${t('path')}`, {exact: true});
async function open(page: Page, options: Parameters<typeof installHostFixture>[1] = {}) {
  await installHostFixture(page, {...options, settings: {autoCheckUpdates: false, theme: 'purple-dark', ...options.settings}});
  await page.goto(url);
  for (const side of ['left', 'right'] as const) await expect(pane(page, side).locator('.file-list')).toHaveAttribute('aria-busy', 'false');
}
async function navigate(page: Page, side: 'left'|'right', value: string, wait = true) {
  await pathInput(page, side).fill(value); await pathInput(page, side).press('Enter');
  if (wait) await expect(pane(page, side).locator('.file-list')).toHaveAttribute('aria-busy', 'false');
}
async function historySetup(page: Page) {
  await open(page);
  for (const name of ['A', 'B', 'C', 'D', 'E', 'F']) await navigate(page, 'left', `/Users/test/${name}`);
}

test('folder navigation retains the table until success and cannot operate on its old rows', async ({page}, testInfo) => {
  await open(page);
  const left = pane(page);
  const oldFolder = left.locator('tr').filter({has: page.locator('.file-name', {hasText: /^Documents$/})});
  // aria-busy=false means the data arrived; the virtual table must also have
  // rendered its initial rows before navigation frame sampling starts.
  await expect(oldFolder).toBeVisible();
  const oldTable = await left.locator('.file-table').elementHandle();
  await page.evaluate(() => {
    const w = window as any;
    w.__fixture.listings['/Users/test/Next'] = [{name: 'Next-only.txt', path: 'Next-only.txt', size: 42, modified: '2026-10-20T12:00:00Z', isDir: false}];
    // Hold the native result until every pending-state interaction is checked.
    // A fixed timeout can finish navigation midway through those assertions.
    const send = w.webkit.messageHandlers.rclone.postMessage, reply = w.__rbnReply;
    let listingID = '';
    w.webkit.messageHandlers.rclone.postMessage = (message: any) => {
      if (message.method === 'list' && message.args[0].path === '/Users/test/Next') listingID = message.id;
      send(message);
    };
    w.__rbnReply = (message: any) => {
      if (message.id === listingID) {w.__heldListingReply = message; return;}
      reply(message);
    };
    w.__releaseNextListing = () => {
      w.webkit.messageHandlers.rclone.postMessage = send; w.__rbnReply = reply;
      w.__listingReleaseTime ??= performance.now();
      const held = w.__heldListingReply; w.__heldListingReply = null;
      if (held) reply(held);
    };
    w.__listingFrames = []; w.__sampleListing = true;
    const sample = () => {
      const element = document.querySelector('[data-testid="left-pane"]')!;
      w.__listingFrames.push({at: performance.now(), rows: element.querySelectorAll('.file-name').length, skeleton: Boolean(element.querySelector('.file-loading')),
        busy: element.querySelector('.file-list')?.getAttribute('aria-busy'), path: element.querySelector<HTMLInputElement>('.path-form input')?.value,
        table: Boolean(element.querySelector('.file-table')), bodyRows: element.querySelectorAll('.file-table tbody tr').length,
        replyReleasedAt: w.__listingReleaseTime ?? null});
      if (w.__sampleListing) requestAnimationFrame(sample);
    };
    requestAnimationFrame(sample);
  });
  let frames: {rows: number; skeleton: boolean}[] = [];
  try {
    const countBefore = await page.evaluate(() => (window as any).__fixture.calls.filter((call: any) => call.method === 'list').length);
    await navigate(page, 'left', '/Users/test/Next', false);
    await expect(left.locator('.file-list')).toHaveAttribute('aria-busy', 'true');
    expect(await oldTable!.evaluate(element => element.isConnected)).toBe(true);
    await expect(left.locator('.file-loading')).toHaveCount(0);
    await expect(oldFolder).toBeVisible();
    await expect(left.getByRole('checkbox', {name: `${t('selected')} Documents`, exact: true})).toBeDisabled();
    await oldFolder.dispatchEvent('dblclick');
    await oldFolder.dispatchEvent('keydown', {key: 'Enter', bubbles: true});
    await oldFolder.dispatchEvent('keydown', {key: 'Delete', bubbles: true});
    await left.dispatchEvent('keydown', {key: 'a', ctrlKey: true, bubbles: true});
    expect(await oldFolder.evaluate(row => ['dragstart', 'contextmenu'].map(type => {
      const event = new MouseEvent(type, {bubbles: true, cancelable: true}); row.dispatchEvent(event); return event.defaultPrevented;
    }))).toEqual([true, true]);
    await expect(page.locator('.start-button')).toBeDisabled();
    await expect(pathInput(page)).toHaveValue('/Users/test/Next');
    expect(await page.evaluate(() => (window as any).__fixture.calls.filter((call: any) => call.method === 'list').length)).toBe(countBefore + 1);
    await expect.poll(() => page.evaluate(() => (window as any).__listingFrames.filter((frame: any) => frame.busy === 'true').length)).toBeGreaterThan(3);
    await expect.poll(() => page.evaluate(() => Boolean((window as any).__heldListingReply))).toBe(true);
    await page.evaluate(() => (window as any).__releaseNextListing());
    await expect(left.locator('.file-list')).toHaveAttribute('aria-busy', 'false');
    await expect(left.locator('.file-name')).toHaveText(['Next-only.txt']);
    await expect(left.getByRole('checkbox', {name: `${t('selected')} Next-only.txt`, exact: true})).toBeEnabled();
    await expect(pane(page, 'right').locator('.file-name').first()).toBeVisible();
    expect(await page.evaluate(() => (window as any).__fixture.calls.some((call: any) => ['startTransfer', 'remove', 'rename', 'mkdir', 'startStream'].includes(call.method)))).toBe(false);
  } finally {
    // Restore the native bridge and preserve diagnostics even if an earlier
    // assertion fails. No pending result is left behind when the test exits.
    frames = await page.evaluate(() => {const w = window as any; w.__releaseNextListing(); w.__sampleListing = false; return w.__listingFrames;}).catch(() => []);
    await testInfo.attach('listing-frames', {body: JSON.stringify(frames, null, 2), contentType: 'application/json'});
  }
  expect(frames.length).toBeGreaterThan(3);
  expect(frames.every(frame => frame.rows > 0 && !frame.skeleton), JSON.stringify(frames.filter(frame => frame.rows === 0 || frame.skeleton))).toBe(true);
});

test('latest folder request wins and an empty successful folder does not become a loading skeleton', async ({page}) => {
  await open(page);
  await page.evaluate(() => {
    const f = (window as any).__fixture;
    const file = (name: string) => ({name, path: name, size: 42, modified: '2026-10-20T12:00:00Z', isDir: false});
    f.listings['/Users/test/Slow'] = [file('Stale.txt')];
    f.listings['/Users/test/Fast'] = [file('Latest.txt')];
    f.listings['/Users/test/Empty'] = [];
    f.delays.list = [350, 30];
  });
  await navigate(page, 'left', '/Users/test/Slow', false);
  await navigate(page, 'left', '/Users/test/Fast');
  await expect(pane(page).locator('.file-name')).toHaveText(['Latest.txt']);
  await page.waitForTimeout(380);
  await expect(pane(page).locator('.file-name')).toHaveText(['Latest.txt']);
  await navigate(page, 'left', '/Users/test/Empty');
  await expect(pane(page).getByText(t('emptyFolder'), {exact: true})).toBeVisible();
  await page.evaluate(() => {(window as any).__fixture.delays.list = [220];});
  await navigate(page, 'left', '/Users/test/Fast', false);
  await expect(pane(page).locator('.file-list')).toHaveAttribute('aria-busy', 'true');
  await expect(pane(page).locator('.file-loading')).toHaveCount(0);
  await expect(pane(page).getByText(t('emptyFolder'), {exact: true})).toBeVisible();
  await expect(pane(page).locator('.file-name')).toHaveText(['Latest.txt']);
});

test('down-only and up-only side buttons use the pointed pane and preserve independent forward history', async ({page}) => {
  await open(page);
  for (const side of ['left', 'right'] as const) for (const name of ['A', 'B']) await navigate(page, side, `/Users/test/${side}/${name}`);
  await pane(page).locator('.pane-side').click();
  const sideButton = async (side: 'left'|'right', type: string, button: number) => pane(page, side).evaluate((target, {type, button}) => {
    const r = target.getBoundingClientRect();
    const event = new MouseEvent(type, {button, buttons: type === 'mousedown' ? 1 << button : 0, clientX: r.x + 35, clientY: r.y + 45, bubbles: true, cancelable: true});
    target.dispatchEvent(event); return event.defaultPrevented;
  }, {type, button});
  expect(await sideButton('right', 'mouseup', 3)).toBe(true);
  await expect(pathInput(page, 'right')).toHaveValue('/Users/test/right/A');
  await expect(pathInput(page)).toHaveValue('/Users/test/left/B');
  expect(await sideButton('right', 'mousedown', 4)).toBe(true);
  await expect(pathInput(page, 'right')).toHaveValue('/Users/test/right/B');
  expect(await sideButton('left', 'mousedown', 3)).toBe(true);
  await expect(pathInput(page)).toHaveValue('/Users/test/left/A');
  expect(await sideButton('left', 'mouseup', 4)).toBe(true);
  await expect(pathInput(page)).toHaveValue('/Users/test/left/B');
  await expect(pathInput(page, 'right')).toHaveValue('/Users/test/right/B');
});

for (const order of ['native-up-first', 'dom-up-first', 'long-dom-down-native-up'] as const) test(`${order}: native release and DOM copies navigate once`, async ({page}) => {
  await historySetup(page);
  await page.evaluate(async order => {
    const target = document.querySelector('[data-testid="left-pane"]')!, r = target.getBoundingClientRect();
    const stamp = performance.now(), w = window as any;
    const dom = (type: string, time: number) => {
      const event = new MouseEvent(type, {button: 3, clientX: r.x + 35, clientY: r.y + 45, bubbles: true, cancelable: true});
      Object.defineProperty(event, 'timeStamp', {value: time}); target.dispatchEvent(event);
    };
    const native = (time: number) => w.__rbnEvent({type: 'navigateHistory', data: {direction: 'back', phase: 'up', x: r.x + 35, y: r.y + 45, eventTime: performance.timeOrigin + time}});
    if (order === 'long-dom-down-native-up') {
      dom('mousedown', stamp); await new Promise(resolve => setTimeout(resolve, 110));
      native(stamp + 500); dom('mouseup', stamp + 500); dom('auxclick', stamp + 501);
    } else {
      if (order === 'native-up-first') native(stamp);
      dom('mouseup', stamp); dom('auxclick', stamp + 1);
      if (order === 'dom-up-first') {await new Promise(resolve => setTimeout(resolve, 110)); native(stamp);}
    }
  }, order);
  await expect(pathInput(page)).toHaveValue('/Users/test/E');
  await page.waitForTimeout(130);
  await expect(pathInput(page)).toHaveValue('/Users/test/E');
});

const appearanceCases: {name: string; theme: Theme; native?: string; stored?: string; blocked?: boolean}[] = [
  {name: 'native light overrides cached dark', theme: 'blue-light', native: 'blue-light', stored: 'purple-dark'},
  {name: 'native dark overrides cached light', theme: 'green-dark', native: 'green-dark', stored: 'purple-light'},
  {name: 'cached theme is available before bootstrap', theme: 'purple-light', stored: 'purple-light'},
  {name: 'invalid host theme uses the valid cache', theme: 'blue-dark', native: 'invalid-theme', stored: 'blue-dark'},
  {name: 'unavailable storage uses the dark default', theme: 'purple-dark', blocked: true},
];
for (const scenario of appearanceCases) test(`first paint: ${scenario.name}`, async ({page}) => {
  await installHostFixture(page, {initialAppearance: false, delays: {bootstrap: [600]}, settings: {theme: scenario.theme, autoCheckUpdates: false}});
  await page.addInitScript(scenario => {
    const w = window as any;
    if (scenario.native) w.__rbnInitialAppearance = {theme: scenario.native};
    if (scenario.blocked) Object.defineProperty(window, 'localStorage', {get() {throw new DOMException('Storage unavailable', 'SecurityError');}});
    else if (scenario.stored) localStorage.setItem('rbn:theme', scenario.stored);
    Object.defineProperty(window, '__rbnReply', {configurable: true, set(value) {
      w.__appearanceBeforeBridge = {theme: document.documentElement.dataset.theme, background: getComputedStyle(document.documentElement).backgroundColor};
      Object.defineProperty(window, '__rbnReply', {value, configurable: true, writable: true});
    }});
    w.__appearanceFrames = [];
    const frame = () => {
      if (document.documentElement) w.__appearanceFrames.push({theme: document.documentElement.dataset.theme, background: getComputedStyle(document.documentElement).backgroundColor});
      if (w.__appearanceFrames.length < 8) requestAnimationFrame(frame);
    };
    requestAnimationFrame(frame);
  }, scenario);
  await page.goto(url);
  await page.waitForFunction(() => (window as any).__appearanceFrames.length >= 8);
  const expected = {theme: scenario.theme, background: scenario.theme.endsWith('-light') ? 'rgb(241, 241, 241)' : 'rgb(28, 28, 28)'};
  expect(await page.evaluate(() => (window as any).__appearanceBeforeBridge)).toEqual(expected);
  for (const frame of await page.evaluate(() => (window as any).__appearanceFrames)) expect(frame).toEqual(expected);
  await expect(pane(page).locator('.file-list')).toHaveAttribute('aria-busy', 'false');
  await expect(page.locator('html')).toHaveAttribute('data-theme', scenario.theme);
});

for (const legacy of [120, 135] as const) test(`migrated ${legacy} percent stays selected and disappears from choices after choosing the new default`, async ({page}, info) => {
  const resize = async (scale: InterfaceScale) => page.setViewportSize({width: Math.floor(1060 / interfaceScaleZoom(scale)), height: Math.floor(680 / interfaceScaleZoom(scale))});
  await page.exposeFunction('__testNativeScale', resize); await resize(legacy);
  await open(page, {settings: {interfaceScale: legacy}});
  await page.locator('.workspace-title > .icon-button').click();
  const dialog = page.locator('.settings-dialog');
  await dialog.getByRole('button', {name: t('appearance'), exact: true}).click();
  const group = dialog.getByRole('radiogroup', {name: t('interfaceScale')}), radios = group.getByRole('radio');
  await expect(radios).toHaveCount(6);
  expect(await radios.evaluateAll(items => items.map(item => Number((item as HTMLInputElement).value)))).toEqual([80, 90, 100, 110, 125, legacy].sort((a, b) => a - b));
  await expect(group.locator(`input[value="${legacy}"]`)).toBeChecked();
  await expect(group.getByText(t('defaultScale'), {exact: true})).toHaveCount(1);
  await page.screenshot({path: info.outputPath(`scale-legacy-${legacy}.png`), animations: 'disabled'});
  await group.locator('input[value="100"]').locator('..').click();
  await expect(radios).toHaveCount(5); await expect(group.locator('input[value="100"]')).toBeChecked();
  await expect.poll(() => page.viewportSize()).toEqual({width: 1177, height: 755});
  expect(await page.evaluate(() => (window as any).__fixture.bootstrap.settings.interfaceScale)).toBe(100);
  await group.locator('input[value="110"]').locator('..').click();
  await expect.poll(() => page.viewportSize()).toEqual({width: 1060, height: 680});
});
