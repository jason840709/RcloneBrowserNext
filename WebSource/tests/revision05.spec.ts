import {expect, test, type Page} from '@playwright/test';
import {fileURLToPath, pathToFileURL} from 'node:url';
import path from 'node:path';
import {installHostFixture, selectPlace} from './native-fixture';
import {translator} from '../renderer/i18n';
import {DEFAULT_OPTIONS, type Settings} from '../shared/types';
import {MAC_EXCLUDES} from '../renderer/presets';
const t = translator('zh-TW');
const url = pathToFileURL(path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../Resources/Web/index.html')).href;
async function open(page: Page, options: Parameters<typeof installHostFixture>[1] = {}) {
  const errors: string[] = []; page.on('pageerror', error => errors.push(error.message));
  await installHostFixture(page, {settings: {autoCheckUpdates: false, theme: 'purple-dark'}, ...options}); await page.goto(url);
  await expect(page.getByTestId('left-pane').locator('.file-name').first()).toBeVisible();
  await expect(page.getByTestId('right-pane').locator('.file-name').first()).toBeVisible();
  return errors;
}
async function calls(page: Page, method: string): Promise<any[]> {return page.evaluate(method => (window as any).__fixture.calls.filter((entry:any) => entry.method === method), method);}
async function state(page: Page): Promise<Settings> {return page.evaluate(() => (window as any).__fixture.bootstrap.settings);}
async function navigate(page: Page, side: 'left'|'right', value: string) {const input=page.getByLabel(`${t(side)} ${t('path')}`,{exact:true});await input.fill(value);await input.press('Enter');await expect(page.getByTestId(`${side}-pane`).locator('.file-name').first()).toBeVisible();}
async function preset(page: Page, name: string) {await page.getByTestId('operation-picker').click();await page.getByRole('menuitemradio',{name:new RegExp('^'+name.replace(/[.*+?^${}()|[\]\\]/g,'\\$&'))}).click();}
async function nativeHistory(page: Page, side: 'left'|'right', direction: 'back'|'forward') {const box=await page.getByTestId(`${side}-pane`).boundingBox();await page.evaluate(data=>(window as any).__rbnEvent({type:'navigateHistory',data}),{direction,x:box!.x+20,y:box!.y+20});}

test('empty Tasks has one contained prompt and no phantom selected task or execution controls', async ({page},info) => {
  await open(page); await page.locator('.main-nav button').last().click();
  const tasks=page.locator('.tasks-page');await expect(tasks.getByRole('heading',{name:t('noTasks')})).toBeVisible();
  await expect(tasks.locator('.task-table,.task-list-footer,.task-primary-actions')).toHaveCount(0);
  for(const name of ['runTask','dryRun','editTask','delete','exportTasks'] as const) await expect(tasks.getByRole('button',{name:t(name),exact:true})).toHaveCount(0);
  await expect(tasks.locator('.status-card button')).toHaveText(t('newTask'));
  await page.screenshot({path:info.outputPath('empty-tasks.png')});
  await tasks.locator('.status-card button').click();const editor=page.locator('.task-editor-dialog');await editor.getByLabel(t('taskName'),{exact:true}).fill('New backup');await editor.getByRole('button',{name:t('save'),exact:true}).click();
  await expect(tasks.locator('.task-table tbody tr')).toHaveCount(1);await expect(tasks.locator('.task-primary-actions')).toBeVisible();
  await tasks.getByRole('button',{name:t('delete'),exact:true}).click();await page.getByRole('dialog').getByRole('button',{name:t('delete'),exact:true}).click();
  await expect(tasks.locator('.task-list-footer')).toHaveCount(0);await expect(tasks.getByRole('heading',{name:t('noTasks')})).toBeVisible();expect(await calls(page,'startTransfer')).toHaveLength(0);
});

test('initial directory failure keeps icon, title, long diagnostic and Retry within one scrollable card', async ({page},info) => {
  await installHostFixture(page,{settings:{autoCheckUpdates:false,theme:'purple-dark'}});
  await page.addInitScript(()=>{(window as any).__fixture.listingError='Sample cloud session expired. Reconnect the sample account.\n'.repeat(18);});
  await page.goto(url);
  const pane=page.getByTestId('right-pane');const card=pane.locator('.status-card-error');await expect(card).toContainText('Sample cloud session expired');
  await expect(card.getByRole('heading',{name:t('cannotBrowse')})).toBeVisible();await expect(card.locator('.empty-icon')).toBeVisible();await expect(card.getByRole('button',{name:t('retry')})).toHaveCount(1);
  expect(await pane.locator('.file-list').evaluate(e=>getComputedStyle(e).backgroundImage)).toBe('none');
  const bounds=await card.evaluate(e=>{const p=e.parentElement!.getBoundingClientRect(),c=e.getBoundingClientRect();return{inside:c.x>=p.x&&c.right<=p.right&&c.y>=p.y&&c.bottom<=p.bottom,bg:getComputedStyle(e).backgroundColor};});expect(bounds.inside).toBe(true);expect(bounds.bg).not.toBe('rgba(0, 0, 0, 0)');
  await card.getByRole('button',{name:t('retry')}).scrollIntoViewIfNeeded();await page.screenshot({path:info.outputPath('contained-error.png')});
  await page.evaluate(()=>{(window as any).__fixture.listingError='';});await card.getByRole('button',{name:t('retry')}).click();await expect(pane.locator('.file-name').first()).toBeVisible();await expect(card).toHaveCount(0);
});

test('success toast floats without moving panes, closes with motion, and dismisses after five seconds', async ({page},info) => {
  await page.emulateMedia({reducedMotion:'no-preference'});await open(page);const before=await page.getByTestId('left-pane').boundingBox();
  await page.getByRole('button',{name:t('rememberWorkspace'),exact:true}).click();const toast=page.locator('.floating-notice');await expect(toast).toContainText(t('workspaceRemembered'));await expect(toast).toHaveAttribute('data-visible','true');
  expect(await page.getByTestId('left-pane').boundingBox()).toEqual(before);expect(await toast.evaluate(e=>getComputedStyle(e).position)).toBe('fixed');expect(await toast.evaluate(e=>getComputedStyle(e).transitionProperty)).toContain('transform');
  await page.screenshot({path:info.outputPath('floating-success.png')});await toast.getByRole('button',{name:t('close')}).click();await expect(toast).toHaveAttribute('data-visible','false');await expect(toast).toHaveCount(0);
  expect(await page.getByTestId('left-pane').boundingBox()).toEqual(before);
  await page.getByRole('button',{name:t('rememberWorkspace'),exact:true}).click();await expect(toast).toBeVisible();await page.mouse.move(0,0);await expect(toast).toHaveCount(0,{timeout:6500});expect(await page.getByTestId('left-pane').boundingBox()).toEqual(before);
});

test('reduced-motion toast fades without translating and can be replaced before an old dismissal', async ({page}) => {
  await open(page);await page.getByRole('button',{name:t('rememberWorkspace'),exact:true}).click();const toast=page.locator('.floating-notice');await expect(toast).toBeVisible();expect(await toast.evaluate(e=>getComputedStyle(e).transform)).toBe('none');
  await toast.getByRole('button',{name:t('close')}).evaluate((button:HTMLButtonElement)=>{button.click();button.click();});
  await page.getByRole('button',{name:t('rememberWorkspace'),exact:true}).click();await expect(toast).toHaveAttribute('data-visible','true');await page.waitForTimeout(260);await expect(toast).toHaveAttribute('data-visible','true');
});

test('new default sync choices are unlimited, during-transfer deletion, and size-time without local hashes', async ({page}) => {
  await open(page);await page.locator('.options-button').click();const d=page.locator('.options-dialog');await expect(d.getByTestId('transfer-comparison')).toHaveValue('nas');await d.getByRole('button',{name:t('sync'),exact:true}).click();
  await expect(d.getByRole('checkbox',{name:t('unlimitedJobs'),exact:true})).toBeChecked();await expect(d.getByLabel(t('deleteMode'),{exact:true})).toHaveValue('during');await expect(d).toContainText(t('syncHint'));
  await d.getByRole('button',{name:t('apply'),exact:true}).click();await page.locator('.dry-run-button').click();const request=(await calls(page,'startTransfer')).at(-1).args[0];expect(request).toMatchObject({mode:'sync',dryRun:true,options:{maxDelete:-1,deleteMode:'during',comparison:'default',localHashPolicy:'none'}});
});

for(const [id,label,transfers,checkers]of [['local-nas','presetLocalNAS',1,10],['nas-cloud','presetNASCloud',7,10],['local-cloud','presetLocalCloud',7,10]]as const) {
 test(`${id} preset keeps locations, resets skip rules, uses explicit single-direction sync and never auto-runs`,async({page})=>{
  await open(page,{settings:{autoCheckUpdates:false,defaultTransferOptions:{...DEFAULT_OPTIONS,skipExisting:true,updateOnly:true,comparison:'checksum',exclude:['*.private'],maxDelete:9}}});
  const left=await page.getByLabel(`${t('left')} ${t('path')}`,{exact:true}).inputValue();const right=await page.getByLabel(`${t('right')} ${t('path')}`,{exact:true}).inputValue();
  await preset(page,t(label));await expect(page.locator('.start-button')).toHaveText(t('startSync'));expect(await calls(page,'startTransfer')).toHaveLength(0);
  expect(await page.getByLabel(`${t('left')} ${t('path')}`,{exact:true}).inputValue()).toBe(left);expect(await page.getByLabel(`${t('right')} ${t('path')}`,{exact:true}).inputValue()).toBe(right);
  await page.locator('.command-button').click();await expect(page.locator('.command-output')).toBeVisible();const request=(await calls(page,'previewTransfer')).at(-1).args[0];expect(request).toMatchObject({direction:'lr',mode:'sync',options:{transfers,checkers,comparison:'default',localHashPolicy:'none',maxDelete:-1,deleteMode:'during',skipExisting:false,updateOnly:false,exclude:MAC_EXCLUDES,extraArgs:id==='local-nas'?['--multi-thread-streams=0']:[]}});
 });
}

test('preset hiding persists, does not alter the applied request, and Restore changes only menu visibility', async ({page,browser},info) => {
  await open(page);await preset(page,t('presetLocalNAS'));await page.getByTestId('operation-picker').click();await page.screenshot({path:info.outputPath('preset-menu.png')});await page.getByRole('menuitem',{name:`${t('hidePreset')} ${t('presetLocalNAS')}`,exact:true}).click();await expect.poll(async()=>(await state(page)).hiddenBuiltinPresets).toEqual(['local-nas']);
  await expect(page.getByRole('menuitemradio',{name:new RegExp('^'+t('presetLocalNAS'))})).toHaveCount(0);await page.keyboard.press('Escape');
  const saved=await state(page), next=await browser.newPage();await open(next,{settings:saved});await next.getByTestId('operation-picker').click();await expect(next.getByRole('menuitemradio',{name:new RegExp('^'+t('presetLocalNAS'))})).toHaveCount(0);await next.close();
  await page.locator('.options-button').click();const d=page.locator('.options-dialog');await d.getByRole('button',{name:t('restorePresets'),exact:true}).click();await expect.poll(async()=>(await state(page)).hiddenBuiltinPresets).toEqual([]);await d.getByRole('button',{name:t('apply'),exact:true}).click();
  await page.locator('.command-button').click();await expect(page.locator('.command-output')).toBeVisible();expect((await calls(page,'previewTransfer')).at(-1).args[0].options).toMatchObject({transfers:1,checkers:10,extraArgs:['--multi-thread-streams=0']});expect(await calls(page,'startTransfer')).toHaveLength(0);
});

test('native side buttons navigate the pane under the pointer and preserve independent forward history per tab', async ({page}) => {
  const errors=await open(page);await navigate(page,'left','/Users/test/A');await navigate(page,'left','/Users/test/B');await navigate(page,'right','RemoteFolder');
  await nativeHistory(page,'left','back');await expect(page.getByLabel(`${t('left')} ${t('path')}`,{exact:true})).toHaveValue('/Users/test/A');await expect(page.getByLabel(`${t('right')} ${t('path')}`,{exact:true})).toHaveValue('RemoteFolder');
  const pane=page.getByTestId('left-pane');await pane.getByRole('button',{name:t('newTab'),exact:true}).click();await expect(pane.getByRole('button',{name:t('forward'),exact:true})).toBeDisabled();await navigate(page,'left','/Users/test/C');await nativeHistory(page,'left','back');await pane.getByRole('tab').first().click();
  await nativeHistory(page,'left','forward');await expect(page.getByLabel(`${t('left')} ${t('path')}`,{exact:true})).toHaveValue('/Users/test/B');await pane.getByRole('tab').last().click();await nativeHistory(page,'left','forward');await expect(page.getByLabel(`${t('left')} ${t('path')}`,{exact:true})).toHaveValue('/Users/test/C');
  await nativeHistory(page,'left','back');await navigate(page,'left','/Users/test/D');await expect(pane.getByRole('button',{name:t('forward'),exact:true})).toBeDisabled();await nativeHistory(page,'left','forward');await expect(page.getByLabel(`${t('left')} ${t('path')}`,{exact:true})).toHaveValue('/Users/test/D');expect(errors).toEqual([]);
});

test('DOM side-button fallback fires once despite a legacy native flag, and a dialog blocks navigation', async ({page}) => {
  await open(page);await navigate(page,'left','/Users/test/A');await navigate(page,'left','/Users/test/B');
  const dispatch=async(button:number)=>page.getByTestId('left-pane').evaluate((pane,button)=>{const r=pane.getBoundingClientRect();return ['mousedown','mouseup','auxclick'].map(type=>{const e=new MouseEvent(type,{button,clientX:r.x+30,clientY:r.y+50,bubbles:true,cancelable:true});pane.dispatchEvent(e);return e.defaultPrevented;});},button);
  expect(await dispatch(3)).toEqual([true,true,true]);await expect(page.getByLabel(`${t('left')} ${t('path')}`,{exact:true})).toHaveValue('/Users/test/A');await dispatch(4);await expect(page.getByLabel(`${t('left')} ${t('path')}`,{exact:true})).toHaveValue('/Users/test/B');
  await page.evaluate(()=>{window.__rbnNativeHistory=true;});await dispatch(3);await expect(page.getByLabel(`${t('left')} ${t('path')}`,{exact:true})).toHaveValue('/Users/test/A');await dispatch(4);await expect(page.getByLabel(`${t('left')} ${t('path')}`,{exact:true})).toHaveValue('/Users/test/B');
  await page.locator('.options-button').click();await nativeHistory(page,'left','back');await expect(page.getByLabel(`${t('left')} ${t('path')}`,{exact:true})).toHaveValue('/Users/test/B');await page.locator('.options-dialog').getByRole('button',{name:t('cancel'),exact:true}).click();
  await nativeHistory(page,'left','back');await expect(page.getByLabel(`${t('left')} ${t('path')}`,{exact:true})).toHaveValue('/Users/test/A');
});

test('keyboard back and forward use active pane and keep edited text in inputs untouched', async ({page})=>{
  await open(page);await navigate(page,'left','/Users/test/A');await navigate(page,'left','/Users/test/B');await page.getByTestId('left-pane').locator('.pane-side').click();await page.keyboard.press('Control+[');await expect(page.getByLabel(`${t('left')} ${t('path')}`,{exact:true})).toHaveValue('/Users/test/A');await page.keyboard.press('Control+]');await expect(page.getByLabel(`${t('left')} ${t('path')}`,{exact:true})).toHaveValue('/Users/test/B');
  const input=page.getByLabel(`${t('left')} ${t('path')}`,{exact:true});await input.focus();await page.keyboard.press('Control+[');await expect(input).toHaveValue('/Users/test/B');
});

for(const theme of ['purple-dark','purple-light']as const) for(const width of [1060,1440]) {
 test(`${theme} ${width}: roles, connected tabs and one path row remain distinct and fit`,async({page},info)=>{
  await page.setViewportSize({width,height:680});await open(page,{settings:{autoCheckUpdates:false,theme}});const pane=page.getByTestId('left-pane');await pane.getByRole('button',{name:t('newTab'),exact:true}).click();await navigate(page,'left','/Users/test/Long folder name for tabs');
  await expect(pane.locator('.pane-heading .role-tag')).toBeVisible();const geometry=await pane.evaluate(p=>{const heading=p.querySelector('.pane-heading')!.getBoundingClientRect(),tabs=p.querySelector('.pane-tabs')!.getBoundingClientRect(),nav=p.querySelector('.path-toolbar')!.getBoundingClientRect(),active=p.querySelector('.pane-tab.active')!,inactive=p.querySelector('.pane-tab:not(.active)')!;return{ordered:heading.bottom<=tabs.top+1&&tabs.bottom<=nav.top+1,connected:getComputedStyle(active).backgroundColor===getComputedStyle(p.querySelector('.path-toolbar')!).backgroundColor,activeBottom:active.getBoundingClientRect().bottom,navTop:nav.top,inactiveBorder:getComputedStyle(inactive).borderWidth,locationSameRow:p.querySelector('.path-toolbar')!.contains(p.querySelector('.location-select')),noOverflow:p.querySelector('.path-toolbar')!.scrollWidth<=nav.width+1};});
  expect(geometry).toMatchObject({ordered:true,connected:true,inactiveBorder:'0px',locationSameRow:true,noOverflow:true});expect(Math.abs(geometry.activeBottom-geometry.navTop)).toBeLessThanOrEqual(1);
  await page.screenshot({path:info.outputPath('connected-tabs.png')});
 });
}

test('job progress shows one decimal, rolling speed, rough ETA and a retained completed average',async({page})=>{
  await open(page,{job:true});const job=page.getByTestId('job-fixture-job');await page.evaluate(()=>{const w=window as any,j=structuredClone(w.__fixture.job);j.stats={...j.stats,bytes:1400000000,totalBytes:3400000000,speed:21000000,speedKind:'rolling',speedWindowSeconds:60,eta:95,filesPerSecond:12.6};w.__rbnEvent({type:'jobUpdate',data:j});});await expect(job.locator('.progress-value')).toHaveText('41.2%');await expect(job.getByRole('progressbar')).toHaveAttribute('aria-valuenow','41.2');await expect(job.locator('.job-metrics')).toContainText(t('fileCount'));await expect(job.locator('.job-metrics')).toContainText('20 MiB/s');await expect(job.locator('.job-metrics')).toContainText('1:35');
  await job.getByRole('button',{name:`${t('speed')} — ${t('infoLabel')}`,exact:true}).click();await expect(page.getByRole('tooltip')).toHaveText(t('speedCalculationHint'));await page.keyboard.press('Escape');
  await page.evaluate(()=>{const w=window as any,j=structuredClone(w.__fixture.job);j.status='completed';j.stats={...j.stats,bytes:3400000000,totalBytes:3400000000,speed:20000000,speedKind:'overall',averageSpeed:20000000,eta:0,elapsedTime:170,transferring:[]};w.__rbnEvent({type:'jobUpdate',data:j});});await expect(job.locator('.progress-value')).toHaveText('100.0%');await expect(job.locator('.job-metrics')).toContainText('19.1 MiB/s');await expect(job.locator('.job-metrics')).toContainText(t('averageSpeed'));
});

test('all-zero-byte files use count progress and a running near-complete job never claims 100.0 percent',async({page})=>{
  await open(page,{job:true});const job=page.getByTestId('job-fixture-job');await page.evaluate(()=>{const w=window as any,j=structuredClone(w.__fixture.job);j.stats={...j.stats,bytes:0,totalBytes:0,speed:0,transfers:13,totalTransfers:30,eta:2,filesPerSecond:8.5};w.__rbnEvent({type:'jobUpdate',data:j});});await expect(job.locator('.progress-value')).toHaveText('43.3%');
  await page.evaluate(()=>{const w=window as any,j=structuredClone(w.__fixture.job);j.stats={...j.stats,bytes:9999999,totalBytes:10000000};w.__rbnEvent({type:'jobUpdate',data:j});});await expect(job.locator('.progress-value')).toHaveText('99.9%');
  await page.evaluate(()=>{const w=window as any,j=structuredClone(w.__fixture.job);j.status='completed';j.stats={...j.stats,bytes:0,totalBytes:0,speed:0,transfers:30,totalTransfers:30,elapsedTime:5,transferring:[]};w.__rbnEvent({type:'jobUpdate',data:j});});await expect(job.locator('.progress-value')).toHaveText('100.0%');
});

test('100,000-file panes stay virtualized and progress updates do not repeat full-list mapping, sorting or scanning',async({page},info)=>{
  test.setTimeout(60000);const errors=await open(page,{fileCount:100000,job:true});const listCalls=(await calls(page,'list')).length;expect(await page.locator('tr[data-index]').count()).toBeLessThan(100);
  const audit=await page.evaluate(async()=>{const w=window as any,original={map:Array.prototype.map,filter:Array.prototype.filter,sort:Array.prototype.sort};let scans=0;for(const key of ['map','filter','sort']as const)(Array.prototype as any)[key]=function(...args:any[]){if(this.length>=100000)scans++;return (original[key]as any).apply(this,args);};const began=performance.now();try{for(let i=0;i<25;i++){const j=structuredClone(w.__fixture.job);j.stats.bytes+=i*1048576;w.__rbnEvent({type:'jobUpdate',data:j});await new Promise(requestAnimationFrame);}return {fullListPasses:scans,updates:25,wallMilliseconds:performance.now()-began};}finally{for(const key of ['map','filter','sort']as const)(Array.prototype as any)[key]=original[key];}});
  expect(audit.fullListPasses).toBe(0);expect((await calls(page,'list')).length).toBe(listCalls);expect(await page.locator('tr[data-index]').count()).toBeLessThan(100);expect(errors).toEqual([]);await info.attach('large-list-progress-audit',{body:JSON.stringify(audit,null,2),contentType:'application/json'});
});


test('a fresh task-saved toast survives closing its editor while a prior root toast is still visible', async ({page})=>{
  await open(page);await page.getByRole('button',{name:t('rememberWorkspace'),exact:true}).click();await expect(page.locator('body > .floating-notice')).toBeVisible();
  await page.getByRole('button',{name:t('saveTask'),exact:true}).click();const editor=page.locator('.task-editor-dialog');await editor.getByLabel(t('taskName'),{exact:true}).fill('Quick task');await editor.getByRole('button',{name:t('save'),exact:true}).click();await expect(editor).toHaveCount(0);
  const toast=page.locator('body > .floating-notice');await expect(toast).toHaveAttribute('data-visible','true');await expect(toast).toContainText(t('taskSaved'));await page.waitForTimeout(300);await expect(toast).toBeVisible();
});

test('opening the operation menu by keyboard focuses the selected operation, never a preset hide button', async ({page})=>{
  await open(page);await page.getByTestId('operation-picker').focus();await page.keyboard.press('ArrowDown');await expect(page.getByRole('menuitemradio',{name:t('copy'),exact:true})).toBeFocused();await page.keyboard.press('Enter');
  await expect(page.locator('.operation-menu')).toHaveCount(0);expect((await state(page)).hiddenBuiltinPresets).toEqual([]);expect(await calls(page,'startTransfer')).toHaveLength(0);
  await preset(page,t('presetNASCloud'));await page.getByTestId('operation-picker').focus();await page.keyboard.press('ArrowDown');await expect(page.getByRole('menuitemradio',{name:new RegExp('^'+t('presetNASCloud'))})).toBeFocused();await page.keyboard.press('Escape');await expect(page.getByTestId('operation-picker')).toBeFocused();
});

for(const language of ['zh-TW','en','ja']as const) test(`${language}: NAS-to-cloud advice names the route and explains unavoidable data transfer`,async({page})=>{
  const tx=translator(language);await open(page,{settings:{autoCheckUpdates:false,language}});await selectPlace(page.getByTestId('left-pane').locator('.location-trigger'),'@local:test-nas-volume');await page.locator('.options-button').click();const d=page.locator('.options-dialog');await expect(d.locator('.comparison-advice')).toContainText(tx('presetNASCloud'));await expect(d.locator('.comparison-advice')).toContainText(tx('comparisonRecommendedSummary'));await expect(d.getByTestId('transfer-comparison')).toHaveValue('nas');
  await d.getByRole('button',{name:`${tx('comparisonRecommendation')} — ${tx('infoLabel')}`,exact:true}).click();await expect(page.getByRole('tooltip')).toHaveText(tx('comparisonAdviceDetail'));await page.keyboard.press('Escape');await expect(d).toBeVisible();
});
