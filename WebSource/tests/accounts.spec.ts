import {test,expect,type Page} from '@playwright/test';
import {fileURLToPath,pathToFileURL} from 'node:url';
import path from 'node:path';
import {installHostFixture} from './native-fixture';
const url=process.env.RBN_TEST_URL || pathToFileURL(path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../../Resources/Web/index.html')).href;
async function open(page:Page,platform='darwin',theme='purple-dark'){
 await installHostFixture(page,{platform,job:false,settings:{autoCheckUpdates:false,theme:theme as any}});
 await page.goto(url);await page.getByTestId('left-pane').waitFor();
 await page.evaluate(()=>{
  const w=window as any;const previous=w.webkit.messageHandlers.rclone.postMessage;
  w.__accounts={commits:0,cancels:0,mode:'create',step:1,browser:false,question:null,error:'',answers:[]};
  const question=()=>w.__accounts.question||{Name:'remote',Help:'Remote or path to alias.\n\nThis help comes from the selected rclone.',Default:'',Required:true,Type:'string',Sensitive:false};
  const snapshot=(phase:string)=>({id:'session-fixture',name:'personal',mode:w.__accounts.mode,phase,step:w.__accounts.step,question:phase==='question'?question():null,error:w.__accounts.error,configPath:'/test/rclone.conf',canOpenBrowser:w.__accounts.browser,tested:false});
  w.webkit.messageHandlers.rclone.postMessage=(m:any)=>{
   if(m.method!=='accountConfig'&&m.method!=='openAccountAuthorization'){previous(m);return;}
   w.__fixture.calls.push(structuredClone(m));const a=m.args[0]||{};let result:any;
   if(m.method==='openAccountAuthorization')result=null;
   else switch(a.action){
    case 'info':result={providers:[{name:'drive',description:'Google Drive'},{name:'onedrive',description:'Microsoft OneDrive'},{name:'alias',description:'Alias'}],remotes:[{name:'existing',type:'drive'}],configPath:'/test/rclone.conf',binary:'/bin/rclone'};break;
    case 'start':w.__accounts.mode=a.mode;result=snapshot(a.mode==='delete'?'ready':'question');break;
    case 'answer':w.__accounts.answers.push(a);w.__accounts.step++;result=snapshot(w.__accounts.browser?'running':'ready');break;
    case 'poll':result=snapshot('running');break;
    case 'cancel':w.__accounts.cancels++;result=snapshot('cancelled');break;
    case 'commit':w.__accounts.commits++;result=snapshot('committed');break;
    case 'test':result={...snapshot('ready'),tested:true};break;
   }
   setTimeout(()=>w.__rbnReply({id:m.id,result}),5);
  };
 });
 await page.locator('.account-setup-button').click();await expect(page.locator('.accounts-dialog')).toBeVisible();await expect(page.getByText('/test/rclone.conf',{exact:true})).toBeVisible();
}
async function add(page:Page){await page.getByRole('button',{name:'新增帳號',exact:true}).click();await page.getByLabel('帳號名稱',{exact:true}).fill('personal');await page.getByLabel('儲存服務',{exact:true}).selectOption('alias');await page.getByRole('button',{name:'下一步',exact:true}).click();}
for(const platform of ['darwin','win32','linux'])test(`${platform}: primary opens GUI, answers stage and explicit save commits`,async({page})=>{
 await open(page,platform);expect(await page.evaluate(()=>(window as any).__fixture.calls.filter((x:any)=>x.method==='configureRemotes').length)).toBe(0);
 await add(page);await expect(page.getByRole('button',{name:'下一步',exact:true})).toBeDisabled();await page.getByLabel('remote',{exact:true}).fill('/test/source');await page.getByRole('button',{name:'下一步',exact:true}).click();
 await expect(page.getByText('設定完成，儲存後即可使用')).toBeVisible();expect(await page.evaluate(()=>(window as any).__accounts.commits)).toBe(0);
 await page.getByRole('button',{name:'測試連線',exact:true}).click();await expect(page.getByText('連線測試通過。')).toBeVisible();await page.getByRole('button',{name:'儲存',exact:true}).click();await expect(page.locator('.accounts-dialog')).toHaveCount(0);expect(await page.evaluate(()=>(window as any).__accounts.commits)).toBe(1);
});
test('cancel asks before discarding; terminal config remains adjacent',async({page})=>{
 await open(page);await add(page);await page.getByRole('button',{name:'取消',exact:true}).click();await expect(page.getByText('放棄這次尚未儲存的設定？')).toBeVisible();await page.getByRole('button',{name:'放棄變更',exact:true}).click();await expect(page.locator('.accounts-dialog')).toHaveCount(0);expect(await page.evaluate(()=>(window as any).__accounts.cancels)).toBe(1);expect(await page.evaluate(()=>(window as any).__accounts.commits)).toBe(0);
 await page.locator('.terminal-config-link').click();await expect.poll(()=>page.evaluate(()=>(window as any).__fixture.calls.filter((x:any)=>x.method==='configureRemotes').length)).toBe(1);
});
test('required Google client ID stays explicit and accepts no empty answer',async({page})=>{
 await open(page);await page.evaluate(()=>{(window as any).__accounts.question={Name:'client_id',Help:'Enter your own client ID.',Default:'',Required:true,Sensitive:true,Type:'string'};});
 await page.getByRole('button',{name:'編輯 existing'}).click();await expect(page.getByText(/Google 的 client ID/)).toBeVisible();await expect(page.getByRole('button',{name:'下一步',exact:true})).toBeDisabled();await page.getByLabel('client_id',{exact:true}).fill('fixture.apps.googleusercontent.com');await page.getByRole('button',{name:'下一步',exact:true}).click();expect((await page.evaluate(()=>(window as any).__accounts.answers))[0].value).toBe('fixture.apps.googleusercontent.com');
});
test('stored secrets are never filled; keeping them sends a flag instead',async({page})=>{
 await open(page);await page.evaluate(()=>{(window as any).__accounts.question={Name:'client_secret',Help:'Secret',Default:'',Required:true,Sensitive:true,HasSavedValue:true,Type:'string'};});
 await page.getByRole('button',{name:'編輯 existing'}).click();await expect(page.getByLabel('保留現有值')).toBeChecked();await expect(page.getByLabel('client_secret',{exact:true})).toHaveValue('');await expect(page.getByLabel('client_secret',{exact:true})).toBeDisabled();await page.getByRole('button',{name:'下一步',exact:true}).click();expect((await page.evaluate(()=>(window as any).__accounts.answers))[0]).toMatchObject({useDefault:true,value:''});
});
test('unknown provider options and server-defined defaults render without code changes',async({page})=>{
 await open(page);await page.evaluate(()=>{(window as any).__accounts.question={Name:'future_option',Help:'New rclone option',Default:'new-choice',Required:true,Exclusive:true,Examples:[{Value:'old-choice',Help:'Old'},{Value:'new-choice',Help:'New'}]};});
 await page.getByRole('button',{name:'編輯 existing'}).click();await expect(page.getByLabel('future_option',{exact:true})).toHaveValue('new-choice');await page.getByLabel('future_option',{exact:true}).selectOption('old-choice');await page.getByRole('button',{name:'下一步',exact:true}).click();expect((await page.evaluate(()=>(window as any).__accounts.answers))[0].value).toBe('old-choice');
});
test('browser wait is cancellable and native URL is not supplied by renderer',async({page})=>{
 await open(page);await page.evaluate(()=>{(window as any).__accounts.browser=true;});await add(page);await page.getByLabel('remote',{exact:true}).fill('/path');await page.getByRole('button',{name:'下一步',exact:true}).click();await expect(page.getByRole('button',{name:'開啟登入頁面'})).toBeVisible();await page.getByRole('button',{name:'開啟登入頁面'}).click();await expect.poll(()=>page.evaluate(()=>(window as any).__fixture.calls.filter((x:any)=>x.method==='openAccountAuthorization').length)).toBe(1);
 expect((await page.evaluate(()=>(window as any).__fixture.calls.filter((x:any)=>x.method==='openAccountAuthorization')))[0].args).toEqual([]);await page.getByRole('button',{name:'取消',exact:true}).click();await page.getByRole('button',{name:'放棄變更',exact:true}).click();await expect(page.locator('.accounts-dialog')).toHaveCount(0);
});
test('delete explains its scope and requires confirmation',async({page})=>{await open(page);await page.getByRole('button',{name:'移除 existing'}).click();await expect(page.getByText('只移除本機連線設定，不會刪除雲端上的檔案。')).toBeVisible();expect(await page.evaluate(()=>(window as any).__accounts.commits)).toBe(0);await page.getByRole('button',{name:'移除',exact:true}).click();await expect(page.locator('.accounts-dialog')).toHaveCount(0);});
for(const theme of ['purple-light','purple-dark','blue-dark','green-light'])test(`account layout ${theme}`,async({page},info)=>{await open(page,'darwin',theme);await page.setViewportSize({width:1024,height:720});await add(page);await expect(page.locator('.dialog-footer button').last()).toBeInViewport();expect(await page.locator('.accounts-dialog').evaluate(e=>e.scrollWidth<=e.clientWidth+1)).toBe(true);await page.locator('.accounts-dialog').screenshot({path:info.outputPath(`accounts-${theme}.png`)});});
