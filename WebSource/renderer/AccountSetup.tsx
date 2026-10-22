import {useCallback,useEffect,useId,useRef,useState} from 'react';
import {ArrowSquareOut,Plus,Cloud,TerminalWindow,FolderOpen,ArrowLeft} from '@phosphor-icons/react';
import type {AccountInfo,AccountOption,AccountProvider,AccountRequest,AccountSession,AccountSetupMode,ResolvedLanguage,SettingsPatch} from '../shared/types';
import {Dialog,Field,Notice} from './components';
import type {Translate} from './i18n';
import {accountChoice,accountHint,accountLabel,accountProvider,accountTranslator} from './account-i18n';
import {errorMessage} from './utils';

type Props={language:ResolvedLanguage;t:Translate;onClose():void;onSaved():Promise<void>;onTerminal():Promise<void>;onSettings(patch:SettingsPatch):Promise<void>};
type StartRequest=Extract<AccountRequest,{action:'start'}>;
const popularProviders=['drive','onedrive','dropbox'];
const serverProviders=['sftp','webdav','ftp'];
const serverFields:Record<string,string[]>={sftp:['host','user','pass','port'],webdav:['url','vendor','user','pass'],ftp:['host','user','pass','port','tls']};
const terminalPhases=['committed','cancelled'];

function optionDefault(option:AccountOption):string {
 if(option.Sensitive||option.IsPassword)return '';
 if(option.DefaultStr!==undefined)return option.DefaultStr;
 if(option.Default===undefined||option.Default===null)return '';
 return typeof option.Default==='object'?'':String(option.Default);
}
function matchesProvider(rule:string|undefined,selected:string):boolean {
 if(!rule||!selected)return true;
 const excluded=rule.startsWith('!');
 const matches=(excluded?rule.slice(1):rule).split(',').map(value=>value.trim()).includes(selected);
 return excluded?!matches:matches;
}
function orderedProviders(providers:AccountProvider[]) {
 return [...providers].sort((left,right)=>{
  const order=[...popularProviders,...serverProviders];
  const l=order.indexOf(left.name),r=order.indexOf(right.name);
  return (l<0?order.length:l)-(r<0?order.length:r)||left.name.localeCompare(right.name,'en');
 });
}

/** The same field renders the schema form and the few remaining dynamic questions. */
function AccountField({option,value,onChange,onUseDefault,language,disabled=false,editing=false,selectedProvider='',onChooseFile}: {
 option:AccountOption;value:string;onChange(value:string):void;onUseDefault?():void;language:ResolvedLanguage;disabled?:boolean;editing?:boolean;selectedProvider?:string;onChooseFile?():void;
}) {
 const a=accountTranslator(language),id=useId();
 const [custom,setCustom]=useState(false);
 const choices=(option.Type==='bool'?[{Value:'true',Help:a('yes')},{Value:'false',Help:a('no')}]:option.Examples||[]).filter(item=>matchesProvider('Provider' in item?item.Provider:undefined,selectedProvider));
 const sensitive=!!option.Sensitive||!!option.IsPassword;
 const password=!!option.IsPassword||/(?:pass|secret|token|key_pem|credentials)/i.test(option.Name);
 const label=accountLabel(option.Name,language),hint=option.Required&&['client_id','client_secret'].includes(option.Name)?undefined:accountHint(option.Name,language);
 const required=!!option.Required&&!editing;
 const smallChoices=!sensitive&&choices.length>0&&choices.length<=12;
 const isCustom=custom||!!value&&!choices.some(item=>item.Value===value);
 const describedBy=hint?`${id}-hint`:undefined;
 const choiceText=(item:{Value:string;Help?:string})=>accountChoice(option.Name,item.Value,item.Help,language);
 const input=(inputLabel?:string)=><input id={id} aria-label={inputLabel} aria-describedby={describedBy} type={password?'password':'text'} value={value} onChange={event=>onChange(event.target.value)} disabled={disabled} required={required} autoComplete="off" spellCheck={false} maxLength={16384} placeholder={editing?a('preserveBlank'):undefined} list={!sensitive&&choices.length>12&&!option.Exclusive?`${id}-examples`:undefined}/>;
 return <div className="account-option" data-option-name={option.Name}>
  {smallChoices?<fieldset className="account-choice-field" disabled={disabled} aria-describedby={describedBy}>
   <legend className="field-label">{label}<span className="account-option-status">{required?a('required'):a('optional')}</span></legend>
   {hint&&<p id={describedBy} className="field-hint">{hint}</p>}
   <div className="account-choices">
    {!required&&!choices.some(item=>item.Value==='')&&<label className="account-choice"><input type="radio" name={id} checked={!value&&!custom} onChange={()=>{setCustom(false);if(onUseDefault)onUseDefault();else onChange(optionDefault(option));}}/><span>{editing?a('keep'):a('default')}</span></label>}
    {choices.map((item,i)=><label className="account-choice" key={`${item.Value}-${i}`}><input type="radio" name={id} value={item.Value} checked={!isCustom&&value===item.Value} required={required} onChange={()=>{setCustom(false);onChange(item.Value);}}/><span>{choiceText(item)}</span></label>)}
    {!option.Exclusive&&option.Type!=='bool'&&<label className="account-choice"><input type="radio" name={id} checked={isCustom} onChange={()=>{setCustom(true);onChange('');}}/><span>{a('custom')}</span></label>}
   </div>
   {!option.Exclusive&&isCustom&&option.Type!=='bool'&&<div className="account-custom-value"><label className="field-label" htmlFor={id}>{a('customValue')}</label>{input(`${label} ${a('customValue')}`)}</div>}
  </fieldset>:<>
   <div className="account-option-label"><label className="field-label" htmlFor={id}>{label}</label><span className="account-option-status">{required?a('required'):a('optional')}</span></div>
   {option.Exclusive&&choices.length>0?<select id={id} aria-describedby={describedBy} value={value} required={required} disabled={disabled} onChange={event=>onChange(event.target.value)}><option value="" disabled={required}>{required?a('choose'):editing?a('keep'):a('default')}</option>{choices.map((item,i)=><option key={`${item.Value}-${i}`} value={item.Value}>{choiceText(item).split('\n')[0]}</option>)}</select>:input()}
   {!sensitive&&choices.length>12&&!option.Exclusive&&<datalist id={`${id}-examples`}>{choices.map((item,i)=><option key={i} value={item.Value}>{choiceText(item).split('\n')[0]}</option>)}</datalist>}
   {hint&&<p id={describedBy} className="field-hint">{hint}</p>}
  </>}
  {onChooseFile&&<button type="button" className="text-button account-file-picker" disabled={disabled} onClick={onChooseFile}><FolderOpen size={15}/>{a('chooseFile')}</button>}
  <details className="account-source-details"><summary>{a('detail')}</summary><div className="account-source-help" tabIndex={0}><code>{option.Name}</code><p>{option.Help}</p>{choices.length>12&&choices.map((item,i)=><p key={i}><code>{item.Value}</code> {item.Help}</p>)}</div></details>
 </div>;
}

export default function AccountSetup({language,t,onClose,onSaved,onTerminal,onSettings}:Props) {
 const a=accountTranslator(language);
 const [info,setInfo]=useState<AccountInfo|null>(null),[session,setSession]=useState<AccountSession|null>(null);
 const [loading,setLoading]=useState(true),[pending,setPending]=useState(false),[error,setError]=useState('');
 const [adding,setAdding]=useState(false),[mode,setMode]=useState<'create'|'edit'>('create'),[setup,setSetup]=useState<AccountSetupMode>('quick');
 const [name,setName]=useState(''),[provider,setProvider]=useState('drive'),[fields,setFields]=useState<Record<string,string>>({});
 const [answer,setAnswer]=useState(''),[keep,setKeep]=useState(false),[discard,setDiscard]=useState(false),[cancelling,setCancelling]=useState(false),[password,setPassword]=useState('');
 const [credentialsOpen,setCredentialsOpen]=useState(false);
 const current=useRef<AccountSession|null>(null),alive=useRef(true),inFlight=useRef(false),cancelInProgress=useRef(false);
 const openedBrowser=useRef(new Set<string>()),savedSessions=useRef(new Set<string>()),lastStart=useRef<StartRequest|null>(null);
 const savedCallback=useRef(onSaved);savedCallback.current=onSaved;
 const nameInput=useRef<HTMLInputElement>(null),questionForm=useRef<HTMLFormElement>(null);
 const put=useCallback((next:AccountSession)=>{current.current=next;if(alive.current)setSession(next);},[]);
 const load=useCallback(async()=>{
  setLoading(true);setError('');
  try {
   const result=await window.rclone.accountConfig({action:'info'}) as AccountInfo;
   if(alive.current){setInfo(result);setAdding(!result.requiresUnlock&&result.remotes.length===0);setMode('create');setProvider(previous=>result.providers.some(item=>item.name===previous)?previous:orderedProviders(result.providers)[0]?.name||'');}
  } catch(reason){if(alive.current)setError(errorMessage(reason));}
  finally{if(alive.current)setLoading(false);}
 },[]);
 useEffect(()=>{
  alive.current=true;void load();
  return()=>{alive.current=false;const active=current.current;if(active&&!terminalPhases.includes(active.phase))void window.rclone.accountConfig({action:'cancel',id:active.id}).catch(()=>{});};
 },[load]);
 useEffect(()=>{
  if(session?.phase!=='running'||cancelling)return;
  let disposed=false,timer:ReturnType<typeof setTimeout>;
  const poll=async()=>{
   try{const next=await window.rclone.accountConfig({action:'poll',id:session.id}) as AccountSession;if(!disposed&&!cancelInProgress.current){put(next);if(next.phase==='running')timer=setTimeout(poll,350);}}
   catch(reason){if(!disposed&&!cancelInProgress.current){setError(errorMessage(reason));timer=setTimeout(poll,1500);}}
  };
  timer=setTimeout(poll,200);return()=>{disposed=true;clearTimeout(timer);};
 },[session?.id,session?.phase,cancelling,put]);
 useEffect(()=>{
  const question=session?.question;setAnswer(question?optionDefault(question):'');setKeep(!!question?.HasSavedValue);
 },[session?.id,session?.step]);
 useEffect(()=>{
  if(!session?.canOpenBrowser||session.phase!=='running'||cancelling||openedBrowser.current.has(session.id))return;
  openedBrowser.current.add(session.id);
  void window.rclone.openAccountAuthorization().catch(reason=>{if(alive.current&&!cancelInProgress.current)setError(errorMessage(reason));});
 },[session?.id,session?.canOpenBrowser,session?.phase,cancelling]);
 useEffect(()=>{
  if(session?.phase!=='committed'||savedSessions.current.has(session.id))return;
  savedSessions.current.add(session.id);
  void savedCallback.current().catch(reason=>{if(alive.current)setError(errorMessage(reason));});
 },[session?.id,session?.phase]);
 useEffect(()=>{if(adding&&!loading&&!session)nameInput.current?.focus();},[adding,loading,session?.id]);
 useEffect(()=>{
  if(session?.phase!=='question')return;
  questionForm.current?.querySelector<HTMLElement>('input:not(:disabled),select:not(:disabled)')?.focus();
 },[session?.id,session?.step,session?.phase]);

 async function perform(action:()=>Promise<void>) {
  if(inFlight.current)return;
  inFlight.current=true;setPending(true);setError('');
  try{await action();}catch(reason){if(alive.current)setError(errorMessage(reason));}
  finally{inFlight.current=false;if(alive.current)setPending(false);}
 }
 async function runStart(request:StartRequest) {lastStart.current=request;put(await window.rclone.accountConfig(request) as AccountSession);}
 function requestClose() {
  if(pending||cancelling)return;
  if(current.current&&!terminalPhases.includes(current.current.phase))setDiscard(true);else onClose();
 }
 async function cleanupSession() {
  const active=current.current;
  if(!active||terminalPhases.includes(active.phase))return active;
  let next=await window.rclone.accountConfig({action:'cancel',id:active.id}) as AccountSession;
  const deadline=Date.now()+12000;
  while(next.phase==='running'&&Date.now()<deadline){await new Promise(resolve=>setTimeout(resolve,180));next=await window.rclone.accountConfig({action:'poll',id:active.id}) as AccountSession;}
  put(next);
  if(!terminalPhases.includes(next.phase))throw new Error(a('cancelling'));
  return next;
 }
 async function finishSession(destination:'close'|'edit'|'retry') {
  if(inFlight.current||cancelInProgress.current)return;
  cancelInProgress.current=true;setCancelling(true);setDiscard(false);setError('');
  try {
   const next=await cleanupSession();
   if(next?.phase==='committed')return;
   current.current=null;setSession(null);
   if(destination==='close'){onClose();return;}
   setAdding(true);
   if(destination==='retry'&&lastStart.current)await runStart(lastStart.current);
  } catch(reason){if(alive.current)setError(errorMessage(reason));}
  finally{cancelInProgress.current=false;if(alive.current)setCancelling(false);}
 }
 const selected=info?.providers.find(item=>item.name===provider);
 const isOAuth=!!selected?.quickSetup;
 const editing=mode==='edit';
 const schema=selected?.options||[];
 const optionValue=(option:AccountOption)=>fields[option.Name]??(editing?'':optionDefault(option));
 const subtypeOption=schema.find(option=>option.Name==='provider')||schema.find(option=>option.Name==='vendor');
 const subtype=subtypeOption?(fields[subtypeOption.Name]??optionDefault(subtypeOption)):'';
 const applicable=schema.filter(option=>matchesProvider(option.Provider,subtype));
 const credentials=applicable.filter(option=>['client_id','client_secret'].includes(option.Name));
 const quickFields=applicable.filter(option=>!option.Advanced&&(option.Required||!serverFields[provider]||serverFields[provider].includes(option.Name)));
 const shownOptions=setup==='detailed'?applicable:isOAuth?credentials:quickFields;
 // Keep required, unset schema additions in the main form. A field must not move
 // into a collapsed section as soon as the user starts typing its answer.
 const requiredAdvanced=shownOptions.filter(option=>option.Advanced&&option.Required&&!optionDefault(option));
 const basicOptions=shownOptions.filter(option=>!option.Advanced||requiredAdvanced.includes(option));
 const advancedOptions=shownOptions.filter(option=>option.Advanced&&!requiredAdvanced.includes(option));
 const duplicateName=mode==='create'&&!!info?.remotes.some(remote=>remote.name===name);
 const validName=!!name.trim()&&name!=='.'&&name!=='..'&&name===name.trim()&&!/[:/\\\[\]\u0000-\u001f]/.test(name)&&!name.startsWith('-')&&name.length<=128;
 const validFields=editing||shownOptions.every(option=>!option.Required||!!optionValue(option));
 const validCredentials=editing||!fields.client_secret||!!fields.client_id?.trim();
 const formValid=validName&&!duplicateName&&!!selected&&validFields&&validCredentials;
 const active=!!session&&!terminalPhases.includes(session.phase),working=loading||pending||cancelling;
 const providers=orderedProviders(info?.providers||[]);
 const docs=provider==='drive'?'https://rclone.org/drive/#making-your-own-client-id':provider==='onedrive'?'https://rclone.org/onedrive/#getting-your-own-client-id-and-key':provider==='dropbox'?'https://rclone.org/dropbox/#get-your-own-dropbox-app-id':'https://rclone.org/docs/';
 const setField=(key:string,value:string)=>setFields(previous=>({...previous,[key]:value}));
 function beginForm(remote?:{name:string;type:string}) {
  setAdding(true);setMode(remote?'edit':'create');setName(remote?.name||'');setFields({});setCredentialsOpen(false);setSetup(remote?'detailed':'quick');setError('');
  if(remote)setProvider(remote.type);
 }
 async function submitForm() {
  if(!formValid)return;
  const visibleNames=new Set(shownOptions.map(option=>option.Name));
  const values=Object.fromEntries(Object.entries(fields).filter(([key])=>visibleNames.has(key)));
  await perform(()=>runStart({action:'start',mode,name,provider,setup,fields:values,useSharedClient:!values.client_id?.trim(),autoSave:mode==='create'&&setup==='quick'}));
 }
 const renderOption=(option:AccountOption)=><AccountField key={option.Name} option={option} value={optionValue(option)} language={language} disabled={working} editing={editing} selectedProvider={subtype} onChange={value=>setField(option.Name,value)} onUseDefault={()=>setFields(previous=>{const next={...previous};delete next[option.Name];return next;})} onChooseFile={/(?:_file|_path)$/.test(option.Name)&&!option.IsPassword?()=>void perform(async()=>{const file=await window.rclone.chooseFile('credential');if(file)setField(option.Name,file);}):undefined}/>;
 const question=session?.question;
 return <Dialog title={a('title')} t={t} onClose={requestClose} dismissible={!pending&&!cancelling} className="accounts-dialog">
  <div className="dialog-body account-body">
   {error&&<Notice kind="error">{error}</Notice>}
   {discard&&<Notice kind="warning"><p>{a('abandon')}</p><div className="account-inline-actions"><button type="button" onClick={()=>setDiscard(false)}>{a('stay')}</button><button type="button" className="danger" onClick={()=>void finishSession('close')}>{a('discard')}</button></div></Notice>}
   {loading&&<p role="status">{a('loading')}</p>}
   {!loading&&!active&&<>
    {!info&&<button type="button" className="account-reload" disabled={working} onClick={()=>void load()}>{a('retry')}</button>}
    {info?.requiresUnlock&&<form id="account-unlock" className="account-unlock" onSubmit={event=>{event.preventDefault();void perform(async()=>{try{await window.rclone.unlockConfig(password);await load();}finally{setPassword('');}});}}>
     <h3>{a('encrypted')}</h3><p className="muted">{a('encryptedHint')}</p>
     <Field label={a('password')}><input type="password" value={password} onChange={event=>setPassword(event.target.value)} autoComplete="off" required autoFocus disabled={working}/></Field>
    </form>}
    {info&&!info.requiresUnlock&&!adding&&<>
     <div className="account-list-heading"><h3>{a('title')}</h3><button type="button" className="primary" disabled={working} onClick={()=>beginForm()}><Plus size={16}/>{a('add')}</button></div>
     <div className="account-list">{info.remotes.map(remote=><div className="account-row" key={remote.name}><Cloud size={20}/><div><strong>{remote.name}</strong><span>{accountProvider(remote.type,info.providers.find(item=>item.name===remote.type)?.description||remote.type,language)}</span></div><button type="button" aria-label={`${a('edit')} ${remote.name}`} disabled={working} onClick={()=>beginForm(remote)}>{a('edit')}</button><button type="button" className="text-button" aria-label={`${a('remove')} ${remote.name}`} disabled={working} onClick={()=>void perform(()=>runStart({action:'start',mode:'delete',name:remote.name,provider:remote.type,setup:'detailed',fields:{},useSharedClient:false,autoSave:false}))}>{a('remove')}</button></div>)}</div>
    </>}
    {info&&!info.requiresUnlock&&adding&&<form id="account-create" onSubmit={event=>{event.preventDefault();void submitForm();}}>
     {!editing&&<fieldset className="account-mode-switch" disabled={working}><legend className="sr-only">{a('setupMode')}</legend>{(['quick','detailed'] as const).map(value=><label key={value}><input type="radio" name="account-setup-mode" value={value} checked={setup===value} onChange={()=>setSetup(value)}/><span>{a(value)}</span></label>)}</fieldset>}
     <p className="account-intro">{editing?a('editHint'):setup==='quick'?a('quickHint'):a('detailedHint')}</p>
     <Field label={a('accountName')} hint={editing?undefined:a('nameHint')} inlineHint><input ref={nameInput} value={name} onChange={event=>setName(event.target.value)} readOnly={editing} disabled={working} autoComplete="off" spellCheck={false} maxLength={128} required aria-invalid={!!name&&(!validName||duplicateName)} aria-describedby={!!name&&(!validName||duplicateName)?'account-name-error':undefined}/></Field>
     {!!name&&(!validName||duplicateName)&&<p id="account-name-error" className="account-validation" role="alert">{duplicateName?a('duplicateName'):a('invalidName')}</p>}
     <Field label={a('provider')}><select value={provider} disabled={working||editing} onChange={event=>{setProvider(event.target.value);setFields({});setCredentialsOpen(false);}}>
      {[{label:a('popular'),names:popularProviders},{label:a('servers'),names:serverProviders},{label:a('otherProviders'),names:providers.filter(item=>![...popularProviders,...serverProviders].includes(item.name)).map(item=>item.name)}].map(group=>{
       const items=group.names.map(value=>providers.find(item=>item.name===value)).filter((item):item is AccountProvider=>!!item);
       return items.length>0?<optgroup key={group.label} label={group.label}>{items.map(item=><option key={item.name} value={item.name}>{accountProvider(item.name,item.description,language)}</option>)}</optgroup>:null;
      })}
     </select></Field>
     {isOAuth&&setup==='quick'?<div className="account-login-options">
      <p className="account-built-in">{a(fields.client_id?.trim()?'customLogin':'builtInLogin')}</p>
      <details className="account-credentials" open={credentialsOpen} onToggle={event=>setCredentialsOpen(event.currentTarget.open)}><summary>{a('customCredentials')}</summary><div className="account-option-stack"><p className="field-hint">{a('credentialsHint')}</p>{credentials.map(renderOption)}{provider==='drive'&&<p className="field-hint">{a('googleNote')}</p>}<button type="button" className="text-button account-docs" onClick={()=>void perform(()=>window.rclone.openExternal(docs))}>{a('docs')}<ArrowSquareOut size={13}/></button></div></details>
     </div>:<>
      {basicOptions.length>0&&<section className="account-option-stack" aria-label={a('connectionOptions')}>{setup==='quick'&&<p className="field-hint">{a('serverHint')}</p>}{!editing&&requiredAdvanced.length>0&&<p className="field-hint">{a('requiredAdvanced')}</p>}{basicOptions.map(renderOption)}</section>}
      {advancedOptions.length>0&&<details className="account-advanced"><summary>{a('advancedOptions')}</summary><div className="account-option-stack"><p className="field-hint">{a('advancedHint')}</p>{advancedOptions.map(renderOption)}</div></details>}
      {shownOptions.length===0&&<p className="field-hint">{a('noOptions')}</p>}
     </>}
     {!validCredentials&&<p className="account-validation" role="alert">{a('credentialPair')}</p>}
    </form>}
   </>}
   {active&&<>
    <div className="account-session-heading"><div><h3>{session.name}</h3><p className="field-hint">{accountProvider(session.provider||provider,selected?.description||provider,language)}</p></div><span>{session.mode==='delete'?a('remove'):session.mode==='edit'?a('edit'):a('add')}</span></div>
    {(session.phase==='running'||cancelling)&&<div className="account-working" role="status"><div className="progress-bar indeterminate" aria-hidden="true"><span className="progress-indicator"/></div><h3>{cancelling?a('cancelling'):session.canOpenBrowser?a('browserTitle'):a('working')}</h3>{session.canOpenBrowser&&!cancelling&&<><p>{a('browser')}</p>{session.autoSave&&<p className="field-hint">{a('autoSaveHint')}</p>}<button type="button" disabled={pending} onClick={()=>void perform(()=>window.rclone.openAccountAuthorization())}>{a('openBrowser')}<ArrowSquareOut size={15}/></button></>}</div>}
    {session.error&&<Notice kind="error"><p>{a('failed')}</p><details className="account-source-details"><summary>{a('errorDetails')}</summary><div className="account-source-help" tabIndex={0}>{session.error}</div></details></Notice>}
    {session.phase==='question'&&question&&!cancelling&&<form id="account-question" ref={questionForm} onSubmit={event=>{event.preventDefault();void perform(async()=>put(await window.rclone.accountConfig({action:'answer',id:session.id,step:session.step,value:answer,useDefault:keep}) as AccountSession));}}>
     <div className="account-question-intro"><h3>{a('additionalInput')}</h3><p className="field-hint">{question.Required&&['client_id','client_secret'].includes(question.Name)?a('requiresOwnCredentials'):a('unexpectedQuestion')}</p></div>
     {question.HasSavedValue&&<label className="account-keep"><input type="checkbox" checked={keep} onChange={event=>setKeep(event.target.checked)}/>{a('keep')}</label>}
     <AccountField key={`${session.id}-${session.step}`} option={{...question,Required:question.Required&&!keep}} value={keep?'':answer} language={language} disabled={pending||keep} selectedProvider={subtype} onChange={setAnswer} onChooseFile={/(?:_file|_path)$/.test(question.Name)&&!question.IsPassword?()=>void perform(async()=>{const file=await window.rclone.chooseFile('credential');if(file){setKeep(false);setAnswer(file);}}):undefined}/>
    </form>}
    {session.phase==='ready'&&!cancelling&&<div className="account-ready"><h3>{session.mode==='delete'?a('removeReady'):a('ready')}</h3><p>{session.mode==='delete'?a('removeHint'):a('staged')}</p>{session.tested&&<Notice kind="success">{a('tested')}</Notice>}{session.mode!=='delete'&&<button type="button" title={a('testHint')} disabled={pending} onClick={()=>void perform(async()=>put(await window.rclone.accountConfig({action:'test',id:session.id}) as AccountSession))}>{a('test')}</button>}</div>}
    {session.phase==='error'&&!session.error&&<Notice kind="error">{a('failed')}</Notice>}
   </>}
   {!active&&!loading&&<details className="account-config"><summary>{a('configFile')}</summary><code>{info?.configPath||'—'}</code><button type="button" className="text-button" disabled={working} onClick={()=>void perform(async()=>{const file=await window.rclone.chooseFile('config');if(file){await onSettings({configPath:file});setFields({});setName('');await load();}})}><FolderOpen size={15}/>{a('chooseConfig')}</button></details>}
  </div>
  <footer className="dialog-footer account-footer">
   {!active&&<button type="button" className="text-button" title={a('terminal')} disabled={working} onClick={()=>void perform(async()=>{await onTerminal();onClose();})}><TerminalWindow size={14}/>config</button>}
   {active&&session.mode!=='delete'&&<button type="button" className="text-button account-back" disabled={pending||cancelling} onClick={()=>void finishSession('edit')}><ArrowLeft size={15}/>{a('backToEdit')}</button>}
   <span className="spacer"/>
   {!active&&adding&&!!info?.remotes.length&&!info.requiresUnlock&&<button type="button" disabled={working} onClick={()=>setAdding(false)}>{a('back')}</button>}
   <button type="button" disabled={pending||cancelling} onClick={requestClose}>{active?a('cancel'):a('close')}</button>
   {!active&&info?.requiresUnlock&&<button type="submit" form="account-unlock" className="primary" disabled={working||!password}>{a('unlock')}</button>}
   {!active&&adding&&!info?.requiresUnlock&&<button type="submit" form="account-create" className="primary" disabled={working||!formValid}>{editing?a('reviewChanges'):setup==='quick'?(isOAuth?a('loginAdd'):a('add')):a('prepare')}</button>}
   {session?.phase==='question'&&!cancelling&&<button type="submit" form="account-question" className="primary" disabled={pending||!!question?.Required&&!keep&&!answer}>{a('next')}</button>}
   {session?.phase==='error'&&!cancelling&&session.mode!=='delete'&&<button type="button" className="primary" disabled={pending} onClick={()=>void finishSession('retry')}>{a('retrySignIn')}</button>}
   {session?.phase==='ready'&&!cancelling&&<button type="button" className={session.mode==='delete'?'danger':'primary'} disabled={pending} onClick={()=>void perform(async()=>put(await window.rclone.accountConfig({action:'commit',id:session.id}) as AccountSession))}>{session.mode==='delete'?a('remove'):a('save')}</button>}
  </footer>
 </Dialog>;
}
