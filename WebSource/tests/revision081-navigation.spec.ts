import {expect, test, type Page} from '@playwright/test';
import {fileURLToPath, pathToFileURL} from 'node:url';
import path from 'node:path';
import {installHostFixture} from './native-fixture';
import {translator} from '../renderer/i18n';

const url = pathToFileURL(path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../Resources/Web/index.html')).href;
const t = translator('zh-TW');
const pane = (page: Page, side: 'left'|'right') => page.getByTestId(`${side}-pane`);
const pathInput = (page: Page, side: 'left'|'right') => page.getByLabel(`${t(side)} ${t('path')}`, {exact: true});
async function open(page: Page) {
  await installHostFixture(page, {settings: {autoCheckUpdates: false, theme: 'purple-dark'}});
  await page.goto(url);
  for (const side of ['left', 'right'] as const) {
    await expect(pane(page, side).locator('.file-list')).toHaveAttribute('aria-busy', 'false');
    for (const name of ['A', 'B', 'C']) {
      await pathInput(page, side).fill(`/Users/test/${side}/${name}`);
      await pathInput(page, side).press('Enter');
      await expect(pane(page, side).locator('.file-list')).toHaveAttribute('aria-busy', 'false');
    }
  }
  await pane(page, 'left').locator('.pane-side').click();
}
async function native(page: Page, direction: 'back'|'forward', side: 'left'|'right', phase: 'swipe'|'command') {
  await pane(page, side).evaluate((element, {direction, phase}) => {
    const r = element.getBoundingClientRect();
    (window as any).__rbnEvent({type: 'navigateHistory', data: {direction, phase,
      x: phase === 'command' ? -1 : r.x + 35, y: phase === 'command' ? -1 : r.y + 45,
      eventTime: performance.timeOrigin + performance.now()}});
  }, {direction, phase});
}

test('native driver swipes navigate the pointed pane while preserving both forward histories', async ({page}) => {
  await open(page);
  await native(page, 'back', 'right', 'swipe');
  await expect(pathInput(page, 'right')).toHaveValue('/Users/test/right/B');
  await expect(pathInput(page, 'left')).toHaveValue('/Users/test/left/C');
  await native(page, 'back', 'left', 'swipe');
  await expect(pathInput(page, 'left')).toHaveValue('/Users/test/left/B');
  await native(page, 'forward', 'right', 'swipe');
  await expect(pathInput(page, 'right')).toHaveValue('/Users/test/right/C');
  await expect(pathInput(page, 'left')).toHaveValue('/Users/test/left/B');
  await native(page, 'forward', 'left', 'swipe');
  await expect(pathInput(page, 'left')).toHaveValue('/Users/test/left/C');
});

test('duplicate swipe delivery is ignored while two rapid distinct swipes both navigate', async ({page}) => {
  await open(page);
  await pane(page, 'right').evaluate(element => {
    const r = element.getBoundingClientRect(), w = window as any, time = performance.timeOrigin + performance.now();
    const data = {direction: 'back', phase: 'swipe', x: r.x + 35, y: r.y + 45, eventTime: time};
    w.__rbnEvent({type: 'navigateHistory', data});
    w.__rbnEvent({type: 'navigateHistory', data});
    w.__rbnEvent({type: 'navigateHistory', data: {...data, eventTime: time + 10}});
  });
  await expect(pathInput(page, 'right')).toHaveValue('/Users/test/right/A');
  await expect(pathInput(page, 'left')).toHaveValue('/Users/test/left/C');
});

test('native menu commands use the active pane and preserve focused text editing', async ({page}) => {
  await open(page);
  await native(page, 'back', 'right', 'command');
  await expect(pathInput(page, 'left')).toHaveValue('/Users/test/left/B');
  await expect(pathInput(page, 'right')).toHaveValue('/Users/test/right/C');
  await native(page, 'forward', 'right', 'command');
  await expect(pathInput(page, 'left')).toHaveValue('/Users/test/left/C');
  await pathInput(page, 'right').focus();
  await native(page, 'back', 'right', 'command');
  await expect(pathInput(page, 'right')).toHaveValue('/Users/test/right/C');
  await expect(pathInput(page, 'left')).toHaveValue('/Users/test/left/C');
  await page.evaluate(() => {
    const editor = document.createElement('div'); editor.contentEditable = 'true'; editor.id = 'navigation-editor';
    editor.textContent = 'Text being edited'; document.body.append(editor); editor.focus();
  });
  await native(page, 'back', 'left', 'command');
  await expect(page.locator('#navigation-editor')).toHaveText('Text being edited');
  await expect(pathInput(page, 'left')).toHaveValue('/Users/test/left/C');
  // Mouse-generated swipes still use the pointed pane, even when an unrelated
  // text input previously held keyboard focus.
  await page.locator('#navigation-editor').evaluate(element => element.remove());
  await pathInput(page, 'left').focus();
  await native(page, 'back', 'right', 'swipe');
  await expect(pathInput(page, 'right')).toHaveValue('/Users/test/right/B');
  await expect(pathInput(page, 'left')).toHaveValue('/Users/test/left/C');
});

test('an open operation dialog blocks driver swipes and native menu navigation', async ({page}) => {
  await open(page);
  await page.locator('.options-button').click();
  await expect(page.locator('.options-dialog')).toBeVisible();
  await native(page, 'back', 'right', 'swipe');
  await native(page, 'back', 'left', 'command');
  await expect(pathInput(page, 'left')).toHaveValue('/Users/test/left/C');
  await expect(pathInput(page, 'right')).toHaveValue('/Users/test/right/C');
  await expect(page.locator('.options-dialog')).toBeVisible();
});

test('ordinary horizontal wheel scrolling does not navigate folder history', async ({page}) => {
  await open(page);
  await pane(page, 'right').dispatchEvent('wheel', {deltaX: 600, deltaY: 0, bubbles: true});
  await expect(pathInput(page, 'left')).toHaveValue('/Users/test/left/C');
  await expect(pathInput(page, 'right')).toHaveValue('/Users/test/right/C');
});
