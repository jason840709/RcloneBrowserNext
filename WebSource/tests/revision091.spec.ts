import {expect, test, type Page} from '@playwright/test';
import {fileURLToPath, pathToFileURL} from 'node:url';
import path from 'node:path';
import {installHostFixture} from './native-fixture';
import {translator} from '../renderer/i18n';
import type {Job, Theme} from '../shared/types';

const url = pathToFileURL(path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../Resources/Web/index.html')).href;
const t = translator('zh-TW');
async function open(page: Page, platform = 'darwin', theme: Theme = 'purple-dark') {
  // Deliver the first job through the event stream; an already-running
  // bootstrap job correctly rejects a later queued snapshot as stale.
  await installHostFixture(page, {platform, job: false, settings: {autoCheckUpdates: false, theme}});
  await page.goto(url);
  await page.getByTestId('left-pane').waitFor();
  await page.locator('.main-nav button').nth(1).click();
}
async function update(page: Page, status: Job['status'], known = false, dry = false) {
  await page.evaluate(({status, known, dry}) => {
    const w = window as any, job = structuredClone(w.__fixture.job);
    job.status = status; job.request.dryRun = dry;
    job.stats.bytes = known ? 25 : 0; job.stats.totalBytes = known ? 100 : 0;
    job.stats.transfers = 0; job.stats.totalTransfers = 0;
    w.__fixture.bootstrap.jobs = [job];
    w.__rbnEvent({type: 'jobUpdate', data: job});
  }, {status, known, dry});
}
const row = (page: Page) => page.getByTestId('job-fixture-job');

for (const theme of ['purple-light','purple-dark','green-light','green-dark','blue-light','blue-dark'] as Theme[]) {
  test(`0.9.1 ${theme}: unknown progress visibly sweeps through its clipping track`, async ({page}, info) => {
    await page.emulateMedia({reducedMotion: 'no-preference'});
    await open(page, 'darwin', theme); await update(page, 'running');
    const track = row(page).getByRole('progressbar'), marker = track.locator('.progress-indicator');
    await expect(marker).toBeVisible(); await expect(track).not.toHaveAttribute('aria-valuenow');
    await expect(track).toHaveAttribute('aria-valuetext', t('scanning'));
    const samples = await marker.evaluate(async element => {
      const result: {transform: string; background: string}[] = [];
      for (let index=0; index<5; index++) {
        result.push({transform:getComputedStyle(element).transform, background:getComputedStyle(element.parentElement!).backgroundImage});
        await new Promise(resolve => setTimeout(resolve, 180));
      }
      return result;
    });
    expect(new Set(samples.map(s => s.transform)).size).toBeGreaterThan(1);
    for (const s of samples) expect(s.background).toBe('none');
    // Redesign: a one-way sweep that the rounded track clips (overflow hidden), instead of a bounce
    // that stayed inside the track. Step the animation to verify it travels across the whole track.
    expect(await marker.evaluate(element => {
      const track = element.parentElement!, box = track.getBoundingClientRect(), animation = element.getAnimations()[0];
      const timing = animation.effect!.getComputedTiming(), duration = Number(timing.duration);
      animation.pause();
      animation.currentTime = 0; const start = element.getBoundingClientRect();
      animation.currentTime = duration / 2; const middle = element.getBoundingClientRect();
      animation.currentTime = duration - 1; const end = element.getBoundingClientRect();
      return {clipped: getComputedStyle(track).overflow === 'hidden', infinite: timing.iterations === Infinity, startsBefore: start.right <= box.left + 1, crosses: middle.right > box.left && middle.left < box.right, endsAfter: end.left >= box.right - 2};
    })).toEqual({clipped: true, infinite: true, startsBefore: true, crosses: true, endsAfter: true});
    await row(page).screenshot({path: info.outputPath(`progress-${theme}.png`)});
  });
}
for (const platform of ['darwin','win32','linux']) {
  test(`0.9.1 ${platform}: progress follows running, measured and terminal states`, async ({page}) => {
    await page.emulateMedia({reducedMotion:'no-preference'}); await open(page, platform);
    await update(page,'queued'); await expect(row(page).locator('.progress-indicator')).toHaveCount(0);
    await expect(row(page).locator('.progress-value')).toHaveText(t('queued'));
    await update(page,'running'); await expect(row(page).locator('.progress-indicator')).toBeVisible();
    await update(page,'running',true); await expect(row(page).locator('.progress-indicator')).toHaveCount(0);
    await expect(row(page).getByRole('progressbar')).toHaveAttribute('aria-valuenow','25');
    for (const state of ['cancelling','cancelled','failed','interrupted','completed'] as Job['status'][]) {
      await update(page,state);
      await expect(row(page).locator('.progress-indicator')).toHaveCount(state==='cancelling'?1:0);
      await expect(row(page).locator('.progress-value')).toHaveText(state==='completed'?'100.0%':t(state));
    }
    await expect(row(page).getByRole('progressbar')).toHaveAttribute('aria-valuenow','100');
  });
}
test('0.9.1 reduced motion keeps a static marker and descriptive state', async ({page}) => {
  await page.emulateMedia({reducedMotion:'reduce'}); await open(page); await update(page,'running');
  const marker = row(page).locator('.progress-indicator'); await expect(marker).toBeVisible();
  const before = await marker.evaluate(e=>({name:getComputedStyle(e).animationName,x:e.getBoundingClientRect().x}));
  await page.waitForTimeout(250);
  expect(await marker.evaluate(e=>({name:getComputedStyle(e).animationName,x:e.getBoundingClientRect().x}))).toEqual(before);
  expect(before.name).toBe('none');
  await expect(row(page).locator('.progress-value')).toHaveText(t('scanning'));
});
test('0.9.1 preview scanning animates, completed preview stops', async ({page}) => {
  await page.emulateMedia({reducedMotion:'no-preference'}); await open(page); await update(page,'running',false,true);
  await expect(row(page).locator('.progress-indicator')).toBeVisible();
  await update(page,'completed',false,true); await expect(row(page).locator('.progress-indicator')).toHaveCount(0);
  await expect(row(page).locator('.job-status')).toHaveText(t('dryCompleted'));
});
for (const platform of ['darwin','win32','linux']) {
  test(`0.9.1 ${platform}: Dock preference is Mac-only and independent of banner permission`, async ({page}) => {
    await open(page,platform); await page.locator('.main-nav button').first().click();
    await page.locator('.app-toolbar').getByRole('button',{name:t('settings'),exact:true}).click();
    await page.locator('.preferences-tabs').getByRole('button',{name:t('appearance'),exact:true}).click();
    const toggle=page.getByRole('checkbox',{name:t('bounceDockOnCompletion'),exact:true});
    if(platform==='darwin') {
      await expect(toggle).toBeChecked(); await toggle.uncheck();
      await expect.poll(()=>page.evaluate(()=>(window as any).__fixture.bootstrap.settings.bounceDockOnCompletion)).toBe(false);
      expect(await page.evaluate(()=>(window as any).__fixture.bootstrap.settings.notifyOnCompletion)).toBe(false);
    } else await expect(toggle).toHaveCount(0);
  });
}
