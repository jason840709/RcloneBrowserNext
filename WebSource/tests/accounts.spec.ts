import {test,expect,type Page} from '@playwright/test';
import {fileURLToPath,pathToFileURL} from 'node:url';
import path from 'node:path';
import {installHostFixture} from './native-fixture';
import {accountTranslator,accountLabel} from '../renderer/account-i18n';
import type {ResolvedLanguage,Theme} from '../shared/types';

const url=process.env.RBN_TEST_URL||pathToFileURL(path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../../Resources/Web/index.html')).href;
async function open(page:Page,options:{platform?:string;theme?:Theme;language?:ResolvedLanguage;existing?:boolean;existingType?:string;locked?:boolean}={}) {
 await installHostFixture(page,{platform:options.platform||'darwin',job:false,settings:{autoCheckUpdates:false,theme:options.theme||'purple-dark',language:options.language||'zh-TW'}});
 await page.goto(url);await page.getByTestId('left-pane').waitFor();
 await page.evaluate(({existing,existingType,locked})=>{
  const w=window as any,previous=w.webkit.messageHandlers.rclone.postMessage;
  const credentials=[{Name:'client_id',Help:'Application client ID. Leave blank to use the shared client.',Default:'',DefaultStr:'',Sensitive:true,Type:'string'},{Name:'client_secret',Help:'Application client secret. Leave blank for shared sign-in.',Default:'',DefaultStr:'',Sensitive:true,Type:'string'}];
  const providers=[
   {name:'alias',description:'Alias',quickSetup:false,options:[{Name:'remote',Help:'Remote or path to alias.',Required:true,Type:'string',Default:''}]},
   {name:'s3',description:'S3',quickSetup:false,options:[{Name:'provider',Help:'Choose your S3 provider.',Required:true,Exclusive:true,Default:'',Examples:[{Value:'AWS',Help:'Amazon Web Services'},{Value:'Minio',Help:'MinIO'}]},{Name:'region',Help:'Region to connect to.',Provider:'AWS,Ceph',Default:''},{Name:'endpoint',Help:'Endpoint for an S3-compatible service.',Provider:'!AWS',Default:''},{Name:'storage_class',Help:'Storage class for new objects.',Provider:'AWS',Default:''}]},
   {name:'webdav',description:'WebDAV',quickSetup:false,options:[{Name:'url',Help:'The URL of the WebDAV service.',Required:true,Default:''},{Name:'vendor',Help:'Name of the WebDAV site.',Default:'',Examples:[{Value:'nextcloud',Help:'Nextcloud'},{Value:'other',Help:'Other site/service or software'}]},{Name:'user',Help:'User name.',Sensitive:true,Default:''},{Name:'pass',Help:'Password.',IsPassword:true,Default:''}]},
   {name:'dropbox',description:'Dropbox',quickSetup:true,options:credentials},
   {name:'onedrive',description:'Microsoft OneDrive',quickSetup:true,options:[...credentials,{Name:'region',Help:'Microsoft cloud region.',Default:'global',Examples:[{Value:'global',Help:'Microsoft Cloud Global'},{Value:'us',Help:'Microsoft Cloud for US Government'}]}]},
   {name:'sftp',description:'SSH/SFTP',quickSetup:false,options:[{Name:'host',Help:'SSH host to connect to.',Required:true,Sensitive:true,Default:''},{Name:'user',Help:'SSH user name.',Sensitive:true,Default:''},{Name:'port',Help:'SSH port.',Default:22,Type:'int'},{Name:'pass',Help:'SSH password, leave blank to use ssh-agent.',IsPassword:true,Default:''},{Name:'key_file',Help:'Path to a PEM private key.',Default:'',Advanced:true}]},
   {name:'drive',description:'Google Drive',quickSetup:true,options:[...credentials,{Name:'scope',Help:'Comma separated list of scopes that rclone should use when requesting access from drive.',Default:'',Examples:[{Value:'drive',Help:'Full access all files, excluding Application Data Folder.'},{Value:'drive.readonly',Help:'Read-only access to file metadata and file contents.'},{Value:'drive.file',Help:'Access to files created by rclone only.\nThese are visible in the drive website.\nFile authorization is revoked when the user deauthorizes the app.'},{Value:'drive.appfolder',Help:'Allows read and write access to the Application Data folder.\nThis is not visible in the drive website.'},{Value:'drive.metadata.readonly',Help:'Allows read-only access to file metadata but does not allow any access to read or download file content.'}]},{Name:'service_account_file',Help:'Service Account Credentials JSON file path.\n\nLeave blank normally.',Default:''},{Name:'root_folder_id',Help:'ID of the root folder.',Default:'',Advanced:true},{Name:'future_option',Help:'A future option provided by the installed rclone.',Default:'server-default',Advanced:true}]},
  ];
  const state=w.__accounts={providers,remotes:existing?[{name:'existing',type:existingType||'drive'}]:[],requiresUnlock:locked,unlocks:0,commits:0,cancels:0,starts:[],answers:[],serial:0,id:'',name:'',provider:'drive',mode:'create',setup:'quick',autoSave:false,phase:'',step:0,browser:false,question:null,error:'',finish:false,completeMarked:false,failFirstStart:false,startQuestion:null,cancelPolls:0,cancelRemaining:0,cancelPending:false,overlap:false};
  const snapshot=()=>({id:state.id,name:state.name,provider:state.provider,mode:state.mode,setup:state.setup,autoSave:state.autoSave,phase:state.phase,step:state.step,question:state.phase==='question'?state.question:null,error:state.error,configPath:'/test/rclone.conf',canOpenBrowser:state.phase==='running'&&state.browser&&!state.cancelPending,authorizationStarted:state.browser,tested:false,needsInputReason:state.phase==='question'?'additional-input':undefined});
  const complete=()=>{
   if(state.completeMarked)return;state.completeMarked=true;state.commits++;
   if(state.mode==='delete')state.remotes=state.remotes.filter((item:any)=>item.name!==state.name);
   else if(!state.remotes.some((item:any)=>item.name===state.name))state.remotes.push({name:state.name,type:state.provider});
   w.__fixture.bootstrap.remotes=[...w.__fixture.bootstrap.remotes.filter((item:any)=>item.name!==state.name),...(state.mode==='delete'?[]:[{name:state.name,type:state.provider,group:'cloud'}])];
  };
  w.webkit.messageHandlers.rclone.postMessage=(message:any)=>{
   if(!['accountConfig','openAccountAuthorization','unlockConfig'].includes(message.method)){previous(message);return;}
   w.__fixture.calls.push(structuredClone(message));const args=message.args[0]||{};let result:any;
   try {
    if(message.method==='openAccountAuthorization')result=null;
    else if(message.method==='unlockConfig'){state.requiresUnlock=false;state.unlocks++;result=null;}
    else switch(args.action){
     case 'info':result={providers:state.providers,remotes:state.remotes,requiresUnlock:state.requiresUnlock,configPath:'/test/rclone.conf',binary:'/bin/rclone'};break;
     case 'start':
      if(state.phase&&!['cancelled','committed'].includes(state.phase))state.overlap=true;
      state.starts.push(structuredClone(args));state.id=`session-${++state.serial}`;state.name=args.name;state.provider=args.provider;state.mode=args.mode;state.setup=args.setup;state.autoSave=args.autoSave;state.step=1;state.error='';state.finish=false;state.completeMarked=false;state.browser=false;state.cancelPending=false;
      if(args.mode==='delete')state.phase='ready';
      else if(state.failFirstStart&&state.serial===1){state.phase='error';state.error='Authorization rejected by service';}
      else if(state.startQuestion){state.phase='question';state.question=state.startQuestion;}
      else if(args.setup==='quick'&&['drive','onedrive','dropbox'].includes(args.provider)){state.phase='running';state.browser=true;}
      else if(args.autoSave){state.phase='committed';complete();}
      else state.phase='ready';
      result=snapshot();break;
     case 'answer':state.answers.push(structuredClone(args));state.step++;state.question=null;if(state.autoSave){state.phase='running';state.browser=true;}else state.phase='ready';result=snapshot();break;
     case 'poll':
      if(state.cancelPending){if(state.cancelRemaining-->0)state.phase='running';else{state.phase='cancelled';state.cancelPending=false;}}
      else if(state.finish){state.phase=state.autoSave?'committed':'ready';if(state.phase==='committed')complete();}
      result=snapshot();break;
     case 'cancel':state.cancels++;state.browser=false;state.cancelRemaining=state.cancelPolls;state.cancelPending=state.cancelRemaining>0;state.phase=state.cancelPending?'running':'cancelled';result=snapshot();break;
     case 'commit':state.phase='committed';complete();result=snapshot();break;
     case 'test':result={...snapshot(),tested:true};break;
    }
    setTimeout(()=>w.__rbnReply({id:message.id,result}),5);
   } catch(error){setTimeout(()=>w.__rbnReply({id:message.id,error:{message:String(error)}}),5);}
  };
 },{existing:!!options.existing,existingType:options.existingType,locked:!!options.locked});
 await page.locator('.account-setup-button').click();
 await expect(page.locator('.accounts-dialog')).toBeVisible();
 await expect(page.locator('.account-body [role="status"]')).toHaveCount(0);
}
async function calls(page:Page,method:string){return page.evaluate(method=>(window as any).__fixture.calls.filter((call:any)=>call.method===method),method);}
async function starts(page:Page){return page.evaluate(()=>(window as any).__accounts.starts);}
async function finishSignIn(page:Page){await page.evaluate(()=>{(window as any).__accounts.finish=true;});await expect(page.locator('.accounts-dialog')).toHaveCount(0);}
async function nameAccount(page:Page,name='個人雲端'){await page.getByLabel('帳號名稱',{exact:true}).fill(name);}

for(const platform of ['darwin','win32','linux'])test(`${platform}: quick setup goes from name and service to browser sign-in and automatic save`,async({page},testInfo)=>{
 await open(page,{platform});
 await expect(page.getByRole('radio',{name:'快速設定',exact:true})).toBeChecked();
 await expect(page.getByLabel('帳號名稱',{exact:true})).toBeFocused();
 await expect(page.getByLabel('雲端或伺服器',{exact:true})).toHaveValue('drive');
 await expect(page.locator('.account-body').getByRole('textbox')).toHaveCount(1);
 await expect(page.getByText('設定檔已加密？')).toHaveCount(0);
 await expect(page.locator('.account-config code')).not.toBeVisible();
 expect(await calls(page,'configureRemotes')).toHaveLength(0);
 const services=await page.getByLabel('雲端或伺服器').locator('option').evaluateAll(nodes=>nodes.map(node=>(node as HTMLOptionElement).value));
 expect(services.slice(0,3)).toEqual(['drive','onedrive','dropbox']);
 await nameAccount(page);
 if(platform==='darwin')await page.screenshot({path:testInfo.outputPath('accounts-quick-standard-zh-TW-purple-dark.png')});
 await page.getByRole('button',{name:'登入並新增帳號',exact:true}).click();
 expect((await starts(page))[0]).toMatchObject({mode:'create',name:'個人雲端',provider:'drive',setup:'quick',fields:{},useSharedClient:true,autoSave:true});
 await expect(page.getByText('等待瀏覽器登入',{exact:true})).toBeVisible();
 await expect.poll(async()=>(await calls(page,'openAccountAuthorization')).length).toBe(1);
 expect((await calls(page,'openAccountAuthorization'))[0].args).toEqual([]);
 await finishSignIn(page);
 await expect(page.getByText('帳號設定已儲存。',{exact:true})).toBeVisible();
 expect(await page.evaluate(()=>(window as any).__accounts.commits)).toBe(1);
 expect((await calls(page,'accountConfig')).filter((call:any)=>call.args[0].action==='commit')).toHaveLength(0);
 await expect.poll(async()=>(await calls(page,'bootstrap')).length).toBeGreaterThan(1);
});

test('custom ID and secret stay on one optional panel and change the selected sign-in route',async({page})=>{
 await open(page);await nameAccount(page);
 await page.getByText('自訂登入憑證（通常可不填）',{exact:true}).click();
 await expect(page.getByLabel(accountLabel('client_id','zh-TW'),{exact:true})).toBeVisible();
 await expect(page.getByLabel(accountLabel('client_secret','zh-TW'),{exact:true})).toBeVisible();
 await expect(page.getByRole('button',{name:'登入並新增帳號',exact:true})).toBeEnabled();
 await page.getByLabel(accountLabel('client_secret','zh-TW'),{exact:true}).fill('fixture-secret');
 await expect(page.getByRole('button',{name:'登入並新增帳號',exact:true})).toBeDisabled();
 await page.getByLabel(accountLabel('client_id','zh-TW'),{exact:true}).fill('fixture.apps.googleusercontent.com');
 await page.getByRole('button',{name:'登入並新增帳號',exact:true}).click();
 expect((await starts(page))[0]).toMatchObject({useSharedClient:false,fields:{client_id:'fixture.apps.googleusercontent.com',client_secret:'fixture-secret'}});
 await finishSignIn(page);
});

test('changing services does not carry another service’s credentials',async({page})=>{
 await open(page);await nameAccount(page);await page.getByText('自訂登入憑證（通常可不填）',{exact:true}).click();
 await page.getByLabel(accountLabel('client_id','zh-TW'),{exact:true}).fill('google-only-client');
 await page.getByLabel('雲端或伺服器').selectOption('dropbox');
 await page.getByRole('button',{name:'登入並新增帳號',exact:true}).click();
 expect((await starts(page))[0]).toMatchObject({provider:'dropbox',fields:{},useSharedClient:true});
 await finishSignIn(page);
});

test('detailed setup submits all edited options in one batch and saves only on confirmation',async({page})=>{
 await open(page);await page.getByRole('radio',{name:'詳細設定',exact:true}).check();await nameAccount(page,'團隊資料');
 await page.getByLabel(accountLabel('client_id','zh-TW'),{exact:true}).fill('custom-client');
 await page.getByLabel(accountLabel('client_secret','zh-TW'),{exact:true}).fill('custom-secret');
 await page.getByRole('radio',{name:'唯讀（可瀏覽和下載，不能修改）',exact:true}).check();
 await page.getByLabel('服務帳戶金鑰檔案',{exact:true}).fill('/test/credentials.json');
 await page.locator('.account-advanced > summary').click();
 await page.getByLabel('起始資料夾 ID',{exact:true}).fill('folder-123');
 await expect(page.getByLabel('Future option',{exact:true})).toHaveValue('server-default');
 await page.getByRole('button',{name:'繼續設定',exact:true}).click();
 expect((await starts(page))[0]).toMatchObject({setup:'detailed',autoSave:false,fields:{client_id:'custom-client',client_secret:'custom-secret',scope:'drive.readonly',service_account_file:'/test/credentials.json',root_folder_id:'folder-123'}});
 expect((await starts(page))[0].fields).not.toHaveProperty('future_option');
 await expect(page.getByText('設定完成，儲存後即可使用')).toBeVisible();
 expect(await page.evaluate(()=>(window as any).__accounts.commits)).toBe(0);
 await page.getByRole('button',{name:'測試連線',exact:true}).click();await expect(page.getByText('連線測試通過。')).toBeVisible();
 await page.getByRole('button',{name:'儲存',exact:true}).click();await expect(page.locator('.accounts-dialog')).toHaveCount(0);
 expect(await page.evaluate(()=>(window as any).__accounts.answers)).toEqual([]);
});

for(const provider of ['sftp','webdav'])test(`${provider}: connection details are entered together without requiring a password`,async({page})=>{
 await open(page);await nameAccount(page,'家用伺服器');await page.getByLabel('雲端或伺服器').selectOption(provider);
 await expect(page.getByRole('button',{name:'新增帳號',exact:true})).toBeDisabled();
 await page.getByLabel(provider==='sftp'?'伺服器位址':'服務網址',{exact:true}).fill(provider==='sftp'?'nas.example.com':'https://nas.example.com/dav');
 await page.getByLabel('使用者名稱',{exact:true}).fill('jason');
 if(provider==='sftp')await expect(page.getByLabel('連接埠',{exact:true})).toHaveValue('22');
 else await page.getByRole('radio',{name:'其他 WebDAV 服務',exact:true}).check();
 await expect(page.getByLabel('密碼',{exact:true})).toHaveValue('');
 await page.getByRole('button',{name:'新增帳號',exact:true}).click();
 await expect(page.locator('.accounts-dialog')).toHaveCount(0);
 const request=(await starts(page))[0];expect(request).toMatchObject({provider,setup:'quick',autoSave:true});expect(request.fields).toMatchObject({user:'jason'});expect(request.fields).not.toHaveProperty('pass');
});

test('only a genuinely locked configuration asks for a password',async({page})=>{
 await open(page,{locked:true});await expect(page.getByText('解鎖設定檔',{exact:true})).toBeVisible();
 await expect(page.getByLabel('帳號名稱',{exact:true})).toHaveCount(0);
 await page.getByLabel('設定檔密碼',{exact:true}).fill('fixture-password');
 await page.getByRole('button',{name:'解鎖並繼續',exact:true}).click();
 await expect(page.getByLabel('帳號名稱',{exact:true})).toBeVisible();
 await expect(page.getByLabel('設定檔密碼',{exact:true})).toHaveCount(0);
 expect(await page.evaluate(()=>(window as any).__accounts.unlocks)).toBe(1);
});

test('invalid dot-only names are rejected before starting a native session',async({page})=>{
 await open(page);
 for(const value of ['.','..']){await nameAccount(page,value);await expect(page.getByRole('button',{name:'登入並新增帳號',exact:true})).toBeDisabled();await expect(page.locator('#account-name-error')).toBeVisible();}
 expect(await starts(page)).toEqual([]);
 await nameAccount(page,'my.drive');await expect(page.getByRole('button',{name:'登入並新增帳號',exact:true})).toBeEnabled();
});

test('a newly required advanced field stays visible and focusable while being filled',async({page})=>{
 await open(page);await page.locator('.account-footer').getByRole('button',{name:'關閉',exact:true}).click();
 await page.evaluate(()=>{(window as any).__accounts.providers.find((provider:any)=>provider.name==='drive').options.push({Name:'future_required',Help:'Required advanced detail.',Required:true,Advanced:true,Default:''});});
 await page.locator('.account-setup-button').click();await page.getByRole('radio',{name:'詳細設定',exact:true}).check();await nameAccount(page);
 const required=page.getByLabel('Future required',{exact:true});await expect(required).toBeVisible();
 await expect(page.getByRole('button',{name:'繼續設定',exact:true})).toBeDisabled();
 await required.fill('required-value');await expect(required).toBeVisible();await expect(required).toBeFocused();
 await page.getByRole('button',{name:'繼續設定',exact:true}).click();
 expect((await starts(page))[0].fields.future_required).toBe('required-value');
});

test('a new required question can be answered and the quick journey resumes',async({page})=>{
 await open(page);await page.evaluate(()=>{(window as any).__accounts.startQuestion={Name:'future_required',Help:'An option introduced by a later rclone.\n'.repeat(30),Required:true,Default:''};});
 await nameAccount(page);await page.getByRole('button',{name:'登入並新增帳號',exact:true}).click();
 await expect(page.getByRole('button',{name:'繼續',exact:true})).toBeDisabled();
 await page.getByLabel('Future required',{exact:true}).fill('confirmed');
 await page.getByRole('button',{name:'繼續',exact:true}).click();
 expect((await page.evaluate(()=>(window as any).__accounts.answers))[0]).toMatchObject({value:'confirmed',useDefault:false});
 await expect.poll(async()=>(await calls(page,'openAccountAuthorization')).length).toBe(1);
 await finishSignIn(page);
});

test('a required personal client ID offers a way back instead of a dead end',async({page})=>{
 await open(page);await page.evaluate(()=>{(window as any).__accounts.startQuestion={Name:'client_id',Help:'Enter your own client ID.',Required:true,Sensitive:true,Default:''};(window as any).__accounts.cancelPolls=2;});
 await nameAccount(page);await page.getByRole('button',{name:'登入並新增帳號',exact:true}).click();
 await expect(page.getByText(/這次登入需要自訂憑證/)).toBeVisible();
 await expect(page.getByRole('button',{name:'繼續',exact:true})).toBeDisabled();
 await page.getByRole('button',{name:'返回修改',exact:true}).click();
 await expect(page.getByLabel('帳號名稱',{exact:true})).toHaveValue('個人雲端');
 await page.evaluate(()=>{(window as any).__accounts.startQuestion=null;});
 await page.getByText('自訂登入憑證（通常可不填）',{exact:true}).click();
 await page.getByLabel(accountLabel('client_id','zh-TW'),{exact:true}).fill('new-client');
 await page.getByRole('button',{name:'登入並新增帳號',exact:true}).click();
 expect(await page.evaluate(()=>(window as any).__accounts.overlap)).toBe(false);
 expect((await starts(page))[1]).toMatchObject({useSharedClient:false,fields:{client_id:'new-client'}});
 await finishSignIn(page);
});

test('failed sign-in can retry after native cancellation finishes',async({page})=>{
 await open(page);await page.evaluate(()=>{(window as any).__accounts.failFirstStart=true;(window as any).__accounts.cancelPolls=2;});
 await nameAccount(page);await page.getByRole('button',{name:'登入並新增帳號',exact:true}).click();
 await expect(page.getByText('連結尚未完成。可以返回修改，或重新嘗試。',{exact:true})).toBeVisible();
 await page.getByRole('button',{name:'重新嘗試',exact:true}).click();
 await expect(page.getByText('等待瀏覽器登入',{exact:true})).toBeVisible();
 expect(await page.evaluate(()=>(window as any).__accounts.overlap)).toBe(false);
 expect(await starts(page)).toHaveLength(2);
 await finishSignIn(page);
});

test('browser opening is automatic once per attempt and can be reopened explicitly',async({page})=>{
 await open(page);await nameAccount(page);await page.getByRole('button',{name:'登入並新增帳號',exact:true}).click();
 await expect.poll(async()=>(await calls(page,'openAccountAuthorization')).length).toBe(1);
 await expect.poll(async()=>(await calls(page,'accountConfig')).filter((call:any)=>call.args[0].action==='poll').length).toBeGreaterThan(1);
 expect(await calls(page,'openAccountAuthorization')).toHaveLength(1);
 await page.getByRole('button',{name:'重新開啟登入頁面',exact:true}).click();
 await expect.poll(async()=>(await calls(page,'openAccountAuthorization')).length).toBe(2);
 await page.getByRole('button',{name:'取消',exact:true}).click();await page.getByRole('button',{name:'放棄變更',exact:true}).click();
 await expect(page.locator('.accounts-dialog')).toHaveCount(0);
 expect(await page.evaluate(()=>(window as any).__accounts.commits)).toBe(0);
 await page.locator('.terminal-config-link').click();await expect.poll(async()=>(await calls(page,'configureRemotes')).length).toBe(1);
});

test('OneDrive lets the user choose between multiple returned drives',async({page})=>{
 await open(page);await page.evaluate(()=>{(window as any).__accounts.startQuestion={Name:'config_driveid',Help:'Select drive.',Required:true,Exclusive:true,Examples:[{Value:'drive-a',Help:'個人文件'},{Value:'drive-b',Help:'部門共用文件'}]};});
 await nameAccount(page);await page.getByLabel('雲端或伺服器').selectOption('onedrive');await page.getByRole('button',{name:'登入並新增帳號',exact:true}).click();
 await page.getByRole('radio',{name:'部門共用文件',exact:true}).check();await page.getByRole('button',{name:'繼續',exact:true}).click();
 expect((await page.evaluate(()=>(window as any).__accounts.answers))[0].value).toBe('drive-b');await finishSignIn(page);
});

test('editing batches only changed fields and never prefills saved secrets',async({page})=>{
 await open(page,{existing:true});await page.getByRole('button',{name:'編輯 existing',exact:true}).click();
 await expect(page.getByLabel(accountLabel('client_secret','zh-TW'),{exact:true})).toHaveValue('');
 await page.locator('.account-advanced > summary').click();await page.getByLabel('起始資料夾 ID',{exact:true}).fill('new-root');
 await page.getByRole('button',{name:'檢查變更',exact:true}).click();
 expect((await starts(page))[0]).toMatchObject({mode:'edit',setup:'detailed',autoSave:false,fields:{root_folder_id:'new-root'}});
 expect((await starts(page))[0].fields).not.toHaveProperty('client_secret');
 await page.getByRole('button',{name:'儲存',exact:true}).click();await expect(page.locator('.accounts-dialog')).toHaveCount(0);
});

test('S3 editing keeps conditional fields available until a provider is selected and sends only applicable changes',async({page})=>{
 await open(page,{existing:true,existingType:'s3'});await page.getByRole('button',{name:'編輯 existing',exact:true}).click();
 for(const name of ['region','endpoint','storage_class'])await expect(page.locator(`[data-option-name="${name}"] input`)).toBeVisible();
 await page.getByLabel('服務地區',{exact:true}).fill('us-east-2');
 await page.getByRole('button',{name:'檢查變更',exact:true}).click();
 expect((await starts(page))[0]).toMatchObject({mode:'edit',provider:'s3',setup:'detailed',fields:{region:'us-east-2'}});
 expect((await starts(page))[0].fields).toEqual({region:'us-east-2'});
 await page.getByRole('button',{name:'儲存',exact:true}).click();await expect(page.locator('.accounts-dialog')).toHaveCount(0);
 await page.locator('.account-setup-button').click();await page.getByRole('button',{name:'編輯 existing',exact:true}).click();
 await page.getByLabel('服務端點網址',{exact:true}).fill('https://previous-provider.example.com');
 await page.locator('[data-option-name="provider"]').getByRole('radio',{name:'Amazon Web Services',exact:true}).check();
 await expect(page.locator('[data-option-name="endpoint"]')).toHaveCount(0);
 await expect(page.locator('[data-option-name="region"] input')).toBeVisible();
 await expect(page.locator('[data-option-name="storage_class"] input')).toBeVisible();
 await page.getByLabel('服務地區',{exact:true}).fill('eu-west-1');
 await page.getByRole('button',{name:'檢查變更',exact:true}).click();
 expect((await starts(page))[1].fields).toEqual({provider:'AWS',region:'eu-west-1'});
 await page.getByRole('button',{name:'儲存',exact:true}).click();await expect(page.locator('.accounts-dialog')).toHaveCount(0);
});

test('a stored secret in a follow-up question stays hidden and keeps its native default',async({page})=>{
 await open(page,{existing:true});await page.evaluate(()=>{(window as any).__accounts.startQuestion={Name:'client_secret',Help:'Secret',Default:'',Required:true,Sensitive:true,HasSavedValue:true,Type:'string'};});
 await page.getByRole('button',{name:'編輯 existing',exact:true}).click();await page.getByRole('button',{name:'檢查變更',exact:true}).click();
 await expect(page.getByLabel('保留現有值',{exact:true})).toBeChecked();
 await expect(page.getByLabel(accountLabel('client_secret','zh-TW'),{exact:true})).toHaveValue('');
 await expect(page.getByLabel(accountLabel('client_secret','zh-TW'),{exact:true})).toBeDisabled();
 await page.getByRole('button',{name:'繼續',exact:true}).click();
 expect((await page.evaluate(()=>(window as any).__accounts.answers))[0]).toMatchObject({useDefault:true,value:''});
});

test('removal explains its local scope and requires explicit confirmation',async({page})=>{
 await open(page,{existing:true});await page.getByRole('button',{name:'移除 existing',exact:true}).click();
 await expect(page.getByText('只移除本機連線設定，不會刪除雲端上的檔案。')).toBeVisible();
 expect(await page.evaluate(()=>(window as any).__accounts.commits)).toBe(0);
 await page.getByRole('button',{name:'移除',exact:true}).click();await expect(page.locator('.accounts-dialog')).toHaveCount(0);
});

test('the complete quick journey works with the keyboard and Escape confirms cancellation',async({page})=>{
 await open(page);await page.keyboard.type('keyboard-drive');await page.keyboard.press('Tab');
 await expect(page.getByLabel('雲端或伺服器')).toBeFocused();
 await page.keyboard.press('ArrowDown');await page.keyboard.press('Enter');
 await page.getByRole('button',{name:'登入並新增帳號',exact:true}).focus();await page.keyboard.press('Enter');
 await expect(page.getByText('等待瀏覽器登入',{exact:true})).toBeVisible();
 await page.keyboard.press('Escape');await expect(page.getByText('放棄這次尚未完成的設定？')).toBeVisible();
 await page.getByRole('button',{name:'繼續設定',exact:true}).click();
 await finishSignIn(page);
});

const themes:Theme[]=['purple-light','purple-dark','blue-light','blue-dark','green-light','green-dark'];
for(const [i,theme] of themes.entries())test(`readable long choices at narrow 200% equivalent viewport: ${theme}`,async({page},testInfo)=>{
 const language:ResolvedLanguage=(['zh-TW','en','ja'] as const)[i%3],a=accountTranslator(language);
 // 1280×900 at 200% browser/native zoom has a 640×450 CSS viewport.
 await page.setViewportSize({width:640,height:450});await open(page,{theme,language});
 await page.getByRole('radio',{name:a('detailed'),exact:true}).check();
 await page.getByLabel(a('accountName'),{exact:true}).fill('shared-drive');
 const scope=page.locator('[data-option-name="scope"]');await scope.scrollIntoViewIfNeeded();
 const rows=scope.locator('.account-choice');
 expect(await rows.evaluateAll(elements=>elements.every(element=>{
  const row=element.getBoundingClientRect(),copy=element.querySelector('span')!.getBoundingClientRect();
  return copy.bottom<=row.bottom+1&&copy.right<=row.right+1&&element.scrollWidth<=element.clientWidth+1;
 }))).toBe(true);
 await rows.filter({has:page.locator('input[value="drive.readonly"]')}).click();
 await expect(page.locator('.account-footer .primary')).toBeInViewport();
 const dialog=page.locator('.accounts-dialog');
 expect(await dialog.evaluate(element=>element.scrollWidth<=element.clientWidth+1)).toBe(true);
 await dialog.screenshot({path:testInfo.outputPath(`accounts-detailed-${theme}-${language}.png`)});
 await page.getByRole('button',{name:a('prepare'),exact:true}).click();
 expect((await starts(page))[0].fields.scope).toBe('drive.readonly');
 await page.getByRole('button',{name:a('save'),exact:true}).click();await expect(dialog).toHaveCount(0);
});

test('quick form and expandable details fit a very narrow window without hiding actions',async({page},testInfo)=>{
 await page.setViewportSize({width:360,height:580});await open(page);await nameAccount(page);
 await expect(page.locator('.account-footer .primary')).toBeInViewport();
 await page.locator('.accounts-dialog').screenshot({path:testInfo.outputPath('accounts-quick-narrow.png')});
 await page.getByText('自訂登入憑證（通常可不填）',{exact:true}).click();
 await page.getByLabel(accountLabel('client_secret','zh-TW'),{exact:true}).scrollIntoViewIfNeeded();
 expect(await page.locator('.accounts-dialog').evaluate(element=>element.scrollWidth<=element.clientWidth+1)).toBe(true);
 await expect(page.locator('.account-footer .primary')).toBeInViewport();
 await page.getByRole('button',{name:'登入並新增帳號',exact:true}).click();
 expect(await page.locator('.progress-indicator').evaluate(element=>getComputedStyle(element).animationName)).toBe('none');
 await finishSignIn(page);
});
