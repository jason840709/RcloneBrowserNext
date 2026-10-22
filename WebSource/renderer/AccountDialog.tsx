import {useEffect, useRef, useState} from 'react';
import {ArrowClockwise, ArrowLeft, ArrowSquareOut, CheckCircle, Cloud, FolderOpen, PencilSimple, Plus, Trash, SpinnerGap} from '@phosphor-icons/react';
import type {AccountCatalog, AccountSession, ResolvedLanguage} from '../shared/types';
import type {Translate} from './i18n';
import {Dialog, Field, Notice} from './components';
import {errorMessage} from './utils';

const copy = {
  'zh-TW': {
    title:'帳號設定', add:'新增帳號', edit:'編輯', remove:'移除', empty:'尚未設定帳號', name:'帳號名稱', service:'儲存服務', search:'搜尋服務名稱', next:'下一步', save:'儲存帳號', back:'回到帳號清單', cancel:'取消設定', close:'關閉', refresh:'重新整理', loading:'正在讀取 rclone 設定…', working:'rclone 正在處理設定或等待瀏覽器登入…', cancelling:'正在取消並清除暫存設定…', saving:'正在儲存帳號…', ready:'設定完成，儲存後即可使用。', deleted:'確認移除此帳號設定？雲端與本機檔案都不會刪除。', staged:'尚未變更原始設定；取消會捨棄這次修改。', saved:'帳號設定已儲存', required:'必填', optional:'選填', keep:'保留已儲存的值', choose:'請選擇', browse:'選擇檔案', source:'rclone 原始說明', browser:'重新開啟登入頁面', default:'預設值', noServices:'沒有符合的服務', invalidName:'請輸入名稱；不可使用冒號、斜線、方括號或控制字元。', google:'Google Drive 的共用 client ID 正在退役。建議先建立自己的 OAuth 用戶端 ID，再填入 ID 與密鑰。', guide:'如何建立自己的 Google 用戶端 ID', providerNote:'服務與設定欄位由目前安裝的 rclone 提供。', configFile:'使用中的設定檔', removeAction:'移除帳號設定', failure:'設定沒有完成。原有帳號尚未變更；可取消後重試，或使用工具列旁的 config。', waiting:'請在瀏覽器完成登入。返回這裡後會自動顯示下一步。', examples:'建議值', success:'已儲存。左右位置選單會更新帳號清單。'
  },
  en: {
    title:'Accounts', add:'Add account', edit:'Edit', remove:'Remove', empty:'No accounts configured', name:'Account name', service:'Storage provider', search:'Search providers', next:'Continue', save:'Save account', back:'Back to accounts', cancel:'Cancel setup', close:'Close', refresh:'Refresh', loading:'Reading rclone configuration…', working:'rclone is processing setup or waiting for browser sign-in…', cancelling:'Cancelling and removing staged changes…', saving:'Saving account…', ready:'Setup is complete. Save to use this account.', deleted:'Remove this account configuration? Cloud and local files will not be deleted.', staged:'The original configuration is unchanged. Cancelling discards these changes.', saved:'Account saved', required:'Required', optional:'Optional', keep:'Keep the stored value', choose:'Choose an option', browse:'Choose file', source:'Original rclone instructions', browser:'Reopen sign-in page', default:'Default', noServices:'No matching providers', invalidName:'Enter a name without colons, slashes, brackets or control characters.', google:'The shared Google Drive client ID is being retired. Create your own OAuth client, then enter its client ID and secret.', guide:'Create your own Google client ID', providerNote:'Providers and fields come from the installed rclone.', configFile:'Configuration file', removeAction:'Remove account configuration', failure:'Setup did not complete. Existing accounts are unchanged. Cancel and try again, or use config beside the toolbar button.', waiting:'Complete sign-in in your browser. The next step will appear here automatically.', examples:'Suggested values', success:'Saved. The location menus will refresh the account list.'
  },
  ja: {
    title:'アカウント設定', add:'アカウントを追加', edit:'編集', remove:'削除', empty:'アカウントは未設定です', name:'アカウント名', service:'ストレージサービス', search:'サービスを検索', next:'次へ', save:'保存', back:'アカウント一覧に戻る', cancel:'設定をキャンセル', close:'閉じる', refresh:'更新', loading:'rclone の設定を読み込み中…', working:'rclone が処理中、またはブラウザーでのログイン待ちです…', cancelling:'キャンセルして一時設定を削除中…', saving:'アカウントを保存中…', ready:'設定が完了しました。保存すると利用できます。', deleted:'このアカウント設定を削除しますか？クラウドやローカルのファイルは削除しません。', staged:'元の設定は変更されていません。キャンセルすると今回の変更を破棄します。', saved:'設定を保存しました', required:'必須', optional:'任意', keep:'保存済みの値を維持', choose:'選択してください', browse:'ファイルを選択', source:'rclone の元の説明', browser:'ログインページを再度開く', default:'既定値', noServices:'該当するサービスがありません', invalidName:'コロン、スラッシュ、角括弧、制御文字を含まない名前を入力してください。', google:'Google Drive の共有クライアント ID は廃止予定です。独自の OAuth クライアントを作成し、ID とシークレットを入力してください。', guide:'Google クライアント ID の作成方法', providerNote:'サービスと項目はインストール済みの rclone から取得します。', configFile:'設定ファイル', removeAction:'アカウント設定を削除', failure:'設定が完了しませんでした。元のアカウントは未変更です。キャンセル後に再試行するか config を使用してください。', waiting:'ブラウザーでログインしてください。次の手順が自動表示されます。', examples:'候補', success:'保存しました。接続先メニューを更新します。'
  }
};
const fieldLabels: Record<string, [string,string,string]> = {
  client_id:['OAuth 用戶端 ID','OAuth client ID','OAuth クライアント ID'], client_secret:['OAuth 用戶端密鑰','OAuth client secret','OAuth クライアントシークレット'],
  scope:['存取權限','Access permissions','アクセス権限'], service_account_file:['服務帳戶金鑰檔案','Service account key file','サービスアカウント鍵ファイル'],
  config_fs_advanced:['顯示進階設定？','Configure advanced options?','詳細設定を行いますか？'], config_is_local:['使用這台電腦的瀏覽器登入？','Sign in using this computer’s browser?','このパソコンのブラウザーでログインしますか？'],
  config_refresh_token:['重新登入此帳號？','Sign in to this account again?','再ログインしますか？'], config_shared_client_id:['繼續使用 rclone 共用用戶端 ID？','Continue with rclone’s shared client ID?','rclone の共有クライアント ID を使用しますか？'],
  config_token:['貼上授權結果','Paste authorization result','認証結果を貼り付け'], token:['授權資料','Authorization token','認証トークン'],
  remote:['遠端位置或本機路徑','Remote or local path','接続先またはローカルパス'], host:['伺服器位址','Server address','サーバーアドレス'], user:['使用者名稱','User name','ユーザー名'], pass:['密碼','Password','パスワード'], port:['連接埠','Port','ポート'], url:['服務網址','Service URL','サービス URL'], region:['服務區域','Region','リージョン'],
};
const textValue = (value: unknown) => value === undefined || value === null ? '' : String(value);
const validName = (name: string) => !!name && name === name.trim() && name.length <= 128 && !/^-/u.test(name) && !/[:/\\\[\]\x00-\x1f\x7f]/u.test(name);

export default function AccountDialog({language,t,onClose,onReload}: {language:ResolvedLanguage;t:Translate;onClose():void;onReload():Promise<void>}) {
  const c=copy[language], index=language==='zh-TW'?0:language==='en'?1:2;
  const [catalog,setCatalog]=useState<AccountCatalog|null>(null), [session,setSession]=useState<AccountSession|null>(null);
  const [screen,setScreen]=useState<'list'|'new'>('list'), [name,setName]=useState(''), [provider,setProvider]=useState('drive'), [search,setSearch]=useState('');
  const [error,setError]=useState(''), [notice,setNotice]=useState(''), [busy,setBusy]=useState(false), [loading,setLoading]=useState(true);
  const [answer,setAnswer]=useState(''), [keep,setKeep]=useState(false);
  const alive=useRef(true), current=useRef<AccountSession|null>(null), closeRequested=useRef(false), apiBusy=useRef(false), generation=useRef(0);
  const apply=(s:AccountSession) => { current.current=s; if(alive.current) setSession(s); };
  const refresh=async () => { setLoading(true); setError(''); try {const result=await window.rclone.accountCatalog(); if(alive.current) setCatalog(result);} catch(e) {if(alive.current)setError(errorMessage(e));} finally {if(alive.current)setLoading(false);} };
  useEffect(()=>{alive.current=true; void refresh(); return ()=>{alive.current=false; const s=current.current; if(s && !['saved','cancelled','saving'].includes(s.phase))void window.rclone.accountCancel(s.id).catch(()=>{});};},[]);
  useEffect(()=>{
    if(!session || ['saved','cancelled'].includes(session.phase))return;
    let stopped=false, timer:ReturnType<typeof setTimeout>;
    const poll=async()=>{
      try {
        const captured=generation.current;
        const s=await window.rclone.accountStatus(session.id);
        if(stopped)return;
        if(captured!==generation.current || apiBusy.current){timer=setTimeout(poll,400);return;}
        apply(s);
        if(s.phase==='cancelled') {
          current.current=null; setSession(null); setError('');
          if(closeRequested.current)onClose(); else {setScreen('list');void refresh();}
          return;
        }
        if(s.phase==='saved')return;
      }catch(e){if(!stopped)setError(errorMessage(e));}
      if(!stopped)timer=setTimeout(poll,400);
    };
    timer=setTimeout(poll,400);return()=>{stopped=true;clearTimeout(timer);};
  },[session?.id]);
  useEffect(()=>{
    const q=session?.option;setAnswer(q?.IsPassword?'':textValue(q?.Default));setKeep(!!q?.IsPassword && !!q.hasDefault);
  },[session?.id,session?.step]);
  const act=async(work:()=>Promise<void>)=>{if(apiBusy.current)return; apiBusy.current=true;generation.current+=1;setBusy(true);setError('');try{await work();}catch(e){if(alive.current)setError(errorMessage(e));}finally{apiBusy.current=false;if(alive.current)setBusy(false);}};
  const begin=(mode:'create'|'edit'|'delete',remoteName=name,type=provider)=>void act(async()=>{
    setNotice('');const s=await window.rclone.accountBegin({name:remoteName,provider:type,mode});
    if(!alive.current){await window.rclone.accountCancel(s.id);return;} apply(s);
  });
  const cancel=(close=false)=>void act(async()=>{
    const s=current.current;closeRequested.current=close;
    if(!s || ['saved','cancelled'].includes(s.phase)){current.current=null;if(close)onClose();else{setSession(null);setScreen('list');void refresh();}return;}
    apply(await window.rclone.accountCancel(s.id));
  });
  const commit=()=>void act(async()=>{
    if(!session)return;const s=await window.rclone.accountCommit(session.id);apply(s);
    current.current=null;setSession(null);setScreen('list');setNotice(c.success);
    await refresh();await onReload();
  });
  const advance=()=>void act(async()=>{
    if(!session || session.phase!=='question')return;
    const s=await window.rclone.accountAnswer(session.id,{step:session.step,value:keep?undefined:answer,useDefault:keep});
    setAnswer('');setKeep(false);apply(s);
  });
  const q=session?.option;
  const title=q?(fieldLabels[q.Name]?.[index] || q.Name):'';
  const options=q?.Examples||[];
  const optionalEmpty=!!q && !q.Required && !q.Exclusive;
  const answerValid=!!q && ((keep&&q.hasDefault) || ((!q.Required || !!answer.trim()) && (!q.Exclusive || options.some(e=>textValue(e.Value)===answer))));
  const isWorking=!!session && ['working','cancelling','saving'].includes(session.phase);
  const google=session?.provider==='drive' || (!session&&screen==='new'&&provider==='drive');
  const choices=(catalog?.providers||[]).filter(p=>(p.name+' '+p.description).toLocaleLowerCase().includes(search.toLocaleLowerCase()));
  const help = q?.Help || '';
  const GoogleNote = ()=><div className="account-provider-note"><p>{c.google}</p><button type="button" className="text-button" onClick={()=>void act(async()=>{await window.rclone.openExternal('https://rclone.org/drive/#making-your-own-client-id');})}>{c.guide}<ArrowSquareOut size={14}/></button></div>;
  return <Dialog title={c.title} t={t} onClose={()=>cancel(true)} dismissible={!busy&&session?.phase!=='saving'&&session?.phase!=='cancelling'} className="account-dialog">
    <div className="dialog-body account-body">
      {error&&<Notice kind="error">{error}</Notice>}{notice&&<Notice kind="success">{notice}</Notice>}
      {!session && loading && <div className="account-working" role="status"><SpinnerGap className="account-spinner" size={26}/><p>{c.loading}</p></div>}
      {!session && !loading && screen==='list' && <>
        <div className="account-list-heading"><p>{c.providerNote}</p><button type="button" className="primary" disabled={!catalog||busy} onClick={()=>{setScreen('new');setName('');setSearch('');setError('');setNotice('');}}><Plus size={16}/>{c.add}</button></div>
        <div className="account-list">{catalog?.remotes.length===0&&<p className="account-empty">{c.empty}</p>}{catalog?.remotes.map(remote=><div className="account-row" key={remote.name}>
          <Cloud size={22}/><div className="account-row-name"><strong>{remote.name}</strong><span>{catalog.providers.find(p=>p.name===remote.type)?.description||remote.type}</span></div>
          <button type="button" disabled={busy} aria-label={`${c.edit} ${remote.name}`} onClick={()=>begin('edit',remote.name,remote.type)}><PencilSimple size={16}/>{c.edit}</button><button type="button" className="text-button" disabled={busy} aria-label={`${c.remove} ${remote.name}`} onClick={()=>begin('delete',remote.name,remote.type)}><Trash size={16}/>{c.remove}</button>
        </div>)}</div>
        {catalog?.configPath&&<details className="account-config-path"><summary>{c.configFile}</summary><code>{catalog.configPath}</code></details>}
      </>}
      {!session && !loading && screen==='new' && <form id="new-account" onSubmit={e=>{e.preventDefault();if(validName(name))begin('create');}}>
        <Field label={c.name}><input autoFocus autoComplete="off" maxLength={128} value={name} onChange={e=>setName(e.target.value)} placeholder="my_drive" aria-invalid={name!==''&&!validName(name)}/></Field>
        {name&&!validName(name)&&<p className="account-inline-error">{c.invalidName}</p>}
        <Field label={c.service}><input type="search" value={search} onChange={e=>setSearch(e.target.value)} placeholder={c.search} aria-label={c.search}/><select size={6} value={provider} aria-label={c.service} onChange={e=>setProvider(e.target.value)}>{choices.map(p=><option key={p.name} value={p.name}>{p.description} ({p.name})</option>)}</select></Field>
        {choices.length===0&&<p>{c.noServices}</p>}{google&&<GoogleNote/>}
      </form>}
      {session&&<>
        <div className="account-session-heading"><Cloud size={24}/><div><strong>{session.name}</strong><span>{session.provider}</span></div></div>
        {session.error&&<Notice kind="error">{session.error}</Notice>}
        {isWorking&&<div className="account-working" role="status"><SpinnerGap className="account-spinner" size={28}/><p>{session.phase==='cancelling'?c.cancelling:session.phase==='saving'?c.saving:c.working}</p>{session.canOpenBrowser&&<><p>{c.waiting}</p><button type="button" disabled={busy} onClick={()=>void act(async()=>{await window.rclone.accountOpenBrowser(session.id);})}>{c.browser}<ArrowSquareOut size={15}/></button></>}</div>}
        {session.phase==='question'&&q&&<form id="account-question" onSubmit={e=>{e.preventDefault();if(answerValid)advance();}}>
          <div className="account-question-heading"><h3>{title}</h3><span>{q.Required?c.required:c.optional}</span></div>
          {q.Name!==title&&<code className="account-field-key">{q.Name}</code>}
          {help&&<p className="account-question-help">{help}</p>}
          {google&&(q.Name.includes('client_id')||q.Name==='client_secret')&&<GoogleNote/>}
          {q.IsPassword&&q.hasDefault&&<label className="checkbox-field"><input type="checkbox" checked={keep} onChange={e=>setKeep(e.target.checked)}/><span>{c.keep}</span></label>}
          {q.Exclusive?<div className="account-choice-list" role="radiogroup" aria-label={title}>{options.map(option=><label key={option.Value} className={`account-choice ${answer===textValue(option.Value)?'selected':''}`}><input type="radio" name="account-choice" value={textValue(option.Value)} checked={answer===textValue(option.Value)} onChange={e=>setAnswer(e.target.value)} disabled={busy}/><span><strong>{option.Help||option.Value}</strong>{option.Help&&<small>{option.Value}</small>}</span></label>)}</div>:
          <><label className="account-value-label"><span className="sr-only">{title}</span><input key={`${session.id}-${session.step}`} autoFocus autoComplete="off" spellCheck={false} type={q.IsPassword?'password':'text'} value={answer} disabled={busy||keep} onChange={e=>setAnswer(e.target.value)} aria-label={title} placeholder={optionalEmpty?c.optional:undefined}/></label>
            {options.length>0&&<Field label={c.examples}><select value="" disabled={busy||keep} onChange={e=>setAnswer(e.target.value)}><option value="">{c.choose}</option>{options.map(option=><option key={option.Value} value={option.Value}>{option.Help||option.Value} — {option.Value}</option>)}</select></Field>}
            {/(_file|_path)$/.test(q.Name)&&<button type="button" className="text-button" disabled={busy||keep} onClick={()=>void act(async()=>{const selected=await window.rclone.chooseFile('accountKey');if(selected)setAnswer(selected);})}><FolderOpen size={16}/>{c.browse}</button>}
          </>}
        </form>}
        {session.phase==='ready'&&<div className="account-ready"><CheckCircle size={32}/><p>{session.mode==='delete'?c.deleted:c.ready}</p></div>}
        {session.phase==='error'&&<p>{c.failure}</p>}
        <p className="account-staging-note">{c.staged}</p>
      </>}
    </div>
    <footer className="dialog-footer account-footer">
      {!session&&screen==='list'&&<button type="button" className="text-button" disabled={loading||busy} onClick={()=>void refresh()}><ArrowClockwise size={16}/>{c.refresh}</button>}
      {!session&&screen==='new'&&<button type="button" className="text-button" disabled={busy} onClick={()=>setScreen('list')}><ArrowLeft size={16}/>{c.back}</button>}
      <span className="spacer"/>
      <button type="button" disabled={busy||session?.phase==='saving'||session?.phase==='cancelling'} onClick={()=>session?cancel():onClose()}>{session?c.cancel:c.close}</button>
      {!session&&screen==='new'&&<button type="submit" form="new-account" className="primary" disabled={busy||!validName(name)||!catalog?.providers.some(p=>p.name===provider)}>{c.next}</button>}
      {session?.phase==='question'&&<button type="submit" form="account-question" className="primary" disabled={busy||!answerValid}>{c.next}</button>}
      {session?.phase==='ready'&&<button type="button" className="primary" disabled={busy} onClick={commit}>{session.mode==='delete'?c.removeAction:c.save}</button>}
    </footer>
  </Dialog>;
}
