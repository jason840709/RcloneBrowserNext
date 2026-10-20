import {chromium,expect} from '@playwright/test';
import {installHostFixture} from './native-fixture.ts';
import {translator} from '../renderer/i18n.ts';
import {pathToFileURL} from 'node:url';
import path from 'node:path';
import {mkdir,writeFile} from 'node:fs/promises';
const out=path.resolve(process.env.RBN_PREVIEW_OUTPUT || '.build-cache/qa05');
await mkdir(out,{recursive:true});
const browser=await chromium.launch({executablePath:process.env.RBN_TEST_BROWSER,headless:true,ignoreDefaultArgs:['--hide-scrollbars']});
const errors:string[]=[];
const paletteTokens:Record<string,Record<string,string>>={};
for(const theme of ['purple-light','purple-dark','blue-light','blue-dark'] as const){
 const page=await browser.newPage({viewport:{width:1440,height:900},reducedMotion:'reduce'});
 page.on('pageerror',error=>errors.push(`${theme}: ${error.message}`));
 await installHostFixture(page,{cleanPreview:true,job:true,settings:{theme,autoCheckUpdates:false}});
 await page.goto(pathToFileURL(path.resolve('../Resources/Web/index.html')).href);
 await page.getByTestId('left-pane').locator('.file-name').first().waitFor();
 await page.getByTestId('right-pane').locator('.file-name').first().waitFor();
 await page.evaluate(()=>document.fonts.ready);
 await page.screenshot({path:path.join(out,`clean-preview-${theme}.png`),animations:'disabled'});
 await page.setViewportSize({width:1060,height:680});await page.screenshot({path:path.join(out,`clean-preview-${theme}-1060.png`),animations:'disabled'});await page.setViewportSize({width:1440,height:900});
 paletteTokens[theme]=await page.evaluate(()=>Object.fromEntries(['text','muted','faint','bg','toolbar','surface','row-stripe','accent','accent-hover','accent-pressed','accent-foreground','accent-soft','accent-soft-text','border','success','success-bg','error','error-bg','warning','warning-bg'].map(key=>[key,(() => { const context=document.createElement('canvas').getContext('2d')!;context.fillStyle=getComputedStyle(document.documentElement).getPropertyValue('--'+key).trim();return context.fillStyle; })()])));
 if(theme==='purple-dark'){
  const t=translator('zh-TW');
  await page.setViewportSize({width:1060,height:680});
  await page.locator('.options-button').click();
  const d=page.locator('.options-dialog');await d.getByRole('button',{name:t('sync'),exact:true}).click();await d.getByTestId('transfer-comparison').selectOption('nas');await d.getByLabel(t('deleteMode'),{exact:true}).selectOption('during');
  await page.screenshot({path:path.join(out,'options-nas-sync-1060.png'),animations:'disabled'});
  for(const [key,name]of [['transferPerformance','options-transfer-1060'],['filtersTab','options-filters-1060']]as const){await d.getByRole('button',{name:t(key),exact:true}).click();await page.screenshot({path:path.join(out,name+'.png'),animations:'disabled'});}
  await d.getByRole('button',{name:t('cancel'),exact:true}).click();await page.locator('.workspace-title > .icon-button').click();await page.screenshot({path:path.join(out,'settings-general-1060.png'),animations:'disabled'});
  await page.locator('.settings-dialog').getByRole('button',{name:t('network'),exact:true}).click();await page.getByRole('radio',{name:t('proxyManual')}).check();await page.screenshot({path:path.join(out,'settings-network-1060.png'),animations:'disabled'});
  await page.locator('.network-options-section').scrollIntoViewIfNeeded();await page.screenshot({path:path.join(out,'settings-rclone-connections-1060.png'),animations:'disabled'});
  await page.locator('.settings-dialog').getByRole('button',{name:t('appearance'),exact:true}).click();await page.locator('.theme-option.swatch-purple-dark').click();await page.locator('.settings-dialog select').selectOption('ja');await page.screenshot({path:path.join(out,'settings-japanese-1060.png'),animations:'disabled'});
 }
 if(theme==='purple-light'){
  await page.evaluate(()=>{const w=window as any;const template=structuredClone(w.__fixture.job.request);w.__fixture.bootstrap.tasks=[['NAS 每日備份','sync'],['研究資料歸檔','copy'],['照片移至封存','move']].map(([name,mode],index)=>({id:`preview-task-${index}`,name,createdAt:'2026-10-20T08:00:00Z',updatedAt:'2026-10-20T08:00:00Z',request:{...template,mode,direction:'lr',options:{...template.options,comparison:index===0?'size':'default'},source:{remote:null,path:index===0?'/Users/test/Documents':'/Users/test/Pictures'},destination:{remote:index===0?'lab-nas':'research-drive',path:'Archive'},selection:[]}}));w.__rbnEvent({type:'configurationChanged'});});
  await page.locator('.main-nav button').last().click();await page.locator('.task-table tbody tr').first().waitFor();
  await page.screenshot({path:path.join(out,'tasks-list-1440.png'),animations:'disabled'});
  const t=translator('zh-TW');await page.getByRole('button',{name:t('editTask'),exact:true}).click();
  await page.setViewportSize({width:1060,height:680});await page.screenshot({path:path.join(out,'task-editor-locations-1060.png'),animations:'disabled'});
  const editor=page.locator('.task-editor-dialog');await editor.getByRole('button',{name:t('modeAndComparison'),exact:true}).click();
  await page.screenshot({path:path.join(out,'task-editor-comparison-1060.png'),animations:'disabled'});
  await editor.getByTestId('transfer-comparison').selectOption('default');
  await editor.getByRole('button',{name:t('comparison')+' — '+t('infoLabel'),exact:true}).click();
  await page.getByRole('tooltip').waitFor();await page.screenshot({path:path.join(out,'comparison-tooltip-1060.png'),animations:'disabled'});
 }
 await page.close();
}
// Revision 0.5 review states use the same production bundle and fictional host.
// Wait for completed opacity transitions so exported stills do not show mid-motion text.
for(const theme of ['purple-dark','purple-light'] as const){
 const t=translator('zh-TW');
 const page=await browser.newPage({viewport:{width:1440,height:900},reducedMotion:'reduce'});
 page.on('pageerror',error=>errors.push(`${theme} critical: ${error.message}`));
 await installHostFixture(page,{cleanPreview:true,settings:{theme,autoCheckUpdates:false}});
 await page.goto(pathToFileURL(path.resolve('../Resources/Web/index.html')).href);
 await page.getByTestId('right-pane').locator('.file-name').first().waitFor();
 await page.evaluate(()=>document.fonts.ready);
 await page.locator('.main-nav button').last().click();
 await expect(page.locator('.tasks-page .status-card')).toBeVisible();
 await page.screenshot({path:path.join(out,`critical-empty-tasks-${theme}.png`),animations:'disabled'});
 await page.locator('.main-nav button').first().click();
 await page.evaluate(()=>{(window as any).__fixture.listingError='rclone 執行失敗：雲端帳號的登入授權已過期。\n請從「帳號設定（Config）」重新登入，再重試。';});
 await page.getByTestId('right-pane').getByRole('button',{name:t('refresh'),exact:true}).click();
 await expect(page.getByTestId('right-pane').locator('.status-card-error')).toBeVisible();
 await page.screenshot({path:path.join(out,`critical-error-card-${theme}.png`),animations:'disabled'});
 await page.evaluate(()=>{(window as any).__fixture.listingError='';});
 await page.getByTestId('right-pane').getByRole('button',{name:t('retry'),exact:true}).click();
 await page.getByTestId('right-pane').locator('.file-name').first().waitFor();
 await page.getByRole('button',{name:t('rememberWorkspace'),exact:true}).click();
 await page.mouse.move(0,0);
 const toast=page.locator('.floating-notice');
 await expect(toast).toHaveCSS('opacity','1');
 await page.screenshot({path:path.join(out,`critical-floating-toast-${theme}.png`),animations:'disabled'});
 await toast.getByRole('button',{name:t('close'),exact:true}).click();await expect(toast).toHaveCount(0);
 await page.getByTestId('operation-picker').click();
 await expect(page.locator('.operation-menu')).toBeVisible();
 await page.screenshot({path:path.join(out,`critical-preset-menu-${theme}.png`),animations:'disabled'});
 await page.keyboard.press('Escape');
 const pane=page.getByTestId('left-pane');
 await pane.getByRole('button',{name:t('newTab'),exact:true}).click();
 const pathInput=page.getByLabel(`${t('left')} ${t('path')}`,{exact:true});
 await pathInput.fill('/Users/test/Documents/Research');await pathInput.press('Enter');
 await pane.locator('.file-name').first().waitFor();await page.mouse.move(0,0);
 await page.screenshot({path:path.join(out,`critical-connected-tabs-${theme}.png`),animations:'disabled'});
 await page.setViewportSize({width:1060,height:680});
 await page.screenshot({path:path.join(out,`critical-connected-tabs-${theme}-1060.png`),animations:'disabled'});
 await page.getByTestId('right-pane').locator('.location-select select').selectOption('lab-nas');
 await page.getByTestId('right-pane').locator('.file-name').first().waitFor();
 await page.getByTestId('operation-picker').click();
 await page.getByRole('menuitemradio',{name:new RegExp('^'+t('presetLocalNAS'))}).click();
 await expect(page.locator('.floating-notice')).toHaveCSS('opacity','1');
 await page.locator('.floating-notice').getByRole('button',{name:t('close'),exact:true}).click();await expect(page.locator('.floating-notice')).toHaveCount(0);
 await page.locator('.options-button').click();
 await page.screenshot({path:path.join(out,`critical-nas-options-${theme}-1060.png`),animations:'disabled'});
 await page.close();
}
await writeFile(path.join(out,'palette-tokens.json'),JSON.stringify(paletteTokens,null,2)+'\n');
await writeFile(path.join(out,'PREVIEWS.txt'),'These images show the production file:// interface with deterministic, clearly fictional test data. No cloud transfer, NAS transfer, mount or native macOS execution is represented. Preview-only data filtering is confined to tests/native-fixture.ts. The shipped app includes no demonstration filesystem or injected fixture.\n');
await browser.close();
if(errors.length)throw new Error(errors.join('\n'));
console.log(`Created all four themes, settings, tasks, tooltips and revision 0.5 critical-state previews in ${out}.`);
