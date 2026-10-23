import { expect, test, type Page } from '@playwright/test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';
import { installHostFixture } from './native-fixture';
import { translator } from '../renderer/i18n';
import type { FileEntry } from '../shared/types';

const url = pathToFileURL(path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../Resources/Web/index.html')).href;
const t = translator('zh-TW');
const duplicateName = 'same-name.js';
const pane = (page: Page) => page.getByTestId('right-pane');
const names = (page: Page) => pane(page).locator('.file-name');
const entry = (name: string, isDir = false, size = 42): FileEntry => ({ name, path: name, size: isDir ? -1 : size, modified: '2026-10-14T00:23:00Z', isDir });
const rootNames = ['A-folder', 'B-folder', 'C-folder', 'D-folder', 'E-folder', 'F-folder', 'G-notes.txt', 'H-image.png', 'I-plan.md', 'J-code.py', 'K-page.html', duplicateName, duplicateName];
// Google Drive may return distinct objects with identical names and paths. The
// host's FileEntry format intentionally carries both rows, without an object ID.
const rootEntries = rootNames.map((name, index) => entry(name, index < 6, index >= 11 ? 37376 : 42));

async function setup(page: Page) {
  await page.setViewportSize({ width: 1440, height: 1200 });
  await installHostFixture(page, { settings: { autoCheckUpdates: false, theme: 'purple-dark' } });
  await page.goto(url);
  await expect(pane(page).locator('.file-list')).toHaveAttribute('aria-busy', 'false');
  await expect(names(page).first()).toBeVisible();
  await page.evaluate(({ rootEntries }) => {
    const state = (window as any).__fixture;
    state.listings['research-drive:'] = rootEntries;
    state.listings['research-drive:A-folder'] = [{name: 'A-only.txt', path: 'A-only.txt', size: 1024, modified: '2026-10-14T00:23:00Z', isDir: false}];
    state.listings['research-drive:B-folder'] = [{name: 'B-only.txt', path: 'B-only.txt', size: 2048, modified: '2026-10-14T00:23:00Z', isDir: false}];
  }, { rootEntries });
  await pane(page).getByRole('button', { name: t('refresh'), exact: true }).click();
  await expect(pane(page).locator('.file-list')).toHaveAttribute('aria-busy', 'false');
  await expect(names(page)).toHaveText(rootNames);
}

async function listCalls(page: Page, remotePath: string) {
  return page.evaluate(remotePath => (window as any).__fixture.calls.filter((call: any) => call.method === 'list' && call.args[0].remote === 'research-drive' && call.args[0].path === remotePath).length, remotePath);
}

test('same-name remote objects remain distinct rows after repeated folder entry, cached Back and refresh', async ({ page }) => {
  await setup(page);
  const rootReads = await listCalls(page, '');
  for (const folder of ['A-folder', 'B-folder', 'A-folder', 'B-folder']) {
    await names(page).filter({ hasText: new RegExp(`^${folder}$`) }).dblclick();
    await expect(pane(page).locator('.path-form input')).toHaveValue(folder);
    await expect(pane(page).locator('.file-list')).toHaveAttribute('aria-busy', 'false');
    await expect(names(page)).toHaveText([folder === 'A-folder' ? 'A-only.txt' : 'B-only.txt']);
    await pane(page).getByRole('button', { name: t('back'), exact: true }).click();
    await expect(pane(page).locator('.path-form input')).toHaveValue('/');
    await expect(names(page)).toHaveText(rootNames);
    await expect(pane(page).locator('.selection-summary')).toHaveText('13 項');
  }
  expect(await listCalls(page, '')).toBe(rootReads);
  await pane(page).getByRole('button', { name: t('refresh'), exact: true }).click();
  await expect.poll(() => listCalls(page, '')).toBe(rootReads + 1);
  await expect(pane(page).locator('.file-list')).toHaveAttribute('aria-busy', 'false');
  await expect(names(page)).toHaveText(rootNames);
  await expect(names(page).filter({ hasText: new RegExp(`^${duplicateName.replaceAll('.', '\\.')}$`) })).toHaveCount(2);
  await expect(pane(page).locator('.selection-summary')).toHaveText('13 項');
  // After cached navigation and refresh, an ordinary uniquely named row must
  // still send its real endpoint/name to the native action, never a display key.
  await names(page).filter({ hasText: /^G-notes\.txt$/ }).click();
  await pane(page).getByRole('button', { name: t('rename'), exact: true }).click();
  const dialog = page.getByRole('dialog');
  await expect(dialog.locator('input')).toHaveValue('G-notes.txt');
  await dialog.locator('input').fill('Renamed notes.txt');
  await dialog.getByRole('button', { name: t('rename'), exact: true }).click();
  await expect.poll(() => page.evaluate(() => (window as any).__fixture.calls.filter((call: any) => call.method === 'rename').map((call: any) => call.args))).toEqual([
    [{ remote: 'research-drive', path: '' }, 'G-notes.txt', 'Renamed notes.txt', false],
  ]);
});

test('refresh replaces duplicate objects with the returned multiplicity instead of leaving orphan rows', async ({ page }) => {
  await setup(page);
  const rootReads = await listCalls(page, '');
  // A fresh listing now contains only one of the same-name objects. The single
  // remaining object must survive without keeping a DOM row for the removed one.
  await page.evaluate(rootEntries => {
    (window as any).__fixture.listings['research-drive:'] = rootEntries.slice(0, -1);
  }, rootEntries);
  await pane(page).getByRole('button', { name: t('refresh'), exact: true }).click();
  await expect.poll(() => listCalls(page, '')).toBe(rootReads + 1);
  await expect(pane(page).locator('.file-list')).toHaveAttribute('aria-busy', 'false');
  await expect(names(page)).toHaveText(rootNames.slice(0, -1));
  await expect(pane(page).locator('.selection-summary')).toHaveText('12 項');
});

test('same-name rows keep their individual metadata through sorting and filtering', async ({ page }) => {
  await setup(page);
  await page.evaluate(({ rootEntries }) => {
    const listing = structuredClone(rootEntries);
    listing[11].size = 8192; listing[11].modified = '2026-10-20T00:23:00Z';
    listing[12].size = 1024; listing[12].modified = '2026-10-10T00:23:00Z';
    (window as any).__fixture.listings['research-drive:'] = listing;
  }, { rootEntries });
  await pane(page).getByRole('button', { name: t('refresh'), exact: true }).click();
  await expect(pane(page).locator('.file-list')).toHaveAttribute('aria-busy', 'false');
  await expect(names(page)).toHaveText(rootNames);
  const rootReads = await listCalls(page, '');
  const search = pane(page).getByRole('textbox', { name: `${t('right')} ${t('search')}`, exact: true });
  await search.fill(duplicateName);
  await expect(names(page)).toHaveText([duplicateName, duplicateName]);
  const sizes = pane(page).locator('tbody tr[data-index] td.numeric');
  const dates = pane(page).locator('tbody tr[data-index] td.date-cell');
  await expect(sizes).toHaveText(['8 KiB', '1 KiB']);
  await expect(dates).toHaveText([/2026\/10\/20/, /2026\/10\/10/]);
  await pane(page).getByRole('button', { name: t('size'), exact: true }).click();
  await expect(sizes).toHaveText(['1 KiB', '8 KiB']);
  await expect(dates).toHaveText([/2026\/10\/10/, /2026\/10\/20/]);
  await pane(page).getByRole('button', { name: t('modified'), exact: true }).click();
  await expect(sizes).toHaveText(['1 KiB', '8 KiB']);
  await pane(page).getByRole('button', { name: t('modified'), exact: true }).click();
  await expect(sizes).toHaveText(['8 KiB', '1 KiB']);
  await expect(dates).toHaveText([/2026\/10\/20/, /2026\/10\/10/]);
  await search.fill('G-notes');
  await expect(names(page)).toHaveText(['G-notes.txt']);
  await search.clear();
  await expect.poll(async () => (await names(page).allTextContents()).sort()).toEqual([...rootNames].sort());
  await expect(pane(page).locator('.selection-summary')).toHaveText('13 項');
  expect(await listCalls(page, '')).toBe(rootReads);
});
