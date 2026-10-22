import {useCallback,useEffect,useRef,useState} from 'react';
import {ArrowSquareOut,Plus,Cloud,TerminalWindow,FolderOpen} from '@phosphor-icons/react';
import type {AccountInfo,AccountSession,ResolvedLanguage,SettingsPatch} from '../shared/types';
import {Dialog,Field,Notice} from './components';
import type {Translate} from './i18n';
import {accountLabel,accountTranslator} from './account-i18n';
import {errorMessage} from './utils';

type Props={language:ResolvedLanguage;t:Translate;onClose():void;onSaved():Promise<void>;onTerminal():Promise<void>;onSettings(patch:SettingsPatch):Promise<void>};
export default function AccountSetup({language,t,onClose,onSaved,onTerminal,onSettings}:Props){
 const a=accountTranslator(language);
 const [info,setInfo]=useState<AccountInfo|null>(null),[session,setSession]=useState<AccountSession|null>(null);
 const [loading,setLoading]=useState(true),[pending,setPending]=useState(false),[error,setError]=useState('');
 const [adding,setAdding]=useState(false),[name,setName]=useState(''),[provider,setProvider]=useState('drive'),[search,setSearch]=useState('');
 const [answer,setAnswer]=useState(''),[keep,setKeep]=useState(false),[discard,setDiscard]=useState(false),[cancelling,setCancelling]=useState(false),[password,setPassword]=useState('');
 const current=useRef<AccountSession|null>(null),alive=useRef(true),inFlight=useRef(false);
 const put=(s:AccountSession)=>{current.current=s;if(alive.current)setSession(s);};
 const load=useCallback(async()=>{setLoading(true);setError('');try{const r=await window.rclone.accountConfig({action:'info'}) as AccountInfo;if(alive.current)setInfo(r);}catch(e){if(alive.current)setError(errorMessage(e));}finally{if(alive.current)setLoading(false);}},[]);
 useEffect(()=>{alive.current=true;void load();return()=>{alive.current=false;const s=current.current;if(s&&!['committed','cancelled'].includes(s.phase))void window.rclone.accountConfig({action:'cancel',id:s.id}).catch(()=>{});};},[load]);
 useEffect(()=>{if(session?.phase!=='running')return;let disposed=false;let timer:ReturnType<typeof setTimeout>;
  const poll=async()=>{try{const next=await window.rclone.accountConfig({action:'poll',id:session.id}) as AccountSession;if(!disposed){put(next);if(next.phase==='running')timer=setTimeout(poll,350);}}catch(e){if(!disposed){setError(errorMessage(e));timer=setTimeout(poll,1500);}}};
  timer=setTimeout(poll,200);return()=>{disposed=true;clearTimeout(timer);};
 },[session?.id,session?.phase]);
 useEffect(()=>{const q=session?.question;setAnswer(q?.Default===undefined?'':String(q.Default));setKeep(!!q?.HasSavedValue);},[session?.id,session?.step]);
 async function perform(action:()=>Promise<void>){if(inFlight.current)return;inFlight.current=true;setPending(true);setError('');try{await action();}catch(e){setError(errorMessage(e));}finally{inFlight.current=false;if(alive.current)setPending(false);}}
 async function start(mode:'create'|'edit'|'delete',remoteName=name,kind=provider){await perform(async()=>{put(await window.rclone.accountConfig({action:'start',mode,name:remoteName,provider:kind}) as AccountSession);});}
 function requestClose(){if(pending||cancelling)return;if(session&&!['committed','cancelled'].includes(session.phase)){setDiscard(true);}else onClose();}
 async function cancel(){setCancelling(true);setDiscard(false);try{const s=current.current;if(s){let r=await window.rclone.accountConfig({action:'cancel',id:s.id}) as AccountSession;const deadline=Date.now()+12000;while(r.phase==='running'&&Date.now()<deadline){await new Promise(resolve=>setTimeout(resolve,180));r=await window.rclone.accountConfig({action:'poll',id:s.id}) as AccountSession;}put(r);if(r.phase!=='cancelled')throw new Error(a('cancelling'));}onClose();}catch(e){setError(errorMessage(e));}finally{setCancelling(false);}}
 const q=session?.question,choices=q?.Examples||[],sensitive=!!q?.Sensitive||!!q?.IsPassword;
 const active=!!session&&!['committed','cancelled'].includes(session.phase),working=loading||pending||cancelling||session?.phase==='running';
 const validName=!!name.trim()&&name===name.trim()&&!/[:/\\\[\]\u0000-\u001f]/.test(name)&&!name.startsWith('-')&&name.length<=128;
 const docs=provider==='drive'?'https://rclone.org/drive/#making-your-own-client-id':provider==='onedrive'?'https://rclone.org/onedrive/':'https://rclone.org/docs/';
 const openDocs=()=>void perform(()=>window.rclone.openExternal(docs));
 const optionLabel=(value:string,help?:string)=>q?.Type==='bool'?(value==='true'?a('yes'):a('no')):(help||value);
 return <Dialog title={a('title')} t={t} onClose={requestClose} dismissible={!pending&&!cancelling} className="accounts-dialog">
  <div className="dialog-body account-body">
   <div className="account-file-heading"><div><span className="field-label">{a('configFile')}</span><code>{session?.configPath||info?.configPath||'—'}</code></div>
    {!active&&<button type="button" className="text-button" disabled={working} onClick={()=>void perform(async()=>{const file=await window.rclone.chooseFile('config');if(file){await onSettings({configPath:file});await load();}})}><FolderOpen size={15}/>{a('chooseConfig')}</button>}
   </div>
   {error&&<Notice kind="error">{error}</Notice>}
   {session?.error&&<Notice kind="error">{session.error}</Notice>}
   {discard&&<Notice kind="warning"><p>{a('abandon')}</p><div className="account-inline-actions"><button type="button" onClick={()=>setDiscard(false)}>{a('stay')}</button><button type="button" className="danger" onClick={()=>void cancel()}>{a('discard')}</button></div></Notice>}
   {loading&&<p role="status">{a('loading')}</p>}
   {!loading&&!active&&<>
    {!info&&<div className="account-inline-actions"><button type="button" disabled={working} onClick={()=>void load()}>{a('retry')}</button></div>}
    {info&&!adding&&<><div className="account-list-heading"><h3>{a('title')}</h3><button type="button" onClick={()=>{setAdding(true);setName('');}}><Plus size={16}/>{a('add')}</button></div>
     {info.remotes.length===0?<p className="muted">{a('noAccounts')}</p>:<div className="account-list">{info.remotes.map(remote=><div className="account-row" key={remote.name}><Cloud size={20}/><div><strong>{remote.name}</strong><span>{remote.type}</span></div><button type="button" aria-label={`${a('edit')} ${remote.name}`} disabled={working} onClick={()=>{setProvider(remote.type);void start('edit',remote.name,remote.type);}}>{a('edit')}</button><button type="button" className="text-button" aria-label={`${a('remove')} ${remote.name}`} disabled={working} onClick={()=>void start('delete',remote.name,remote.type)}>{a('remove')}</button></div>)}</div>}
    </>}
    {info&&adding&&<form id="account-create" onSubmit={event=>{event.preventDefault();if(validName)void start('create');}}>
     <Field label={a('accountName')} hint={a('nameHint')} inlineHint><input value={name} onChange={e=>setName(e.target.value)} autoFocus autoComplete="off" spellCheck={false} maxLength={128} required/></Field>
     {!!name&&!validName&&<p className="account-validation" role="alert">{a('invalidName')}</p>}
     <Field label={a('search')}><input type="search" value={search} onChange={e=>setSearch(e.target.value)} autoComplete="off"/></Field>
     <Field label={a('provider')}><select value={provider} onChange={e=>setProvider(e.target.value)}>{info.providers.filter(p=>p.name===provider||`${p.name} ${p.description}`.toLowerCase().includes(search.toLowerCase())).map(p=><option key={p.name} value={p.name}>{p.description||p.name} ({p.name})</option>)}</select></Field>
    </form>}
    <details className="account-unlock"><summary>{a('encrypted')}</summary><form onSubmit={e=>{e.preventDefault();void perform(async()=>{try{await window.rclone.unlockConfig(password);await load();}finally{setPassword('');}});}}><Field label={a('password')}><input type="password" value={password} onChange={e=>setPassword(e.target.value)} autoComplete="off"/></Field><button type="submit" disabled={working||!password}>{a('unlock')}</button></form></details>
   </>}
   {active&&<>
    <div className="account-session-heading"><h3>{session.name}</h3><span>{session.mode==='delete'?a('remove'):session.mode==='edit'?a('edit'):a('add')}</span></div>
    {(session.phase==='running'||cancelling)&&<div className="account-working" role="status"><div className="progress-bar indeterminate"><span className="progress-indicator"/></div><p>{cancelling?a('cancelling'):session.canOpenBrowser?a('browser'):a('working')}</p>{session.canOpenBrowser&&!cancelling&&<button type="button" disabled={pending} onClick={()=>void perform(()=>window.rclone.openAccountAuthorization())}>{a('openBrowser')}<ArrowSquareOut size={15}/></button>}</div>}
    {session.phase==='question'&&q&&!cancelling&&<form id="account-question" onSubmit={e=>{e.preventDefault();void perform(async()=>{put(await window.rclone.accountConfig({action:'answer',id:session.id,step:session.step,value:answer,useDefault:keep}) as AccountSession);});}}>
     <div className="account-question-heading"><h3>{accountLabel(q.Name,language)}</h3><span>{q.Required?a('required'):a('optional')}</span></div>
     <p className="account-question-help">{q.Help}</p>
     {provider==='drive'&&['client_id','client_secret'].includes(q.Name)&&<Notice>{a('googleNote')} <button type="button" className="text-button" onClick={openDocs}>{a('docs')}<ArrowSquareOut size={13}/></button></Notice>}
     {q.HasSavedValue&&<label className="account-keep"><input type="checkbox" checked={keep} onChange={e=>setKeep(e.target.checked)}/>{a('keep')}</label>}
     <Field label={q.Name}>
      {q.Exclusive&&choices.length>0?<select value={answer} required={q.Required} disabled={pending} onChange={e=>{setKeep(false);setAnswer(e.target.value);}}><option value="" disabled={q.Required}>{a('choose')}</option>{choices.map((item,i)=><option key={`${item.Value}-${i}`} value={item.Value}>{optionLabel(item.Value,item.Help)}</option>)}</select>:
       <input type={q.IsPassword||/(?:pass|secret|token|key_pem|credentials)/i.test(q.Name)?'password':'text'} value={keep?'':answer} disabled={pending||keep} required={q.Required&&!keep} autoComplete="off" spellCheck={false} maxLength={16384} list={!sensitive&&choices.length?'account-examples':undefined} onChange={e=>setAnswer(e.target.value)}/>}
     </Field>
     {!q.Exclusive&&!sensitive&&choices.length>0&&<><datalist id="account-examples">{choices.map((item,i)=><option key={i} value={item.Value}>{item.Help}</option>)}</datalist><div className="account-examples">{choices.map((item,i)=><button key={i} type="button" className={answer===item.Value?'selected':''} disabled={pending} onClick={()=>setAnswer(item.Value)}><code>{item.Value}</code><span>{item.Help}</span></button>)}</div></>}
     {/(?:_file|_path)$/.test(q.Name)&&!sensitive&&<button type="button" className="text-button" onClick={()=>void perform(async()=>{const path=await window.rclone.chooseFile('credential');if(path){setKeep(false);setAnswer(path);}})}><FolderOpen size={15}/>{a('chooseFile')}</button>}
    </form>}
    {session.phase==='ready'&&!cancelling&&<div className="account-ready"><h3>{session.mode==='delete'?a('removeReady'):a('ready')}</h3><p>{session.mode==='delete'?a('removeHint'):a('staged')}</p>{session.tested&&<Notice kind="success">{a('tested')}</Notice>}{session.mode!=='delete'&&<button type="button" title={a('testHint')} disabled={pending} onClick={()=>void perform(async()=>put(await window.rclone.accountConfig({action:'test',id:session.id}) as AccountSession))}>{a('test')}</button>}</div>}
    {session.phase==='error'&&<p>{a('failed')}</p>}
   </>}
   <p className="account-engine-note">{a('engineNote')}</p>
  </div>
  <footer className="dialog-footer account-footer">
   {!active&&<button type="button" className="text-button" title={a('terminal')} disabled={working} onClick={()=>void perform(async()=>{await onTerminal();onClose();})}><TerminalWindow size={14}/>config</button>}
   <span className="spacer"/>
   <button type="button" disabled={pending||cancelling} onClick={requestClose}>{active?a('cancel'):a('close')}</button>
   {!active&&adding&&<button type="submit" form="account-create" className="primary" disabled={working||!validName}>{a('next')}</button>}
   {session?.phase==='question'&&!cancelling&&<button type="submit" form="account-question" className="primary" disabled={pending||!!q?.Required&&!keep&&!answer}>{a('next')}</button>}
   {session?.phase==='ready'&&!cancelling&&<button type="button" className={session.mode==='delete'?'danger':'primary'} disabled={pending} onClick={()=>void perform(async()=>{const r=await window.rclone.accountConfig({action:'commit',id:session.id}) as AccountSession;put(r);await onSaved();})}>{session.mode==='delete'?a('remove'):a('save')}</button>}
  </footer>
 </Dialog>;
}
