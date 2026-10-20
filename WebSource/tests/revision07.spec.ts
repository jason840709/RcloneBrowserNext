import {expect, test, type Page, type Locator} from '@playwright/test';
import {fileURLToPath, pathToFileURL} from 'node:url';
import path from 'node:path';
import {installHostFixture, selectPlace} from './native-fixture';
import {translator} from '../renderer/i18n';
import {childEndpoint, endpointEqual, endpointName, parentEndpoint} from '../renderer/utils';
import type {Language} from '../shared/types';

const url = pathToFileURL(path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../Resources/Web/index.html')).href;
const t = translator('zh-TW');
const longRemotes = Array.from({length: 60}, (_, index) => ({name: `cloud-${String(index + 1).padStart(2, '0')}`, type: 'drive', group: 'cloud' as const}));
async function open(page: Page, options: Parameters<typeof installHostFixture>[1] = {}) {
  const errors: string[] = [];
  page.on('pageerror', error => errors.push(error.message));
  await installHostFixture(page, {...options, settings: {autoCheckUpdates: false, theme: 'purple-dark', ...options.settings}});
  await page.goto(url);
  await page.getByTestId('left-pane').locator('.file-name').first().waitFor();
  return errors;
}
async function calls(page: Page, method: string): Promise<any[]> {
  return page.evaluate(method => (window as any).__fixture.calls.filter((call: any) => call.method === method), method);
}
const place = (page: Page, side: 'left' | 'right') => page.getByTestId(`${side}-pane`).locator('.location-trigger');
async function popupBelow(trigger: Locator, selectedValue?: string) {
  const page = trigger.page();
  const popup = page.locator('.location-popup');
  await expect(popup).toBeVisible();
  const anchor = await trigger.boundingBox(), box = await popup.boundingBox();
  const viewport = page.viewportSize()!;
  expect(box!.y).toBeGreaterThanOrEqual(anchor!.y + anchor!.height + 5);
  expect(box!.x).toBeGreaterThanOrEqual(0);
  expect(box!.x + box!.width).toBeLessThanOrEqual(viewport.width + 1);
  expect(box!.y + box!.height).toBeLessThanOrEqual(viewport.height - 7);
  expect(box!.height).toBeGreaterThan(90);
  if (selectedValue) {
    const chosen = popup.locator(`[role="option"][data-value=${JSON.stringify(selectedValue)}]`);
    await expect(chosen).toHaveAttribute('aria-selected', 'true');
    const item = await chosen.boundingBox(), list = await popup.locator('.location-options').boundingBox();
    expect(item!.y).toBeGreaterThanOrEqual(list!.y - 1);
    expect(item!.y + item!.height).toBeLessThanOrEqual(list!.y + list!.height + 1);
  }
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
}

for (const scale of [80, 90, 100, 110, 125] as const) test(`${scale}%: both long location menus stay below their trigger after choosing the last cloud`, async ({page}, info) => {
  await page.setViewportSize({width: Math.floor(1060 / (scale / 100)), height: Math.floor(680 / (scale / 100))});
  const errors = await open(page, {extraRemotes: longRemotes, settings: {interfaceScale: scale}});
  const grid = page.locator('.browser-grid'), before = await grid.boundingBox();
  for (const side of ['left', 'right'] as const) {
    const trigger = place(page, side);
    await selectPlace(trigger, 'cloud-60');
    await expect(trigger).toHaveAttribute('aria-expanded', 'false');
    await trigger.click();
    await popupBelow(trigger, 'cloud-60');
    expect(await page.locator('.location-options').evaluate(element => element.scrollHeight > element.clientHeight && element.scrollTop > 0)).toBe(true);
    if (side === 'right') await page.screenshot({path: info.outputPath(`locations-${scale}.png`), animations: 'disabled'});
    const popupBox = await page.locator('.location-popup').boundingBox();
    await page.locator('.location-options').evaluate(element => element.scrollTop = 0);
    await expect(page.locator('.location-popup')).toHaveCSS('top', `${popupBox!.y}px`);
    expect(await grid.boundingBox()).toEqual(before);
    await page.keyboard.press('Escape');
    await expect(trigger).toBeFocused();
  }
  expect(await calls(page, 'startTransfer')).toHaveLength(0);
  expect(errors).toEqual([]);
});

test('location search supports keyboard choice, Escape, Tab and outside dismissal without navigating the pane', async ({page}) => {
  const errors = await open(page, {extraRemotes: longRemotes});
  const trigger = place(page, 'left');
  await trigger.focus(); await trigger.press('ArrowDown');
  const search = page.getByRole('combobox');
  await expect(search).toBeFocused();
  await search.fill('cloud-6');
  await expect(page.locator('.location-popup [role="option"]')).toHaveCount(1);
  await search.dispatchEvent('keydown', {key: 'Enter', isComposing: true, bubbles: true});
  await expect(page.locator('.location-popup')).toBeVisible();
  await search.dispatchEvent('keydown', {key: 'Enter', keyCode: 229, bubbles: true});
  await expect(page.locator('.location-popup')).toBeVisible();
  await search.press('Enter');
  await expect(trigger).toHaveAttribute('title', `${t('left')} ${t('location')}: cloud-60 · drive`);
  await trigger.press('Home');
  await expect(search).toHaveAttribute('aria-activedescendant', /option-0$/);
  await search.fill('does-not-exist');
  await expect(page.locator('.location-no-results')).toHaveText(t('noMatches'));
  await search.press('Enter'); await expect(search).toBeFocused();
  await search.fill('cloud-'); await search.press('Alt+End'); await search.press('ArrowUp'); await search.press('Enter');
  await expect(trigger).toHaveAttribute('title', `${t('left')} ${t('location')}: cloud-59 · drive`);
  await trigger.click(); await search.press('Escape'); await expect(trigger).toBeFocused();
  await trigger.click(); await search.press('Tab');
  await expect(page.locator('.location-popup')).toHaveCount(0);
  await expect(trigger).not.toBeFocused();
  await trigger.click(); await page.locator('.pane-heading').last().click();
  await expect(page.locator('.location-popup')).toHaveCount(0);
  await trigger.click(); await page.getByLabel(`${t('left')} ${t('path')}`, {exact: true}).focus();
  await expect(page.locator('.location-popup')).toHaveCount(0);
  await trigger.click();
  await page.evaluate(() => window.dispatchEvent(new CustomEvent('rbn:navigate-history', {detail: {direction: 'back', eventTime: Date.now()}})));
  await expect(trigger).toHaveAttribute('title', `${t('left')} ${t('location')}: cloud-60 · drive`);
  await expect(page.locator('.location-popup')).toHaveCount(0);
  expect(errors).toEqual([]);
});

test('local locations remain selectable while unavailable remote locations stay disabled', async ({page}) => {
  await open(page, {available: false});
  const trigger = place(page, 'left');
  await trigger.click();
  const remote = page.locator('.location-popup [data-value="research-drive"]');
  await expect(remote).toHaveAttribute('aria-disabled', 'true');
  await remote.click({force: true}); await expect(page.locator('.location-popup')).toBeVisible();
  const search = page.getByRole('combobox');
  await search.fill('research-drive'); await search.press('Enter');
  await expect(page.locator('.location-popup')).toBeVisible();
  await search.fill(t('downloadsFolder')); await search.press('Enter');
  await expect(page.getByLabel(`${t('left')} ${t('path')}`, {exact: true})).toHaveValue('/Users/test/Downloads');
  expect(await calls(page, 'startTransfer')).toHaveLength(0);
});

test('known local locations retain their name when a startup path has a trailing separator', async ({page}) => {
  await open(page, {settings: {initialLocations: {left: {remote: null, path: '/Users/test/'}}}});
  await place(page, 'left').click();
  await expect(page.locator('.location-popup [role="option"][aria-selected="true"]')).toHaveAttribute('data-value', '@local:home');
  await expect(page.locator('.location-popup [role="option"][data-value=""]')).toHaveCount(0);
});

for (const language of ['zh-TW', 'en', 'ja'] as const) test(`${language}: task and startup location menus stay below the trigger inside compact modal windows`, async ({page}, info) => {
  await page.setViewportSize({width: 848, height: 544});
  const tx = translator(language), errors = await open(page, {extraRemotes: longRemotes, settings: {language, interfaceScale: 125}});
  await page.getByRole('button', {name: tx('saveTask'), exact: true}).click();
  const task = page.locator('.task-editor-dialog');
  const taskTrigger = task.locator('.endpoint-editor .location-trigger').last();
  await selectPlace(taskTrigger, 'cloud-60'); await taskTrigger.click();
  await popupBelow(taskTrigger, 'cloud-60');
  expect(await page.locator('.location-popup').evaluate(element => element.parentElement?.tagName)).toBe('DIALOG');
  await page.keyboard.press('Escape');
  await expect(task).toBeVisible(); await task.getByRole('button', {name: tx('cancel'), exact: true}).click();
  await page.locator('.workspace-title > .icon-button').click();
  const settings = page.locator('.settings-dialog');
  const startupTrigger = settings.locator('.startup-location-editors .location-trigger').last();
  await startupTrigger.scrollIntoViewIfNeeded();
  await selectPlace(startupTrigger, 'cloud-60'); await startupTrigger.click();
  await popupBelow(startupTrigger, 'cloud-60');
  await page.screenshot({path: info.outputPath(`startup-popup-${language}.png`), animations: 'disabled'});
  await page.keyboard.press('Escape'); await expect(settings).toBeVisible();
  expect(errors).toEqual([]);
});

test('local path navigation stops at Windows drive and UNC share roots without altering remote or POSIX names', () => {
  const local = (value: string) => ({remote: null, path: value});
  for (const [start, expected] of [
    ['C:\\Users\\Tester\\Downloads', 'C:/Users/Tester'], ['C:\\Users', 'C:/'], ['C:\\', 'C:/'], ['D:/', 'D:/'],
    ['\\\\nas\\backup\\Archive', '//nas/backup'], ['\\\\nas\\backup', '//nas/backup'], ['//nas/backup/', '//nas/backup'],
    ['/Users/Tester', '/Users'], ['/Users', '/'], ['/', '/'], ['/work/name\\with\\slashes', '/work'],
  ]) expect(parentEndpoint(local(start))).toEqual(local(expected));
  expect(childEndpoint(local('C:\\'), 'Docs')).toEqual(local('C:/Docs'));
  expect(childEndpoint(local('\\\\nas\\backup'), '資料')).toEqual(local('//nas/backup/資料'));
  expect(endpointName(local('C:\\Users\\Tester\\資料'))).toBe('資料');
  expect(endpointEqual(local('C:\\Users\\Tester'), local('C:/Users/Tester/'))).toBe(true);
  expect(endpointEqual(local('/work/a\\b'), local('/work/a/b'))).toBe(false);
  expect(childEndpoint({remote: 'cloud', path: 'C:\\Folder'}, 'a\\b')).toEqual({remote: 'cloud', path: 'C:\\Folder/a\\b'});
  expect(parentEndpoint({remote: 'sftp', path: '/root/path'})).toEqual({remote: 'sftp', path: '/root'});
  expect(parentEndpoint({remote: 'sftp', path: '/root'})).toEqual({remote: 'sftp', path: '/'});
});

for (const platform of ['darwin', 'windows', 'linux']) test(`${platform}: only supported native tools and appearance settings are exposed`, async ({page}) => {
  await open(page, {platform});
  const right = page.getByTestId('right-pane');
  await right.locator('.pane-more-menu summary').click();
  await expect(right.getByRole('menuitem', {name: t('mountRemote'), exact: true})).toHaveCount(platform === 'darwin' ? 1 : 0);
  await expect(right.getByRole('menuitem', {name: t('directoryTree'), exact: true})).toBeEnabled();
  await expect(right.getByRole('menuitem', {name: t('streamFile'), exact: true})).toHaveCount(1);
  await page.locator('.application-menu summary').click();
  await expect(page.locator('.application-menu kbd')).toHaveText(platform === 'darwin' ? '⌘ ,' : 'Ctrl ,');
  await page.locator('.application-menu').getByRole('menuitem', {name: new RegExp('^'+t('settings')+' ')}).click();
  const dialog = page.locator('.settings-dialog');
  await expect(dialog.getByRole('button', {name: t('choosePlayer'), exact: true})).toHaveCount(1);
  await dialog.getByRole('button', {name: t('appearance'), exact: true}).click();
  await expect(dialog.getByRole('checkbox', {name: t('showStatusItem'), exact: true})).toHaveCount(platform === 'darwin' ? 1 : 0);
  await expect(dialog.getByRole('checkbox', {name: t('notifyOnCompletion'), exact: true})).toHaveCount(platform === 'darwin' ? 1 : 0);
});

test('a Windows custom executable saves its drive-qualified parent installation folder', async ({page}) => {
  await open(page, {platform: 'windows'});
  await page.evaluate(() => { (window as any).__fixture.chosenExecutable = 'C:\\Tools\\rclone\\rclone.exe'; });
  await page.locator('.workspace-title > .icon-button').click();
  const dialog = page.locator('.settings-dialog');
  await dialog.locator('.location-advanced summary').click();
  await dialog.getByRole('button', {name: t('chooseExecutable'), exact: true}).click();
  await expect.poll(async () => (await calls(page, 'saveSettings')).length).toBe(1);
  expect((await calls(page, 'saveSettings'))[0].args[0]).toEqual({rclonePath: 'C:\\Tools\\rclone\\rclone.exe', rcloneDirectory: 'C:/Tools/rclone'});
});

for (const language of ['zh-TW', 'en', 'ja'] as const) test(`${language}: symbolic-link policy survives defaults and saved-task editing without starting a transfer`, async ({page}) => {
  const tx = translator(language);
  await open(page, {settings: {language}});
  await page.locator('.options-button').click();
  const options = page.locator('.options-dialog');
  await expect(options.getByTestId('transfer-symlinks')).toHaveValue('skip');
  await options.getByTestId('transfer-symlinks').selectOption('preserve');
  await options.getByRole('button', {name: `${tx('symlinkMode')} — ${tx('infoLabel')}`, exact: true}).click();
  await expect(page.getByRole('tooltip')).toHaveText(tx('symlinkHint'));
  await page.keyboard.press('Escape');
  await options.getByRole('button', {name: tx('saveDefaults'), exact: true}).click();
  await expect.poll(async () => (await calls(page, 'saveSettings')).length).toBeGreaterThan(0);
  await options.getByRole('button', {name: tx('apply'), exact: true}).click();
  await page.getByRole('button', {name: tx('saveTask'), exact: true}).click();
  const task = page.locator('.task-editor-dialog');
  await task.getByLabel(tx('taskName'), {exact: true}).fill('Link-preserving backup');
  await task.getByRole('button', {name: tx('save'), exact: true}).click();
  expect((await calls(page, 'saveTask'))[0].args[1].options.symlinkMode).toBe('preserve');
  await page.locator('.main-nav button').last().click();
  await page.getByRole('button', {name: tx('editTask'), exact: true}).click();
  await task.getByRole('button', {name: tx('modeAndComparison'), exact: true}).click();
  await expect(task.getByTestId('transfer-symlinks')).toHaveValue('preserve');
  expect(await calls(page, 'startTransfer')).toHaveLength(0);
});

async function reportFixture(page: Page, language: Language = 'zh-TW', complete = true) {
  const errors = await open(page, {job: true, settings: {language}});
  await page.evaluate(({complete}) => {
    const w = window as any, fixture = w.__fixture;
    const time = '2026-10-20T12:00:00Z';
    const records = [
      {status: 'info', action: 'configuration', evidence: 'app-configuration', message: '傳輸設定', configuration: {kind: 'complete', schemaVersion: 1, request: {...fixture.job.request, label: 'Sample active-log backup'}, engineVersion: '1.75.2', effectiveModifyWindow: '1s'}},
      {status: 'success', action: 'copy', evidence: 'json-log', path: 'Notes/report.pdf', message: 'Copied (new)', size: 104857600},
      {status: 'success', action: 'copy', evidence: 'json-log', path: 'Notes/report.pdf', message: 'Copied (replaced existing)', size: 209715200},
      {status: 'error', action: 'copy', evidence: 'json-log', path: 'Session/live-log.ab12cd34.partial', relatedPath: 'Session/live-log', issue: 'size-mismatch', sourceSize: 209715200, destinationSize: 314572800, message: 'corrupted on transfer: sizes differ src 209715200 vs dst 314572800'},
      {status: 'error', action: 'copy', evidence: 'json-log', path: 'Session/live-log.ab12cd34.partial', relatedPath: 'Session/live-log', issue: 'source-growing', sourceSize: 314572800, destinationSize: 419430400, message: 'corrupted on transfer: sizes differ src 314572800 vs dst 419430400'},
      {status: 'error', action: 'copy', evidence: 'json-log', path: 'Notes/snapshot.zip', issue: 'size-mismatch', sourceSize: 2048, destinationSize: 1024, message: 'corrupted on transfer: sizes differ src 2048 vs dst 1024'},
      {status: 'error', action: 'cleanup', evidence: 'json-log', path: 'Notes/uncompleted.ab12cd34.partial', issue: 'cleanup-failed', message: 'Failed to remove: Permission denied'},
      {status: 'skipped', action: 'symlink', evidence: 'json-log', path: 'Tools/current', issue: 'symlink-ignored', message: 'Can\'t follow symlink without -L/--copy-links'},
      {status: 'matched', action: 'match', evidence: 'comparison', path: 'Notes/unchanged.pdf', message: 'unchanged'},
      {status: 'info', action: 'retry', evidence: 'json-log', attempt: 3, attemptLimit: 3, message: 'Attempt 3/3 failed with 1 errors'},
    ].map((record, index) => ({sequence: index + 1, time, ...record}));
    fixture.reports['fixture-job'] = records;
    fixture.reportOverrides['fixture-job'] = {formatVersion: 2, copyByteTotalsAvailable: complete, copiedBytes: 314572800, failedCopyBytes: 734004224, sizeMismatchEvents: 3, growingSourceEvents: 1, lastAttempt: 3, maxAttempts: 3, retryFailures: 3, cleanupFailureEvents: 1};
    const job = structuredClone(fixture.job);
    job.status = 'failed'; job.error = 'Failed to sync: corrupted on transfer: sizes differ src 209715200 vs dst 314572800';
    job.stats = {...job.stats, bytes: 1048577024, totalBytes: 1048577024, transfers: 2, totalTransfers: 5, checks: 300, totalChecks: 300, errors: 3, speed: 1048577024 / 60, elapsedTime: 60, transferring: []};
    job.report = fixture.summarizeReport(job.id);
    fixture.bootstrap.jobs = [job]; w.__rbnEvent({type: 'jobUpdate', data: job});
  }, {complete});
  await page.locator('.main-nav button').nth(1).click();
  return errors;
}

for (const language of ['zh-TW', 'en', 'ja'] as const) test(`${language}: report explains retry bytes, source growth and cleanup failures with exact figures and original evidence`, async ({page}, info) => {
  await page.setViewportSize({width: 1060, height: 680});
  const tx = translator(language), errors = await reportFixture(page, language);
  const job = page.getByTestId('job-fixture-job');
  await expect(job.locator(':scope > .notice.error')).toHaveText(tx('sourceGrowingJob'));
  await expect(job.locator('.job-metrics .metric-label').first()).toContainText(tx('processedBytes'));
  await job.locator('.job-details > summary').click();
  await expect(job.locator('.job-byte-summary dd')).toHaveText(['300 MiB314,572,800 B', '700 MiB734,004,224 B', '3 / 3']);
  await job.locator('.job-original-error summary').click();
  await expect(job.locator('.job-original-error pre')).toContainText('sizes differ src 209715200 vs dst 314572800');
  await expect(page.locator('.report-entry')).toHaveCount(10);
  const configuration = page.locator('.report-entry').first();
  await expect(configuration.locator('.report-action')).toHaveText(tx('reportConfigurationDetails'));
  await configuration.locator('details summary').click();
  await expect(configuration.locator('pre')).toContainText('Sample active-log backup');
  await expect(configuration.locator('pre')).toHaveCSS('user-select', 'text');
  await page.locator('.report-tabs button').last().click();
  const growing = page.locator('.report-entry').nth(1);
  await expect(growing.locator('.report-entry-content > p').first()).toHaveText(tx('reportSourceGrowing'));
  await expect(growing.locator('.report-related-path')).toContainText('Session/live-log');
  await expect(growing.locator('.report-size-detail dd')).toHaveText(['300 MiB314,572,800 B', '400 MiB419,430,400 B']);
  await growing.locator('details summary').click();
  await expect(growing.locator('details p')).toContainText('sizes differ src');
  await expect(page.locator('.report-entry').nth(2).locator('.report-entry-content > p').first()).toHaveText(tx('reportSizeMismatch'));
  await expect(page.locator('.report-entry').last().locator('.report-entry-content > p').first()).toHaveText(tx('reportCleanupFailed'));
  await job.locator('.job-byte-summary').scrollIntoViewIfNeeded();
  await page.screenshot({path: info.outputPath(`report-breakdown-${language}.png`), animations: 'disabled'});
  await page.locator('.report-tabs button').nth(2).click();
  await expect(page.locator('.report-entry-content > p').first()).toHaveText(tx('reportSymlinkIgnored'));
  await expect(page.locator('.report-entry').last().locator('.report-entry-content > p').first()).toHaveText(tx('reportSkipCompared').replace('{comparison}', tx('comparisonNAS')));
  expect(errors).toEqual([]);
});

test('an incomplete copy-byte total is omitted and source-growth history cannot replace an unrelated final error', async ({page}) => {
  await reportFixture(page, 'zh-TW', false);
  await page.evaluate(() => {
    const w = window as any, job = structuredClone(w.__fixture.bootstrap.jobs[0]);
    job.error = 'Destination unavailable: Permission denied';
    w.__rbnEvent({type: 'jobUpdate', data: job});
  });
  const job = page.getByTestId('job-fixture-job');
  await expect(job.locator(':scope > .notice.error')).toHaveText('Destination unavailable: Permission denied');
  await job.locator('.job-details > summary').click();
  await expect(job.locator('.job-byte-summary')).not.toContainText(t('copiedBytes'));
  await expect(job.locator('.job-byte-summary')).toContainText(t('failedCopyBytes'));
});
