import {expect,test,type Page} from '@playwright/test';
import {installHostFixture} from './native-fixture';
import {fileURLToPath,pathToFileURL} from 'node:url';
import path from 'node:path';
const url=pathToFileURL(path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../../Resources/Web/index.html')).href;
async function open(page:Page,platform='darwin',language:'zh-TW'|'en'|'ja'='zh-TW',theme:any='purple-dark') {
  await installHostFixture(page,{platform,job:false,settings:{autoCheckUpdates:false,language,theme}});
  await page.goto(url);await page.getByTestId('left-pane').waitFor();
}
const dialog=(page:Page)=>page.locator('.account-dialog');
const calls=(page:Page,method:string)=>page.evaluate(m=>(window as any).__fixture.calls.filter((x:any)=>x.method===m),method);
for(const platform of ['darwin','win32','linux']) {
  test(`${platform}: graphical account button and traditional config are separate`,async({page})=>{
    await open(page,platform);
    await page.locator('.account-terminal-button').click();expect((await calls(page,'configureRemotes')).length).toBe(1);
    await page.locator('.account-setup-button').click();await expect(dialog(page)).toBeVisible();
    await expect(dialog(page).getByText('research-drive',{exact:true})).toBeVisible();
    expect((await calls(page,'configureRemotes')).length).toBe(1);
    await dialog(page).getByRole('button',{name:'新增帳號',exact:true}).click();
    await dialog(page).getByLabel('帳號名稱',{exact:true}).fill('gui-alias');
    await dialog(page).getByRole('listbox',{name:'儲存服務'}).selectOption('alias');
    await dialog(page).getByRole('button',{name:'下一步',exact:true}).click();
    await expect(dialog(page).getByRole('button',{name:'下一步',exact:true})).toBeDisabled();
    await dialog(page).getByRole('textbox',{name:'遠端位置或本機路徑',exact:true}).fill('/tmp/test');
    await dialog(page).getByRole('button',{name:'下一步',exact:true}).click();
    expect((await calls(page,'accountCommit')).length).toBe(0);
    await expect(dialog(page).getByText('設定完成，儲存後即可使用。')).toBeVisible();
    await dialog(page).getByRole('button',{name:'儲存帳號',exact:true}).click();
    await expect(dialog(page).getByText('gui-alias',{exact:true})).toBeVisible();
    expect((await calls(page,'accountCommit')).length).toBe(1);
  });
}
test('cancel from a question discards the transaction without save',async({page})=>{
  await open(page);await page.locator('.account-setup-button').click();
  await dialog(page).getByRole('button',{name:'編輯 research-drive',exact:true}).click();
  await expect(dialog(page).getByRole('textbox',{name:'遠端位置或本機路徑',exact:true})).toBeVisible();
  await page.keyboard.press('Escape');await expect(dialog(page)).toHaveCount(0);
  expect((await calls(page,'accountCancel')).length).toBeGreaterThan(0);
  expect((await calls(page,'accountCommit')).length).toBe(0);
});
test('delete asks for confirmation and changes only the remote entry',async({page})=>{
  await open(page);await page.locator('.account-setup-button').click();
  await dialog(page).getByRole('button',{name:'移除 research-drive',exact:true}).click();
  await expect(dialog(page).getByText('確認移除此帳號設定？雲端與本機檔案都不會刪除。')).toBeVisible();
  expect((await calls(page,'accountCommit')).length).toBe(0);
  await dialog(page).getByRole('button',{name:'移除帳號設定',exact:true}).click();
  await expect(dialog(page).getByText('research-drive',{exact:true})).toHaveCount(0);
  expect((await calls(page,'remove')).length).toBe(0);
});
test('new provider fields render without a hardcoded provider form',async({page})=>{
  await open(page);
  await page.evaluate(()=>{(window as any).__fixture.accountQuestion={Name:'future_region',Help:'A new field supplied by the installed engine.',Type:'string',Required:true,Exclusive:true,Default:'east',Examples:[{Value:'east',Help:'East region'},{Value:'west',Help:'West region'}]};});
  await page.locator('.account-setup-button').click();await dialog(page).getByRole('button',{name:'新增帳號',exact:true}).click();
  await dialog(page).getByLabel('帳號名稱',{exact:true}).fill('future-account');
  await dialog(page).getByRole('listbox',{name:'儲存服務'}).selectOption('future');
  await dialog(page).getByRole('button',{name:'下一步',exact:true}).click();
  await expect(dialog(page).getByRole('heading',{name:'future_region',exact:true})).toBeVisible();
  await dialog(page).getByLabel('West region west',{exact:true}).check();
  await dialog(page).getByRole('button',{name:'下一步',exact:true}).click();
  expect((await calls(page,'accountAnswer'))[0].args[1]).toMatchObject({value:'west',step:1});
});
test('stored password stays masked and keeping it sends only the default choice',async({page})=>{
  await open(page);await page.evaluate(()=>{(window as any).__fixture.accountQuestion={Name:'client_secret',Help:'OAuth client secret',Type:'string',Default:'',IsPassword:true,hasDefault:true,Required:false};});
  await page.locator('.account-setup-button').click();await dialog(page).getByRole('button',{name:'編輯 research-drive',exact:true}).click();
  await expect(dialog(page).getByLabel('保留已儲存的值')).toBeChecked();
  const input=dialog(page).locator('input[type="password"]');await expect(input).toHaveValue('');await expect(input).toBeDisabled();
  await dialog(page).getByRole('button',{name:'下一步',exact:true}).click();
  expect((await calls(page,'accountAnswer'))[0].args[1]).toMatchObject({useDefault:true});
});
test('Google own-client requirement is visible and blank is not resubmitted',async({page})=>{
  await open(page);await page.evaluate(()=>{(window as any).__fixture.accountQuestion={Name:'client_id',Help:'Google Application Client Id. This value is required.',Type:'string',Default:'',Required:true};});
  await page.locator('.account-setup-button').click();await dialog(page).getByRole('button',{name:'新增帳號',exact:true}).click();
  await dialog(page).getByLabel('帳號名稱',{exact:true}).fill('google');await dialog(page).getByRole('button',{name:'下一步',exact:true}).click();
  await expect(dialog(page).getByRole('button',{name:'下一步',exact:true})).toBeDisabled();
  await expect(dialog(page).getByRole('button',{name:'如何建立自己的 Google 用戶端 ID'})).toBeVisible();
  expect((await calls(page,'accountAnswer')).length).toBe(0);
});
for(const language of ['zh-TW','en','ja'] as const) {
  test(`${language}: settings opens account GUI and preserves keyboard close`,async({page})=>{
    await open(page,'darwin',language);await page.keyboard.press('Control+,');
    await page.locator('.settings-dialog .section-actions button.primary').first().click();
    await expect(dialog(page)).toBeVisible();await page.keyboard.press('Escape');await expect(dialog(page)).toHaveCount(0);
  });
}
for(const theme of ['purple-light','purple-dark','green-light','green-dark','blue-light','blue-dark']){
  test(`${theme}: account layout stays within dialog`,async({page},info)=>{
    await open(page,'darwin','zh-TW',theme);await page.locator('.account-setup-button').click();
    await dialog(page).getByRole('button',{name:'新增帳號',exact:true}).click();
    await expect(dialog(page).getByRole('listbox')).toBeVisible();
    const d=await dialog(page).evaluate(e=>({scroll:e.scrollWidth,width:e.clientWidth,height:e.getBoundingClientRect().height,available:innerHeight}));
    expect(d.scroll).toBeLessThanOrEqual(d.width+1);expect(d.height).toBeLessThanOrEqual(d.available);
    await dialog(page).screenshot({path:info.outputPath(`accounts-${theme}.png`)});
  });
}
