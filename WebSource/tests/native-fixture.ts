import type { Page } from '@playwright/test';
import type { Bootstrap, Job, Settings } from '../shared/types.ts';
import { DEFAULT_OPTIONS } from '../shared/types.ts';

export const unusualName = '<img src=x onerror="window.__unsafe=1"> & "照片".txt';
export const chosenFolder = '/Users/test/Rclone Engine & Scripts';
export const chosenExecutable = '/Users/test/Tools/rclone';

export async function installHostFixture(page: Page, options: {
  available?: boolean; settings?: Partial<Settings>; job?: boolean; cleanPreview?: boolean; fileCount?: number; preferredLanguage?: string; appStatus?: 'current'|'available'|'unpublished'; manualStatus?: 'skipped' | 'updated' | 'current';
} = {}) {
  const available = options.available ?? true;
  const request = {
    source: { remote: null, path: '/Users/test/Documents' },
    destination: { remote: 'research-drive', path: 'Archive' },
    mode: 'copy' as const, options: DEFAULT_OPTIONS, selection: [], dryRun: false,
  };
  const job: Job = {
    id: 'fixture-job', request, status: 'running', createdAt: '2026-10-19T09:00:00Z', startedAt: '2026-10-19T09:00:01Z',
    command: 'rclone copy /Users/test/Documents research-drive:Archive --use-json-log',
    stats: {
      bytes: 268435456, totalBytes: 1073741824, speed: 16777216, eta: 48, transfers: 4, totalTransfers: 16,
      checks: 12, totalChecks: 24, errors: 0, deletes: 0, elapsedTime: 16,
      transferring: [{ name: '研究資料.zip', size: 268435456, bytes: 134217728, percentage: 50, speed: 16777216, speedAvg: 16777216, eta: 8 }],
    },
    logs: [{ time: '2026-10-19T09:00:17Z', level: 'info', message: 'Copied (new)', object: '研究資料.zip' }],
  };
  const bootstrap: Bootstrap = {
    environment: { version: available ? 'v1.75.2' : '', rclonePath: available ? '/Users/test/Engine/rclone' : '', configPath: '/Users/test/.config/rclone/rclone.conf', platform: 'darwin', arch: 'arm64', available },
    settings: { rcloneDirectory: '/Users/test/Engine', rclonePath: '', configPath: '', language: 'zh-TW', theme: 'purple-light', autoCheckUpdates: true, skippedRcloneVersion: '', settingsRevision: 0, settingsSchemaVersion: 5, hiddenBuiltinPresets: [], savedWorkspace: null, networkOptions: {bindMode: 'auto', bindAddress: '', connectTimeout: '1m', ioTimeout: '5m', tpsLimit: 0, tpsBurst: 1, userAgent: '', disableHTTP2: false}, paneColumnWidths: {}, defaultTransferOptions: DEFAULT_OPTIONS, maxConcurrentJobs: 0, proxyMode: 'system', httpProxy: '', httpsProxy: '', noProxy: '', defaultRcloneOptions: [], initialLocations: {}, streamPlayerPath: '', streamPlayerArguments: ['-'], showStatusItem: false, notifyOnCompletion: false, showHiddenFiles: true, showFolderIcons: true, showFileIcons: true, alternatingRows: true, ...options.settings },
    resolvedLanguage: options.settings?.language === 'system' ? (options.preferredLanguage?.startsWith('ja') ? 'ja' : options.preferredLanguage?.startsWith('zh') ? 'zh-TW' : 'en') : options.settings?.language || 'zh-TW',
    home: '/Users/test', localLocations: [{id: 'home', name: 'test', path: '/Users/test', kind: 'home', group: 'local'}, ...(['desktop','documents','downloads','pictures','music','movies'] as const).map(kind => ({id: kind, name: kind, path: `/Users/test/${kind[0].toUpperCase()}${kind.slice(1)}`, kind, group: 'local' as const})), {id: 'volumes', name: 'Volumes', path: '/Volumes', kind: 'volumes', group: 'local'}, {id: 'test-nas-volume', name: 'Media Backup', path: '/Volumes/Media Backup', kind: 'volume', group: 'network'}], remotes: [{ name: 'research-drive', type: 'drive', group: 'cloud' }, { name: 'lab-nas', type: 'sftp', group: 'network' }, { name: 'web-storage', type: 'webdav', group: 'other' }],
    jobs: options.job ? [job] : [], tasks: [],
  };
  await page.addInitScript(({ bootstrap, job, unusualName, chosenFolder, chosenExecutable, manualStatus, cleanPreview, fileCount, preferredLanguage, appStatus }) => {
    const win = window as any;
    const state = {
      bootstrap, job, preferredLanguage, appStatus, started: 0, calls: [] as {id: string; method: string; args: any[]}[],
      chosenFolder, chosenExecutable, manualStatus, listingError: '', delays: {} as Record<string, number[]>, rejectSave: false, manualErrorOnce: false, toolSessions: [] as any[],
    };
    win.__fixture = state;
    const files = [
      { name: '.hidden.txt', path: '.hidden.txt', size: 12, modified: '2025-01-01T01:00:00Z', isDir: false },
      { name: 'Documents', path: 'Documents', size: -1, modified: '2026-10-18T14:00:00Z', isDir: true },
      { name: '照片與影片', path: '照片與影片', size: -1, modified: '2026-10-17T08:30:00Z', isDir: true },
      { name: unusualName, path: unusualName, size: 2048, modified: '2026-10-18T12:00:00Z', isDir: false },
      ...Array.from({length: fileCount}, (_, index) => ({ name: `研究紀錄 ${String(index + 1).padStart(2, '0')}.pdf`, path: `研究紀錄 ${index + 1}.pdf`, size: (index + 1) * 1048576, modified: '2026-10-18T11:42:00Z', isDir: false })),
    ].filter(entry => !cleanPreview || (entry.name !== unusualName && !entry.name.startsWith('.')));
    const handle = (method: string, args: any[]) => {
      switch (method) {
        case 'bootstrap': return state.bootstrap;
        case 'list':
          if (state.listingError) throw new Error(state.listingError);
          if (args[0].path === '/missing-folder') throw new Error('Directory does not exist: /missing-folder');
          if (args[0].remote && !state.bootstrap.environment.available) throw new Error('Remote browsing requires rclone.');
          return files;
        case 'chooseFolder': return state.chosenFolder;
        case 'chooseFile': return args[0] === 'rclone' ? state.chosenExecutable : args[0] === 'player' ? '/Applications/VLC.app' : '/Users/test/config & backup.conf';
        case 'saveSettings': {
          const patch = structuredClone(args[0]);
          if (state.rejectSave) { state.rejectSave = false; throw new Error('Settings rejected for test'); }
          const old = state.bootstrap.settings;
          state.bootstrap.settings = {...old, ...patch, paneColumnWidths: {...old.paneColumnWidths, ...patch.paneColumnWidths}, defaultTransferOptions: {...old.defaultTransferOptions, ...patch.defaultTransferOptions}, networkOptions: {...old.networkOptions, ...patch.networkOptions}, settingsRevision: (old.settingsRevision || 0) + 1};
          if ('rcloneDirectory' in patch && !patch.rclonePath) state.bootstrap.settings.rclonePath = `${patch.rcloneDirectory}/rclone`;
          if ('rclonePath' in patch || 'rcloneDirectory' in patch) {
            state.bootstrap.environment.available = true;
            state.bootstrap.environment.version = 'v1.75.2';
            state.bootstrap.environment.rclonePath = state.bootstrap.settings.rclonePath;
          }
          if ('language' in patch) { const preferred = state.preferredLanguage.toLowerCase().split(/[-_]/)[0]; state.bootstrap.resolvedLanguage = patch.language === 'system' ? preferred === 'zh' ? 'zh-TW' : preferred === 'ja' ? 'ja' : 'en' : patch.language; }
          state.bootstrap.environment.settingsRevision = state.bootstrap.settings.settingsRevision;
          return state.bootstrap.environment;
        }
        case 'checkForUpdates': {
          win.__rbnEvent?.({type: 'updateStatus', data: {phase: 'checking', message: '正在檢查 rclone 更新…'}});
          if (!args[0]) return { status: 'current', currentVersion: '1.75.2', latestVersion: '1.75.2' };
          if (state.manualErrorOnce) { state.manualErrorOnce = false; throw new Error('Update server temporarily unavailable'); }
          if (state.manualStatus === 'skipped') state.bootstrap.settings.skippedRcloneVersion = '1.76.0';
          if (state.manualStatus === 'updated') {
            state.bootstrap.environment.available = true;
            state.bootstrap.environment.version = 'v1.76.0';
            state.bootstrap.environment.rclonePath = state.bootstrap.settings.rclonePath || `${state.bootstrap.settings.rcloneDirectory}/rclone`;
          }
          state.bootstrap.settings.settingsRevision += 1; state.bootstrap.environment.settingsRevision = state.bootstrap.settings.settingsRevision;
          return {status: state.manualStatus, currentVersion: '1.75.2', latestVersion: '1.76.0', path: state.bootstrap.environment.rclonePath};
        }
        case 'checkAppUpdates': return {status: state.appStatus, current: '0.5.0', latest: state.appStatus === 'available' ? '0.6.0' : undefined, releaseURL: 'https://github.com/jason840709/RcloneBrowserNext/releases/latest'};
        case 'showAbout': return null;
        case 'listToolSessions': return state.toolSessions;
        case 'directoryTree': return {text: `${args[0].remote || '/Users/test'}\n├── Documents\n└── 照片與影片`, truncated: false};
        case 'exportFileList': return `/Users/test/files.${args[1] || 'csv'}`;
        case 'publicLink': return 'https://example.invalid/public-share';
        case 'copyText': return null;
        case 'startMount': case 'startStream': {
          const session = {id: method === 'startMount' ? 'fixture-mount' : 'fixture-stream', kind: method === 'startMount' ? 'mount' : 'stream', title: method === 'startMount' ? 'research-drive:' : args[1], status: 'running', createdAt: '2026-10-20T00:00:00Z', destination: method === 'startMount' ? '/Users/test/Mount' : '/Applications/VLC.app'};
          state.toolSessions.push(session); return session;
        }
        case 'stopToolSession': {
          const session = state.toolSessions.find(item => item.id === args[0]);
          if (session) {session.status = 'stopped'; win.__rbnEvent?.({type: 'toolSessionUpdate', data: structuredClone(session)});}
          return null;
        }
        case 'listJobs': return state.bootstrap.jobs;
        case 'listTasks': return state.bootstrap.tasks;
        case 'previewTransfer': return {command: 'rclone copy source destination --use-json-log', warnings: []};
        case 'startTransfer': {
          const next = {...state.job, id: `fixture-start-${++state.started}`, request: structuredClone(args[0])}; state.bootstrap.jobs = [next]; return next;
        }
        case 'retryJob': return state.job;
        case 'size': if (args[0].path === '/error') throw new Error('Native error <&>'); else return {count: 26, bytes: 1073741824};
        case 'remove': return true;
        case 'saveTask': {
          const task = {id: args[2] || 'fixture-task', name: args[0], request: args[1], createdAt: '2026-10-19T09:00:00Z', updatedAt: '2026-10-19T09:00:00Z'};
          state.bootstrap.tasks = [task]; return task;
        }
        case 'clearFinishedJobs': state.bootstrap.jobs = state.bootstrap.jobs.filter(item => ['queued', 'running', 'cancelling'].includes(item.status)); return null;
        case 'deleteTask': state.bootstrap.tasks = state.bootstrap.tasks.filter(item => item.id !== args[0]); return null;
        case 'exportLog': case 'exportTasks': return '/Users/test/Export.txt';
        case 'importTasks': return state.bootstrap.tasks;
        case 'mkdir': case 'rename': case 'cancelJob': case 'unlockConfig': case 'configureRemotes': case 'openExternal': return null;
        default: throw new Error(`Unknown native method: ${method}`);
      }
    };
    win.webkit = {messageHandlers: {rclone: {postMessage(message: {id: string; method: string; args: any[]}) {
      state.calls.push(structuredClone(message));
      const delay = state.delays[message.method]?.shift() ?? 2;
      const bootstrapSnapshot = message.method === 'bootstrap' ? structuredClone(state.bootstrap) : null;
      setTimeout(() => {
        try { win.__rbnReply?.({id: message.id, result: bootstrapSnapshot || structuredClone(handle(message.method, message.args))}); }
        catch (error) { win.__rbnReply?.({id: message.id, error: {message: error instanceof Error ? error.message : String(error)}}); }
      }, delay);
    }}}};
  }, { bootstrap, job, unusualName, chosenFolder, chosenExecutable, manualStatus: options.manualStatus ?? 'current', cleanPreview: options.cleanPreview ?? false, fileCount: options.fileCount ?? 24, preferredLanguage: options.preferredLanguage || 'zh-TW', appStatus: options.appStatus || 'unpublished' });
}
