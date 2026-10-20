import {expect, test, type Page} from '@playwright/test';
import {fileURLToPath, pathToFileURL} from 'node:url';
import path from 'node:path';
import {installHostFixture} from './native-fixture';
import {translator} from '../renderer/i18n';
import {DEFAULT_OPTIONS, type Settings, type Theme, type TransferRequest} from '../shared/types';
const t = translator('zh-TW');
const appURL = pathToFileURL(path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../Resources/Web/index.html')).href;
async function open(page: Page, options: Parameters<typeof installHostFixture>[1] = {}) {
  const errors: string[] = []; page.on('pageerror', e => errors.push(e.message));
  await installHostFixture(page, {settings: {autoCheckUpdates: false}, ...options}); await page.goto(appURL);
  await expect(page.getByTestId('left-pane').locator('.file-name').first()).toBeVisible();
  await expect(page.getByTestId('right-pane').locator('.file-name').first()).toBeVisible();
  return errors;
}
async function calls(page: Page, method: string): Promise<any[]> {return page.evaluate(method => (window as any).__fixture.calls.filter((item: any) => item.method === method), method);}
async function settings(page: Page) { await page.locator('.workspace-title > .icon-button').click(); return page.locator('.settings-dialog'); }
async function state(page: Page): Promise<Settings> {return page.evaluate(() => (window as any).__fixture.bootstrap.settings);}
async function waitSaved(page: Page) {await expect(page.locator('.autosave-note')).not.toContainText(t('savingSettings'));}
async function taskEditor(page: Page) {await page.getByRole('button', {name: t('saveTask'), exact: true}).click(); return page.locator('.task-editor-dialog');}

for (const [preferredLanguage, resolved, docLang] of [['zh-CN','zh-TW','zh-Hant'], ['zh-Hans','zh-TW','zh-Hant'], ['ja-JP','ja','ja'], ['de-DE','en','en']] as const) {
  test(`system language uses the native primary ${preferredLanguage} → ${resolved}; manual choice survives restart`, async ({page,browser}) => {
    const errors = await open(page, {preferredLanguage, settings: {language: 'system', theme: 'purple-dark', autoCheckUpdates: false}});
    await expect(page.locator('html')).toHaveAttribute('lang', docLang);
    const tx = translator(resolved); await expect(page.locator('.start-button')).toHaveText(tx('startCopy'));
    const d = await settings(page); await d.getByRole('button', {name: tx('appearance'), exact: true}).click();
    await expect(d.locator('select')).toHaveValue('system');
    await d.locator('select').selectOption('ja'); await expect(page.locator('html')).toHaveAttribute('lang','ja');
    await expect.poll(async () => (await state(page)).language).toBe('ja');
    const next = await browser.newPage(); await open(next, {preferredLanguage, settings: await state(page)});
    await expect(next.locator('html')).toHaveAttribute('lang','ja'); await next.close(); expect(errors).toEqual([]);
  });
}

test('Remember restores locations, direction, mode and all options without selection or automatic transfers', async ({page,browser}) => {
  await open(page); const left = page.getByTestId('left-pane'), right = page.getByTestId('right-pane');
  await left.locator('.location-select select').selectOption('lab-nas');
  await right.locator('.location-select select').selectOption('@local:documents');
  await page.getByRole('button', {name: t('rightToLeft'), exact: true}).click();
  await right.getByText('研究紀錄 01.pdf', {exact: true}).click();
  await page.locator('.options-button').click(); const d = page.locator('.options-dialog');
  await d.getByTestId('transfer-comparison').selectOption('nas');
  await d.getByRole('checkbox', {name:t('skipExisting'),exact:true}).check();
  await d.getByRole('button', {name:t('transferPerformance'),exact:true}).click();
  await d.getByLabel(t('bandwidth'), {exact: true}).fill('7M'); await d.getByLabel(t('transfers'), {exact:true}).fill('6');
  await d.getByLabel(t('extraArgs'), {exact:true}).fill('--buffer-size=32M');
  await d.getByRole('button', {name:t('filtersTab'),exact:true}).click();
  await d.getByLabel(t('exclude'), {exact:true}).fill('*.tmp\n.DS_Store');
  await d.getByRole('button', {name:t('apply'),exact:true}).click();
  await page.getByRole('button', {name:t('rememberWorkspace'),exact:true}).click();
  await expect(page.locator('.app-notice')).toContainText(t('workspaceRemembered'));
  const saved = await state(page); expect(saved.savedWorkspace).toMatchObject({left:{remote:'lab-nas',path:''},right:{remote:null,path:'/Users/test/Documents'},direction:'rl',mode:'copy',options:{comparison:'default',localHashPolicy:'none',skipExisting:true,bandwidth:'7M',transfers:6,exclude:['*.tmp','.DS_Store'],extraArgs:['--buffer-size=32M']}});
  expect(saved.savedWorkspace).not.toHaveProperty('selection'); expect((await calls(page,'startTransfer')).length).toBe(0);
  const next=await browser.newPage();await open(next,{settings:saved});
  await expect(next.getByRole('button',{name:t('rightToLeft'),exact:true})).toHaveAttribute('aria-pressed','true');
  await expect(next.getByTestId('right-pane').locator('tr[data-selected]')).toHaveCount(0);
  await next.locator('.command-button').click(); await expect(next.locator('.command-output')).toBeVisible();
  const restored=(await calls(next,'previewTransfer')).at(-1).args[0];expect(restored.options).toEqual(saved.savedWorkspace!.options);expect(restored.direction).toBe('rl');expect(restored.source).toEqual(saved.savedWorkspace!.right);
  expect((await calls(next,'startTransfer')).length).toBe(0);await next.close();
});

test('startup location edits update a remembered workspace and forgetting removes both old and new defaults', async ({page,browser}) => {
  const workspace={left:{remote:null,path:'/Users/test/Old'},right:{remote:'lab-nas',path:'OldBackup'},direction:'rl' as const,mode:'sync' as const,options:{...DEFAULT_OPTIONS,comparison:'size' as const,maxDelete:-1}};
  await open(page,{settings:{autoCheckUpdates:false,savedWorkspace:workspace,initialLocations:{left:{remote:null,path:'/Users/test/Legacy'}}}});
  const d=await settings(page); await d.getByLabel(`${t('left')} ${t('location')}`,{exact:true}).selectOption('@local:documents');
  await d.getByLabel(`${t('right')} ${t('path')}`,{exact:true}).fill('NewBackup');await d.getByLabel(`${t('right')} ${t('path')}`,{exact:true}).press('Enter');await waitSaved(page);
  const saved=await state(page);expect(saved.savedWorkspace).toEqual({...workspace,left:{remote:null,path:'/Users/test/Documents'},right:{remote:'lab-nas',path:'NewBackup'}});
  const next=await browser.newPage();await open(next,{settings:saved});await expect(next.getByLabel(`${t('left')} ${t('path')}`,{exact:true})).toHaveValue('/Users/test/Documents');await expect(next.getByLabel(`${t('right')} ${t('path')}`,{exact:true})).toHaveValue('NewBackup');expect((await calls(next,'startTransfer')).length).toBe(0);await next.close();
  await d.getByRole('button',{name:t('forgetWorkspace'),exact:true}).click();await waitSaved(page);expect(await state(page)).toMatchObject({savedWorkspace:null,initialLocations:{}});
});

test('Tasks save and edit the complete request; Dry Run and Run execute the saved snapshot', async ({page}) => {
  const errors=await open(page);const d=await taskEditor(page);await d.getByLabel(t('taskName'),{exact:true}).fill('NAS nightly copy');
  await d.getByRole('button',{name:t('rightToLeft'),exact:true}).click();
  await d.locator('.endpoint-editor').first().locator('select').selectOption('@local:volumes');
  await d.locator('.endpoint-editor').first().locator('.endpoint-path-row input').fill('/Volumes/Media Backup/Archive');await d.locator('.endpoint-editor').first().locator('.endpoint-path-row input').press('Enter');
  await d.locator('.endpoint-editor').last().locator('select').selectOption('lab-nas');
  await d.locator('.endpoint-editor').last().locator('.endpoint-path-row input').fill('Source');await d.locator('.endpoint-editor').last().locator('.endpoint-path-row input').press('Enter');
  await d.getByRole('button',{name:t('browseSelection'),exact:true}).click();
  await d.getByRole('checkbox',{name:'Documents',exact:true}).check();await d.getByRole('checkbox',{name:'研究紀錄 01.pdf',exact:true}).check();
  await d.getByRole('button',{name:t('modeAndComparison'),exact:true}).click();await d.getByTestId('transfer-comparison').selectOption('nas');await d.getByRole('checkbox',{name:t('skipExisting'),exact:true}).check();
  await d.getByRole('checkbox',{name:t('oneFileSystem'),exact:true}).check();await d.getByRole('checkbox',{name:t('preserveMetadata'),exact:true}).check();
  await d.getByRole('button',{name:t('transferPerformance'),exact:true}).click();await d.getByLabel(t('transfers'),{exact:true}).fill('5');await d.getByLabel(t('bandwidth'),{exact:true}).fill('12M');await d.getByLabel(t('connectTimeout'),{exact:true}).fill('20s');await d.getByLabel(t('extraArgs'),{exact:true}).fill('--buffer-size=32M\n--multi-thread-streams=2');
  await d.getByRole('button',{name:t('filtersTab'),exact:true}).click();await d.getByLabel(t('exclude'),{exact:true}).fill('*.tmp\n.DS_Store');await d.getByLabel(t('include'),{exact:true}).fill('*.pdf\nDocuments/**');await d.getByLabel(t('maxAge'),{exact:true}).fill('30d');await d.getByLabel(t('maxDepth'),{exact:true}).fill('6');
  await d.getByRole('button',{name:t('save'),exact:true}).click();await expect(d).toHaveCount(0);
  const first=(await calls(page,'saveTask')).at(-1).args[1] as TransferRequest;
  expect(first).toMatchObject({source:{remote:'lab-nas',path:'Source'},destination:{remote:null,path:'/Volumes/Media Backup/Archive'},direction:'rl',mode:'copy',dryRun:false,selection:[{name:'Documents',isDir:true},{name:'研究紀錄 01.pdf',isDir:false}],options:{comparison:'default',localHashPolicy:'none',skipExisting:true,oneFileSystem:true,preserveMetadata:true,transfers:5,bandwidth:'12M',connectTimeout:'20s',extraArgs:['--buffer-size=32M','--multi-thread-streams=2'],exclude:['*.tmp','.DS_Store'],include:['*.pdf','Documents/**'],maxAge:'30d',maxDepth:6}});
  await page.locator('.main-nav button').last().click();await expect(page.locator('.task-table tbody tr')).toHaveCount(1);expect((await page.locator('.task-table tbody tr').boundingBox())!.height).toBeLessThanOrEqual(52);
  await page.getByRole('button',{name:t('editTask'),exact:true}).click();await expect(d.locator('.selected-task-items')).toContainText('研究紀錄 01.pdf');await expect(d.getByRole('button',{name:t('rightToLeft'),exact:true})).toHaveAttribute('aria-pressed','true');
  await d.getByLabel(t('taskName'),{exact:true}).fill('NAS reviewed copy');await d.getByRole('button',{name:t('save'),exact:true}).click();
  const edited=(await calls(page,'saveTask')).at(-1);expect(edited.args[2]).toBe('fixture-task');expect({...edited.args[1],label:first.label}).toEqual(first);
  await page.getByRole('button',{name:t('dryRun'),exact:true}).click();await expect.poll(async()=>(await calls(page,'startTransfer')).length).toBe(1);expect((await calls(page,'startTransfer'))[0].args[0]).toEqual({...edited.args[1],dryRun:true,label:'NAS reviewed copy'});
  await page.locator('.main-nav button').last().click();await page.getByRole('button',{name:t('runTask'),exact:true}).click();await expect.poll(async()=>(await calls(page,'startTransfer')).length).toBe(2);expect((await calls(page,'startTransfer'))[1].args[0]).toEqual({...edited.args[1],dryRun:false,label:'NAS reviewed copy'});expect(errors).toEqual([]);
});

test('editing destination keeps saved selection; changing source clears it visibly before saving', async ({page}) => {
  await open(page);await page.getByTestId('left-pane').getByText('研究紀錄 01.pdf',{exact:true}).click();let d=await taskEditor(page);await d.getByRole('button',{name:t('save'),exact:true}).click();await page.locator('.main-nav button').last().click();await page.getByRole('button',{name:t('editTask'),exact:true}).click();
  d=page.locator('.task-editor-dialog');await d.locator('.endpoint-editor').last().locator('.endpoint-path-row input').fill('ChangedTarget');await d.locator('.endpoint-editor').last().locator('.endpoint-path-row input').press('Enter');await expect(d.locator('.selected-task-items')).toContainText('研究紀錄 01.pdf');
  await d.locator('.endpoint-editor').first().locator('select').selectOption('@local:downloads');await expect(d).toContainText(t('selectionChangedSource'));await expect(d.locator('.selected-task-items')).toHaveCount(0);await d.getByRole('button',{name:t('save'),exact:true}).click();expect((await calls(page,'saveTask')).at(-1).args[1].selection).toEqual([]);expect((await calls(page,'startTransfer')).length).toBe(0);
});

test('rclone connection settings save partial patches, custom IP commits atomically, and task timeouts inherit', async ({page}) => {
  const errors=await open(page);const d=await settings(page);await expect(d.getByLabel(t('limitJobs'),{exact:true})).toHaveValue('unlimited');
  await d.getByRole('button',{name:t('network'),exact:true}).click();
  await d.getByLabel(t('bindMode'),{exact:true}).selectOption('address');await expect(d.locator('.bind-pending')).toBeVisible();expect((await calls(page,'saveSettings')).length).toBe(0);
  await d.getByLabel(t('bindAddress'),{exact:true}).fill('192.0.2.10');await d.getByLabel(t('bindAddress'),{exact:true}).press('Enter');await waitSaved(page);expect((await calls(page,'saveSettings'))[0].args[0]).toEqual({networkOptions:{bindMode:'address',bindAddress:'192.0.2.10'}});
  await page.evaluate(()=>{(window as any).__fixture.delays.saveSettings=[90,60,40,20];});
  await d.getByLabel(t('connectTimeout'),{exact:true}).fill('40s');await d.getByLabel(t('connectTimeout'),{exact:true}).press('Enter');await d.getByLabel(t('ioTimeout'),{exact:true}).fill('8m');await d.getByLabel(t('ioTimeout'),{exact:true}).press('Enter');await d.getByLabel(t('tpsLimit'),{exact:true}).fill('5');await d.getByLabel(t('tpsLimit'),{exact:true}).press('Enter');await d.getByRole('checkbox',{name:t('disableHTTP2'),exact:true}).check();await waitSaved(page);
  expect((await state(page)).networkOptions).toMatchObject({bindMode:'address',bindAddress:'192.0.2.10',connectTimeout:'40s',ioTimeout:'8m',tpsLimit:5,disableHTTP2:true});
  expect((await calls(page,'saveSettings')).slice(1).map(c=>c.args[0])).toEqual([{networkOptions:{connectTimeout:'40s'}},{networkOptions:{ioTimeout:'8m'}},{networkOptions:{tpsLimit:5}},{networkOptions:{disableHTTP2:true}}]);
  await d.locator('.dialog-footer button').last().click();await page.locator('.options-button').click();const opts=page.locator('.options-dialog');await opts.getByRole('button',{name:t('transferPerformance'),exact:true}).click();await expect(opts.getByLabel(t('connectTimeout'),{exact:true})).toHaveValue('');await expect(opts.getByLabel(t('connectTimeout'),{exact:true})).toHaveAttribute('placeholder',t('inheritNetwork'));await opts.getByRole('button',{name:t('cancel'),exact:true}).click();expect(errors).toEqual([]);
});

test('comparison tips work with hover, focus, click and Escape without dismissing the dialog', async ({page,browser}) => {
  await page.setViewportSize({width:1060,height:680});await open(page);await page.locator('.options-button').click();const d=page.locator('.options-dialog');const info=d.getByRole('button',{name:`${t('comparison')} — ${t('infoLabel')}`,exact:true});
  await info.hover();await expect(page.getByRole('tooltip')).toHaveText(t('comparisonDefaultHint'));await page.keyboard.press('Escape');await expect(page.getByRole('tooltip')).toHaveCount(0);await d.getByTestId('transfer-comparison').focus();await info.hover();await page.mouse.move(0,0);await expect(page.getByRole('tooltip')).toHaveCount(0);
  await info.focus();await expect(page.getByRole('tooltip')).toBeVisible();await page.keyboard.press('Escape');await expect(page.getByRole('tooltip')).toHaveCount(0);await expect(d).toBeVisible();
  await info.click();await page.mouse.move(0,0);await expect(page.getByRole('tooltip')).toBeVisible();const bounds=await page.getByRole('tooltip').boundingBox();expect(bounds!.x).toBeGreaterThanOrEqual(0);expect(bounds!.y).toBeGreaterThanOrEqual(0);expect(bounds!.x+bounds!.width).toBeLessThanOrEqual(1060);expect(bounds!.y+bounds!.height).toBeLessThanOrEqual(680);
  await d.getByTestId('transfer-comparison').selectOption('size');await info.hover();await expect(page.getByRole('tooltip')).toHaveText(t('comparisonSizeHint'));await page.keyboard.press('Escape');await d.getByRole('button',{name:t('cancel'),exact:true}).click();
  for (const language of ['zh-TW','en','ja'] as const) {
    const sample=await browser.newPage({viewport:{width:1060,height:680},reducedMotion:'reduce'});const tx=translator(language);
    const errors=await open(sample,{settings:{language,autoCheckUpdates:false}});await sample.locator('.options-button').click();const dialog=sample.locator('.options-dialog');
    const trigger=dialog.getByRole('button',{name:`${tx('comparison')} — ${tx('infoLabel')}`,exact:true});
    for (const [value,hint] of [['default','comparisonDefaultHint'],['checksum','comparisonChecksumHint'],['checksum-only','comparisonChecksumOnlyHint'],['size','comparisonSizeHint'],['modtime','comparisonModtimeHint'],['none','comparisonNoneHint'],['nas','comparisonNASHint']] as const) {
      await dialog.getByTestId('transfer-comparison').selectOption(value);await trigger.click();const tip=sample.getByRole('tooltip');await expect(tip).toHaveText(tx(hint));const box=await tip.boundingBox();expect(box!.x).toBeGreaterThanOrEqual(0);expect(box!.y).toBeGreaterThanOrEqual(0);expect(box!.x+box!.width).toBeLessThanOrEqual(1060);expect(box!.y+box!.height).toBeLessThanOrEqual(680);await sample.keyboard.press('Escape');
    }
    await expect(dialog.getByTestId('transfer-comparison').locator('option:checked')).toHaveText(tx('comparisonNAS'));expect(errors).toEqual([]);await sample.close();
  }
});

test('location picker classifies native known places, mounted NAS, cloud and ambiguous remotes separately', async ({page}) => {
  await open(page);const select=page.getByTestId('left-pane').locator('.location-select select');
  expect(await select.locator('optgroup').evaluateAll(groups=>groups.map(g=>({label:(g as HTMLOptGroupElement).label,items:Array.from(g.querySelectorAll('option')).map(o=>o.value)})))).toEqual([
    {label:t('localPlaces'),items:['@local:home','@local:desktop','@local:documents','@local:downloads','@local:pictures','@local:music','@local:movies','@local:volumes']},
    {label:t('networkPlaces'),items:['@local:test-nas-volume','lab-nas']}, {label:t('cloudPlaces'),items:['research-drive']}, {label:t('otherPlaces'),items:['web-storage']}
  ]);
  await select.selectOption('@local:test-nas-volume');await expect(page.getByLabel(`${t('left')} ${t('path')}`,{exact:true})).toHaveValue('/Volumes/Media Backup');await select.selectOption('@local:downloads');await expect(page.getByLabel(`${t('left')} ${t('path')}`,{exact:true})).toHaveValue('/Users/test/Downloads');expect((await calls(page,'startTransfer')).length).toBe(0);
});

test('the application menu exposes native About, engine updates and distinct app release checks', async ({page,browser}) => {
  await open(page,{settings:{autoCheckUpdates:false},appStatus:'available'});const menu=page.locator('.application-menu');await menu.locator('summary').click();await page.getByRole('menuitem',{name:t('aboutApp'),exact:true}).click();expect((await calls(page,'showAbout')).length).toBe(1);
  await menu.locator('summary').click();await page.getByRole('menuitem',{name:t('checkEngineUpdates'),exact:true}).click();await expect(page.locator('.app-notice')).toContainText(t('alreadyCurrent'));expect((await calls(page,'checkForUpdates')).at(-1).args).toEqual([true]);
  await menu.locator('summary').click();await page.getByRole('menuitem',{name:t('checkAppUpdates'),exact:true}).click();await expect(page.getByRole('dialog')).toContainText(t('appUpdateAvailable'));await expect(page.getByRole('dialog')).toContainText('0.4.0 → 0.5.0');await page.getByRole('button',{name:t('openReleasePage'),exact:true}).click();expect((await calls(page,'openExternal')).at(-1).args).toEqual(['https://github.com/jason840709/RcloneBrowserNext/releases/latest']);expect((await calls(page,'checkAppUpdates')).length).toBe(1);
  await page.locator('.dialog-footer').getByRole('button',{name:t('close'),exact:true}).click();await page.evaluate(()=>{(window as any).__fixture.appStatus='current';});
  await menu.locator('summary').click();await page.getByRole('menuitem',{name:t('checkAppUpdates'),exact:true}).click();await expect(page.getByRole('dialog')).toContainText(t('appCurrent'));await expect(page.getByRole('button',{name:t('openReleasePage'),exact:true})).toBeVisible();
  for (const language of ['zh-TW','en','ja'] as const) {
    const sample=await browser.newPage({viewport:{width:1060,height:680},reducedMotion:'reduce'});const tx=translator(language);
    const errors=await open(sample,{settings:{language,autoCheckUpdates:false},appStatus:'unpublished'});await sample.locator('.application-menu summary').click();await sample.getByRole('menuitem',{name:tx('checkAppUpdates'),exact:true}).click();const dialog=sample.getByRole('dialog');
    await expect(dialog).toContainText(tx('appUnpublished'));await expect(dialog).not.toContainText(tx('appUpdateHint'));await expect(dialog.getByRole('button',{name:tx('openReleasePage'),exact:true})).toHaveCount(0);await expect(dialog.locator('.dialog-footer button')).toHaveCount(1);expect(await calls(sample,'openExternal')).toEqual([]);await dialog.locator('.dialog-footer button').click();await expect(dialog).toHaveCount(0);expect(errors).toEqual([]);await sample.close();
  }
});

for(const theme of ['purple-light','purple-dark','blue-light','blue-dark'] as Theme[]) {
  test(`${theme}: narrow columns leave one separator and full-width zebra pixels through empty space`, async ({page},testInfo) => {
    const errors=await open(page,{fileCount:1,cleanPreview:true,settings:{theme,autoCheckUpdates:false,paneColumnWidths:{left:{name:220,size:86,modified:164}}}});
    const pane=page.getByTestId('left-pane');const handle=pane.getByTestId('left-resize-name');const box=await handle.boundingBox();await page.mouse.move(box!.x+6,box!.y+16);await page.mouse.down();await page.mouse.move(box!.x-130,box!.y+16);await page.mouse.up();await page.mouse.move(0,0);
    await expect.poll(async()=>(await state(page)).paneColumnWidths.left!.name).toBe(120);
    const geometry=await pane.evaluate(element=>{
      const pane=element as HTMLElement,table=pane.querySelector('table')!,fill=table.querySelector('tbody tr[data-index="0"] .row-fill')!,row0=table.querySelector('tbody tr[data-index="0"]')!,row1=table.querySelector('tbody tr[data-index="1"]')!;
      const fr=fill.getBoundingClientRect(),r0=row0.getBoundingClientRect(),r1=row1.getBoundingClientRect(),pr=pane.getBoundingClientRect(),tab=pane.querySelector('.pane-tab')!.getBoundingClientRect(),root=getComputedStyle(document.documentElement),scroller=pane.querySelector('[data-virtuoso-scroller]')!;
      return {fillerWidth:fr.width,headerBorder:getComputedStyle(table.querySelector('th:nth-child(2)')!).borderRightWidth,line:getComputedStyle(pane.querySelector('.column-resizer')!,'::after').width,hit:getComputedStyle(pane.querySelector('.column-resizer')!).width,scrollbar:getComputedStyle(scroller,'::-webkit-scrollbar').width,gaps:{left:tab.left-pr.left,top:tab.top-pr.top},tokens:Object.fromEntries(['bg','toolbar','surface','surface-raised','row-stripe','accent'].map(k=>[k,root.getPropertyValue('--'+k).trim()])),samples:[{x:fr.x+20,y:r0.y+18},{x:fr.x+20,y:r1.y+18},{x:pr.x+20,y:r0.y+3*37+18},{x:fr.x+20,y:r0.y+3*37+18},{x:fr.x+20,y:r0.y+4*37+18}]};
    });
    expect(geometry.fillerWidth).toBeGreaterThan(120);expect(geometry.headerBorder).toBe('0px');expect(geometry.line).toBe('1px');expect(parseFloat(geometry.hit)).toBeGreaterThanOrEqual(10);expect(parseFloat(geometry.scrollbar)).toBeGreaterThanOrEqual(14);expect(geometry.gaps.left).toBeGreaterThanOrEqual(8);expect(geometry.gaps.top).toBeGreaterThanOrEqual(8);
    for(const key of ['bg','toolbar','surface','surface-raised','row-stripe']){const token=geometry.tokens[key].slice(1);const hex=token.length===3?[...token].map(c=>c+c).join(''):token;expect(hex.slice(0,2)).toBe(hex.slice(2,4));expect(hex.slice(2,4)).toBe(hex.slice(4,6));}
    const shot=await page.screenshot({path:testInfo.outputPath(`zebra-${theme}.png`),animations:'disabled'});
    const pixels=await page.evaluate(async({png,points})=>{const image=new Image();image.src=`data:image/png;base64,${png}`;await image.decode();const canvas=document.createElement('canvas');canvas.width=image.width;canvas.height=image.height;const ctx=canvas.getContext('2d')!;ctx.drawImage(image,0,0);return points.map(p=>Array.from(ctx.getImageData(Math.floor(p.x),Math.floor(p.y),1,1).data).slice(0,3));},{png:shot.toString('base64'),points:geometry.samples});
    const rgb=(value:string)=>{const hex=value.length===4?'#'+[...value.slice(1)].map(c=>c+c).join(''):value;return [1,3,5].map(i=>parseInt(hex.slice(i,i+2),16));};const normal=rgb(geometry.tokens.surface),stripe=rgb(geometry.tokens['row-stripe']);
    expect(pixels).toEqual([normal,stripe,stripe,stripe,normal]);expect(normal).not.toEqual(stripe);expect(errors).toEqual([]);
  });
}

test('sync tasks round-trip deletion controls including unlimited maximum and never run during editing', async ({page}) => {
  await open(page);const d=await taskEditor(page);await d.getByLabel(t('taskName'),{exact:true}).fill('Sync with explicit limits');await d.getByRole('button',{name:t('sync'),exact:true}).click();await d.getByRole('button',{name:t('modeAndComparison'),exact:true}).click();await d.getByLabel(t('deleteMode'),{exact:true}).selectOption('before');await d.getByRole('checkbox',{name:t('unlimitedJobs'),exact:true}).check();await d.getByRole('checkbox',{name:t('deleteExcluded'),exact:true}).check();await d.getByTestId('transfer-comparison').selectOption('size');await d.getByRole('button',{name:t('save'),exact:true}).click();
  const stored=(await calls(page,'saveTask')).at(-1).args[1];expect(stored).toMatchObject({mode:'sync',dryRun:false,selection:[],options:{deleteMode:'before',maxDelete:-1,deleteExcluded:true,comparison:'size'}});expect((await calls(page,'startTransfer')).length).toBe(0);
  await page.locator('.main-nav button').last().click();await page.getByRole('button',{name:t('editTask'),exact:true}).click();await d.getByRole('button',{name:t('modeAndComparison'),exact:true}).click();await expect(d.getByRole('checkbox',{name:t('unlimitedJobs'),exact:true})).toBeChecked();await expect(d.getByLabel(t('deleteMode'),{exact:true})).toHaveValue('before');await d.getByRole('button',{name:t('save'),exact:true}).click();expect((await calls(page,'saveTask')).at(-1).args[1]).toEqual(stored);
});

for (const language of ['zh-TW','en','ja'] as const) {
  test(`${language}: full task editor and network controls fit a compact window and keep borders separated`, async ({page},testInfo) => {
    const tx=translator(language);await page.setViewportSize({width:1060,height:680});const errors=await open(page,{settings:{autoCheckUpdates:false,language,theme:'purple-dark'}});
    await page.getByRole('button',{name:tx('saveTask'),exact:true}).click();const d=page.locator('.task-editor-dialog');
    for(const tab of ['locationsTab','modeAndComparison','transferPerformance','filtersTab'] as const){
      await d.getByRole('button',{name:tx(tab),exact:true}).click();
      const layout=await d.evaluate(element=>{const dialog=element.getBoundingClientRect(),footer=element.querySelector('.dialog-footer')!.getBoundingClientRect(),header=element.querySelector('.dialog-header')!.getBoundingClientRect(),content=element.querySelector('.options-content')!.getBoundingClientRect(),tabs=Array.from(element.querySelectorAll('.options-tabs button')).map(e=>e.getBoundingClientRect());return {inside:dialog.x>=0&&dialog.y>=0&&dialog.right<=innerWidth&&dialog.bottom<=innerHeight,footerFits:element.querySelector('.dialog-footer')!.scrollWidth<=footer.width+1,headerBefore:header.bottom<content.top,contentBeforeFooter:content.bottom<=footer.top+1,tabGaps:tabs.slice(1).map((box,i)=>box.left-tabs[i].right)};});
      expect(layout.inside).toBe(true);expect(layout.footerFits).toBe(true);expect(layout.headerBefore).toBe(true);expect(layout.contentBeforeFooter).toBe(true);expect(layout.tabGaps.every(gap=>gap>=8)).toBe(true);
      await page.screenshot({path:testInfo.outputPath(`task-${language}-${tab}.png`),animations:'disabled'});
    }
    await d.getByRole('button',{name:tx('cancel'),exact:true}).click();const pref=await settings(page);await pref.getByRole('button',{name:tx('network'),exact:true}).click();await pref.locator('.network-options-section').scrollIntoViewIfNeeded();await expect(pref.getByLabel(tx('tpsLimit'),{exact:true})).toBeVisible();await page.screenshot({path:testInfo.outputPath(`network-${language}.png`),animations:'disabled'});expect(errors).toEqual([]);
  });
}
