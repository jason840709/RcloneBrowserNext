import { useEffect, useRef } from 'react';
import { DotsThree, TreeStructure, DownloadSimple, Link, HardDrives, Play, Columns } from '@phosphor-icons/react';
import type { Translate } from './i18n';
import type { ToolAction } from './Tools';

export default function PaneMenu({t,remote,selectedCount,selectedDirectory,disabled,onAction,onResetColumns}: {
  t:Translate;remote:boolean;selectedCount:number;selectedDirectory:boolean;disabled:boolean;onAction(action:ToolAction):void;onResetColumns():void;
}) {
  const ref=useRef<HTMLDetailsElement>(null);
  const close=()=>{if(ref.current)ref.current.open=false;};
  useEffect(()=>{
    const listener=(event:PointerEvent)=>{if(ref.current&&!ref.current.contains(event.target as Node))close();};
    document.addEventListener('pointerdown',listener);return()=>document.removeEventListener('pointerdown',listener);
  },[]);
  const action=(key:ToolAction)=>{close();onAction(key);};
  return <details ref={ref} className="pane-more-menu" onKeyDown={event=>{
    if(event.key==='Escape'){event.preventDefault();event.stopPropagation();close();ref.current?.querySelector('summary')?.focus();}
    if(['ArrowDown','ArrowUp','Home','End'].includes(event.key)){
      event.preventDefault();event.stopPropagation();if(ref.current)ref.current.open=true;
      const buttons=[...(ref.current?.querySelectorAll<HTMLButtonElement>('button:not(:disabled)')||[])];const i=buttons.indexOf(document.activeElement as HTMLButtonElement);
      buttons[event.key==='Home'?0:event.key==='End'?buttons.length-1:event.key==='ArrowDown'?(i+1)%buttons.length:(i-1+buttons.length)%buttons.length]?.focus();
    }
  }}><summary className="icon-button" aria-label={t('moreActions')} title={t('moreActions')} aria-haspopup="menu"><DotsThree size={21} weight="bold"/></summary><div className="pane-more-content" role="menu" aria-label={t('moreActions')}>
    <button type="button" role="menuitem" disabled={disabled} onClick={()=>action('tree')}><TreeStructure size={17}/>{t('directoryTree')}</button>
    <button type="button" role="menuitem" disabled={disabled} onClick={()=>action('exportCSV')}><DownloadSimple size={17}/>{t('exportFileCSV')}</button>
    <button type="button" role="menuitem" disabled={disabled} onClick={()=>action('exportTXT')}><DownloadSimple size={17}/>{t('exportFileTXT')}</button>
    {remote&&<><div className="menu-separator" role="separator"/><button type="button" role="menuitem" disabled={disabled||selectedCount!==1} onClick={()=>action('link')}><Link size={17}/>{t('publicLink')}</button><button type="button" role="menuitem" disabled={disabled} onClick={()=>action('mount')}><HardDrives size={17}/>{t('mountRemote')}</button></>}
    <button type="button" role="menuitem" disabled={disabled||selectedCount!==1||selectedDirectory} onClick={()=>action('stream')}><Play size={17}/>{t('streamFile')}</button><div className="menu-separator" role="separator"/><button type="button" role="menuitem" onClick={()=>{close();onResetColumns();}}><Columns size={17}/>{t('resetColumns')}</button>
  </div></details>;
}
