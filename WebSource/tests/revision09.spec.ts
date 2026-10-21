import {expect, test, type Locator, type Page} from '@playwright/test';
import {fileURLToPath, pathToFileURL} from 'node:url';
import path from 'node:path';
import {installHostFixture} from './native-fixture';
import {translator} from '../renderer/i18n';
import {interfaceScaleZoom} from '../renderer/appearance';
import {DEFAULT_OPTIONS, type Settings, type TransferMode, type TransferRequest} from '../shared/types';

const url = pathToFileURL(path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../Resources/Web/index.html')).href;
const t = translator('zh-TW');

async function open(page: Page, settings: Partial<Settings> = {}) {
  await installHostFixture(page, {settings: {autoCheckUpdates: false, theme: 'purple-dark', ...settings}});
  await page.goto(url);
  for (const side of ['left', 'right']) {
    await expect(page.getByTestId(`${side}-pane`).locator('.file-list')).toHaveAttribute('aria-busy', 'false');
  }
}

async function bounds(locator: Locator) {
  await expect(locator).toBeVisible();
  const box = await locator.boundingBox();
  expect(box).not.toBeNull();
  return box!;
}

async function reachable(locator: Locator) {
  await expect(locator).toBeVisible();
  expect(await locator.evaluate(element => {
    const r = element.getBoundingClientRect();
    const hit = document.elementFromPoint(r.x + r.width / 2, r.y + r.height / 2);
    return {
      inside: r.left >= 0 && r.top >= 0 && r.right <= innerWidth + 1 && r.bottom <= innerHeight + 1,
      hit: hit === element || element.contains(hit),
    };
  })).toEqual({inside: true, hit: true});
}

async function calls(page: Page, method: string): Promise<{args: any[]}[]> {
  return page.evaluate(method => (window as any).__fixture.calls.filter((item: any) => item.method === method), method);
}

async function saved(page: Page): Promise<Settings> {
  return page.evaluate(() => (window as any).__fixture.bootstrap.settings);
}

async function chooseMode(page: Page, mode: TransferMode, language: 'zh-TW'|'en'|'ja' = 'zh-TW') {
  await page.getByTestId('operation-picker').click();
  await page.getByRole('menuitemradio', {name: translator(language)(mode), exact: true}).click();
}

for (const language of ['zh-TW', 'en', 'ja'] as const) {
  test(`${language}: compact toolbar keeps settings and account together; theme columns pair light above dark`, async ({page}, info) => {
    // Match the CSS viewport of the minimum 1060 × 680 native window at the
    // largest standard pageZoom. Native startup geometry is tested in AppKit.
    const zoom = interfaceScaleZoom(125), tx = translator(language);
    await page.setViewportSize({width: Math.floor(1060 / zoom), height: Math.floor(680 / zoom)});
    await open(page, {language, interfaceScale: 125});
    const heading = page.locator('.workspace-heading');
    const preferences = heading.getByRole('button', {name: tx('settings'), exact: true});
    const account = heading.getByRole('button', {name: tx('configLabel'), exact: true});
    const workspace = heading.getByRole('button', {name: tx('rememberWorkspace'), exact: true});
    const task = heading.getByRole('button', {name: tx('saveTask'), exact: true});
    const hint = heading.getByRole('button', {name: new RegExp(`^${tx('workspaceTaskDifference')} — `)});
    await expect(heading.getByRole('heading', {name: tx('files'), exact: true})).toHaveCount(0);
    for (const button of [preferences, account, workspace, task, hint]) await reachable(button);
    const [settingsBox, accountBox, workspaceBox, taskBox, hintBox, divider] = await Promise.all([
      bounds(preferences), bounds(account), bounds(workspace), bounds(task), bounds(hint), bounds(heading.locator('.workspace-save-divider')),
    ]);
    expect(settingsBox.x + settingsBox.width).toBeLessThanOrEqual(accountBox.x + 1);
    expect(Math.abs(settingsBox.y + settingsBox.height / 2 - accountBox.y - accountBox.height / 2)).toBeLessThanOrEqual(1);
    expect(workspaceBox.x + workspaceBox.width).toBeLessThanOrEqual(divider.x + 1);
    expect(divider.x + divider.width).toBeLessThanOrEqual(taskBox.x + 1);
    expect(taskBox.x + taskBox.width).toBeLessThanOrEqual(hintBox.x + 1);
    expect(Math.abs(workspaceBox.y + workspaceBox.height / 2 - taskBox.y - taskBox.height / 2)).toBeLessThanOrEqual(1);
    expect(divider.width).toBeLessThanOrEqual(1.5);
    expect(divider.height).toBeGreaterThan(8);
    await hint.hover();
    const tooltip = page.getByRole('tooltip');
    await expect(tooltip).toHaveText(tx('workspaceTaskDifferenceHint'));
    const tooltipBox = await bounds(tooltip), viewport = page.viewportSize()!;
    expect(tooltipBox.x).toBeGreaterThanOrEqual(0);
    expect(tooltipBox.x + tooltipBox.width).toBeLessThanOrEqual(viewport.width + 1);
    expect(tooltipBox.y + tooltipBox.height).toBeLessThanOrEqual(viewport.height + 1);
    await page.mouse.move(0, 0);
    await page.keyboard.press('Escape');
    await expect(tooltip).toHaveCount(0);

    await preferences.click();
    const dialog = page.locator('.settings-dialog');
    await dialog.getByRole('button', {name: tx('appearance'), exact: true}).click();
    await expect(dialog.locator('.theme-option')).toHaveCount(6);
    const light = [], dark = [];
    for (const family of ['purple', 'green', 'blue']) {
      light.push(await bounds(dialog.locator(`.swatch-${family}-light`)));
      dark.push(await bounds(dialog.locator(`.swatch-${family}-dark`)));
    }
    for (let index = 0; index < 3; index++) {
      expect(Math.abs(light[index].y - light[0].y)).toBeLessThanOrEqual(1);
      expect(Math.abs(dark[index].y - dark[0].y)).toBeLessThanOrEqual(1);
      expect(Math.abs(light[index].x - dark[index].x)).toBeLessThanOrEqual(1);
      expect(light[index].y + light[index].height).toBeLessThan(dark[index].y);
      if (index > 0) expect(light[index - 1].x + light[index - 1].width).toBeLessThan(light[index].x);
    }
    await dialog.locator('.swatch-green-light').click();
    await expect(dialog.locator('.swatch-green-light')).toHaveAttribute('aria-pressed', 'true');
    await expect(page.locator('html')).toHaveAttribute('data-theme', 'green-light');
    await expect.poll(async () => (await saved(page)).theme).toBe('green-light');
    await page.screenshot({path: info.outputPath(`appearance-${language}-125.png`), animations: 'disabled'});
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1)).toBe(true);
    expect(await calls(page, 'startTransfer')).toHaveLength(0);
  });
}

test('adjacent save actions preserve distinct workspace and named-task snapshots without starting a transfer', async ({page, browser}) => {
  const options = {...DEFAULT_OPTIONS, transfers: 7, checkers: 10, bandwidth: '7M', exclude: ['*.tmp', '.DS_Store']};
  const locations = {left: {remote: null, path: '/Users/test/Archive'}, right: {remote: 'lab-nas', path: 'Source'}};
  await open(page, {initialLocations: locations, defaultTransferOptions: options});
  await page.getByRole('button', {name: t('rightToLeft'), exact: true}).click();
  await chooseMode(page, 'sync');
  await page.getByTestId('right-pane').getByRole('checkbox', {name: `${t('selected')} Documents`, exact: true}).check();
  const heading = page.locator('.workspace-heading');
  await heading.getByRole('button', {name: t('rememberWorkspace'), exact: true}).click();
  await expect.poll(async () => (await saved(page)).savedWorkspace).not.toBeNull();
  const workspaceSettings = await saved(page), workspace = workspaceSettings.savedWorkspace!;
  expect(workspace).toMatchObject({...locations, direction: 'rl', mode: 'sync', options});
  expect(workspace).not.toHaveProperty('selection');
  expect(await calls(page, 'saveTask')).toHaveLength(0);
  expect(await calls(page, 'startTransfer')).toHaveLength(0);

  await heading.getByRole('button', {name: t('saveTask'), exact: true}).click();
  const editor = page.locator('.task-editor-dialog');
  await editor.getByLabel(t('taskName'), {exact: true}).fill('Selected NAS folders');
  await editor.getByRole('button', {name: t('save'), exact: true}).click();
  await expect(editor).toHaveCount(0);
  const taskCalls = await calls(page, 'saveTask');
  expect(taskCalls).toHaveLength(1);
  const taskRequest = taskCalls[0].args[1] as TransferRequest;
  expect(taskCalls[0].args[0]).toBe('Selected NAS folders');
  expect(taskRequest).toMatchObject({
    source: locations.right, destination: locations.left, direction: 'rl', mode: 'sync',
    selection: [{name: 'Documents', isDir: true}], options, dryRun: false,
  });
  expect((await saved(page)).savedWorkspace).toEqual(workspace);
  expect(await calls(page, 'startTransfer')).toHaveLength(0);

  const restarted = await browser.newPage();
  try {
    await open(restarted, workspaceSettings);
    await expect(restarted.getByRole('button', {name: t('rightToLeft'), exact: true})).toHaveAttribute('aria-pressed', 'true');
    await expect(restarted.getByTestId('right-pane').locator('tr[data-selected]')).toHaveCount(0);
    await restarted.locator('.command-button').click();
    await expect(restarted.locator('.command-output')).toBeVisible();
    const request = (await calls(restarted, 'previewTransfer')).at(-1)!.args[0] as TransferRequest;
    expect(request).toMatchObject({source: locations.right, destination: locations.left, direction: 'rl', mode: 'sync', options, selection: []});
    expect(await calls(restarted, 'startTransfer')).toHaveLength(0);
  } finally { await restarted.close(); }
});

for (const language of ['zh-TW', 'en', 'ja'] as const) {
  test(`${language}: copy, sync and move explanations use the full column and a neutral text color`, async ({page}) => {
    const tx = translator(language);
    await open(page, {language});
    for (const theme of ['purple-light', 'purple-dark']) {
      await page.evaluate(theme => { document.documentElement.dataset.theme = theme; }, theme);
      for (const mode of ['copy', 'sync', 'move'] as const) {
        await chooseMode(page, mode, language);
        const hint = page.locator('.operation-hint');
        await expect(hint).toHaveText(tx(mode === 'copy' ? 'copyHint' : mode === 'sync' ? 'syncHint' : 'moveHint'));
        const [hintBox, pickerBox] = await Promise.all([bounds(hint), bounds(page.getByTestId('operation-picker'))]);
        expect(Math.abs(hintBox.x - pickerBox.x)).toBeLessThanOrEqual(1);
        expect(Math.abs(hintBox.width - pickerBox.width)).toBeLessThanOrEqual(1);
        const style = await hint.evaluate(element => {
          const computed = getComputedStyle(element), reference = document.createElement('span');
          reference.style.color = 'var(--muted)'; element.append(reference);
          const neutralColor = getComputedStyle(reference).color; reference.remove();
          return {color: computed.color, neutralColor, align: computed.textAlign, wrap: computed.getPropertyValue('text-wrap'), overflowing: element.scrollWidth > element.clientWidth + 1};
        });
        expect(style.color).toBe(style.neutralColor);
        expect(['start', 'left']).toContain(style.align);
        expect(style.wrap).not.toContain('balance');
        expect(style.overflowing).toBe(false);
        await expect(hint).not.toHaveClass(/\bcaution\b/);
      }
    }
    await page.locator('.options-button').click();
    await expect(page.locator('.options-mode-hint')).not.toHaveClass(/\bcaution\b/);
    expect(await calls(page, 'startTransfer')).toHaveLength(0);
  });
}

test('a configured speed limit remains visible in a compact window; unlimited removes the summary without infinity shorthand', async ({page}) => {
  const zoom = interfaceScaleZoom(125);
  await page.setViewportSize({width: Math.floor(1060 / zoom), height: Math.floor(680 / zoom)});
  await open(page, {interfaceScale: 125, defaultTransferOptions: {...DEFAULT_OPTIONS, transfers: 7, checkers: 10, bandwidth: '7M'}});
  const controls = page.locator('.transfer-controls'), summary = controls.locator('.bandwidth-summary');
  await expect(controls.locator('.options-mini')).toHaveCount(0);
  await expect(controls).not.toContainText('∞');
  await expect(summary).toContainText(t('bandwidth'));
  await expect(summary).toContainText('7 MiB/s');
  await reachable(summary);

  for (const bandwidth of ['off', '0', '', '12M']) {
    await page.locator('.options-button').click();
    const dialog = page.locator('.options-dialog');
    await dialog.getByRole('button', {name: t('transferPerformance'), exact: true}).click();
    await expect(dialog.getByLabel(t('transfers'), {exact: true})).toHaveValue('7');
    await expect(dialog.getByLabel(t('checkers'), {exact: true})).toHaveValue('10');
    await dialog.getByLabel(t('bandwidth'), {exact: true}).fill(bandwidth);
    await dialog.getByRole('button', {name: t('apply'), exact: true}).click();
    await expect(dialog).toHaveCount(0);
    if (bandwidth === '12M') {
      await expect(summary).toContainText('12 MiB/s');
      await reachable(summary);
    } else await expect(summary).toHaveCount(0);
    await expect(controls).not.toContainText('∞');
  }
  // The compact layout deliberately hides the secondary command-preview action.
  // Expand only after verifying every limit change in the compact layout, then
  // inspect the actual request to ensure the display did not alter its options.
  await page.setViewportSize({width: 1440, height: 900});
  await page.locator('.command-button').click();
  await expect(page.locator('.command-output')).toBeVisible();
  expect((await calls(page, 'previewTransfer')).at(-1)!.args[0].options).toMatchObject({transfers: 7, checkers: 10, bandwidth: '12M'});
  expect(await calls(page, 'startTransfer')).toHaveLength(0);
});
