import {expect, test, type Page} from '@playwright/test';
import {fileURLToPath, pathToFileURL} from 'node:url';
import path from 'node:path';
import {installHostFixture} from './native-fixture';
import {translator} from '../renderer/i18n';

// 0.12.2: returning to Files must not rebuild it. In WKWebView the rebuilt page
// showed the window background for ~0.25 s after a finished transfer (fixed by
// sliding with margins instead of a transform), and the rebuilt lists grew
// their vertical scroll bars over the first frames (fixed by keeping Files
// mounted while hidden, as tab views do).
const t = translator('zh-TW');
const url = pathToFileURL(path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../Resources/Web/index.html')).href;
type Frame = {files: boolean; height: number; top: number; rows: number; transform: string; position: string; left: number; right: number; width: number; mainWidth: number} | null;

async function open(page: Page, job = false) {
  await page.emulateMedia({reducedMotion: 'no-preference'});
  await installHostFixture(page, {job, settings: {autoCheckUpdates: false, theme: 'green-dark'}, fileCount: 300});
  await page.goto(url);
  await page.getByTestId('left-pane').locator('.file-name').first().waitFor();
}
/** Switch pages and record the visible page and left list on each of the next frames. */
async function switchAndSample(page: Page, name: 'files' | 'jobs' | 'tasks'): Promise<Frame[]> {
  await page.evaluate(() => {
    const frames: Frame[] = [];
    (window as unknown as {__frames: Frame[]}).__frames = frames;
    const step = () => {
      const view = [...document.querySelectorAll<HTMLElement>('.page-view')].find(element => element.offsetParent !== null);
      const list = document.querySelector<HTMLElement>('[data-testid="left-pane"] [data-virtuoso-scroller]');
      if (!view) frames.push(null);
      else {
        const style = getComputedStyle(view);
        const visibleList = list && list.offsetParent !== null ? list : null;
        frames.push({files: Boolean(view.querySelector('[data-testid="left-pane"]')), height: visibleList?.scrollHeight ?? -1, top: visibleList?.scrollTop ?? -1, rows: visibleList?.querySelectorAll('tbody tr').length ?? -1,
          transform: style.transform, position: style.position, left: parseFloat(style.marginLeft), right: parseFloat(style.marginRight),
          width: view.getBoundingClientRect().width, mainWidth: document.querySelector<HTMLElement>('.app-main')!.clientWidth});
      }
      if (frames.length < 16) requestAnimationFrame(step);
    };
    requestAnimationFrame(step);
  });
  await page.getByRole('button', {name: t(name)}).first().click();
  await expect.poll(() => page.evaluate(() => (window as unknown as {__frames: Frame[]}).__frames.length)).toBe(16);
  return page.evaluate(() => (window as unknown as {__frames: Frame[]}).__frames);
}

test('the page slide keeps the page width and never uses a transform', async ({page}) => {
  await open(page);
  for (const [name, sign] of [['tasks', 1], ['files', -1], ['jobs', 1], ['files', -1]] as const) {
    const frames = (await switchAndSample(page, name)).filter((frame): frame is NonNullable<Frame> => frame !== null);
    expect(frames.length).toBeGreaterThan(8);
    expect(frames.some(frame => frame.left * sign > 1)).toBe(true);
    for (const frame of frames) {
      expect(frame.transform).toBe('none');
      expect(frame.position).toBe('static');
      expect(frame.left + frame.right).toBeCloseTo(0, 3);
      expect(frame.width).toBeCloseTo(frame.mainWidth, 0);
    }
    await expect.poll(() => page.locator('.page-view:visible').evaluate(element => getComputedStyle(element).marginLeft)).toBe('0px');
  }
});

for (const job of [false, true]) test(`returning to Files keeps each list's height, scroll position and rows from the first frame (${job ? 'with a job' : 'idle'})`, async ({page}) => {
  await open(page, job);
  const list = page.getByTestId('left-pane').locator('[data-virtuoso-scroller]');
  await list.evaluate(element => { element.scrollTop = 1000; });
  await expect.poll(() => list.evaluate(element => element.scrollTop)).toBe(1000);
  const settled = await list.evaluate(element => element.scrollHeight);
  for (const away of ['jobs', 'tasks'] as const) {
    await switchAndSample(page, away);
    const frames = (await switchAndSample(page, 'files')).filter((frame): frame is NonNullable<Frame> => frame !== null && frame.files);
    expect(frames.length).toBeGreaterThan(8);
    for (const frame of frames) {
      expect(frame.height).toBe(settled);
      expect(frame.top).toBe(1000);
      expect(frame.rows).toBeGreaterThan(0);
    }
  }
});

test('a hidden Files page leaves other pages and their controls alone', async ({page}) => {
  await open(page, true);
  await page.getByRole('button', {name: t('jobs')}).first().click();
  // The hidden page is not visible, focusable or reachable by role.
  await expect(page.getByTestId('left-pane')).toBeHidden();
  await expect(page.locator('.page-view:visible')).toHaveCount(1);
  await expect(page.locator('.jobs-page-layout')).toBeVisible();
  await page.getByRole('button', {name: t('files')}).first().click();
  await expect(page.getByTestId('left-pane')).toBeVisible();
  await expect(page.locator('.page-view:visible')).toHaveCount(1);
});

test('automatic column widths never flash at their minimum when Files is shown again from the toolbar', async ({page, browserName}) => {
  // The Mac toolbar switches pages through a menu action, not a click, so the
  // hidden page's width observer could record 0 and the right pane's automatic
  // name column showed at 120 px for a frame. Slow the CPU to widen that window.
  await page.setViewportSize({width: 2000, height: 1000});
  await page.emulateMedia({reducedMotion: 'no-preference'});
  await installHostFixture(page, {job: true, settings: {autoCheckUpdates: false, theme: 'green-dark', paneColumnWidths: {left: {name: 400, size: 82, modified: 158}}}});
  await page.goto(url);
  await page.getByTestId('right-pane').locator('.file-name').first().waitFor();
  if (browserName === 'chromium') await (await page.context().newCDPSession(page)).send('Emulation.setCPUThrottlingRate', {rate: 6});
  const nameColumn = page.getByTestId('right-pane').locator('colgroup col').nth(1);
  const settled = await nameColumn.evaluate(element => (element as HTMLElement).style.width);
  expect(parseFloat(settled)).toBeGreaterThan(300);
  const seen = new Set<string>();
  for (let round = 0; round < 15; round++) for (const target of ['jobs', 'files'] as const) {
    await page.evaluate(() => {
      const widths: string[] = [];
      (window as unknown as {__widths: string[]}).__widths = widths;
      const step = () => {
        const column = document.querySelector<HTMLElement>('[data-testid="right-pane"] colgroup col:nth-child(2)');
        if (column?.closest('.page-view')) widths.push(column.style.width);
        if (widths.length < 6) requestAnimationFrame(step);
      };
      requestAnimationFrame(step);
    });
    await page.evaluate(next => (window as unknown as {__rbnEvent(event: unknown): void}).__rbnEvent({type: 'menuAction', data: {action: 'page', page: next}}), target);
    if (target === 'files') {
      await expect.poll(() => page.evaluate(() => (window as unknown as {__widths: string[]}).__widths.length), {timeout: 15_000}).toBe(6);
      for (const width of await page.evaluate(() => (window as unknown as {__widths: string[]}).__widths)) seen.add(width);
    } else await expect(page.locator('.jobs-page-layout')).toBeVisible();
  }
  expect([...seen]).toEqual([settled]);
});
