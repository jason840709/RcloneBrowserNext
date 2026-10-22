export type ResolvedLanguage = 'zh-TW' | 'en' | 'ja';
export type Language = ResolvedLanguage | 'system';
export type Theme = 'purple-dark' | 'purple-light' | 'blue-dark' | 'blue-light' | 'green-dark' | 'green-light';
export type InterfaceScale = 80 | 90 | 100 | 110 | 120 | 125 | 135;
export interface Endpoint { remote: string | null; path: string }
export interface RemoteInfo { name: string; type: string; group?: 'cloud' | 'network' | 'other' }
export interface LocalLocation { id: string; name: string; path: string; kind: 'home' | 'desktop' | 'documents' | 'downloads' | 'pictures' | 'music' | 'movies' | 'volumes' | 'volume'; group: 'local' | 'network'; isRemovable?: boolean }
export interface FileEntry { name: string; path: string; size: number; modified: string; isDir: boolean; isLink?: boolean }
export interface FinderDrop { source: Endpoint; selection: Selection[]; x: number; y: number }
export interface Selection { name: string; isDir: boolean }
export type BuiltinPresetID = 'local-nas' | 'nas-cloud' | 'local-cloud' | 'local-local' | 'cloud-cloud' | 'cloud-local';
export type TransferMode = 'copy' | 'sync' | 'move';
export interface TransferOptions {
  transfers: number; checkers: number; bandwidth: string; comparison: 'default' | 'checksum' | 'modtime' | 'size' | 'checksum-only' | 'none';
  skipExisting: boolean; updateOnly: boolean; createEmptyDirs: boolean; exclude: string[];
  include: string[]; retries: number; maxDelete: number; preserveMetadata: boolean;
  driveSharedWithMe: boolean;
  localHashPolicy: 'default' | 'none'; symlinkMode: 'skip' | 'preserve';
  deleteMode: 'before' | 'during' | 'after'; deleteExcluded: boolean;
  ignoreChecksum: boolean; modifyWindow: string; checkFirst: boolean; noTraverse: boolean;
  fastList: boolean; oneFileSystem: boolean; noUpdateModtime: boolean;
  minSize: string; maxSize: string; minAge: string; maxAge: string; maxDepth: number;
  connectTimeout: string; ioTimeout: string; lowLevelRetries: number; retrySleep: string;
  extraArgs: string[];
}
export interface TransferRequest {
  source: Endpoint; destination: Endpoint; mode: TransferMode; options: TransferOptions;
  selection: Selection[]; dryRun: boolean; label?: string; direction?: 'lr' | 'rl';
}
export interface TransferFile { name: string; size: number; bytes: number; percentage: number; speed: number; speedAvg: number; eta: number | null }
export interface TransferStats {
  bytes: number; totalBytes: number; speed: number; eta: number | null; transfers: number; totalTransfers: number;
  speedKind?: 'rolling' | 'overall'; speedWindowSeconds?: number; averageSpeed?: number; filesPerSecond?: number; etaSource?: 'bytes' | 'files' | null;
  checks: number; totalChecks: number; listed?: number; errors: number; deletes: number; elapsedTime: number; transferring: TransferFile[];
}
export type JobStatus = 'queued' | 'running' | 'cancelling' | 'completed' | 'failed' | 'cancelled' | 'interrupted';
export interface LogEntry { time: string; level: string; message: string; object?: string; size?: number }
export interface Job {
  id: string; request: TransferRequest; status: JobStatus; createdAt: string; startedAt?: string; endedAt?: string;
  stats: TransferStats; logs: LogEntry[]; error?: string; exitCode?: number | null; command: string;
  cancellation?: {requestedAt: string; lastSignal?: 'SIGINT' | 'SIGTERM' | 'SIGKILL'; forced: boolean; processExited: boolean};
  report?: JobReportSummary;
}
export type JobReportCategory = 'all'|'success'|'errors'|'skipped'|'comparison';
export interface JobReportSummary {
  available: boolean; formatVersion: number; eventCount: number; successEvents: number;
  copiedEvents: number; movedEvents: number; deletedEvents: number; errorEvents: number;
  unattributedErrors: number; plannedEvents: number; informationEvents: number;
  comparisonEvents: number; matchedEvents: number; skippedEvents?: number; candidateEvents: number;
  missingSourceEvents: number; comparisonErrorEvents: number; comparisonMalformed: number;
  comparisonPendingBytes: number; comparisonComplete: boolean; skippedFiles: null; failedFiles: null;
  copyByteTotalsAvailable?: boolean; copiedBytes?: number; failedCopyBytes?: number; sizeMismatchEvents?: number;
  growingSourceEvents?: number; retryFailures?: number; lastAttempt?: number; maxAttempts?: number;
  cleanupEvents?: number; cleanupFailureEvents?: number;
}
export interface JobReportItem {
  sequence: number; time: string; status: string; action: string; path?: string;
  message: string; size?: number; objectType?: string; evidence?: string; configuration?: Record<string, unknown>;
  issue?: 'size-mismatch'|'source-growing'|'source-changed'|'cleanup-failed'|'deletion-deferred'|'symlink-ignored'|'special-ignored';
  sourceSize?: number; destinationSize?: number; relatedPath?: string; attempt?: number; attemptLimit?: number;
}
export interface JobReportPage {available: boolean; items: JobReportItem[]; nextCursor: number|null; summary?: JobReportSummary}
export interface ClearJobsRequest {ids: string[]; mode: 'finished' | 'stop-and-clear'}
export interface ClearJobsResult {removedIds: string[]; retainedIds: string[]; stoppedIds: string[]; forcedStopIds: string[]}
export interface SavedTask { validationError?: string; id: string; name: string; request: TransferRequest; createdAt: string; updatedAt: string }
export interface PaneColumnWidths { name: number; size: number; modified: number }
export type MenuAction = {action: 'settings' | 'help' | 'configureRemotes' | 'about' | 'checkAppUpdates' | 'checkForUpdates'} | {action: 'language'; language: Language};
export interface SavedWorkspace { left: Endpoint; right: Endpoint; direction: 'lr' | 'rl'; mode: TransferMode; options: TransferOptions }
export interface NetworkOptions { bindMode: 'auto' | 'ipv4' | 'ipv6' | 'address'; bindAddress: string; connectTimeout: string; ioTimeout: string; tpsLimit: number; tpsBurst: number; userAgent: string; disableHTTP2: boolean }
export interface Settings {
  rcloneDirectory: string; rclonePath: string; configPath: string; language: Language; theme: Theme;
  interfaceScale: InterfaceScale;
  autoCheckUpdates: boolean; skippedRcloneVersion: string;
  streamPlayerPath: string; streamPlayerArguments: string[];
  showStatusItem: boolean; notifyOnCompletion: boolean; bounceDockOnCompletion?: boolean; showHiddenFiles: boolean; showFolderIcons: boolean; showFileIcons: boolean; alternatingRows: boolean;
  settingsRevision: number; settingsSchemaVersion: number;
  paneColumnWidths: {left?: PaneColumnWidths; right?: PaneColumnWidths};
  hiddenBuiltinPresets?: BuiltinPresetID[];
  defaultTransferOptions: TransferOptions; maxConcurrentJobs: number;
  proxyMode: 'system' | 'manual'; httpProxy: string; httpsProxy: string; noProxy: string;
  defaultRcloneOptions: string[]; initialLocations: {left?: Endpoint; right?: Endpoint};
  savedWorkspace: SavedWorkspace | null; networkOptions: NetworkOptions;
}
export type SettingsPatch = Omit<Partial<Settings>, 'networkOptions'> & {networkOptions?: Partial<NetworkOptions>};
export interface Environment { version: string; rclonePath: string; configPath: string; platform: string; arch: string; available: boolean; error?: string; settingsRevision?: number }
export interface UpdateResult {
  status: 'busy' | 'current' | 'skipped' | 'later' | 'updated' | 'unavailable' | 'error' | 'disabled' | 'notInstalled' | 'available';
  currentVersion?: string; latestVersion?: string; path?: string; message?: string;
}
export interface UpdateStatus { phase: string; message: string; status?: UpdateResult['status'] }
export interface Bootstrap { environment: Environment; settings: Settings; resolvedLanguage: ResolvedLanguage; remotes: RemoteInfo[]; localLocations: LocalLocation[]; home: string; jobs: Job[]; tasks: SavedTask[] }
export interface AppUpdateResult { status: 'current' | 'available' | 'unpublished'; current: string; latest?: string; releaseURL: string }
export interface CommandPreview { command: string; warnings: string[] }
export interface ToolSession { id: string; kind: 'mount' | 'stream'; title: string; status: 'running' | 'completed' | 'failed' | 'stopped'; error?: string; destination?: string; createdAt: string }
export interface MountOptions {readOnly: boolean; cacheMode: 'off' | 'minimal' | 'writes' | 'full'}
export interface AppAPI {
  showAbout(): Promise<void>;
  onFinderDrop(callback: (drop: FinderDrop) => void): () => void;
  copyText(text: string): Promise<void>;
  directoryTree(endpoint: Endpoint, maxDepth?: number): Promise<{text: string; truncated: boolean}>;
  exportFileList(endpoint: Endpoint, format?: 'csv' | 'txt'): Promise<string | null>;
  publicLink(endpoint: Endpoint, name: string, isDir: boolean): Promise<string | null>;
  startMount(endpoint: Endpoint, options?: MountOptions): Promise<ToolSession | null>;
  startStream(endpoint: Endpoint, name: string): Promise<ToolSession | null>;
  listToolSessions(): Promise<ToolSession[]>;
  stopToolSession(id: string): Promise<void>;
  onToolSessionUpdate(callback: (session: ToolSession) => void): () => void;
  bootstrap(): Promise<Bootstrap>;
  list(endpoint: Endpoint): Promise<FileEntry[]>;
  mkdir(endpoint: Endpoint, name: string): Promise<void>;
  rename(endpoint: Endpoint, name: string, newName: string, isDir: boolean): Promise<void>;
  remove(endpoint: Endpoint, selection: Selection[]): Promise<boolean>;
  size(endpoint: Endpoint): Promise<{ count: number; bytes: number }>;
  chooseFolder(current?: string): Promise<string | null>;
  chooseFile(kind: 'rclone' | 'config' | 'player'): Promise<string | null>;
  previewTransfer(request: TransferRequest): Promise<CommandPreview>;
  startTransfer(request: TransferRequest): Promise<Job | null>;
  cancelJob(id: string): Promise<void>;
  retryJob(id: string): Promise<Job | null>;
  listJobs(): Promise<Job[]>;
  clearFinishedJobs(): Promise<void>;
  clearJobs(request: ClearJobsRequest): Promise<ClearJobsResult>;
  getJobReport(id: string, options: {category: JobReportCategory; cursor?: number; limit?: number}): Promise<JobReportPage>;
  exportJobReport(id: string, format?: 'jsonl'|'comparison'): Promise<string|null>;
  saveTask(name: string, request: TransferRequest, id?: string): Promise<SavedTask>;
  deleteTask(id: string): Promise<void>;
  listTasks(): Promise<SavedTask[]>;
  saveSettings(settings: SettingsPatch): Promise<Environment>;
  unlockConfig(password: string): Promise<void>;
  configureRemotes(): Promise<void>;
  openExternal(url: string): Promise<void>;
  exportLog(id: string): Promise<string | null>;
  exportTasks(): Promise<string | null>;
  importTasks(): Promise<SavedTask[] | null>;
  checkForUpdates(manual: boolean): Promise<UpdateResult>;
  checkAppUpdates(): Promise<AppUpdateResult>;
  onJobUpdate(callback: (job: Job) => void): () => void;
  onUpdateStatus(callback: (status: UpdateStatus) => void): () => void;
  onConfigurationChanged(callback: () => void): () => void;
  onMenuAction(callback: (action: MenuAction) => void): () => void;
}
export const DEFAULT_OPTIONS: TransferOptions = {
  transfers: 4, checkers: 8, bandwidth: '', comparison: 'default', skipExisting: false, updateOnly: false,
  createEmptyDirs: true, exclude: ['.DS_Store', '._*'], include: [], retries: 3, maxDelete: -1,
  preserveMetadata: false, driveSharedWithMe: false,
  localHashPolicy: 'none', symlinkMode: 'skip', deleteMode: 'during', deleteExcluded: false, ignoreChecksum: false, modifyWindow: '', checkFirst: false,
  noTraverse: false, fastList: false, oneFileSystem: false, noUpdateModtime: false,
  minSize: '', maxSize: '', minAge: '', maxAge: '', maxDepth: -1, connectTimeout: '', ioTimeout: '',
  lowLevelRetries: 10, retrySleep: '', extraArgs: [],
};
