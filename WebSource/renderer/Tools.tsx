import { useCallback, useEffect, useRef, useState } from 'react';
import { Copy, TreeStructure, HardDrives, Stop, Play, ArrowClockwise } from '@phosphor-icons/react';
import type { Endpoint, Language, MountOptions, Selection, ToolSession } from '../shared/types';
import type { Translate } from './i18n';
import { Checkbox, Dialog, Field, Notice } from './components';
import { endpointText, errorMessage, formatDate } from './utils';

export type ToolAction = 'tree' | 'exportCSV' | 'exportTXT' | 'link' | 'mount' | 'stream';
export interface ToolTarget {action: 'tree'|'link'|'mount'; endpoint: Endpoint; item?: Selection}

export function ToolDialog({target,t,onClose,onSession}: {target: ToolTarget; t: Translate; onClose():void; onSession(session:ToolSession):void}) {
  const [text,setText] = useState('');
  const [error,setError] = useState('');
  const [notice,setNotice] = useState('');
  const [busy,setBusy] = useState(false);
  const [truncated,setTruncated] = useState(false);
  const [depth,setDepth] = useState(3);
  const [mount,setMount] = useState<MountOptions>({readOnly:true,cacheMode:'writes'});
  const alive=useRef(true);
  const initialized=useRef(false);
  const run=useCallback(async(action:()=>Promise<void>)=>{
    setBusy(true);setError('');setNotice('');
    try{await action();}catch(reason){if(alive.current)setError(errorMessage(reason));}
    finally{if(alive.current)setBusy(false);}
  },[]);
  const loadTree=useCallback((maxDepth:number)=>run(async()=>{
    const result=await window.rclone.directoryTree(target.endpoint,maxDepth);
    if(alive.current){setText(result.text);setTruncated(result.truncated);}
  }),[run,target.endpoint]);
  useEffect(()=>{
    alive.current=true;
    if(!initialized.current){
      initialized.current=true;
      if(target.action==='tree')void loadTree(3);
      else if(target.action==='link'&&target.item)void run(async()=>{
        const result=await window.rclone.publicLink(target.endpoint,target.item!.name,target.item!.isDir);
        if(alive.current){if(result)setText(result);else onClose();}
      });
    }
    return()=>{alive.current=false;};
  },[target,loadTree,run,onClose]);
  const title=t(target.action==='tree'?'directoryTree':target.action==='link'?'publicLink':'mountRemote');
  return <Dialog title={title} t={t} onClose={onClose} className={target.action==='tree'?'tree-dialog':'small-dialog'}><div className="dialog-body">
    <p className="tool-location">{endpointText(target.endpoint)}{target.item?` / ${target.item.name}`:''}</p>
    {error&&<Notice kind="error">{error}</Notice>}{notice&&<Notice kind="success">{notice}</Notice>}
    {target.action==='tree'&&<><div className="tree-controls"><Field label={t('maxDepth')}><select value={depth} disabled={busy} onChange={event=>{const next=Number(event.target.value);setDepth(next);void loadTree(next);}}>{[1,2,3,4,5,8].map(value=><option key={value} value={value}>{value}</option>)}</select></Field><button type="button" disabled={busy} onClick={()=>void loadTree(depth)}><ArrowClockwise size={16}/>{t('refresh')}</button></div>{truncated&&<Notice kind="warning">{t('treeTruncated')}</Notice>}</>}
    {(target.action==='tree'||target.action==='link')&&(busy?<p role="status">{t('processing')}</p>:<pre className="tool-output" tabIndex={0}>{text}</pre>)}
    {target.action==='mount'&&<><p className="section-hint">{t('mountHint')}</p><div className="checkbox-stack"><Checkbox checked={mount.readOnly} onChange={readOnly=>setMount(old=>({...old,readOnly}))}>{t('readOnlyMount')}</Checkbox></div><Field label={t('mountCache')}><select value={mount.cacheMode} onChange={event=>setMount(old=>({...old,cacheMode:event.target.value as MountOptions['cacheMode']}))}><option value="off">{t('cacheOff')}</option><option value="minimal">{t('cacheMinimal')}</option><option value="writes">{t('cacheWrites')}</option><option value="full">{t('cacheFull')}</option></select></Field></>}
  </div><footer className="dialog-footer">{text&&<button type="button" className="text-button" onClick={()=>void run(async()=>{await window.rclone.copyText(text);setNotice(t('copied'));})}><Copy size={16}/>{t('copyText')}</button>}<span className="spacer"/><button type="button" onClick={onClose}>{t('close')}</button>{target.action==='mount'&&<button type="button" className="primary" disabled={busy} onClick={()=>void run(async()=>{const session=await window.rclone.startMount(target.endpoint,mount);if(session){onSession(session);onClose();}})}><HardDrives size={16}/>{t('mountStart')}</button>}</footer></Dialog>;
}

export function ToolSessions({sessions,t,language,onError}: {sessions:ToolSession[];t:Translate;language:Language;onError(message:string):void}) {
  const [stopping,setStopping]=useState<string|null>(null);
  if(!sessions.length)return null;
  return <section className="tool-sessions"><h2>{t('toolsSessions')}</h2>{sessions.map(session=><article key={session.id} className="tool-session"><div className="tool-session-icon">{session.kind==='mount'?<HardDrives size={21}/>:<Play size={20}/>}</div><div className="tool-session-detail"><strong>{session.title}</strong><span>{session.destination||formatDate(session.createdAt,language)}</span>{session.error&&<p className="error-text">{session.error}</p>}</div><span className={`tool-session-status ${session.status}`}>{t(session.status==='stopped'?'stopped':session.status==='running'?(session.kind==='mount'?'mounted':'playing'):session.status)}</span>{session.status==='running'&&<button type="button" disabled={stopping===session.id} onClick={()=>{setStopping(session.id);void window.rclone.stopToolSession(session.id).catch(reason=>onError(errorMessage(reason))).finally(()=>setStopping(null));}}><Stop size={15}/>{t(session.kind==='mount'?'unmount':'stopPlaying')}</button>}</article>)}</section>;
}
