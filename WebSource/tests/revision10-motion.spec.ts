import {expect, test, type Page} from '@playwright/test';
import {fileURLToPath, pathToFileURL} from 'node:url';
import path from 'node:path';
import {installHostFixture} from './native-fixture';
import {translator} from '../renderer/i18n';

// 0.10.0 interaction rules the user asked for explicitly: sheets close from the
// dimmed area (but never throw away edits), segmented thumbs glide to the
// selection, the first page does not slide in, and help tags appear quickly.
const t = translator('zh-TW');
const url = pathToFileURL(path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../Resources/Web/index.html')).href;
async function open(page: Page) {
  const errors: string[] = [];
  page.on('pageerror', error => errors.push(error.message));
  await installHostFixture(page, {settings: {autoCheckUpdates: false, theme: 'green-dark'}});
  await page.goto(url);
  await page.getByTestId('left-pane').locator('.file-name').first().waitFor();
  return errors;
}
/** Click the scrim beside the open sheet (the top-left corner of the window). */
async function clickScrim(page: Page) { await page.mouse.click(6, 300); }

test('clicking the dimmed area closes a sheet, and the native toolbar scrim does the same', async ({page}) => {
  const errors = await open(page);
  await page.getByRole('button', {name: t('settings'), exact: true}).click();
  const sheet = page.locator('.settings-dialog');
  await expect(sheet).toBeVisible();
  await clickScrim(page);
  await expect(page.locator('dialog[open]')).toHaveCount(0);
  // The Mac host forwards a click on its title-bar scrim as a menu action.
  await page.getByRole('button', {name: t('settings'), exact: true}).click();
  await expect(sheet).toBeVisible();
  await page.evaluate(() => (window as any).__rbnEvent({type: 'menuAction', data: {action: 'dismissModal'}}));
  await expect(page.locator('dialog[open]')).toHaveCount(0);
  expect(errors).toEqual([]);
});

test('a sheet with edits nudges instead of closing when the dimmed area is clicked', async ({page}) => {
  await open(page);
  await page.locator('.options-button').click();
  const sheet = page.locator('.options-dialog');
  await expect(sheet).toBeVisible();
  // Untouched: closes like Cancel.
  await clickScrim(page);
  await expect(page.locator('dialog[open]')).toHaveCount(0);
  await page.locator('.options-button').click();
  await sheet.getByTestId('transfer-mode').selectOption('sync');
  await clickScrim(page);
  await expect(sheet).toBeVisible();
  await expect(sheet).toHaveAttribute('data-nudge', '');
  await expect(sheet.getByTestId('transfer-mode')).toHaveValue('sync');
  await sheet.getByRole('button', {name: t('cancel'), exact: true}).click();
  await expect(page.locator('dialog[open]')).toHaveCount(0);
});

test('segmented thumbs sit under the selected segment and glide after the first placement', async ({page}) => {
  await open(page);
  const picker = page.locator('.direction-picker').first();
  await expect(picker).toHaveAttribute('data-thumb', 'ready');
  const thumbX = () => picker.evaluate(element => parseFloat(getComputedStyle(element).getPropertyValue('--thumb-x')));
  const selectedX = () => picker.locator('button[aria-pressed="true"]').evaluate(element => (element as HTMLElement).offsetLeft);
  expect(await thumbX()).toBe(await selectedX());
  await page.getByRole('button', {name: t('rightToLeft'), exact: true}).click();
  await expect.poll(thumbX).toBe(await selectedX());
  const transition = () => picker.evaluate(element => getComputedStyle(element, '::before').transitionProperty);
  // Reduce Motion: the thumb only cross-fades. Otherwise it glides.
  await page.emulateMedia({reducedMotion: 'reduce'});
  expect(await transition()).not.toContain('transform');
  await page.emulateMedia({reducedMotion: 'no-preference'});
  expect(await transition()).toContain('transform');
  // Unselected segments carry no fill, so two shapes never meet.
  expect(await picker.locator('button[aria-pressed="false"]').evaluate(element => getComputedStyle(element).backgroundColor)).toBe('rgba(0, 0, 0, 0)');
});

test('the first page appears without motion; switching pages slides in from the chosen side', async ({page}) => {
  await open(page);
  await expect(page.locator('.page-view')).toHaveAttribute('data-direction', 'none');
  await page.getByRole('button', {name: t('tasks')}).first().click();
  await expect(page.locator('.page-view')).toHaveAttribute('data-direction', 'forward');
  await page.getByRole('button', {name: t('files')}).first().click();
  await expect(page.locator('.page-view')).toHaveAttribute('data-direction', 'back');
});

test('help tags open after 0.4 seconds of hover', async ({page}) => {
  await open(page);
  const trigger = page.locator('.transfer-controls .info-tooltip-trigger').first();
  await trigger.hover();
  await page.waitForTimeout(250);
  await expect(page.locator('.info-tooltip')).toHaveCount(0);
  await expect(page.locator('.info-tooltip')).toBeVisible({timeout: 500});
});

test('only the pane header is a size container, so the virtualised list keeps its own scroll geometry', async ({page}) => {
  // 0.10.0 made the whole pane an inline-size container; in WebKit at 90% and
  // 125% the list then pulled the scroll position back near its end.
  await open(page);
  const pane = page.getByTestId('left-pane');
  expect(await pane.evaluate(element => getComputedStyle(element).containerType)).toBe('normal');
  expect(await pane.locator('.pane-header').evaluate(element => getComputedStyle(element).containerType)).toBe('inline-size');
  expect(await pane.locator('.file-list').evaluate(element => getComputedStyle(element).containerType)).toBe('normal');
});

test('settings confirmations float and leave by themselves instead of pushing the sheet down', async ({page}) => {
  await open(page);
  await page.getByRole('button', {name: t('settings'), exact: true}).click();
  const sheet = page.locator('.settings-dialog');
  await expect(sheet).toBeVisible();
  await expect(sheet.locator('.dialog-body > .notice.success')).toHaveCount(0);
});

test('only the source pane keeps a checkbox column; switching direction moves it across', async ({page}) => {
  await open(page);
  const width = (side: 'left'|'right') => page.getByTestId(`${side}-pane`).locator('.file-table th.check-cell').evaluate(element => Math.round(element.getBoundingClientRect().width));
  await expect.poll(() => width('left')).toBe(32);
  await expect.poll(() => width('right')).toBe(0);
  await page.getByRole('button', {name: t('rightToLeft'), exact: true}).click();
  await expect.poll(() => width('left')).toBe(0);
  await expect.poll(() => width('right')).toBe(32);
  await expect(page.getByTestId('left-pane').getByRole('checkbox')).toHaveCount(0);
});
