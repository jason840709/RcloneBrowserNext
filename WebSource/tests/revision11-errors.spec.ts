import {expect, test, type Page} from '@playwright/test';
import {fileURLToPath, pathToFileURL} from 'node:url';
import path from 'node:path';
import {installHostFixture} from './native-fixture';
import {translator} from '../renderer/i18n';

// 0.10.2: problems show as a small light with a plain title. Orange when rclone
// recovers by itself, red when the user must act; only urgent problems unfold.
// A job that finished successfully looks normal.
const t = translator('zh-TW');
const url = pathToFileURL(path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../Resources/Web/index.html')).href;
const rateLimit = "couldn't list directory: googleapi: Error 403: Quota exceeded for quota metric 'Queries' of service 'drive.googleapis.com' for consumer 'project_number:202264815644'. rateLimitExceeded";

async function openWith(page: Page, patch: Record<string, unknown>, stats: Record<string, unknown>) {
  const errors: string[] = [];
  page.on('pageerror', error => errors.push(error.message));
  await installHostFixture(page, {job: true, settings: {autoCheckUpdates: false, theme: 'green-dark'}});
  await page.goto(url);
  await page.getByTestId('left-pane').locator('.file-name').first().waitFor();
  await page.evaluate(([patch, stats]) => {
    const w = window as any, job = structuredClone(w.__fixture.bootstrap.jobs[0]);
    Object.assign(job, patch); Object.assign(job.stats, stats);
    w.__rbnEvent({type: 'jobUpdate', data: job});
  }, [patch, stats] as const);
  await page.locator('.main-nav button').nth(1).click();
  return errors;
}

test('a retried rate limit is an orange light with its explanation folded', async ({page}) => {
  const errors = await openWith(page, {error: rateLimit}, {errors: 3, retryError: true});
  const alert = page.locator('.job-alert');
  await expect(alert).toHaveClass(/caution/);
  await expect(alert.locator('.alert-title')).toHaveText(t('errRateLimitTitle'));
  await expect(alert.locator('.alert-light')).toHaveClass(/live/);
  expect(await alert.evaluate(element => (element as HTMLDetailsElement).open)).toBe(false);
  await alert.locator('summary').first().click();
  await expect(alert.locator('.job-alert-body')).toContainText(t('errRateLimitShared'));
  await expect(alert.locator('pre')).toHaveText(rateLimit);
  expect(errors).toEqual([]);
});

test('an urgent failure is red and unfolds by itself', async ({page}) => {
  await openWith(page, {status: 'failed', error: 'Failed to copy: write /Volumes/Backup/a.mov: no space left on device'}, {errors: 1});
  const alert = page.locator('.job-alert');
  await expect(alert).toHaveClass(/urgent/);
  await expect(alert.locator('.alert-light')).not.toHaveClass(/live/);
  await expect.poll(() => alert.evaluate(element => (element as HTMLDetailsElement).open)).toBe(true);
  await expect(alert.locator('.job-alert-body')).toContainText(t('errDiskFull'));
});

test('a job that finished after retrying its errors looks normal', async ({page}) => {
  await openWith(page, {status: 'completed', error: undefined, endedAt: '2026-10-19T09:10:00Z'}, {errors: 3});
  await expect(page.locator('.job-alert')).toHaveCount(0);
  await expect(page.locator('.job-details .error-count')).toHaveCount(0);
  await expect(page.locator('.job-file-counts .error-text, .job-file-counts .warning-text')).toHaveCount(0);
});

test('while no new data arrives the speed stays visible with a small busy ring', async ({page}) => {
  await openWith(page, {}, {speedState: 'hidden', speed: 76_000});
  const speed = page.locator('.job-metrics .metric-pending');
  await expect(speed.locator('strong')).toContainText('/s');
  await expect(speed.locator('.activity-ring')).toHaveAttribute('aria-label', t('speedHidden'));
  await expect(speed).toHaveAttribute('title', new RegExp(t('speedHiddenHint').slice(0, 12)));
  await expect(page.getByText(t('speedHidden'), {exact: true})).toHaveCount(0);
});

test('while rclone only compares, the last speed stays and the ring says it is checking', async ({page}) => {
  await openWith(page, {}, {speedState: 'checking', speed: 10_000_000});
  const speed = page.locator('.job-metrics .metric-pending');
  await expect(speed.locator('strong')).toContainText('/s');
  await expect(speed.locator('.activity-ring')).toHaveAttribute('aria-label', t('speedChecking'));
});

test('each count hint covers its label, its number and the space up to the next item', async ({page}) => {
  await openWith(page, {}, {speedState: 'live', speed: 1_000_000});
  for (const row of ['.job-metrics', '.job-file-counts']) {
    const items = page.locator(`${row} > div`);
    const count = await items.count();
    for (let index = 0; index < count - 1; index += 1) {
      const item = items.nth(index), next = items.nth(index + 1);
      await expect(item).toHaveAttribute('title', /.+/);
      const box = await item.boundingBox(), nextBox = await next.boundingBox();
      // Same line: the item reaches the next one, so no hint-free gap remains.
      if (box && nextBox && Math.abs(box.y - nextBox.y) < 2) expect(Math.abs(box.x + box.width - nextBox.x)).toBeLessThan(1);
    }
  }
  await expect(page.locator('.job-metrics [title] [title], .job-file-counts [title] [title]')).toHaveCount(0);
});

// Retry scope: after errors, only the failed files are retried by default; the
// setting can restore rclone's complete re-check.
test('retrying only failed files is the default and can be switched to a complete re-check', async ({page}) => {
  const errors: string[] = [];
  page.on('pageerror', error => errors.push(error.message));
  await installHostFixture(page, {settings: {autoCheckUpdates: false}});
  await page.goto(url);
  await page.getByTestId('left-pane').locator('.file-name').first().waitFor();
  await page.locator('.app-toolbar .settings-button').click();
  const dialog = page.locator('dialog.settings-dialog');
  const scope = dialog.getByLabel(t('retryScope'), {exact: true});
  await expect(scope).toHaveValue('failed');
  await expect(scope.locator('option:checked')).toHaveText(t('retryScopeFailed'));
  await scope.selectOption('full');
  await expect.poll(async () => page.evaluate(() => (window as any).__fixture.calls.filter((call: any) => call.method === 'saveSettings').map((call: any) => call.args[0])))
    .toContainEqual({retryScope: 'full'});
  expect(errors).toEqual([]);
});
