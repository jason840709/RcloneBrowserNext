import type { AppAPI, Job, UpdateStatus, MenuAction, ToolSession, FinderDrop } from '../shared/types';

type Reply = { id: string; result?: unknown; error?: string | { message?: string } | null };
type HistoryNavigation = {direction: 'back'|'forward'; x: number; y: number; eventTime?: number; phase?: 'down'|'up'|'swipe'|'command'};
type NativeEvent = { type: 'jobUpdate'; data: Job } | { type: 'updateStatus'; data: UpdateStatus } | { type: 'configurationChanged'; data?: unknown } | {type: 'menuAction'; data: MenuAction} | {type: 'toolSessionUpdate'; data: ToolSession} | {type: 'finderDrop'; data: FinderDrop} | {type: 'navigateHistory'; data: HistoryNavigation};
type Pending = { resolve(value: unknown): void; reject(reason: Error): void; timer: ReturnType<typeof setTimeout> };

declare global {
  interface Window {
    rclone: AppAPI;
    __rbnNativeHistory?: boolean;
    webkit?: { messageHandlers?: { rclone?: { postMessage(message: { id: string; method: string; args: unknown[] }): void } } };
    __rbnReply?: (reply: Reply) => void;
    __rbnEvent?: (event: NativeEvent) => void;
  }
}

// The native host remains the sole authority for filesystem access and commands.
// No browser fallback provides file access or simulates an installed rclone.
export function installNativeBridge(): void {
  const handler = window.webkit?.messageHandlers?.rclone;
  if (!handler || window.rclone) return;
  const pending = new Map<string, Pending>();
  const jobs = new Set<(job: Job) => void>();
  const updates = new Set<(status: UpdateStatus) => void>();
  const configurationChanges = new Set<() => void>();
  const toolSessions = new Set<(session: ToolSession) => void>();
  const finderDrops = new Set<(drop: FinderDrop) => void>();
  const menuActions = new Set<(action: MenuAction) => void>();
  let sequence = 0;
  const limits: Record<string, number> = {
    bootstrap: 90_000, directoryTree: 180_000, exportFileList: 900_000, publicLink: 600_000, startMount: 600_000, startStream: 600_000, list: 120_000, size: 300_000,
    chooseFolder: 600_000, chooseFile: 600_000,
    startTransfer: 600_000, retryJob: 600_000, remove: 600_000, clearJobs: 180_000,
    exportLog: 600_000, exportTasks: 600_000, importTasks: 600_000, exportJobReport: 600_000,
    configureRemotes: 120_000, checkForUpdates: 300_000, checkAppUpdates: 120_000,
  };
  const call = <T>(method: string, ...input: unknown[]): Promise<T> => new Promise((resolve, reject) => {
    const id = `rbn-${Date.now().toString(36)}-${++sequence}`;
    const args = [...input];
    while (args.length && args[args.length - 1] === undefined) args.pop();
    const timer = setTimeout(() => {
      pending.delete(id);
      const language = document.documentElement.lang;
      reject(new Error(language === 'ja' ? 'アプリの応答がありません。処理が続いている可能性があります。再試行する前に状態を確認してください。' : language === 'en' ? 'The app did not respond in time. The operation may still be running; check its status before trying again.' : '程式回應逾時。操作可能仍在進行，請先查看狀態再重試。'));
    }, limits[method] ?? 90_000);
    pending.set(id, { resolve: value => resolve(value as T), reject, timer });
    try { handler.postMessage({ id, method, args }); }
    catch (error) {
      clearTimeout(timer); pending.delete(id);
      reject(error instanceof Error ? error : new Error(String(error)));
    }
  });
  window.__rbnReply = reply => {
    if (!reply || typeof reply.id !== 'string') return;
    const item = pending.get(reply.id);
    if (!item) return;
    clearTimeout(item.timer); pending.delete(reply.id);
    if (reply.error) item.reject(new Error(typeof reply.error === 'string' ? reply.error : reply.error.message || (document.documentElement.lang === 'ja' ? '操作が完了しませんでした' : document.documentElement.lang === 'en' ? 'Operation failed' : '操作未完成')));
    else item.resolve(reply.result);
  };
  window.__rbnEvent = event => {
    if (!event) return;
    if (event.type === 'configurationChanged') { for (const callback of configurationChanges) callback(); return; }
    if (!event.data) return;
    if (event.type === 'navigateHistory') window.dispatchEvent(new CustomEvent('rbn:navigate-history', {detail: event.data}));
    if (event.type === 'jobUpdate') for (const callback of jobs) callback(event.data);
    if (event.type === 'updateStatus') for (const callback of updates) callback(event.data);
    if (event.type === 'toolSessionUpdate') for (const callback of toolSessions) callback(event.data);
    if (event.type === 'finderDrop') for (const callback of finderDrops) callback(event.data);
    if (event.type === 'menuAction') for (const callback of menuActions) callback(event.data);
  };
  const api: AppAPI = {
    showAbout: () => call('showAbout'),
    onFinderDrop: callback => { finderDrops.add(callback); return () => { finderDrops.delete(callback); }; },
    copyText: text => call('copyText', text),
    directoryTree: (endpoint, maxDepth) => call('directoryTree', endpoint, maxDepth),
    exportFileList: (endpoint, format) => call('exportFileList', endpoint, format),
    publicLink: (endpoint, name, isDir) => call('publicLink', endpoint, name, isDir),
    startMount: (endpoint, options) => call('startMount', endpoint, options),
    startStream: (endpoint, name) => call('startStream', endpoint, name),
    listToolSessions: () => call('listToolSessions'), stopToolSession: id => call('stopToolSession', id),
    onToolSessionUpdate: callback => { toolSessions.add(callback); return () => { toolSessions.delete(callback); }; },
    bootstrap: () => call('bootstrap'), list: endpoint => call('list', endpoint),
    mkdir: (endpoint, name) => call('mkdir', endpoint, name),
    rename: (endpoint, name, newName, isDir) => call('rename', endpoint, name, newName, isDir),
    remove: (endpoint, selection) => call('remove', endpoint, selection),
    size: endpoint => call('size', endpoint), chooseFolder: current => call('chooseFolder', current),
    chooseFile: kind => call('chooseFile', kind), previewTransfer: request => call('previewTransfer', request),
    startTransfer: request => call('startTransfer', request), cancelJob: id => call('cancelJob', id),
    retryJob: id => call('retryJob', id), listJobs: () => call('listJobs'),
    clearFinishedJobs: () => call('clearFinishedJobs'),
    clearJobs: request => call('clearJobs', request),
    getJobReport: (id, options) => call('getJobReport', id, options),
    exportJobReport: (id, format = 'jsonl') => call('exportJobReport', id, format),
    saveTask: (name, request, id) => call('saveTask', name, request, id), deleteTask: id => call('deleteTask', id),
    listTasks: () => call('listTasks'), saveSettings: settings => call('saveSettings', settings),
    unlockConfig: password => call('unlockConfig', password), configureRemotes: () => call('configureRemotes'),
    openExternal: url => call('openExternal', url), exportLog: id => call('exportLog', id),
    exportTasks: () => call('exportTasks'), importTasks: () => call('importTasks'),
    checkForUpdates: manual => call('checkForUpdates', manual),
    checkAppUpdates: () => call('checkAppUpdates'),
    onJobUpdate: callback => { jobs.add(callback); return () => { jobs.delete(callback); }; },
    onUpdateStatus: callback => { updates.add(callback); return () => { updates.delete(callback); }; },
    onMenuAction: callback => { menuActions.add(callback); return () => { menuActions.delete(callback); }; },
    onConfigurationChanged: callback => { configurationChanges.add(callback); return () => { configurationChanges.delete(callback); }; },
  };
  window.rclone = Object.freeze(api);
}
