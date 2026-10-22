import { useRef, useState } from 'react';
import { ArrowRight, ArrowsClockwise, CheckCircle, XCircle, Clock, Stop, ArrowCounterClockwise, DownloadSimple, CaretDown, CaretUp, ListBullets, Trash, WarningCircle, SpinnerGap } from '@phosphor-icons/react';
import type { Job, Language, ClearJobsRequest } from '../shared/types';
import type { Translate } from './i18n';
import { Dialog, IconButton, Notice, InfoTooltip } from './components';
import { endpointText, errorMessage, formatBytes, formatDate, formatDuration } from './utils';
import JobReport from './JobReport';

export const jobIsActive = (job: Job) => ['queued', 'running', 'cancelling'].includes(job.status);

function JobRow({ job, t, language, onError, onNotice, onRetry }: {job: Job; t: Translate; language: Language; onError(message: string): void; onNotice(message: string): void; onRetry(job: Job): void}) {
  const [busy, setBusy] = useState(false);
  const [detailsOpen, setDetailsOpen] = useState(false);
  const stats = job.stats;
  const sizeError = job.status === 'failed' && /sizes differ src/.test(job.error || '');
  const failureMessage = sizeError ? t(job.report?.growingSourceEvents ? 'sourceGrowingJob' : 'sizeMismatchJob') : job.error;
  const report = job.report;
  const copyDataAvailable = report?.copyByteTotalsAvailable && typeof report.copiedBytes === 'number';
  const active = jobIsActive(job);
  const dry = job.request.dryRun;
  const fraction = stats.totalBytes > 0 ? Math.min(1, Math.max(0, stats.bytes / stats.totalBytes)) : stats.totalTransfers > 0 ? Math.min(1, Math.max(0, stats.transfers / stats.totalTransfers)) : null;
  const progress = job.status === 'completed' ? 100 : fraction === null ? null : Number((active ? Math.min(99.9, fraction * 100) : fraction * 100).toFixed(1));
  const indeterminate = progress === null && ['running', 'cancelling'].includes(job.status);
  const displaySpeed = Number.isFinite(stats.speed) && stats.speed >= 0 ? stats.speed : 0;
  const stateLabel = dry && job.status === 'completed' ? t('dryCompleted') : dry && job.status === 'running' ? t('dryRunning') : !active && job.cancellation?.processExited ? t('stopped') : t(job.status);
  const act = async (action: () => Promise<unknown>) => { setBusy(true); try { await action(); } catch (reason) { onError(errorMessage(reason)); } finally { setBusy(false); } };
  const counts = `${stats.transfers.toLocaleString()} / ${stats.totalTransfers > 0 ? stats.totalTransfers.toLocaleString() : '—'}`;
  const statusIcon = job.status === 'completed' ? <CheckCircle size={17} weight="fill"/> : job.status === 'failed' ? <XCircle size={17} weight="fill"/> : job.status === 'interrupted' ? <WarningCircle size={17}/> : active ? <Clock size={16}/> : <Stop size={15}/>;
  return <article className={`job-row job-${job.status} ${dry ? 'job-dry' : ''}`} data-testid={`job-${job.id}`}>
    <div className="job-summary">
      <div className="job-identity"><div className="job-title"><span className={`job-symbol ${job.request.mode}`}><ArrowsClockwise size={18}/></span><strong>{job.request.label || t(job.request.mode)}</strong>{dry && <span className="dry-tag">{t('dryLabel')}</span>}<span className={`job-status ${job.status}`}>{statusIcon}{stateLabel}</span></div><div className="job-route" title={`${endpointText(job.request.source)} → ${endpointText(job.request.destination)}`}><span>{endpointText(job.request.source)}</span><ArrowRight size={12}/><span>{endpointText(job.request.destination)}</span></div></div>
      <div className="job-metrics"><div><span className="metric-label">{dry ? t('estimate') : t('processedBytes')}{!dry&&<InfoTooltip label={t('processedBytes')} text={t('processedBytesHint')}/>}</span><strong>{formatBytes(stats.bytes)}<small> / {stats.totalBytes > 0 ? formatBytes(stats.totalBytes) : '—'}</small></strong></div><div><span className="metric-label">{t('fileCount')}<InfoTooltip label={t('fileCount')} text={t('completedTransfersHint')}/></span><strong>{counts}</strong></div><div><span className="metric-label">{t(active ? 'rollingSpeed' : 'averageSpeed')}<InfoTooltip label={t('speed')} text={t('speedCalculationHint')}/></span><strong>{dry ? '—' : displaySpeed > 0 ? `${formatBytes(displaySpeed)}/s` : stats.elapsedTime > 0 ? '0 B/s' : t('calculating')}</strong></div><div><span className="metric-label">{active ? t('remaining') : t('elapsed')}{active && <InfoTooltip label={t('remaining')} text={t('etaHint')}/>}</span><strong>{active ? stats.eta == null ? t('calculating') : formatDuration(stats.eta) : formatDuration(stats.elapsedTime)}</strong></div></div>
      <div className="job-actions">{active ? <IconButton title={t('cancelJob')} disabled={busy || job.status === 'cancelling'} onClick={() => act(() => window.rclone.cancelJob(job.id))}><Stop size={17}/></IconButton> : <IconButton title={t('retryJob')} disabled={busy} onClick={() => act(async () => { const next = await window.rclone.retryJob(job.id); if (next) onRetry(next); })}><ArrowCounterClockwise size={18}/></IconButton>}</div>
    </div>
    <div className="job-progress-line"><div className={`progress-track ${indeterminate ? 'indeterminate' : ''}`} role="progressbar" aria-label={dry ? t('dryLabel') : t('transferred')} aria-valuenow={progress ?? undefined} aria-valuemin={0} aria-valuemax={100} aria-valuetext={progress !== null ? `${progress.toFixed(1)}%` : job.status === 'running' ? t('scanning') : stateLabel}>{indeterminate ? <span className="progress-indicator" aria-hidden="true"/> : <span className="progress-fill" style={{transform: `scaleX(${(progress ?? 0) / 100})`}}/>}</div><span className="progress-value">{progress !== null ? `${progress.toFixed(1)}%` : job.status === 'running' ? t('scanning') : stateLabel}</span></div>
    <dl className="job-file-counts"><div><dt>{t('neededFiles')}<InfoTooltip label={t('neededFiles')} text={t('neededFilesHint')}/></dt><dd>{stats.totalTransfers.toLocaleString()}</dd></div><div><dt>{t(dry?'plannedFiles':'transferredFiles')}</dt><dd>{stats.transfers.toLocaleString()}</dd></div><div><dt>{t('checked')}<InfoTooltip label={t('checked')} text={t('checksHint')}/></dt><dd>{stats.checks.toLocaleString()} / {stats.totalChecks.toLocaleString()}</dd></div><div><dt>{t('skippedRecords')}<InfoTooltip label={t('skippedRecords')} text={t('skippedRecordsHint')}/></dt><dd>{job.report?.available?(job.report.matchedEvents+(job.report.skippedEvents||0)).toLocaleString():'—'}</dd></div><div><dt>{t('errorAttempts')}<InfoTooltip label={t('errorAttempts')} text={t('errorAttemptsHint')}/></dt><dd className={stats.errors?'error-text':''}>{stats.errors.toLocaleString()}</dd></div></dl>
    {failureMessage && <Notice kind="error">{failureMessage}</Notice>}
    {!active && job.cancellation && job.startedAt && <Notice kind={job.cancellation.forced ? 'warning' : 'info'}>{t(job.cancellation.forced ? 'forcedStopHint' : 'stoppedJobHint')}</Notice>}
    <details className="job-details" onToggle={event=>setDetailsOpen(event.currentTarget.open)}><summary><CaretDown size={12}/>{t('jobDetails')}{stats.errors > 0 && <span className="error-count">{stats.errors} {t('errors')}</span>}<time dateTime={job.createdAt}>{formatDate(job.createdAt, language, true)}</time></summary><div className="job-detail-body">
      <p className="section-hint">{dry ? t('dryStatsHint') : t('totalsHint')}</p>
      <dl className="job-extra-stats">{typeof stats.listed==='number'&&<div><dt>{t('listedEntries')}</dt><dd>{stats.listed.toLocaleString()}</dd></div>}<div><dt>{dry ? `${t('estimate')} ${t('deletes')}` : t('deletes')}</dt><dd>{stats.deletes.toLocaleString()}</dd></div><div><dt>{t('elapsed')}</dt><dd>{formatDuration(stats.elapsedTime)}</dd></div>{!dry && Number.isFinite(stats.filesPerSecond) && <div><dt>{t('fileRate')}</dt><dd>{stats.filesPerSecond!.toFixed(1)}</dd></div>}</dl>
      {!dry&&report?.available&&(copyDataAvailable||Boolean(report.sizeMismatchEvents)||Boolean(report.lastAttempt))&&<dl className="job-byte-summary">
        {copyDataAvailable&&<div><dt>{t('copiedBytes')}<InfoTooltip label={t('copiedBytes')} text={t('copiedBytesHint')}/></dt><dd>{formatBytes(report.copiedBytes!)}<small>{report.copiedBytes!.toLocaleString()} B</small></dd></div>}
        {Boolean(report.sizeMismatchEvents)&&typeof report.failedCopyBytes==='number'&&<div><dt>{t('failedCopyBytes')}<InfoTooltip label={t('failedCopyBytes')} text={t('failedCopyBytesHint')}/></dt><dd>{formatBytes(report.failedCopyBytes)}<small>{report.failedCopyBytes.toLocaleString()} B</small></dd></div>}
        {Boolean(report.lastAttempt)&&<div><dt>{t('jobAttempt')}<InfoTooltip label={t('jobAttempt')} text={t('jobAttemptHint')}/></dt><dd>{report.lastAttempt} / {report.maxAttempts||job.request.options.retries}</dd></div>}
      </dl>}
      {failureMessage!==job.error&&job.error&&<details className="job-original-error"><summary>{t('reportOriginalMessage')}</summary><pre>{job.error}</pre></details>}
      {detailsOpen&&<JobReport id={job.id} summary={job.report} options={job.request.options} language={language} t={t} onNotice={onNotice}/>}
      {stats.transferring.length > 0 && <div className="current-files"><h4>{t('currentFiles')}</h4>{stats.transferring.map((file, index) => <div className="current-file" key={`${file.name}-${index}`}><span title={file.name}>{file.name}</span><span>{formatBytes(file.bytes)} / {formatBytes(file.size)}</span><span>{dry ? '—' : `${formatBytes(file.speedAvg || file.speed)}/s`}</span><span>{file.eta == null ? t('calculating') : formatDuration(file.eta)}</span></div>)}</div>}
      <div className="log-header"><h4>{t('originalLog')}</h4><button type="button" className="text-button" disabled={busy} onClick={() => act(async () => { const path = await window.rclone.exportLog(job.id); if (path) onNotice(`${t('exportSuccess')} ${path}`); })}><DownloadSimple size={14}/>{t('exportLog')}</button></div>
      <pre className="log-output" tabIndex={0}>{job.logs.length === 0 ? t('noLogs') : job.logs.slice(-150).map((entry, index) => <span className={`log-${entry.level.toLowerCase()}`} key={`${entry.time}-${index}`}>{entry.time} {entry.level.toUpperCase()} {entry.object ? `${entry.object}: ` : ''}{entry.message}{'\n'}</span>)}</pre>
      {job.logs.length > 150 && <p className="section-hint">{t('logTail')}</p>}
      <h4>{t('command')}</h4><pre className="command-output" tabIndex={0}>{job.command}</pre>
    </div></details>
  </article>;
}

export default function Jobs({ jobs, t, language, compact = false, expanded = true, onExpanded, onViewAll, onJobsCleared, onError, onNotice, onRetry }:
  {jobs: Job[]; t: Translate; language: Language; compact?: boolean; expanded?: boolean; onExpanded?(value: boolean): void; onViewAll?(): void;
    onJobsCleared(ids: string[]): void; onError(message: string): void; onNotice(message: string): void; onRetry(job: Job): void}) {
  const [filter, setFilter] = useState<'all'|'active'|'history'>('all');
  const [busy, setBusy] = useState(false);
  const [clearSnapshot, setClearSnapshot] = useState<{scopeIds: string[]; completedIds: string[]; activeCount: number} | null>(null);
  const [clearError, setClearError] = useState('');
  const [clearMode, setClearMode] = useState<ClearJobsRequest['mode'] | null>(null);
  const clearing = useRef(false);
  const active = jobs.filter(jobIsActive);
  const sorted = [...jobs].sort((a, b) => Number(jobIsActive(b)) - Number(jobIsActive(a)) || b.createdAt.localeCompare(a.createdAt));
  const visible = compact ? sorted.slice(0, 3) : sorted.filter(job => filter === 'all' || (filter === 'active' ? jobIsActive(job) : !jobIsActive(job)));
  const clear = async (request: ClearJobsRequest) => {
    if (clearing.current || !request.ids.length) return;
    clearing.current = true;
    setBusy(true); setClearMode(request.mode); setClearError('');
    try {
      const result = await window.rclone.clearJobs(request);
      // Remove only the acknowledged IDs from the latest parent state. New jobs
      // and late events must not be replaced by an older listJobs snapshot.
      onJobsCleared(result.removedIds);
      setClearSnapshot(null);
      if (result.forcedStopIds.length) onError(t('forcedStopHint'));
      else if (result.retainedIds.length) onError(t('jobsRetainedHint'));
      else onNotice(result.stoppedIds.length ? t('jobsStoppedAndCleared') : t('jobsCleared'));
    } catch (reason) {
      if (clearSnapshot) setClearError(errorMessage(reason));
      else onError(errorMessage(reason));
    } finally { clearing.current = false; setBusy(false); setClearMode(null); }
  };
  const beginClear = () => {
    if (busy) return;
    if (filter !== 'history' && active.length) {
      setClearError('');
      setClearSnapshot({scopeIds: (filter === 'active' ? active : jobs).map(job => job.id), completedIds: jobs.filter(job => job.status === 'completed').map(job => job.id), activeCount: active.length});
    } else void clear({ids: jobs.filter(job => !jobIsActive(job)).map(job => job.id), mode: 'finished'});
  };
  const canClear = filter === 'history' ? jobs.some(job => !jobIsActive(job)) : filter === 'active' ? active.length > 0 : jobs.length > 0;
  return <section className={`jobs-section ${compact ? 'jobs-dock' : 'jobs-page'} ${!expanded ? 'collapsed' : ''}`} aria-label={t('jobs')}>
    <header className="jobs-heading"><div className="jobs-heading-title">{compact && <IconButton title={t(expanded ? 'collapseJobs' : 'expandJobs')} onClick={() => onExpanded?.(!expanded)}>{expanded ? <CaretDown size={15}/> : <CaretUp size={15}/>}</IconButton>}<ListBullets size={18}/><h2>{t(compact ? 'queue' : 'jobs')}</h2>{active.length > 0 && <span className="count-badge">{active.length}</span>}</div>
      <div className="jobs-heading-actions">{compact ? <button type="button" className="text-button" onClick={onViewAll}>{t('allJobs')}<ArrowRight size={13}/></button> : <><div className="segmented filter-tabs">{(['all','active','history'] as const).map(key => <button type="button" aria-pressed={filter === key} className={filter === key ? 'selected' : ''} key={key} disabled={busy} onClick={() => setFilter(key)}>{t(key)}</button>)}</div><IconButton title={t(filter === 'history' ? 'clearFinished' : 'clearJobs')} disabled={busy || !canClear} onClick={beginClear}>{busy ? <SpinnerGap size={17} className="loading-icon"/> : <Trash size={17}/>}</IconButton></>}</div>
    </header>
    {expanded && <div className="job-list">{visible.length === 0 ? <div className="jobs-empty" role="status"><p>{t(filter === 'active' && jobs.length > 0 ? 'noActiveJobs' : 'noJobs')}</p></div> : visible.map(job => <JobRow key={job.id} job={job} t={t} language={language} onError={onError} onNotice={onNotice} onRetry={onRetry}/>)}</div>}
    {clearSnapshot && <Dialog title={t('clearJobsTitle')} t={t} onClose={() => { if (!busy) setClearSnapshot(null); }} dismissible={!busy} className="clear-jobs-dialog">
      <div className="dialog-body"><p>{t('clearJobsPrompt').replace('{count}', String(clearSnapshot.activeCount))}</p><p className="section-hint">{t('clearJobsStopHint')}</p>{clearError && <Notice kind="error">{clearError}</Notice>}{busy && <Notice><span className="stopping-jobs" role="status"><SpinnerGap size={17} className="loading-icon"/>{t(clearMode === 'stop-and-clear' ? 'stoppingJobs' : 'clearingJobs')}</span></Notice>}</div>
      <div className="clear-jobs-choices"><button type="button" className="danger clear-stop-choice" disabled={busy} onClick={() => void clear({ids: clearSnapshot.scopeIds, mode: 'stop-and-clear'})}><Stop size={17}/>{t('stopAndClear')}</button><button type="button" disabled={busy || !clearSnapshot.completedIds.length} onClick={() => void clear({ids: clearSnapshot.completedIds, mode: 'finished'})}><Trash size={17}/>{t('clearCompletedOnly')}<span className="clear-choice-count">{clearSnapshot.completedIds.length}</span></button></div>
      <footer className="dialog-footer"><span className="spacer"/><button type="button" disabled={busy} onClick={() => setClearSnapshot(null)}>{t('cancel')}</button></footer>
    </Dialog>}
  </section>;
}
