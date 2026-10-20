import {chromium} from '@playwright/test';
import {installHostFixture} from './native-fixture.ts';
import {translator} from '../renderer/i18n.ts';
import {pathToFileURL} from 'node:url';
import path from 'node:path';
import {mkdir,writeFile} from 'node:fs/promises';
const out=path.resolve(process.env.RBN_PREVIEW_OUTPUT || '.build-cache/qa04');
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
await writeFile(path.join(out,'palette-tokens.json'),JSON.stringify(paletteTokens,null,2)+'\n');
await writeFile(path.join(out,'PREVIEWS.txt'),'These images show the production file:// interface with deterministic, clearly fictional test data. No cloud transfer, NAS transfer, mount or native macOS execution is represented. Preview-only data filtering is confined to tests/native-fixture.ts. The shipped app includes no demonstration filesystem or injected fixture.\n');
await browser.close();
if(errors.length)throw new Error(errors.join('\n'));
console.log(`Created four clean previews plus settings, task editor and tooltip screenshots in ${out}.`);
