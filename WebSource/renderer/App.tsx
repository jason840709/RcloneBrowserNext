import { useHistoryNavigation } from './useHistoryNavigation';
import { useCallback, useEffect, useRef, useState } from 'react';
import { ArrowLeft, ArrowRight, ArrowsLeftRight, FolderOpen, ListBullets, BookBookmark, GearSix, CaretDown, SlidersHorizontal,
  FloppyDisk, TerminalWindow, Play, Eye, CheckCircle, WarningCircle, ArrowSquareOut, X, Cloud, HardDrives, ChartBar } from '@phosphor-icons/react';
import { DEFAULT_OPTIONS, type Bootstrap, type CommandPreview, type Endpoint, type Job, type SavedTask, type Settings, type SettingsPatch, type TransferMode, type TransferOptions, type TransferRequest, type UpdateStatus, type ToolSession, type AppUpdateResult, type ResolvedLanguage, type BuiltinPresetID } from '../shared/types';
import OperationPicker from './OperationPicker';
import { applyTheme, initialTheme, startupIcon, themeIcon } from './appearance';
import {presetOptions, presetLabel, presetSummary, recommendedPreset} from './presets';
import BrowserPane, { type FileAction } from './BrowserPane';
import Jobs, { jobIsActive } from './Jobs';
import Tasks from './Tasks';
import TransferOptionsDialog from './TransferOptions';
import SettingsDialog from './Settings';
import ApplicationMenu from './ApplicationMenu';
import {ToolDialog, ToolSessions, type ToolAction, type ToolTarget} from './Tools';
import { Dialog, EmptyState, Field, IconButton, Notice, InfoTooltip, FloatingNotice } from './components';
import { translator, resolveLanguage } from './i18n';
import { useBrowser } from './useBrowser';
import { endpointEqual, endpointName, endpointText, errorMessage, formatBytes, validName } from './utils';

type Modal = 'options' | 'settings' | 'saveTask' | 'preview' | 'help' | 'appUpdate' | null;
type FileDialog = { kind: Exclude<FileAction, 'remove'>; side: 'left'|'right'; endpoint: Endpoint; oldName?: string; isDir?: boolean };
const initialSettings: Settings = { rcloneDirectory: '', rclonePath: '', configPath: '', language: 'system', theme: 'purple-dark', interfaceScale: 100, autoCheckUpdates: true, skippedRcloneVersion: '', paneColumnWidths: {}, defaultTransferOptions: DEFAULT_OPTIONS, maxConcurrentJobs: 0, proxyMode: 'system', httpProxy: '', httpsProxy: '', noProxy: '', defaultRcloneOptions: [], initialLocations: {}, savedWorkspace: null, networkOptions: {bindMode: 'auto', bindAddress: '', connectTimeout: '1m', ioTimeout: '5m', tpsLimit: 0, tpsBurst: 1, userAgent: '', disableHTTP2: false}, settingsRevision: 0, settingsSchemaVersion: 7, hiddenBuiltinPresets: [], streamPlayerPath: '', streamPlayerArguments: ['-'], showStatusItem: false, notifyOnCompletion: false, showHiddenFiles: true, showFolderIcons: true, showFileIcons: true, alternatingRows: true };
function mergeSettings(base: Settings, patch: SettingsPatch): Settings {
  return {...base, ...patch,
    paneColumnWidths: {...base.paneColumnWidths, ...patch.paneColumnWidths},
    defaultTransferOptions: {...base.defaultTransferOptions, ...patch.defaultTransferOptions},
    networkOptions: {...base.networkOptions, ...patch.networkOptions},
  };
}

function bandwidthLimitLabel(value: string): string | null {
  const match = /^([0-9]+(?:\.[0-9]+)?)([bB]|[kKmMgGtTpPeE](?:[iI]|i[bB])?)?$/.exec(value);
  if (!match || Number(match[1]) === 0) return null;
  // rclone treats an unsuffixed number as KiB; all size suffixes are binary.
  const units: Record<string, string> = {b: 'B', k: 'KiB', m: 'MiB', g: 'GiB', t: 'TiB', p: 'PiB', e: 'EiB'};
  return `${match[1]} ${units[match[2]?.[0].toLowerCase() || 'k']}/s`;
}

export default function App() {
  const [bootstrap, setBootstrap] = useState<Bootstrap | null>(null);
  const [startupError, setStartupError] = useState('');
  const [updateStatus, setUpdateStatus] = useState<UpdateStatus | null>(null);
  const startupCheck = useRef(false);
  const [settings, setSettings] = useState<Settings>(() => ({...initialSettings, theme: initialTheme()}));
  const settingsRef = useRef(settings);
  const saveQueue = useRef<Promise<void>>(Promise.resolve());
  const settingsEpoch = useRef(0);
  const serverRevision = useRef(0);
  const bootstrapSequence = useRef(0);
  const [pendingSettings, setPendingSettings] = useState(0);
  const [jobs, setJobs] = useState<Job[]>([]);
  const [tasks, setTasks] = useState<SavedTask[]>([]);
  const [toolSessions, setToolSessions] = useState<ToolSession[]>([]);
  const [toolTarget, setToolTarget] = useState<ToolTarget | null>(null);
  const [page, setPage] = useState<'files'|'jobs'|'tasks'>('files');
  const [activePane, setActivePane] = useState<'left'|'right'>('left');
  const [direction, setDirection] = useState<'lr'|'rl'>('lr');
  const [mode, setMode] = useState<TransferMode>('copy');
  const [options, setOptions] = useState<TransferOptions>(() => structuredClone(DEFAULT_OPTIONS));
  const [modal, setModal] = useState<Modal>(null);
  const [fileDialog, setFileDialog] = useState<FileDialog | null>(null);
  const [fileName, setFileName] = useState('');
  const [fileError, setFileError] = useState('');
  const [sizeResult, setSizeResult] = useState<{count: number; bytes: number} | null>(null);
  const [fileBusy, setFileBusy] = useState(false);
  const sizeGeneration = useRef(0);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');
  const [noticeSerial, setNoticeSerial] = useState(0);
  const [activePreset, setActivePreset] = useState<BuiltinPresetID | null>(null);
  const [jobsExpanded, setJobsExpanded] = useState(true);
  const [loadedTask, setLoadedTask] = useState<SavedTask | null>(null);
  const [editingTask, setEditingTask] = useState<{name: string; id?: string; request: TransferRequest; validationError?: string} | null>(null);
  const [appUpdate, setAppUpdate] = useState<AppUpdateResult | null>(null);
  const systemLanguage = useRef<ResolvedLanguage>(resolveLanguage(navigator.languages?.[0] || navigator.language || 'en'));
  const [modalError, setModalError] = useState('');
  const [preview, setPreview] = useState<CommandPreview | null>(null);
  const left = useBrowser();
  const right = useBrowser();
  const observedStatuses = useRef(new Map<string, Job['status']>());
  const clearedJobIds = useRef(new Set<string>());
  const language = settings.language === 'system' ? systemLanguage.current : settings.language;
  const t = translator(language);
  const source = direction === 'lr' ? left : right;
  const destination = direction === 'lr' ? right : left;
  const activeJobs = jobs.filter(jobIsActive).length;
  const bridgeAvailable = Boolean(window.rclone);
  const ready = bootstrap?.environment.available || false;
  const bandwidthLimit = bandwidthLimitLabel(options.bandwidth);
  const request = (dryRun = false): TransferRequest => ({source: {...source.endpoint}, destination: {...destination.endpoint}, direction, mode, options: structuredClone(options), selection: source.selection.map(item => ({...item})), dryRun, ...(loadedTask ? {label: loadedTask.name} : {})});

  const showError = useCallback((message: string) => { setError(message); setNotice(''); setNoticeSerial(value => value + 1); }, []);
  const showNotice = useCallback((message: string) => { setNotice(message); setError(''); setNoticeSerial(value => value + 1); }, []);
  const upsertJob = useCallback((job: Job) => {
    if (clearedJobIds.current.has(job.id)) return;
    const previous = observedStatuses.current.get(job.id);
    const previousTerminal = previous !== undefined && !['queued', 'running', 'cancelling'].includes(previous);
    // A late IPC return must not replace a newer completion event with an older queued/running snapshot.
    if ((previousTerminal && jobIsActive(job)) || (previous === 'running' && job.status === 'queued') || (previous === 'cancelling' && ['queued', 'running'].includes(job.status))) return;
    observedStatuses.current.set(job.id, job.status);
    setJobs(old => {
      const exists = old.some(item => item.id === job.id);
      const next = exists ? old.map(item => item.id === job.id ? job : item) : [job, ...old];
      const retained = new Set(next.filter(item => !jobIsActive(item) && item.status !== 'interrupted').sort((a,b) => (b.endedAt || b.createdAt).localeCompare(a.endedAt || a.createdAt)).slice(0,200).map(item => item.id));
      return next.filter(item => jobIsActive(item) || item.status === 'interrupted' || retained.has(item.id));
    });
    if (!job.request.dryRun && !jobIsActive(job) && !previousTerminal) {
      // Failed or cancelled transfers can also have copied/deleted files. Refresh once on termination, never on each statistics update.
      left.reload(); right.reload();
    }
  }, [left.reload, right.reload]);
  const removeClearedJobs = useCallback((ids: string[]) => {
    for (const id of ids) { clearedJobIds.current.add(id); observedStatuses.current.delete(id); }
    setJobs(old => old.filter(job => !clearedJobIds.current.has(job.id)));
  }, []);
  const fetchBootstrap = useCallback(async (initial = false, reloadLocations = true) => {
    const sequence = ++bootstrapSequence.current;
    const epoch = settingsEpoch.current;
    try {
      const incoming = await window.rclone.bootstrap();
      // A reply started before the latest user edit must never undo that edit.
      if (sequence !== bootstrapSequence.current || epoch !== settingsEpoch.current || (incoming.settings.settingsRevision ?? 0) < serverRevision.current) return;
      const data = {...incoming, settings: mergeSettings(initialSettings, incoming.settings)};
      serverRevision.current = data.settings.settingsRevision;
      if (data.settings.language === 'system' && data.resolvedLanguage) systemLanguage.current = data.resolvedLanguage;
      settingsRef.current = data.settings;
      for (const job of data.jobs) observedStatuses.current.set(job.id, job.status);
      setBootstrap(data); setSettings(data.settings); setJobs(data.jobs.filter(job => !clearedJobIds.current.has(job.id))); setTasks(data.tasks); setStartupError('');
      if (initial) {
        const workspace = data.settings.savedWorkspace;
        setOptions(structuredClone(workspace?.options || data.settings.defaultTransferOptions));
        if (workspace) { setDirection(workspace.direction); setMode(workspace.mode); }
        left.navigate(workspace?.left || data.settings.initialLocations.left || {remote: null, path: data.home});
        right.navigate(workspace?.right || data.settings.initialLocations.right || (data.environment.available && data.remotes.length > 0 ? {remote: data.remotes[0].name, path: ''} : {remote: null, path: data.home}));
      } else if (reloadLocations) { left.reload(); right.reload(); }
    } catch (reason) { if (initial) setStartupError(errorMessage(reason)); else throw reason; }
  }, [left.navigate, right.navigate, left.reload, right.reload]);
  const loadBootstrap = useCallback(async (initial = false) => {
    // Configuration completion and updater events can arrive during a settings save.
    await saveQueue.current.catch(() => {});
    await fetchBootstrap(initial);
  }, [fetchBootstrap]);
  const flushSettings = useCallback(() => saveQueue.current, []);
  const saveSettings = useCallback((patch: SettingsPatch): Promise<void> => {
    const epoch = ++settingsEpoch.current;
    const next = mergeSettings(settingsRef.current, patch);
    settingsRef.current = next;
    setSettings(next); // Theme and language update on the initiating click.
    setBootstrap(old => old ? {...old, settings: next} : old);
    setPendingSettings(count => count + 1);
    const changesLocation = 'rclonePath' in patch || 'rcloneDirectory' in patch || 'configPath' in patch;
    const operation = saveQueue.current.catch(() => {}).then(async () => {
      try {
        const environment = await window.rclone.saveSettings(patch);
        serverRevision.current = Math.max(serverRevision.current, environment.settingsRevision ?? 0);
        if (epoch === settingsEpoch.current) {
          setBootstrap(old => old ? {...old, environment} : old);
          await fetchBootstrap(false, changesLocation);
        }
      } catch (reason) {
        // Read persisted settings after a rejected save; do not leave a success-looking draft.
        if (epoch === settingsEpoch.current) await fetchBootstrap(false, changesLocation).catch(() => {});
        throw reason;
      } finally { setPendingSettings(count => Math.max(0, count - 1)); }
    });
    saveQueue.current = operation.catch(() => {});
    return operation;
  }, [fetchBootstrap]);
  const configureAccounts = useCallback(async () => {
    await saveQueue.current;
    await window.rclone.configureRemotes();
    showNotice(translator(settingsRef.current.language === 'system' ? systemLanguage.current : settingsRef.current.language)('remoteSetupOpened'));
  }, [showNotice]);

  const checkEngineUpdates = useCallback(async () => {
    await saveQueue.current;
    const tx = translator(settingsRef.current.language === 'system' ? systemLanguage.current : settingsRef.current.language);
    try {
      const result = await window.rclone.checkForUpdates(true);
      await loadBootstrap();
      if (result.status === 'error' || result.status === 'unavailable') showError(result.message || tx('updateUnavailable'));
      else if (result.status === 'current') showNotice(tx('alreadyCurrent'));
      else if (result.status === 'updated') showNotice(tx('rcloneUpdated'));
      else if (result.status === 'skipped') showNotice(tx('versionSkipped'));
      else if (result.status === 'busy') showNotice(tx('updateBusy'));
    } catch (reason) { showError(errorMessage(reason)); }
    finally { setUpdateStatus(null); }
  }, [loadBootstrap, showError, showNotice]);
  const checkAppUpdates = useCallback(async () => {
    setAppUpdate(null); setModalError(''); setModal('appUpdate');
    try { await saveQueue.current; setAppUpdate(await window.rclone.checkAppUpdates()); }
    catch (reason) { setModalError(errorMessage(reason)); }
  }, []);
  const showAbout = useCallback(() => { void window.rclone.showAbout().catch(reason => showError(errorMessage(reason))); }, [showError]);

  useEffect(() => {
    if (!bridgeAvailable) return;
    const unsubscribe = window.rclone.onJobUpdate(upsertJob);
    const unsubscribeUpdates = window.rclone.onUpdateStatus(status => {
      setUpdateStatus(status.status ? null : status);
      if (status.status === 'updated') void loadBootstrap().catch(reason => showError(errorMessage(reason)));
    });
    const unsubscribeConfiguration = window.rclone.onConfigurationChanged(() => {
      void loadBootstrap().catch(reason => showError(errorMessage(reason)));
    });
    const unsubscribeMenu = window.rclone.onMenuAction(action => {
      if (action.action === 'settings' || action.action === 'help') setModal(action.action);
      else if (action.action === 'language') void saveSettings({language: action.language}).catch(reason => showError(errorMessage(reason)));
      else if (action.action === 'configureRemotes') void configureAccounts().catch(reason => showError(errorMessage(reason)));
      else if (action.action === 'checkAppUpdates') void checkAppUpdates();
      else if (action.action === 'checkForUpdates') void checkEngineUpdates();
      else if (action.action === 'about') showAbout();
    });
    void loadBootstrap(true);
    return () => { unsubscribe(); unsubscribeUpdates(); unsubscribeConfiguration(); unsubscribeMenu(); };
  }, [bridgeAvailable, loadBootstrap, upsertJob, showError, saveSettings, configureAccounts, checkAppUpdates, checkEngineUpdates, showAbout]);
  useEffect(() => {
    if (startupCheck.current || !bootstrap) return;
    startupCheck.current = true;
    if (!bootstrap.settings.autoCheckUpdates || !bootstrap.environment.available || !bootstrap.environment.rclonePath) return;
    void window.rclone.checkForUpdates(false).then(async result => {
      if (result.status === 'updated' || result.status === 'skipped') await loadBootstrap();
    }).catch(() => {}).finally(() => setUpdateStatus(null));
  }, [bootstrap, loadBootstrap]);
  useEffect(() => {
    applyTheme(settings.theme);
    const favicon = document.querySelector<HTMLLinkElement>('link[rel="icon"]');
    if (favicon) favicon.href = themeIcon(settings.theme);
    document.documentElement.lang = language === 'zh-TW' ? 'zh-Hant' : language;
  }, [settings.theme, language]);
  useEffect(() => {
    const onKey = (event: globalThis.KeyboardEvent) => { if ((event.metaKey || event.ctrlKey) && event.key === ',') { event.preventDefault(); setModal('settings'); } };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, []);

  useEffect(() => {
    if (!bridgeAvailable) return;
    return window.rclone.onFinderDrop(drop => {
      const targetSide = document.elementFromPoint(drop.x, drop.y)?.closest<HTMLElement>('[data-pane-side]')?.dataset.paneSide;
      if (modal || fileDialog || toolTarget || document.querySelector('dialog[open]') || !ready || pendingSettings > 0 || left.pathDirty || right.pathDirty || busy || fileBusy || (targetSide !== 'left' && targetSide !== 'right')) { showError(t('finderDropBlocked')); return; }
      const target = targetSide === 'left' ? left : right;
      if (target.error || target.loading || (!target.endpoint.remote && !target.endpoint.path) || endpointEqual(drop.source, target.endpoint)) { showError(t('finderDropBlocked')); return; }
      const origin = targetSide === 'left' ? right : left;
      left.clearSelections(); right.clearSelections();
      origin.navigate(drop.source, drop.selection);
      setDirection(targetSide === 'left' ? 'rl' : 'lr');
      setMode('copy'); setLoadedTask(null); setOptions(old => ({...old, deleteExcluded: false}));
      showNotice(t('finderDropReady')); setModal('options');
    });
  }, [bridgeAvailable, modal, fileDialog, toolTarget, ready, pendingSettings, left, right, busy, fileBusy, t, showError, showNotice]);

  useHistoryNavigation((direction, x, y) => {
    if (page !== 'files' || modal || fileDialog || toolTarget || fileBusy || document.querySelector('dialog[open]')) return;
    const underPointer = typeof x === 'number' && typeof y === 'number' ? document.elementFromPoint(x, y)?.closest<HTMLElement>('[data-pane-side]')?.dataset.paneSide : undefined;
    const side = underPointer === 'left' || underPointer === 'right' ? underPointer : activePane;
    const pane = side === 'left' ? left : right;
    if (pane.endpoint.remote && !ready) return;
    setActivePane(side); if (direction === 'back') pane.back(); else pane.forward();
  });
  const applyPreset = (id: BuiltinPresetID) => { setOptions(presetOptions(id)); setMode('sync'); setActivePreset(id); setLoadedTask(null); showNotice(`${t('presetApplied')} ${t(presetLabel(id))}`); };
  const hidePreset = (id: BuiltinPresetID) => { if (activePreset === id) setActivePreset(null); void saveSettings({hiddenBuiltinPresets: [...new Set([...(settingsRef.current.hiddenBuiltinPresets || []), id])]}).catch(reason => showError(errorMessage(reason))); };
  const restorePresets = async () => { await saveSettings({hiddenBuiltinPresets: []}); };
  const currentRecommendation = recommendedPreset(source.endpoint, destination.endpoint, bootstrap?.remotes || [], bootstrap?.localLocations || []);

  const blocked = pendingSettings > 0 ? t('confirmingSettings') : !ready ? t('unavailable') : source.pathDirty || destination.pathDirty ? t('uncommittedPath') : (!source.endpoint.path && !source.endpoint.remote) || (!destination.endpoint.path && !destination.endpoint.remote) ? t('selectLocation') :
    endpointEqual(source.endpoint, destination.endpoint) ? t('sameEndpoint') : source.missingSelection ? t('missingSelection') :
    mode === 'move' && options.updateOnly ? t('moveNewerHint') : mode === 'sync' && source.selection.some(item => !item.isDir) ? t('syncSelection') : mode === 'sync' && source.selection.length > 0 && options.deleteExcluded ? t('syncSelectionDeleteExcluded') : source.error || destination.error ? t('cannotBrowse') : '';
  const transferDisabled = Boolean(blocked) || busy || source.loading || destination.loading;
  const run = async (dryRun: boolean) => {
    if (transferDisabled) return;
    setBusy(true); setError(''); setNotice('');
    try {
      const job = await window.rclone.startTransfer(request(dryRun));
      if (job) { upsertJob(job); setJobsExpanded(true); }
    } catch (reason) { showError(errorMessage(reason)); } finally { setBusy(false); }
  };
  const openPreview = async () => {
    if (source.pathDirty || destination.pathDirty) { showError(t('uncommittedPath')); return; }
    setModalError(''); setPreview(null); setModal('preview');
    try { setPreview(await window.rclone.previewTransfer(request())); } catch (reason) { setModalError(errorMessage(reason)); }
  };
  const openSaveTask = (asNew = false) => {
    if (source.pathDirty || destination.pathDirty) { showError(t('uncommittedPath')); return; }
    setEditingTask({name: (!asNew && loadedTask?.name) || `${endpointName(source.endpoint)} → ${endpointName(destination.endpoint)}`, id: asNew ? undefined : loadedTask?.id, request: request()});
    setModal('saveTask');
  };
  const editTask = (task: SavedTask) => { setEditingTask(structuredClone(task)); setModal('saveTask'); };
  const saveTask = async (name: string, next: TransferRequest, id?: string) => {
    const result = await window.rclone.saveTask(name, next, id);
    setTasks(await window.rclone.listTasks()); setModal(null); setEditingTask(null);
    if (page === 'files') {
      const reverse = next.direction === 'rl';
      left.clearSelections(); right.clearSelections();
      left.navigate(reverse ? next.destination : next.source, reverse ? [] : next.selection);
      right.navigate(reverse ? next.source : next.destination, reverse ? next.selection : []);
      setDirection(next.direction || 'lr'); setMode(next.mode); setOptions(structuredClone(next.options)); setLoadedTask(result);
    } else if (loadedTask?.id === result.id) setLoadedTask(null);
    showNotice(t('taskSaved'));
  };
  const runTask = async (task: SavedTask, dryRun: boolean) => {
    await saveQueue.current;
    const job = await window.rclone.startTransfer({...structuredClone(task.request), dryRun, label: task.name});
    if (job) { upsertJob(job); setJobsExpanded(true); setPage('jobs'); }
  };
  const rememberWorkspace = async () => {
    if (left.pathDirty || right.pathDirty) { showError(t('uncommittedPath')); return; }
    await saveSettings({savedWorkspace: {left: {...left.endpoint}, right: {...right.endpoint}, direction, mode, options: structuredClone(options)}});
    showNotice(t('workspaceRemembered'));
  };
  const fileAction = async (side: 'left'|'right', kind: FileAction) => {
    const browser = side === 'left' ? left : right;
    if (browser.loading || browser.error || fileBusy) return;
    const selection = (direction === 'lr' ? side === 'left' : side === 'right') ? browser.selection : browser.focusedEntry ? [browser.focusedEntry] : [];
    if (browser.pathDirty) { showError(t('uncommittedPath')); return; }
    if ((kind === 'rename' && selection.length !== 1) || (kind === 'remove' && selection.length === 0)) return;
    if (kind === 'remove') {
      setFileBusy(true);
      try { const removed = await window.rclone.remove(browser.endpoint, selection); if (removed) { browser.setSelection([]); browser.setFocusedEntry(null); browser.reload(); showNotice(t('removed')); } } catch (reason) { showError(errorMessage(reason)); } finally { setFileBusy(false); }
      return;
    }
    setFileError(''); setSizeResult(null); setFileName(kind === 'rename' ? selection[0]?.name || '' : '');
    setFileDialog({kind, side, endpoint: {...browser.endpoint}, ...(kind === 'rename' ? {oldName: selection[0]?.name, isDir: selection[0]?.isDir} : {})});
    if (kind === 'size') {
      const id = ++sizeGeneration.current; setFileBusy(true);
      try { const size = await window.rclone.size(browser.endpoint); if (sizeGeneration.current === id) setSizeResult(size); } catch (reason) { if (sizeGeneration.current === id) setFileError(errorMessage(reason)); } finally { if (sizeGeneration.current === id) setFileBusy(false); }
    }
  };
  const submitFile = async () => {
    if (!fileDialog || fileDialog.kind === 'size') return;
    if (!validName(fileName)) { setFileError(t('fileNameHint')); return; }
    setFileBusy(true); setFileError('');
    try {
      if (fileDialog.kind === 'newFolder') await window.rclone.mkdir(fileDialog.endpoint, fileName);
      else await window.rclone.rename(fileDialog.endpoint, fileDialog.oldName!, fileName, Boolean(fileDialog.isDir));
      const browser = fileDialog.side === 'left' ? left : right;
      browser.setSelection([]); browser.setFocusedEntry(null); browser.reload(); setFileDialog(null); showNotice(t(fileDialog.kind === 'newFolder' ? 'folderCreated' : 'renamed'));
    } catch (reason) { setFileError(errorMessage(reason)); } finally { setFileBusy(false); }
  };
  const changeDirection = (next: 'lr'|'rl') => {
    if (next === direction) return;
    left.clearSelections(); right.clearSelections(); setDirection(next); setLoadedTask(null);
  };
  const swap = () => {
    const a = {...left.endpoint};
    left.clearSelections(); right.clearSelections();
    left.navigate(right.endpoint); right.navigate(a); setLoadedTask(null);
  };
  const upsertToolSession = useCallback((session: ToolSession) => setToolSessions(old => { const existing = old.find(item => item.id === session.id); if (existing && existing.status !== 'running' && session.status === 'running') return old; return existing ? old.map(item => item.id === session.id ? session : item) : [session, ...old]; }), []);
  useEffect(() => {
    if (!bridgeAvailable) return;
    const unsubscribe = window.rclone.onToolSessionUpdate(upsertToolSession);
    let live = true;
    void window.rclone.listToolSessions().then(incoming => { if (live) setToolSessions(old => [...old, ...incoming.filter(item => !old.some(existing => existing.id === item.id))]); }).catch(reason => { if (live) showError(errorMessage(reason)); });
    return () => { live = false; unsubscribe(); };
  }, [bridgeAvailable, upsertToolSession, showError]);
  const toolAction = async (side: 'left'|'right', action: ToolAction) => {
    const browser = side === 'left' ? left : right;
    if (browser.loading || browser.error || fileBusy) return;
    if (browser.pathDirty) { showError(t('uncommittedPath')); return; }
    const endpoint = {...browser.endpoint};
    const selection = (direction === 'lr' ? side === 'left' : side === 'right') ? browser.selection : browser.focusedEntry ? [browser.focusedEntry] : [];
    const item = selection[0] ? {...selection[0]} : undefined;
    try {
      await saveQueue.current;
      if (action === 'exportCSV' || action === 'exportTXT') {
        const path = await window.rclone.exportFileList(endpoint, action === 'exportCSV' ? 'csv' : 'txt');
        if (path) showNotice(`${t('exportSuccess')} ${path}`);
      } else if (action === 'stream') {
        if (!item || item.isDir) return;
        const session = await window.rclone.startStream(endpoint, item.name);
        if (session) { upsertToolSession(session); setPage('jobs'); }
      } else setToolTarget({action, endpoint, item});
    } catch(reason) { showError(errorMessage(reason)); }
  };
  const external = async (url: string) => { try { await window.rclone.openExternal(url); } catch (reason) { showError(errorMessage(reason)); } };

  if (!bridgeAvailable) return <main className="startup"><img className="app-mark large" src={startupIcon(settings.theme)} alt=""/><h1>Rclone Browser Next</h1><EmptyState icon={<TerminalWindow size={36}/>} title={t('desktopRequired')}>{t('desktopRequiredHint')}</EmptyState></main>;
  if (!bootstrap) return <main className="startup"><img className="app-mark large" src={startupIcon(settings.theme)} alt=""/><h1>Rclone Browser Next</h1>{startupError ? <EmptyState kind="error" icon={<WarningCircle size={32}/>} title={t('startupError')} action={<button type="button" onClick={() => { setStartupError(''); void loadBootstrap(true); }}>{t('reload')}</button>}>{startupError}</EmptyState> : <p className="loading-status" role="status">{t('loadingApp')}</p>}</main>;

  return <div className={`app-shell platform-${bootstrap.environment.platform}`}>
    <header className="app-toolbar">
      <ApplicationMenu platform={bootstrap.environment.platform} t={t} language={settings.language} theme={settings.theme} onSettings={() => setModal('settings')} onHelp={() => setModal('help')} onConfigure={() => void configureAccounts().catch(reason => showError(errorMessage(reason)))} onLanguage={language => void saveSettings({language}).catch(reason => showError(errorMessage(reason)))} onAbout={showAbout} onEngineUpdate={() => void checkEngineUpdates()} onAppUpdate={() => void checkAppUpdates()}/>
      <nav className="main-nav" aria-label={t('mainNavigation')}>{([{key: 'files', icon: <FolderOpen size={17}/>}, {key: 'jobs', icon: <ListBullets size={18}/>}, {key: 'tasks', icon: <BookBookmark size={17}/>} ] as const).map(item => <button type="button" key={item.key} className={page === item.key ? 'active' : ''} aria-current={page === item.key ? 'page' : undefined} onClick={() => setPage(item.key)}>{item.icon}{t(item.key)}{item.key === 'jobs' && activeJobs > 0 && <span className="count-badge">{activeJobs}</span>}</button>)}</nav>
      <div className="app-toolbar-actions"/>
    </header>
    {!ready && <div className="engine-banner"><WarningCircle size={20}/><div><strong>{t('unavailable')}</strong><span>{t('unavailableHint')}</span></div><button type="button" onClick={() => setModal('settings')}>{t('openSettings')}</button></div>}
    <FloatingNotice message={error || notice} kind={error ? 'error' : 'success'} serial={noticeSerial} onClose={() => { setError(''); setNotice(''); }}/>
    <main className={`app-main page-${page}`}>
      {page === 'files' && <div className="workspace"><div className="workspace-heading">
        <div className="workspace-title"><IconButton title={t('settings')} onClick={() => setModal('settings')}><GearSix size={19}/></IconButton><button type="button" className="account-setup-button" onClick={() => void configureAccounts().catch(reason => showError(errorMessage(reason)))} disabled={!ready || pendingSettings > 0}><TerminalWindow size={16}/>{t('configLabel')}</button></div>
        {loadedTask && <div className="loaded-task"><BookBookmark size={14}/><span>{t('loadedTask')}：{loadedTask.name}</span><IconButton title={t('close')} onClick={() => setLoadedTask(null)}><X size={13}/></IconButton></div>}
        <div className="workspace-save-actions" role="group" aria-label={t('workspaceTaskDifference')}>
          <button type="button" disabled={pendingSettings > 0 || left.pathDirty || right.pathDirty || left.loading || right.loading || Boolean(left.error || right.error)} onClick={() => void rememberWorkspace().catch(reason => showError(errorMessage(reason)))}><FloppyDisk size={16}/>{t('rememberWorkspace')}</button>
          <span className="workspace-save-divider" aria-hidden="true"/>
          <button type="button" onClick={() => openSaveTask()} disabled={source.missingSelection}><FloppyDisk size={16}/>{t('saveTask')}</button>
          <InfoTooltip label={t('workspaceTaskDifference')} text={t('workspaceTaskDifferenceHint')}/>
        </div>
      </div>
        <div className="browser-grid"><BrowserPane side="left" browser={left} remotes={bootstrap.remotes} locations={bootstrap.localLocations || []} home={bootstrap.home} platform={bootstrap.environment.platform} t={t} language={language} active={activePane === 'left'} isSource={direction === 'lr'} disabled={fileBusy} remoteAvailable={ready} onToolAction={action => void toolAction('left', action)} preferences={settings} columnWidths={settings.paneColumnWidths.left} onColumnWidths={widths => void saveSettings({paneColumnWidths: {left: widths}}).catch(reason => showError(errorMessage(reason)))} onActivate={() => setActivePane('left')} onFileAction={kind => void fileAction('left', kind)} onError={showError}/>
          <aside className="transfer-controls" aria-label={t('options')}><div className="transfer-controls-top"><h2>{t('direction')}</h2><div className="direction-picker"><button type="button" aria-label={t('leftToRight')} className={direction === 'lr' ? 'selected' : ''} aria-pressed={direction === 'lr'} onClick={() => changeDirection('lr')}><span>{t('left')}</span><ArrowRight size={19}/><span>{t('right')}</span></button><button type="button" aria-label={t('rightToLeft')} className={direction === 'rl' ? 'selected' : ''} aria-pressed={direction === 'rl'} onClick={() => changeDirection('rl')}><span>{t('left')}</span><ArrowLeft size={19}/><span>{t('right')}</span></button></div><div className="field"><div className="field-label-row"><span className="field-label">{t('operation')}</span><InfoTooltip label={t('operation')} text={t(mode === 'sync' ? 'syncDetail' : mode === 'move' ? 'moveDetail' : 'copyDetail')}/></div><OperationPicker mode={mode} preset={activePreset} hidden={settings.hiddenBuiltinPresets || []} t={t} onPreset={applyPreset} onHide={hidePreset} onMode={next => { if (next === 'move' && options.updateOnly) showNotice(t('moveNewerHint')); setActivePreset(null); setMode(next); setOptions(old => ({...old, ...(next === 'sync' ? {noTraverse: false} : {deleteExcluded: false}), ...(next === 'move' ? {updateOnly: false} : {})})); }}/></div><p className="operation-hint">{t(mode === 'copy' ? 'copyHint' : mode === 'sync' ? 'syncHint' : 'moveHint')}</p>{activePreset && <p className="preset-active-summary">{t(presetSummary(activePreset))}</p>}</div>
            <div className="transfer-route"><div><span>{t('source')}</span><strong title={endpointText(source.endpoint)}>{source.endpoint.remote ? <Cloud size={13}/> : <HardDrives size={13}/>}<span>{endpointName(source.endpoint)}</span></strong></div><ArrowDownIndicator/><div><span>{t('destination')}</span><strong title={endpointText(destination.endpoint)}>{destination.endpoint.remote ? <Cloud size={13}/> : <HardDrives size={13}/>}<span>{endpointName(destination.endpoint)}</span></strong></div><div className="scope-summary"><span>{source.selection.length > 0 ? `${t('selected')} ${source.selection.length} ${t('items')}` : t('wholeFolder')}</span>{source.selection.length > 0 && <InfoTooltip label={t('selectionScope')} text={t('selectedTransferHint')}/>}</div><button type="button" className="text-button swap-button" onClick={swap} disabled={left.loading || right.loading}><ArrowsLeftRight size={13}/>{t('swap')}</button></div>
            <div className="transfer-controls-bottom"><button type="button" className="options-button" onClick={() => setModal('options')}><SlidersHorizontal size={17}/>{t('options')}</button>{bandwidthLimit && <p className="bandwidth-summary"><span>{t('bandwidth')}</span><strong>{bandwidthLimit}</strong></p>}{blocked && ready && <p className="transfer-block" role="status">{blocked}{mode === 'sync' && source.selection.length > 0 && <button type="button" className="text-button" onClick={() => source.setSelection([])}>{t('clearSelection')}</button>}</p>}<button type="button" className="dry-run-button" title={t('dryRunHint')} disabled={transferDisabled} onClick={() => run(true)}><Eye size={16}/>{t('dryRun')}</button><button type="button" className={`primary start-button ${mode !== 'copy' ? 'caution-primary' : ''}`} disabled={transferDisabled} onClick={() => run(false)}><Play size={15} weight="fill"/>{busy ? t('starting') : t(mode === 'copy' ? 'startCopy' : mode === 'sync' ? 'startSync' : 'startMove')}</button><button type="button" className="text-button command-button" disabled={!ready || busy} onClick={openPreview}><TerminalWindow size={12}/>{t('commandPreview')}</button></div>
          </aside>
          <BrowserPane side="right" browser={right} remotes={bootstrap.remotes} locations={bootstrap.localLocations || []} home={bootstrap.home} platform={bootstrap.environment.platform} t={t} language={language} active={activePane === 'right'} isSource={direction === 'rl'} disabled={fileBusy} remoteAvailable={ready} onToolAction={action => void toolAction('right', action)} preferences={settings} columnWidths={settings.paneColumnWidths.right} onColumnWidths={widths => void saveSettings({paneColumnWidths: {right: widths}}).catch(reason => showError(errorMessage(reason)))} onActivate={() => setActivePane('right')} onFileAction={kind => void fileAction('right', kind)} onError={showError}/>
        </div>
        <Jobs jobs={jobs} t={t} language={language} compact expanded={jobsExpanded} onExpanded={setJobsExpanded} onViewAll={() => setPage('jobs')} onJobsCleared={removeClearedJobs} onError={showError} onNotice={showNotice} onRetry={upsertJob}/>
      </div>}
      {page === 'jobs' && <div className="jobs-page-layout"><Jobs jobs={jobs} t={t} language={language} onJobsCleared={removeClearedJobs} onError={showError} onNotice={showNotice} onRetry={upsertJob}/><ToolSessions sessions={toolSessions} t={t} language={language} onError={showError}/></div>}
      {page === 'tasks' && <Tasks tasks={tasks} t={t} language={language} available={ready && pendingSettings === 0} onEdit={editTask} onRun={runTask} onTasksChange={setTasks} onSaveCurrent={() => openSaveTask(true)} onError={showError} onNotice={showNotice}/>}
    </main>
    <footer className="app-statusbar"><div><span className={`status-dot ${ready ? 'ready' : ''}`}/><span>{ready ? `rclone ${bootstrap.environment.version.replace(/^rclone\s+/i, '')}` : t('notReady')}</span></div><span className="statusbar-center" role={updateStatus?.message ? 'status' : undefined}>{updateStatus?.message || `${bootstrap.remotes.length} ${t('remoteCount')}`}</span><span className="statusbar-version">0.9.0</span></footer>

    {toolTarget && <ToolDialog target={toolTarget} t={t} onClose={() => setToolTarget(null)} onSession={session => { upsertToolSession(session); setPage('jobs'); }}/> }
    {modal === 'options' && <TransferOptionsDialog options={options} mode={mode} recommendation={currentRecommendation} hiddenPresets={settings.hiddenBuiltinPresets || []} onRestorePresets={restorePresets} defaults={settings.defaultTransferOptions} t={t} onClose={() => setModal(null)} onSave={(next, nextMode) => { setOptions(next); setMode(nextMode); setActivePreset(null); setError(''); setNotice(''); setModal(null); }} onSaveDefaults={async next => { await saveSettings({defaultTransferOptions: next}); }}/>}
    {modal === 'settings' && <SettingsDialog settings={settings} environment={bootstrap.environment} locations={bootstrap.localLocations || []} remotes={bootstrap.remotes} home={bootstrap.home} pending={pendingSettings > 0} currentLocations={{left: left.endpoint, right: right.endpoint}} currentLocationsValid={!left.pathDirty && !right.pathDirty && !left.error && !right.error} t={t} onSave={saveSettings} onFlush={flushSettings} onReload={() => loadBootstrap()} onConfigure={configureAccounts} onClose={() => setModal(null)}/>}
    {modal === 'saveTask' && editingTask && <TransferOptionsDialog options={editingTask.request.options} mode={editingTask.request.mode} hiddenPresets={settings.hiddenBuiltinPresets || []} onRestorePresets={restorePresets} defaults={settings.defaultTransferOptions} t={t} onClose={() => { setModal(null); setEditingTask(null); }} onSave={() => {}} onSaveDefaults={async next => { await saveSettings({defaultTransferOptions: next}); }} task={{...editingTask, locations: bootstrap.localLocations || [], remotes: bootstrap.remotes, home: bootstrap.home, onSave: saveTask}}/>}
    {modal === 'appUpdate' && <Dialog title={t('checkAppUpdates')} t={t} onClose={() => setModal(null)} className="small-dialog"><div className="dialog-body">{modalError ? <Notice kind="error">{modalError}</Notice> : appUpdate ? <><h3>{t(appUpdate.status === 'available' ? 'appUpdateAvailable' : appUpdate.status === 'current' ? 'appCurrent' : 'appUnpublished')}</h3><p>Rclone Next {appUpdate.current}{appUpdate.latest && appUpdate.latest !== appUpdate.current ? ` → ${appUpdate.latest}` : ''}</p>{appUpdate.status !== 'unpublished' && <p>{t('appUpdateHint')}</p>}</> : <p role="status">{t('checkingUpdates')}</p>}</div><footer className="dialog-footer"><span className="spacer"/><button type="button" onClick={() => setModal(null)}>{t('close')}</button>{appUpdate && appUpdate.status !== 'unpublished' && <button type="button" className="primary" onClick={() => void external(appUpdate.releaseURL)}>{t('openReleasePage')}<ArrowSquareOut size={14}/></button>}</footer></Dialog>}
    {modal === 'preview' && <Dialog title={t('previewTitle')} t={t} onClose={() => setModal(null)} className="preview-dialog"><div className="dialog-body"><p>{t('previewHint')}</p>{modalError && <Notice kind="error">{modalError}</Notice>}{preview ? <>{preview.warnings.map((warning, index) => <Notice kind="warning" key={index}>{warning}</Notice>)}<pre className="command-output" tabIndex={0}>{preview.command}</pre><button type="button" className="text-button" onClick={() => void window.rclone.copyText(preview.command).then(() => showNotice(t('copied'))).catch(reason => showError(errorMessage(reason)))}>{t('copyText')}</button></> : !modalError && <p role="status">{t('processing')}</p>}</div><footer className="dialog-footer"><span className="spacer"/><button type="button" onClick={() => setModal(null)}>{t('close')}</button></footer></Dialog>}
    {modal === 'help' && <Dialog title={t('helpTitle')} t={t} onClose={() => setModal(null)} className="help-dialog"><div className="dialog-body"><ol className="help-steps"><li>{t('helpStep1')}</li><li>{t('helpStep2')}</li><li>{t('helpStep3')}</li></ol><Notice>{t('helpSelection')}</Notice><h3>{t('shortcuts')}</h3><dl className="shortcut-list">{[['⌘ / Ctrl + L','shortcutPath'],['⌘ / Ctrl + R','shortcutRefresh'],['⌘ / Ctrl + A','shortcutAll'],['⌘ / Ctrl + ↑','shortcutUp'],['⌘ / Ctrl + [','back'],['⌘ / Ctrl + ]','forward'],['Enter','shortcutOpen'],['Space','shortcutSelect']].map(([key,label]) => <div key={key}><dt><kbd>{key}</kbd></dt><dd>{t(label as 'shortcutPath')}</dd></div>)}</dl><button type="button" className="text-button" onClick={() => external('https://rclone.org/docs/')}>{t('docs')}<ArrowSquareOut size={14}/></button></div><footer className="dialog-footer"><span className="spacer"/><button type="button" onClick={() => setModal(null)}>{t('close')}</button></footer></Dialog>}
    {fileDialog && <Dialog title={t(fileDialog.kind === 'size' ? 'totalSize' : fileDialog.kind)} t={t} onClose={() => { setFileDialog(null); ++sizeGeneration.current; setFileBusy(false); }} className="small-dialog"><form onSubmit={event => { event.preventDefault(); void submitFile(); }}><div className="dialog-body">{fileError && <Notice kind="error">{fileError}</Notice>}<p className="file-dialog-location">{endpointText(fileDialog.endpoint)}</p>{fileDialog.kind === 'size' ? sizeResult ? <div className="size-result"><ChartBar size={30}/><strong>{formatBytes(sizeResult.bytes)}</strong><span>{sizeResult.count.toLocaleString()} {t('totalFiles')}</span></div> : <p role="status">{t('processing')} {t('sizeHint')}</p> : <Field label={t('name')} hint={t('fileNameHint')}><input autoFocus required value={fileName} onChange={event => setFileName(event.target.value)}/></Field>}</div><footer className="dialog-footer"><span className="spacer"/><button type="button" onClick={() => { setFileDialog(null); ++sizeGeneration.current; setFileBusy(false); }}>{t(fileDialog.kind === 'size' ? 'close' : 'cancel')}</button>{fileDialog.kind !== 'size' && <button type="submit" className="primary" disabled={fileBusy || !fileName.trim()}>{fileBusy ? t('processing') : t(fileDialog.kind === 'newFolder' ? 'create' : 'rename')}</button>}</footer></form></Dialog>}
  </div>;
}

function ArrowDownIndicator() { return <span className="route-down" aria-hidden="true"><ArrowRight size={14}/></span>; }
