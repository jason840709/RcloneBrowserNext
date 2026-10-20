import {expect, test, type Page, type Locator} from '@playwright/test';
import {fileURLToPath, pathToFileURL} from 'node:url';
import path from 'node:path';
import {readFileSync} from 'node:fs';
import {installHostFixture} from './native-fixture';
import {translator} from '../renderer/i18n';
import {INTERFACE_SCALES, interfaceScaleZoom} from '../renderer/appearance';
import type {InterfaceScale, Job, Language, Settings, Theme} from '../shared/types';

const t = translator('zh-TW');
const directory = path.dirname(fileURLToPath(import.meta.url));
const url = pathToFileURL(path.resolve(directory, '../../Resources/Web/index.html')).href;
const activeStatuses = ['running', 'queued', 'cancelling'];
const themes: Theme[] = ['purple-dark','purple-light','blue-dark','blue-light','green-dark','green-light'];

async function open(page: Page, options: Parameters<typeof installHostFixture>[1] = {}) {
  const errors: string[] = [];
  page.on('pageerror', error => errors.push(error.message));
  await installHostFixture(page, {...options, settings: {autoCheckUpdates: false, theme: 'purple-dark', ...options.settings}});
  await page.goto(url);
  await expect(page.getByTestId('left-pane').locator('.file-name').first()).toBeVisible();
  await expect(page.getByTestId('right-pane').locator('.file-name').first()).toBeVisible();
  return errors;
}
async function settings(page: Page, language: Language = 'zh-TW') {
  await page.locator('.workspace-title > .icon-button').click();
  const dialog=page.locator('.settings-dialog');
  await dialog.getByRole('button',{name:translator(language)('appearance'),exact:true}).click();
  return dialog;
}
async function calls(page: Page, method: string): Promise<any[]> {
  return page.evaluate(method => (window as any).__fixture.calls.filter((entry:any) => entry.method === method), method);
}
async function saved(page: Page): Promise<Settings> {
  return page.evaluate(() => (window as any).__fixture.bootstrap.settings);
}
async function reachable(locator: Locator) {
  await locator.scrollIntoViewIfNeeded();
  await expect(locator).toBeVisible();
  expect(await locator.evaluate(element => {
    const r=element.getBoundingClientRect(); const hit=document.elementFromPoint(r.x+r.width/2,r.y+r.height/2);
    return {inside:r.left>=0&&r.top>=0&&r.right<=innerWidth+1&&r.bottom<=innerHeight+1, hit:hit===element||element.contains(hit)};
  })).toEqual({inside:true,hit:true});
}
async function mockNativeZoom(page: Page, initial: InterfaceScale=100) {
  const resize=async(scale: InterfaceScale) => page.setViewportSize({width:Math.floor(1060/interfaceScaleZoom(scale)),height:Math.floor(680/interfaceScaleZoom(scale))});
  await resize(initial);
  // This host-only callback emulates WKWebView.pageZoom by changing CSS viewport.
  // The production app does not contain or invoke it.
  await page.exposeFunction('__testNativeScale',resize);
}
async function jobIds(page: Page) {
  return page.locator('.jobs-page .job-row').evaluateAll(rows => rows.map(row=>row.getAttribute('data-testid')!.slice(4)).sort());
}
async function seedJobs(page: Page, statuses: Job['status'][] = ['running','queued','completed','failed','cancelled','interrupted']) {
  await page.evaluate(statuses => {
    const w=window as any;
    w.__fixture.bootstrap.jobs=statuses.map((status,index) => {
      const job=structuredClone(w.__fixture.job); job.id=`sample-${status}`;job.status=status;
      job.request.label=`Sample ${status}`;job.createdAt=`2026-10-20T10:00:0${index}Z`;
      if (status==='queued') delete job.startedAt;
      if (!['running','queued','cancelling'].includes(status)) job.endedAt='2026-10-20T10:01:00Z';
      w.__rbnEvent({type:'jobUpdate',data:job});return job;
    });
  },statuses);
  await page.locator('.main-nav button').nth(1).click();
  await expect(page.locator('.jobs-page .job-row')).toHaveCount(statuses.length);
}
async function addJob(page: Page, id: string, status: Job['status']) {
  await page.evaluate(({id,status}) => {const w=window as any,j=structuredClone(w.__fixture.job);j.id=id;j.status=status;j.request.label=id;w.__fixture.bootstrap.jobs.push(j);w.__rbnEvent({type:'jobUpdate',data:j});},{id,status});
}

for(const language of ['zh-TW','en','ja'] as const) test(`${language}: five interface sizes save immediately through native host, with 100 percent in the middle`, async ({page,browser},info) => {
  await mockNativeZoom(page);
  const errors=await open(page,{settings:{language,interfaceScale:100}});const tx=translator(language),dialog=await settings(page,language);
  const radios=dialog.getByRole('radiogroup',{name:tx('interfaceScale')}).getByRole('radio');
  await expect(radios).toHaveCount(5);await expect(radios.nth(2)).toBeChecked();await expect(radios.nth(2)).toHaveAccessibleName(`100% ${tx('defaultScale')}`);
  for(const scale of INTERFACE_SCALES) {
    await dialog.locator(`.interface-scale-picker input[value="${scale}"]`).locator('..').click();
    await expect(dialog.locator(`.interface-scale-picker input[value="${scale}"]`)).toBeChecked();
    await expect.poll(async()=>(await saved(page)).interfaceScale).toBe(scale);
    await expect.poll(()=>page.viewportSize()).toEqual({width:Math.floor(1060/interfaceScaleZoom(scale)),height:Math.floor(680/interfaceScaleZoom(scale))});
    await reachable(dialog.locator('.dialog-footer button').last());
    expect(await page.evaluate(()=>({zoom:getComputedStyle(document.documentElement).zoom,font:getComputedStyle(document.documentElement).fontSize,overflow:document.documentElement.scrollWidth>innerWidth,transform:getComputedStyle(document.querySelector('.app-shell')!).transform}))).toEqual({zoom:'1',font:'14px',overflow:false,transform:'none'});
  }
  await page.screenshot({path:info.outputPath(`scale-${language}-125.png`),animations:'disabled'});
  expect((await calls(page,'saveSettings')).map(call=>call.args[0])).toEqual(INTERFACE_SCALES.map(interfaceScale=>({interfaceScale})));
  const value=await saved(page),next=await browser.newPage();await mockNativeZoom(next,125);await open(next,{settings:value});const restored=await settings(next,language);
  await expect(restored.locator('.interface-scale-picker input[value="125"]')).toBeChecked();await next.close();expect(errors).toEqual([]);
});

test('scale keyboard selection and rapid edits survive save rejection without applying CSS zoom', async ({page}) => {
  await mockNativeZoom(page);await open(page);const dialog=await settings(page);
  await dialog.locator('.interface-scale-picker input[value="100"]').focus();await page.keyboard.press('ArrowRight');await expect.poll(async()=>(await saved(page)).interfaceScale).toBe(110);
  await page.evaluate(()=>{(window as any).__fixture.rejectSave=true;});await dialog.locator('.interface-scale-picker input[value="125"]').locator('..').click();
  await expect(dialog.getByRole('alert')).toContainText('Settings rejected');await expect(dialog.locator('.interface-scale-picker input[value="110"]')).toBeChecked();
  await page.evaluate(()=>{const w=window as any;w.__fixture.delays.saveSettings=[120,2];});
  await dialog.locator('.interface-scale-picker').evaluate(group=>{(group.querySelector('input[value="80"]') as HTMLInputElement).click();(group.querySelector('input[value="100"]') as HTMLInputElement).click();});
  await expect.poll(async()=>(await saved(page)).interfaceScale).toBe(100);await expect.poll(()=>page.viewportSize()).toEqual({width:1177,height:755});await expect(dialog.locator('.interface-scale-picker input[value="100"]')).toBeChecked();
  expect((await calls(page,'saveSettings')).map(call=>call.args[0])).toEqual([{interfaceScale:110},{interfaceScale:125},{interfaceScale:80},{interfaceScale:100}]);
});

for(const language of ['zh-TW','en','ja'] as const) test(`${language}: all six themes change the brand icon, Next text and native setting together`, async ({page}) => {
  const errors=await open(page,{settings:{language}}),dialog=await settings(page,language);
  await expect(dialog.locator('.theme-option')).toHaveCount(6);
  for(const theme of themes) {
    await dialog.locator(`.swatch-${theme}`).click();await expect(page.locator('html')).toHaveAttribute('data-theme',theme);
    const family=theme.split('-')[0],icon=family==='purple'?'favicon.svg':`favicon-${family}.svg`;
    await expect(page.locator('.brand img')).toHaveAttribute('src',icon);await expect(page.locator('link[rel="icon"]')).toHaveAttribute('href',icon);
    await expect.poll(async()=>(await saved(page)).theme).toBe(theme);
    const rendered=await page.evaluate(()=>{const root=getComputedStyle(document.documentElement),next=document.querySelector('.brand em')||document.querySelector('.brand b')||document.querySelector('.brand strong');const canvas=document.createElement('canvas').getContext('2d')!;const color=(v:string)=>{canvas.fillStyle=v;return canvas.fillStyle;};return{icon:(document.querySelector('.brand img') as HTMLImageElement).naturalWidth,accent:color(root.getPropertyValue('--accent')),next:next?color(getComputedStyle(next).color):null,neutral:['bg','toolbar','surface','surface-raised','row-stripe'].map(k=>color(root.getPropertyValue('--'+k)))};});
    expect(rendered.icon).toBeGreaterThan(0);expect(rendered.next).toBe(rendered.accent);
    for(const hex of rendered.neutral){const value=hex.slice(1);expect(value.slice(0,2)).toBe(value.slice(2,4));expect(value.slice(2,4)).toBe(value.slice(4,6));}
  }
  expect(errors).toEqual([]);
});

test('a rejected color change restores the saved brand icon and accent',async({page})=>{
  await open(page,{settings:{theme:'green-dark'}});const dialog=await settings(page);await page.evaluate(()=>{(window as any).__fixture.rejectSave=true;});await dialog.locator('.swatch-blue-light').click();
  await expect(dialog.getByRole('alert')).toContainText('Settings rejected');await expect(page.locator('html')).toHaveAttribute('data-theme','green-dark');await expect(page.locator('.brand img')).toHaveAttribute('src','favicon-green.svg');
});

for(const language of ['zh-TW','en','ja'] as const) for(const theme of ['green-dark','green-light'] as const) test(`${language} ${theme}: 125 percent at the minimum native window keeps panes, settings, transfer and task actions reachable`, async ({page},info) => {
  await mockNativeZoom(page,125);const tx=translator(language),errors=await open(page,{job:true,settings:{theme,language,interfaceScale:125}});
  for(const selector of ['.start-button','.dry-run-button','.options-button','.direction-picker button:first-child','.direction-picker button:last-child']) await reachable(page.locator(selector));
  for(const side of ['left','right']) {const pane=page.getByTestId(`${side}-pane`);await reachable(pane.locator('.path-form input'));await reachable(pane.getByRole('button',{name:tx('newTab'),exact:true}));}
  await page.locator('.options-button').click();const options=page.locator('.options-dialog');
  for(const tab of ['modeAndComparison','transferPerformance','filtersTab'] as const){await options.getByRole('button',{name:tx(tab),exact:true}).click();await reachable(options.getByRole('button',{name:tx('apply'),exact:true}));await reachable(options.locator('.options-content input,.options-content select,.options-content textarea').last());expect(await options.evaluate(e=>e.scrollWidth<=e.clientWidth+1)).toBe(true);}
  await options.getByRole('button',{name:tx('cancel'),exact:true}).click();
  const preferences=await settings(page,language);await reachable(preferences.locator('.swatch-green-dark'));await reachable(preferences.locator('.swatch-green-light'));await reachable(preferences.getByRole('checkbox',{name:tx('notifyOnCompletion'),exact:true}));await reachable(preferences.locator('.dialog-footer button').last());await preferences.locator('.dialog-footer button').last().click();
  await page.getByRole('button',{name:tx('saveTask'),exact:true}).click();const editor=page.locator('.task-editor-dialog');await editor.getByLabel(tx('taskName'),{exact:true}).fill('Sample backup');
  for(const tab of ['locationsTab','modeAndComparison','transferPerformance','filtersTab'] as const){await editor.getByRole('button',{name:tx(tab),exact:true}).click();await reachable(editor.getByRole('button',{name:tx('save'),exact:true}));await reachable(editor.getByRole('button',{name:tx('cancel'),exact:true}));expect(await editor.evaluate(e=>e.scrollWidth<=e.clientWidth+1)).toBe(true);}
  await page.screenshot({path:info.outputPath('task-editor-125.png'),animations:'disabled'});await editor.getByRole('button',{name:tx('save'),exact:true}).click();await page.locator('.main-nav button').last().click();
  for(const key of ['runTask','dryRun','editTask','delete'] as const)await reachable(page.locator('.tasks-page').getByRole('button',{name:tx(key),exact:true}));
  expect(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true);expect(errors).toEqual([]);
});

test('Finished trash clears all ended statuses without stopping active jobs or opening a confirmation', async ({page})=>{
  await open(page);await seedJobs(page);const jobs=page.locator('.jobs-page');await jobs.getByRole('button',{name:t('history'),exact:true}).click();await jobs.getByRole('button',{name:t('clearFinished'),exact:true}).click();
  await expect(jobs.locator('.job-row')).toHaveCount(0);await expect(page.locator('.clear-jobs-dialog')).toHaveCount(0);
  expect((await calls(page,'clearJobs')).map(c=>({...c.args[0],ids:[...c.args[0].ids].sort()}))).toEqual([{ids:['sample-cancelled','sample-completed','sample-failed','sample-interrupted'],mode:'finished'}]);
  await jobs.getByRole('button',{name:t('all'),exact:true}).click();expect(await jobIds(page)).toEqual(['sample-queued','sample-running']);expect(await calls(page,'cancelJob')).toHaveLength(0);
});

for(const filter of ['all','active'] as const)test(`${filter}: cancellation leaves every record unchanged, and completed-only excludes failed, stopped and newly arrived jobs`,async({page})=>{
  await open(page);await seedJobs(page);const jobs=page.locator('.jobs-page');await jobs.getByRole('button',{name:t(filter),exact:true}).click();await jobs.getByRole('button',{name:t('clearJobs'),exact:true}).click();const dialog=page.locator('.clear-jobs-dialog');
  await expect(dialog).toContainText(t('clearJobsStopHint'));await dialog.getByRole('button',{name:t('cancel'),exact:true}).click();expect(await calls(page,'clearJobs')).toHaveLength(0);
  await jobs.getByRole('button',{name:t('clearJobs'),exact:true}).click();await addJob(page,'new-completed','completed');await dialog.getByRole('button',{name:new RegExp('^'+t('clearCompletedOnly'))}).click();await expect(dialog).toHaveCount(0);
  expect((await calls(page,'clearJobs')).at(-1).args[0]).toEqual({ids:['sample-completed'],mode:'finished'});await jobs.getByRole('button',{name:t('all'),exact:true}).click();expect(await jobIds(page)).toEqual(['new-completed','sample-cancelled','sample-failed','sample-interrupted','sample-queued','sample-running']);
});

test('completed-only is disabled when there are no green completed records',async({page})=>{
  await open(page);await seedJobs(page,['running','failed','cancelled']);await page.locator('.jobs-page').getByRole('button',{name:t('clearJobs'),exact:true}).click();const choice=page.locator('.clear-jobs-dialog').getByRole('button',{name:new RegExp('^'+t('clearCompletedOnly'))});await expect(choice).toBeDisabled();await expect(choice.locator('.clear-choice-count')).toHaveText('0');expect(await calls(page,'clearJobs')).toHaveLength(0);
});

for(const filter of ['all','active'] as const)test(`${filter}: stop-and-clear retains stopping rows until exit, snapshots scope, and rejects late resurrecting events`,async({page},info)=>{
  await open(page);await seedJobs(page);const jobs=page.locator('.jobs-page');await jobs.getByRole('button',{name:t(filter),exact:true}).click();
  await page.evaluate(()=>{(window as any).__fixture.bulkStopDelay=1100;});await jobs.getByRole('button',{name:t('clearJobs'),exact:true}).click();const dialog=page.locator('.clear-jobs-dialog');await addJob(page,'new-running','running');
  await dialog.getByRole('button',{name:t('stopAndClear'),exact:true}).click();await expect(dialog).toContainText(t('stoppingJobs'));await expect(jobs.getByTestId('job-sample-running')).toHaveClass(/job-cancelling/);await expect(jobs.getByTestId('job-sample-queued')).toHaveClass(/job-cancelling/);await expect(dialog.getByRole('button',{name:t('cancel'),exact:true})).toBeDisabled();await expect(dialog.getByRole('button',{name:t('close'),exact:true})).toBeDisabled();
  await page.keyboard.press('Escape');await expect(dialog).toBeVisible();await page.screenshot({path:info.outputPath('stopping.png'),animations:'disabled'});await expect(dialog).toHaveCount(0);await jobs.getByRole('button',{name:t('all'),exact:true}).click();
  const expected=filter==='all'?['new-running']:['new-running','sample-cancelled','sample-completed','sample-failed','sample-interrupted'];expect(await jobIds(page)).toEqual(expected);
  const request=(await calls(page,'clearJobs')).at(-1).args[0];expect({...request,ids:[...request.ids].sort()}).toEqual({ids:filter==='all'?['sample-cancelled','sample-completed','sample-failed','sample-interrupted','sample-queued','sample-running']:['sample-queued','sample-running'],mode:'stop-and-clear'});expect(await calls(page,'clearJobs')).toHaveLength(1);
  await page.evaluate(()=>{const w=window as any;for(const status of ['running','cancelled']){const old=structuredClone(w.__fixture.job);old.id='sample-running';old.status=status;w.__rbnEvent({type:'jobUpdate',data:old});}});await page.waitForTimeout(60);expect(await jobIds(page)).toEqual(expected);
});

test('bulk stop failure can be retried; acknowledged retention and forced stopping remain visible',async({page})=>{
  await open(page);await seedJobs(page,['running','queued','completed']);await page.evaluate(()=>{(window as any).__fixture.bulkError='Could not stop sample worker';});const jobs=page.locator('.jobs-page');await jobs.getByRole('button',{name:t('clearJobs'),exact:true}).click();const dialog=page.locator('.clear-jobs-dialog');await dialog.getByRole('button',{name:t('stopAndClear'),exact:true}).click();await expect(dialog.getByRole('alert')).toContainText('Could not stop sample worker');expect(await jobIds(page)).toEqual(['sample-completed','sample-queued','sample-running']);
  await page.evaluate(()=>{const f=(window as any).__fixture;f.bulkError='';f.bulkRetainIds=['sample-queued'];f.forcedStopIds=['sample-running'];});await dialog.getByRole('button',{name:t('stopAndClear'),exact:true}).click();await expect(dialog).toHaveCount(0);expect(await jobIds(page)).toEqual(['sample-queued']);await expect(page.locator('.floating-notice')).toContainText(t('forcedStopHint'));expect(await calls(page,'clearJobs')).toHaveLength(2);
});

test('a new progress event keeps more than 200 interrupted jobs available for manual recovery',async({page})=>{
  await open(page);
  await page.evaluate(()=>{const w=window as any;w.__fixture.bootstrap.jobs=Array.from({length:220},(_,index)=>({...structuredClone(w.__fixture.job),id:`interrupted-${index}`,status:'interrupted',createdAt:'2026-10-19T00:00:00Z'}));w.__rbnEvent({type:'configurationChanged'});});
  await page.locator('.main-nav button').nth(1).click();await expect(page.locator('.jobs-page .job-row')).toHaveCount(220);await addJob(page,'new-running','running');await expect(page.locator('.jobs-page .job-row')).toHaveCount(221);await expect(page.locator('.jobs-page .job-interrupted')).toHaveCount(220);
});

for(const language of ['zh-TW','en','ja'] as const)test(`${language}: stopping confirmation fits 125 percent, and a stopped job describes retained changes and destination-dependent partial cleanup`,async({page})=>{
  await mockNativeZoom(page,125);const tx=translator(language);await open(page,{settings:{language,interfaceScale:125,theme:'green-dark'}});await seedJobs(page,['running','completed']);await page.locator('.jobs-page').getByRole('button',{name:tx('clearJobs'),exact:true}).click();const dialog=page.locator('.clear-jobs-dialog');
  for(const key of ['stopAndClear','clearCompletedOnly','cancel'] as const)await reachable(dialog.getByRole('button',{name:key==='clearCompletedOnly'?new RegExp('^'+tx(key)):tx(key),exact:key!=='clearCompletedOnly'}));await dialog.getByRole('button',{name:tx('cancel'),exact:true}).click();
  await page.evaluate(()=>{const w=window as any,j=structuredClone(w.__fixture.job);j.id='normal-stop';j.status='cancelled';j.cancellation={requestedAt:'2026-10-20T10:00:00Z',forced:false,lastSignal:'SIGINT',processExited:true};w.__rbnEvent({type:'jobUpdate',data:j});});const row=page.getByTestId('job-normal-stop');await expect(row.locator('.job-status')).toHaveText(tx('stopped'));await expect(row.locator('.notice')).toHaveText(tx('stoppedJobHint'));
});

test('blue and green icons preserve canonical v2 vector geometry and contain valid complete ICNS representation lengths',()=>{
  const canonical=readFileSync(path.resolve(directory,'../assets/icons/canonical-small.svg'),'utf8');
  const geometry=(svg:string)=>svg.replace(/<title\b[^>]*>[\s\S]*?<\/title>/g,'').replace(/#[0-9a-f]{6}/gi,'#PAINT').replace(/>\s+</g,'><').trim();
  for(const family of ['blue','green']){
    const variant=readFileSync(path.resolve(directory,`../renderer/favicon-${family}.svg`),'utf8');expect(geometry(variant)).toBe(geometry(canonical));
    const data=readFileSync(path.resolve(directory,`../../Resources/AppIcon-${family}.icns`));expect(data.toString('ascii',0,4)).toBe('icns');expect(data.readUInt32BE(4)).toBe(data.length);let offset=8;const reps:string[]=[];
    while(offset<data.length){const size=data.readUInt32BE(offset+4);expect(size).toBeGreaterThan(8);reps.push(data.toString('ascii',offset,offset+4));expect(data.subarray(offset+8,offset+16)).toEqual(Buffer.from([137,80,78,71,13,10,26,10]));offset+=size;}
    expect(offset).toBe(data.length);expect(reps.sort()).toEqual(['icp4','icp5','icp6','ic07','ic08','ic09','ic10','ic11','ic12','ic13','ic14'].sort());
  }
});
