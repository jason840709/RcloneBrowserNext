import {useEffect, useMemo, useRef, useState} from 'react';
import {ArrowClockwise, CaretLeft, CaretRight, DownloadSimple, WarningCircle, CheckCircle} from '@phosphor-icons/react';
import type {JobReportCategory, JobReportItem, JobReportPage, JobReportSummary, Language} from '../shared/types';
import {translator, type Translate} from './i18n';
import {IconButton, InfoTooltip, Notice} from './components';
import {errorMessage, formatBytes} from './utils';

const categories = [
  {value:'all',label:'all'}, {value:'comparison',label:'reportComparison'},
  {value:'skipped',label:'reportSkipped'}, {value:'success',label:'reportSuccess'},
  {value:'errors',label:'reportErrors'},
] as const;

export default function JobReport({id, summary, language, t, onNotice}: {id:string; summary?:JobReportSummary; language:Language; t:Translate; onNotice(message:string):void}) {
  const [category,setCategory]=useState<JobReportCategory>('all');
  const [cursors,setCursors]=useState([0]),[index,setIndex]=useState(0);
  const [page,setPage]=useState<JobReportPage|null>(null),[busy,setBusy]=useState(false),[exporting,setExporting]=useState(false);
  const [error,setError]=useState(''),[revision,setRevision]=useState(0);
  const request=useRef(0),cursor=cursors[index];
  useEffect(()=>{
    const serial=++request.current;setBusy(true);setError('');
    void window.rclone.getJobReport(id,{category,cursor,limit:100}).then(result=>{if(request.current===serial)setPage(result);}).catch(reason=>{if(request.current===serial)setError(errorMessage(reason));}).finally(()=>{if(request.current===serial)setBusy(false);});
    return()=>{++request.current;};
  },[id,category,cursor,revision]);
  const changeCategory=(value:JobReportCategory)=>{setCategory(value);setCursors([0]);setIndex(0);setPage(null);};
  const next=()=>{if(page?.nextCursor==null)return;setCursors(old=>[...old.slice(0,index+1),page.nextCursor!]);setIndex(index+1);setPage(null);};
  const previous=()=>{setIndex(Math.max(0,index-1));setPage(null);};
  const exportReport=async(format:'jsonl'|'comparison'='jsonl')=>{setExporting(true);setError('');try{const path=await window.rclone.exportJobReport(id,format);if(path)onNotice(`${t('exportSuccess')} ${path}`);}catch(reason){setError(errorMessage(reason));}finally{setExporting(false);}};
  const currentSummary=summary?.available&&summary.eventCount>=(page?.summary?.eventCount??-1)?summary:page?.summary;
  const rows=useMemo(()=>{
    const tx=translator(language);
    const timeFormatter=new Intl.DateTimeFormat(language==='system'?'en':language,{year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',second:'2-digit',hourCycle:'h23'});
    return (page?.items||[]).slice(0,100).map(item=>{
      const date=new Date(item.time),time=Number.isNaN(date.getTime())?item.time:timeFormatter.format(date);
      const failed=item.status==='error'||item.status==='comparison-error';
      return <li key={item.sequence} className={`report-entry ${failed?'report-entry-error':''}`}>
        <div className="report-entry-meta"><time dateTime={item.time} title={item.time}>{time}</time><span className={`report-action report-action-${item.status}`}>{failed?<WarningCircle size={13}/>:item.status==='success'?<CheckCircle size={13}/>:null}{reportAction(item,tx)}</span>{typeof item.size==='number'&&item.size>=0&&<small>{formatBytes(item.size)}</small>}</div>
        <div className="report-entry-content">{item.path?<strong className="report-file-path">{item.path}</strong>:<strong className="report-general-label">{tx(failed?'reportGeneralError':'reportGeneralEvent')}</strong>}<p>{reportMessage(item,tx)}</p></div>
      </li>;
    });
  },[page?.items,language]);
  return <section className="job-report" aria-label={t('fileReport')}>
    <header className="job-report-header"><h4>{t('fileReport')}</h4><InfoTooltip label={t('fileReport')} text={t('reportHint')}/><span className="spacer"/><IconButton title={t('refreshReport')} disabled={busy} onClick={()=>setRevision(value=>value+1)}><ArrowClockwise size={16} className={busy?'loading-icon':''}/></IconButton><button type="button" className="text-button" disabled={exporting||!currentSummary?.available||page?.available===false} onClick={()=>void exportReport()}><DownloadSimple size={15}/>{t('exportFullReport')}</button></header>
    <nav className="report-tabs" aria-label={t('fileReport')}>{categories.map(item=><button type="button" key={item.value} aria-pressed={category===item.value} disabled={busy} onClick={()=>changeCategory(item.value)}>{t(item.label)}{currentSummary?.available&&<span className="report-tab-count">{categoryCount(item.value,currentSummary).toLocaleString()}</span>}</button>)}</nav>
    {(category==='comparison'||Boolean(currentSummary?.comparisonMalformed))&&<div className="report-extra-actions"><button type="button" className="text-button" disabled={exporting||!currentSummary?.available||page?.available===false} onClick={()=>void exportReport('comparison')}><DownloadSimple size={15}/>{t('exportRawComparison')}</button></div>}
    {error&&<Notice kind="error">{error}</Notice>}
    {Boolean(currentSummary?.comparisonMalformed)&&<Notice kind="warning">{t('reportMalformedHint')}</Notice>}
    {category==='errors'&&currentSummary&&currentSummary.unattributedErrors>0&&<p className="report-interpretation">{t('reportGeneralErrorCount')} {currentSummary.unattributedErrors.toLocaleString()} · {t('reportGeneralErrorHint')}</p>}
    {category==='skipped'&&<p className="report-interpretation">{t('skippedRecordsHint')}</p>}
    {category==='comparison'&&<p className="report-interpretation">{t('reportComparisonHint')}</p>}
    {category==='success'&&<p className="report-interpretation">{t('reportSuccessHint')}</p>}
    <div className="report-list" aria-busy={busy}>{busy?<p className="report-empty" role="status">{t('loadingReport')}</p>:page?.available===false?<p className="report-empty">{t('reportUnavailable')}</p>:rows.length?<ol>{rows}</ol>:<p className="report-empty">{t('reportEmpty')}</p>}</div>
    <footer className="report-pagination"><span>{t('reportPage')} {index+1} · {page?.items.length||0} / 100 {t('reportRecords')}</span>{summary?.eventCount&&page&&summary.eventCount>(page.summary?.eventCount||0)?<span className="report-new-records">{t('reportNewRecords')}</span>:null}<span className="spacer"/><IconButton title={t('previousReportPage')} disabled={busy||index===0} onClick={previous}><CaretLeft size={15}/></IconButton><IconButton title={t('nextReportPage')} disabled={busy||page?.nextCursor==null} onClick={next}><CaretRight size={15}/></IconButton></footer>
  </section>;
}

function categoryCount(category:JobReportCategory,summary:JobReportSummary){return category==='success'?summary.successEvents:category==='errors'?summary.errorEvents+summary.comparisonErrorEvents:category==='skipped'?summary.matchedEvents+(summary.skippedEvents||0):category==='comparison'?summary.comparisonEvents:summary.eventCount;}
function reportAction(item:JobReportItem,t:Translate){
  if(item.status==='matched'||item.action==='match')return t('reportMatchedAction');
  if(item.status==='candidate')return t('reportCandidateAction');
  if(item.status==='comparison-error')return t('reportComparisonError');
  if(item.status==='planned')return t('reportPlannedAction');
  if(item.status==='skipped')return t('reportSkippedAction');
  if(item.status==='error')return t('reportErrorAction');
  const action=item.action.toLowerCase();
  if(['copy','copied'].includes(action))return t('reportCopiedAction');
  if(['move','moved'].includes(action))return t('reportMovedAction');
  if(['delete','deleted','remove','removed'].includes(action))return t('reportDeletedAction');
  if(['missing-source','destination-only'].includes(action))return t('reportDestinationOnly');
  return item.status==='success'?t('reportCompletedAction'):t('reportComparison');
}

function reportMessage(item:JobReportItem,t:Translate){
  if(item.evidence!=='comparison')return item.message;
  switch(item.action){
    case 'match':return t('reportMatchedMessage');
    case 'missing-destination':return t('reportMissingDestinationMessage');
    case 'different':return t('reportDifferentMessage');
    case 'missing-source':return t('reportMissingSourceMessage');
    case 'comparison-error':return t('reportComparisonErrorMessage');
    case 'unparsed-comparison':return t('reportMalformedHint');
    default:return item.message;
  }
}
