import {expect,test} from '@playwright/test';
import {pathToFileURL,fileURLToPath} from 'node:url';
import path from 'node:path';
import {installHostFixture} from './native-fixture';

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../..');
const url=pathToFileURL(process.env.RBN_FLICKER_BASELINE || path.join(root,'Resources/Web/index.html')).href;
for(const running of [false,true]) {
  test(`file rows are present in the first painted frames after returning from transfers (${running?'running':'idle'})`,async({page})=>{
    await installHostFixture(page,{job:running,settings:{theme:'green-dark',autoCheckUpdates:false},fileCount:200});
    await page.goto(url);
    await expect(page.getByTestId('left-pane').locator('.file-name').first()).toBeVisible();
    await page.locator('.main-nav button').nth(1).click();
    await expect(page.locator('.jobs-page-layout')).toBeVisible();
    await page.evaluate(()=>{
      const win=window as any;win.__rowFrames=[];
      let started=false;
      const sample=()=>{
        const left=document.querySelector('[data-testid="left-pane"]');
        const right=document.querySelector('[data-testid="right-pane"]');
        if(left&&right){win.__rowFrames.push({left:left.querySelectorAll('tbody tr[data-index]').length,right:right.querySelectorAll('tbody tr[data-index]').length});}
        if(win.__rowFrames.length<4)requestAnimationFrame(sample);
      };
      const observer=new MutationObserver(()=>{
        if(!started&&document.querySelector('[data-testid="left-pane"]')){started=true;observer.disconnect();requestAnimationFrame(sample);}
      });
      observer.observe(document.getElementById('root')!,{childList:true,subtree:true});
    });
    await page.locator('.main-nav button').nth(0).click();
    await page.waitForFunction(()=>(window as any).__rowFrames.length>=4);
    const frames=await page.evaluate(()=>(window as any).__rowFrames as {left:number;right:number}[]);
    expect(frames).toHaveLength(4);
    for(const frame of frames){expect(frame.left).toBeGreaterThan(0);expect(frame.right).toBeGreaterThan(0);}
  });
}
