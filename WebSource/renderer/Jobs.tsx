import { useState } from 'react';
import { ArrowRight, ArrowsClockwise, CheckCircle, XCircle, Clock, Stop, ArrowCounterClockwise, DownloadSimple, CaretDown, CaretUp, ListBullets, Trash, WarningCircle } from '@phosphor-icons/react';
import type { Job, Language } from '../shared/types';
import type { Translate } from './i18n';
import { EmptyState, IconButton, Notice, InfoTooltip } from './components';
import { endpointText, errorMessage, formatBytes, formatDate, formatDuration } from './utils';

export const jobIsActive = (job: Job) => ['queued', 'running', 'cancelling'].includes(job.status);

function JobRow({ job, t, language, onError, onNotice, onRetry }: {job: Job; t: Translate; language: Language; onError(message: string): void; onNotice(message: string): void; onRetry(job: Job): void}) {
  const [busy, setBusy] = useState(false);
  const stats = job.stats;
  const active = jobIsActive(job);
  const dry = job.request.dryRun;
  const fraction = stats.totalBytes > 0 ? Math.min(1, Math.max(0, stats.bytes / stats.totalBytes)) : stats.totalTransfers > 0 ? Math.min(1, Math.max(0, stats.transfers / stats.totalTransfers)) : null;
  const progress = fraction === null ? null : Number((active ? Math.min(99.9, fraction * 100) : fraction * 100).toFixed(1));
  const displaySpeed = Number.isFinite(stats.speed) && stats.speed >= 0 ? stats.speed : 0;
  const stateLabel = dry && job.status === 'completed' ? t('dryCompleted') : dry && job.status === 'running' ? t('dryRunning') : t(job.status);
  const act = async (action: () => Promise<unknown>) => { setBusy(true); try { await action(); } catch (reason) { onError(errorMessage(reason)); } finally { setBusy(false); } };
  const counts = `${stats.transfers.toLocaleString()} / ${stats.totalTransfers > 0 ? stats.totalTransfers.toLocaleString() : '—'}`;
  const statusIcon = job.status === 'completed' ? <CheckCircle size={17} weight="fill"/> : job.status === 'failed' ? <XCircle size={17} weight="fill"/> : job.status === 'interrupted' ? <WarningCircle size={17}/> : active ? <Clock size={16}/> : <Stop size={15}/>;
  return <article className={`job-row job-${job.status} ${dry ? 'job-dry' : ''}`} data-testid={`job-${job.id}`}>
    <div className="job-summary">
      <div className="job-identity"><div className="job-title"><span className={`job-symbol ${job.request.mode}`}><ArrowsClockwise size={18}/></span><strong>{job.request.label || t(job.request.mode)}</strong>{dry && <span className="dry-tag">{t('dryLabel')}</span>}<span className={`job-status ${job.status}`}>{statusIcon}{stateLabel}</span></div><div className="job-route" title={`${endpointText(job.request.source)} → ${endpointText(job.request.destination)}`}><span>{endpointText(job.request.source)}</span><ArrowRight size={12}/><span>{endpointText(job.request.destination)}</span></div></div>
      <div className="job-metrics"><div><span>{dry ? t('estimate') : t('transferred')}</span><strong>{formatBytes(stats.bytes)}<small> / {stats.totalBytes > 0 ? formatBytes(stats.totalBytes) : '—'}</small></strong></div><div><span>{t('fileCount')}</span><strong>{counts}</strong></div><div><span className="metric-label">{t(active ? 'rollingSpeed' : 'averageSpeed')}<InfoTooltip label={t('speed')} text={t('speedCalculationHint')}/></span><strong>{dry ? '—' : displaySpeed > 0 ? `${formatBytes(displaySpeed)}/s` : stats.elapsedTime > 0 ? '0 B/s' : t('calculating')}</strong></div><div><span className="metric-label">{active ? t('remaining') : t('elapsed')}{active && <InfoTooltip label={t('remaining')} text={t('etaHint')}/>}</span><strong>{active ? stats.eta == null ? t('calculating') : formatDuration(stats.eta) : formatDuration(stats.elapsedTime)}</strong></div></div>
      <div className="job-actions">{active ? <IconButton title={t('cancelJob')} disabled={busy || job.status === 'cancelling'} onClick={() => act(() => window.rclone.cancelJob(job.id))}><Stop size={17}/></IconButton> : <IconButton title={t('retryJob')} disabled={busy} onClick={() => act(async () => { const next = await window.rclone.retryJob(job.id); if (next) onRetry(next); })}><ArrowCounterClockwise size={18}/></IconButton>}</div>
    </div>
    <div className="job-progress-line"><div className={`progress-track ${fraction === null && active ? 'indeterminate' : ''}`} role="progressbar" aria-label={dry ? t('dryLabel') : t('transferred')} aria-valuenow={progress ?? undefined} aria-valuemin={0} aria-valuemax={100} aria-valuetext={fraction === null ? t('scanning') : `${progress?.toFixed(1)}%`}><span className="progress-fill" style={{transform: `scaleX(${fraction ?? 0})`}}/></div><span className="progress-value">{fraction === null ? active ? t('scanning') : '—' : `${progress?.toFixed(1)}%`}</span></div>
    {job.error && <Notice kind="error">{job.error}</Notice>}
    <details className="job-details"><summary><CaretDown size={12}/>{t('jobDetails')}{stats.errors > 0 && <span className="error-count">{stats.errors} {t('errors')}</span>}<time dateTime={job.createdAt}>{formatDate(job.createdAt, language, true)}</time></summary><div className="job-detail-body">
      <p className="section-hint">{dry ? t('dryStatsHint') : t('totalsHint')}</p>
      <dl className="job-extra-stats"><div><dt>{t('checked')}</dt><dd>{stats.checks.toLocaleString()} / {stats.totalChecks > 0 ? stats.totalChecks.toLocaleString() : '—'}</dd></div><div><dt>{t('errors')}</dt><dd className={stats.errors ? 'error-text' : ''}>{stats.errors.toLocaleString()}</dd></div><div><dt>{dry ? `${t('estimate')} ${t('deletes')}` : t('deletes')}</dt><dd>{stats.deletes.toLocaleString()}</dd></div><div><dt>{t('elapsed')}</dt><dd>{formatDuration(stats.elapsedTime)}</dd></div>{!dry && Number.isFinite(stats.filesPerSecond) && <div><dt>{t('fileRate')}</dt><dd>{stats.filesPerSecond!.toFixed(1)}</dd></div>}</dl>
      {stats.transferring.length > 0 && <div className="current-files"><h4>{t('currentFiles')}</h4>{stats.transferring.map((file, index) => <div className="current-file" key={`${file.name}-${index}`}><span title={file.name}>{file.name}</span><span>{formatBytes(file.bytes)} / {formatBytes(file.size)}</span><span>{dry ? '—' : `${formatBytes(file.speedAvg || file.speed)}/s`}</span><span>{file.eta == null ? t('calculating') : formatDuration(file.eta)}</span></div>)}</div>}
      <div className="log-header"><h4>{t('originalLog')}</h4><button type="button" className="text-button" disabled={busy} onClick={() => act(async () => { const path = await window.rclone.exportLog(job.id); if (path) onNotice(`${t('exportSuccess')} ${path}`); })}><DownloadSimple size={14}/>{t('exportLog')}</button></div>
      <pre className="log-output" tabIndex={0}>{job.logs.length === 0 ? t('noLogs') : job.logs.slice(-150).map((entry, index) => <span className={`log-${entry.level.toLowerCase()}`} key={`${entry.time}-${index}`}>{entry.time} {entry.level.toUpperCase()} {entry.object ? `${entry.object}: ` : ''}{entry.message}{'\n'}</span>)}</pre>
      {job.logs.length > 150 && <p className="section-hint">{t('logTail')}</p>}
      <h4>{t('command')}</h4><pre className="command-output" tabIndex={0}>{job.command}</pre>
    </div></details>
  </article>;
}

export default function Jobs({ jobs, t, language, compact = false, expanded = true, onExpanded, onViewAll, onJobsChange, onError, onNotice, onRetry }:
  {jobs: Job[]; t: Translate; language: Language; compact?: boolean; expanded?: boolean; onExpanded?(value: boolean): void; onViewAll?(): void;
    onJobsChange(jobs: Job[]): void; onError(message: string): void; onNotice(message: string): void; onRetry(job: Job): void}) {
  const [filter, setFilter] = useState<'all'|'active'|'history'>('all');
  const [busy, setBusy] = useState(false);
  const active = jobs.filter(jobIsActive);
  const sorted = [...jobs].sort((a, b) => Number(jobIsActive(b)) - Number(jobIsActive(a)) || b.createdAt.localeCompare(a.createdAt));
  const visible = compact ? sorted.slice(0, 3) : sorted.filter(job => filter === 'all' || (filter === 'active' ? jobIsActive(job) : !jobIsActive(job)));
  const clear = async () => { setBusy(true); try { await window.rclone.clearFinishedJobs(); onJobsChange(await window.rclone.listJobs()); } catch (reason) { onError(errorMessage(reason)); } finally { setBusy(false); } };
  return <section className={`jobs-section ${compact ? 'jobs-dock' : 'jobs-page'} ${!expanded ? 'collapsed' : ''}`} aria-label={t('jobs')}>
    <header className="jobs-heading"><div className="jobs-heading-title">{compact && <IconButton title={t(expanded ? 'collapseJobs' : 'expandJobs')} onClick={() => onExpanded?.(!expanded)}>{expanded ? <CaretDown size={15}/> : <CaretUp size={15}/>}</IconButton>}<ListBullets size={18}/><h2>{t(compact ? 'queue' : 'jobs')}</h2>{active.length > 0 && <span className="count-badge">{active.length}</span>}</div>
      <div className="jobs-heading-actions">{compact ? <button type="button" className="text-button" onClick={onViewAll}>{t('allJobs')}<ArrowRight size={13}/></button> : <><div className="segmented filter-tabs">{(['all','active','history'] as const).map(key => <button type="button" aria-pressed={filter === key} className={filter === key ? 'selected' : ''} key={key} onClick={() => setFilter(key)}>{t(key)}</button>)}</div><IconButton title={t('clearFinished')} disabled={busy || !jobs.some(job => !jobIsActive(job))} onClick={clear}><Trash size={17}/></IconButton></>}</div>
    </header>
    {expanded && <div className="job-list">{visible.length === 0 ? <EmptyState compact={compact} icon={<ArrowsClockwise size={compact ? 24 : 38}/>} title={t(filter === 'active' && jobs.length > 0 ? 'noActiveJobs' : 'noJobs')}>{t('noJobsHint')}</EmptyState> : visible.map(job => <JobRow key={job.id} job={job} t={t} language={language} onError={onError} onNotice={onNotice} onRetry={onRetry}/>)}</div>}
  </section>;
}
