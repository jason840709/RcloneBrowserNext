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
  test(`${language}: compact toolbar centres navigation and keeps account, save actions and settings on one row; appearance choices form single rows`, async ({page}, info) => {
    // Match the CSS viewport of the minimum 1060 × 680 native window at the
    // largest standard pageZoom. Native startup geometry is tested in AppKit.
    const zoom = interfaceScaleZoom(125), tx = translator(language);
    await page.setViewportSize({width: Math.floor(1060 / zoom), height: Math.floor(680 / zoom)});
    await open(page, {language, interfaceScale: 125});
    const toolbar = page.locator('.app-toolbar');
    const brand = toolbar.locator('.application-menu summary');
    const nav = toolbar.getByRole('navigation', {name: tx('mainNavigation'), exact: true});
    const tabs = nav.getByRole('button');
    const account = toolbar.getByRole('button', {name: tx('configLabel'), exact: true});
    const group = toolbar.getByRole('group', {name: tx('workspaceTaskDifference'), exact: true});
    const workspace = group.getByRole('button', {name: tx('rememberWorkspace'), exact: true});
    const task = group.getByRole('button', {name: tx('saveTask'), exact: true});
    const preferences = toolbar.getByRole('button', {name: tx('settings'), exact: true});
    await expect(toolbar.getByRole('heading')).toHaveCount(0);
    await expect(tabs).toHaveText([tx('files'), tx('jobs'), tx('tasks')]);
    await expect(tabs.first()).toHaveAttribute('aria-current', 'page');
    for (const control of [brand, ...await tabs.all(), account, workspace, task, preferences]) {
      await expect(control).toBeVisible();
      expect(await control.evaluate(element => {
        const r = element.getBoundingClientRect(), hit = document.elementFromPoint(r.x + r.width / 2, r.y + r.height / 2);
        return {inside: r.left >= 0 && r.top >= 0 && r.right <= innerWidth + 1 && r.bottom <= innerHeight + 1, hit: hit === element || element.contains(hit)};
      }), `${control}`).toEqual({inside: true, hit: true});
    }
    const [bar, brandBox, navBox, accountBox, workspaceBox, taskBox, settingsBox] = await Promise.all([toolbar, brand, nav, account, workspace, task, preferences].map(bounds));
    const ordered = [brandBox, navBox, accountBox, workspaceBox, taskBox, settingsBox], names = ['brand', 'navigation', 'account', 'workspace', 'task', 'settings'];
    for (let index = 1; index < ordered.length; index++) expect(ordered[index - 1].x + ordered[index - 1].width, `${names[index - 1]} ends before ${names[index]}`).toBeLessThanOrEqual(ordered[index].x + 1);
    for (const box of ordered) expect(Math.abs(box.y + box.height / 2 - bar.y - bar.height / 2)).toBeLessThanOrEqual(1);
    expect(Math.abs(navBox.x + navBox.width / 2 - bar.x - bar.width / 2)).toBeLessThanOrEqual(1);
    // The workspace/task distinction is native help on the save group instead of an ⓘ button.
    await expect(group).toHaveAttribute('title', tx('workspaceTaskDifferenceHint'));
    await expect(toolbar.locator('.info-tooltip-trigger')).toHaveCount(0);
    // Save actions belong to the Files page only; account and settings stay.
    await tabs.last().click();
    await expect(group).toHaveCount(0);
    await reachable(account); await reachable(preferences);
    await tabs.first().click();
    await expect(group).toBeVisible();

    await preferences.click();
    const dialog = page.locator('.settings-dialog');
    await dialog.locator('.preferences-tabs').getByRole('button', {name: tx('appearance'), exact: true}).click();
    const modes = dialog.getByRole('radiogroup', {name: tx('appearanceMode'), exact: true}).getByRole('radio');
    const accents = dialog.getByRole('radiogroup', {name: tx('accentColor'), exact: true}).getByRole('radio');
    await expect(modes).toHaveText([tx('appearanceAuto'), tx('appearanceLight'), tx('appearanceDark')]);
    await expect(accents).toHaveCount(3);
    for (const [index, key] of (['accentPurple', 'accentGreen', 'accentBlue'] as const).entries()) await expect(accents.nth(index)).toHaveAttribute('aria-label', tx(key));
    for (const radios of [modes, accents]) {
      const boxes: {x: number; y: number; width: number; height: number}[] = [];
      for (const radio of await radios.all()) { await reachable(radio); boxes.push(await bounds(radio)); }
      for (let index = 1; index < boxes.length; index++) {
        expect(Math.abs(boxes[index].y + boxes[index].height / 2 - boxes[0].y - boxes[0].height / 2)).toBeLessThanOrEqual(1);
        expect(boxes[index - 1].x + boxes[index - 1].width).toBeLessThan(boxes[index].x);
      }
    }
    await accents.nth(1).click();
    await modes.nth(1).click();
    await expect(accents.nth(1)).toHaveAttribute('aria-checked', 'true');
    await expect(modes.nth(1)).toHaveAttribute('aria-checked', 'true');
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
  const heading = page.locator('.app-toolbar .workspace-save-actions');
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

// The operation description paragraph was removed: explanations are the rail's operation help
// and the options form's label help, and the picker names the chosen operation.
const detailKey = {copy: 'copyDetail', sync: 'syncDetail', move: 'moveDetail'} as const;
for (const language of ['zh-TW', 'en', 'ja'] as const) {
  test(`${language}: copy, sync and move explanations follow the chosen operation in help and in the options form`, async ({page}) => {
    const tx = translator(language);
    await open(page, {language});
    const help = page.locator('.transfer-controls .rail-group .info-tooltip-trigger');
    await expect(help).toHaveCount(1);
    for (const mode of ['copy', 'sync', 'move'] as const) {
      await chooseMode(page, mode, language);
      await expect(page.getByTestId('operation-picker')).toHaveText(tx(mode));
      await expect(help).toHaveAccessibleDescription(tx(detailKey[mode]));
      await expect(page.locator('.operation-hint')).toHaveCount(0);
      await page.locator('.options-button').click();
      const dialog = page.locator('.options-dialog'), select = dialog.getByTestId('transfer-mode');
      await expect(select).toHaveValue(mode);
      await expect(dialog.locator(`label[for="${await select.getAttribute('id')}"]`)).toHaveAttribute('title', tx(detailKey[mode]));
      await expect(dialog.locator('.options-mode-hint')).toHaveCount(0);
      await dialog.getByRole('button', {name: tx('cancel'), exact: true}).click();
      await expect(dialog).toHaveCount(0);
    }
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
