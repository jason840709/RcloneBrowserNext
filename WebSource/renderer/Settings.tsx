import { useEffect, useRef, useState } from 'react';
import { ArrowClockwise, ArrowSquareOut, DownloadSimple, TerminalWindow, Key, FolderOpen, Check, Palette, Network, HardDrives } from '@phosphor-icons/react';
import type { Endpoint, Environment, Settings as AppSettings, SettingsPatch, Theme, UpdateStatus, LocalLocation, RemoteInfo, NetworkOptions } from '../shared/types';
import type { Translate } from './i18n';
import { Checkbox, Dialog, Field, Notice, InfoTooltip } from './components';
import { errorMessage } from './utils';
import { EndpointEditor } from './LocationPicker';
import { INTERFACE_SCALES } from './appearance';

export default function SettingsDialog({ settings, environment, locations, remotes, home, pending, currentLocations, currentLocationsValid, t, onSave, onFlush, onReload, onConfigure, onClose }:
  {settings: AppSettings; environment: Environment; locations: LocalLocation[]; remotes: RemoteInfo[]; home: string; pending: boolean; currentLocations: {left: Endpoint; right: Endpoint}; currentLocationsValid: boolean; t: Translate; onSave(patch: SettingsPatch): Promise<void>; onFlush(): Promise<void>; onReload(): Promise<void>; onConfigure(): Promise<void>; onClose(): void}) {
  const [tab, setTab] = useState<'general'|'appearance'|'network'>('general');
  const [customBind, setCustomBind] = useState(settings.networkOptions.bindMode === 'address');
  useEffect(() => setCustomBind(settings.networkOptions.bindMode === 'address'), [settings.networkOptions.bindMode]);
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');
  const [update, setUpdate] = useState<UpdateStatus | null>(null);
  useEffect(() => window.rclone.onUpdateStatus(status => {
    setUpdate(status.status ? null : status);
  }), []);
  const act = async (action: () => Promise<unknown>) => {
    setBusy(true); setError(''); setNotice('');
    try { await action(); } catch (reason) { setUpdate(null); setError(errorMessage(reason)); }
    finally { setBusy(false); }
  };
  const patch = (next: SettingsPatch) => {
    setError(''); setNotice('');
    void onSave(next).catch(reason => setError(errorMessage(reason)));
  };
  const chooseExecutable = () => act(async () => {
    await onFlush();
    const path = await window.rclone.chooseFile('rclone');
    if (path) await onSave({rclonePath: path, rcloneDirectory: path.slice(0, path.lastIndexOf('/')) || '/'});
  });
  const chooseDirectory = () => act(async () => {
    await onFlush();
    const path = await window.rclone.chooseFolder(settings.rcloneDirectory || undefined);
    if (path) await onSave({rcloneDirectory: path, rclonePath: ''});
  });
  const choosePlayer = () => act(async () => {
    await onFlush();
    const path = await window.rclone.chooseFile('player');
    if (path) await onSave({streamPlayerPath: path});
  });
  const chooseConfig = () => act(async () => {
    await onFlush();
    const path = await window.rclone.chooseFile('config');
    if (path) await onSave({configPath: path});
  });
  const checkUpdates = () => act(async () => {
    // Drain all earlier location changes before the native updater resolves its target.
    await onFlush();
    const result = await window.rclone.checkForUpdates(true);
    setUpdate(null);
    await onReload();
    if (result.status === 'error' || result.status === 'unavailable') setError(result.message || t('updateUnavailable'));
    else if (result.status === 'current') setNotice(t('alreadyCurrent'));
    else if (result.status === 'updated') setNotice(t('rcloneUpdated'));
    else if (result.status === 'skipped') setNotice(t('versionSkipped'));
    else if (result.status === 'busy') setNotice(t('updateBusy'));
  });
  const themes: {value: Theme; label: 'purpleLight'|'purpleDark'|'blueLight'|'blueDark'|'greenLight'|'greenDark'}[] = [
    {value: 'purple-light', label: 'purpleLight'}, {value: 'purple-dark', label: 'purpleDark'},
    {value: 'blue-light', label: 'blueLight'}, {value: 'blue-dark', label: 'blueDark'},
    {value: 'green-light', label: 'greenLight'}, {value: 'green-dark', label: 'greenDark'},
  ];
  const startupLocation = (side: 'left'|'right'): Endpoint => settings.savedWorkspace?.[side] || settings.initialLocations[side] || (side === 'right' && remotes[0] ? {remote: remotes[0].name, path: ''} : {remote: null, path: home});
  const setStartup = (side: 'left'|'right', value: Endpoint) => patch(settings.savedWorkspace ? {savedWorkspace: {...settings.savedWorkspace, [side]: value}} : {initialLocations: {...settings.initialLocations, [side]: value}});
  const setNetwork = <K extends keyof NetworkOptions>(key: K, value: NetworkOptions[K]) => patch({networkOptions: {[key]: value}});
  const selectedPath = settings.rclonePath || (settings.rcloneDirectory ? `${settings.rcloneDirectory.replace(/\/$/, '')}/rclone` : '');
  const actualPath = pending ? selectedPath : environment.rclonePath || selectedPath;
  return <Dialog title={t('settings')} onClose={onClose} t={t} className="settings-dialog">
    <div className="preferences-layout">
      <nav className="preferences-tabs" aria-label={t('settings')}>
        <button type="button" aria-pressed={tab === 'general'} onClick={() => setTab('general')}><HardDrives size={19}/>{t('general')}</button>
        <button type="button" aria-pressed={tab === 'appearance'} onClick={() => setTab('appearance')}><Palette size={19}/>{t('appearance')}</button>
        <button type="button" aria-pressed={tab === 'network'} onClick={() => setTab('network')}><Network size={19}/>{t('network')}</button>
      </nav>
      <div className="dialog-body preferences-content">
        {error && <Notice kind="error">{error}</Notice>}{notice && <Notice kind="success">{notice}</Notice>}
        {tab === 'general' && <>
          <section className="settings-section engine-settings"><h3>{t('rcloneLocation')}</h3>
            <div className={`engine-state ${environment.available ? 'engine-ready' : ''}`}>
              <div className="engine-version"><span className={`status-dot ${environment.available ? 'ready' : ''}`}/><strong>{pending ? t('checkingLocation') : environment.available ? `rclone ${environment.version.replace(/^rclone\s+/i, '')}` : t('notInstalled')}</strong><button type="button" className="text-button" disabled={busy || pending} onClick={() => act(onReload)} title={t('redetect')} aria-label={t('redetect')}><ArrowClockwise size={16}/></button></div>
              <code className="engine-path" data-testid="actual-rclone-path">{actualPath || t('chooseDirectoryHint')}</code>
            </div>
            <p className="section-hint">{environment.available ? t('locationUpdateHint') : t('downloadLocationHint')}</p>
            <div className="section-actions location-actions"><button type="button" disabled={busy} onClick={chooseDirectory}><FolderOpen size={17}/>{environment.available ? t('replaceLocation') : t('chooseDirectory')}</button>{!environment.available && <button type="button" disabled={busy} onClick={chooseExecutable}>{t('chooseExecutable')}</button>}</div>
            {environment.available && <details className="location-advanced"><summary>{t('advancedLocation')}</summary><div className="advanced-content"><button type="button" disabled={busy} onClick={chooseExecutable}><TerminalWindow size={16}/>{t('chooseExecutable')}</button></div></details>}
            {environment.error && !pending && <Notice kind="warning">{environment.error}</Notice>}
            <div className="update-settings"><label className="checkbox-field"><input type="checkbox" checked={settings.autoCheckUpdates} onChange={event => patch({autoCheckUpdates: event.target.checked})}/>{t('autoCheckUpdates')}</label>
              {settings.skippedRcloneVersion && <p className="section-hint skipped-version">{t('skippedVersion')} {settings.skippedRcloneVersion}</p>}
              {update?.message && <p className="update-status" role="status"><ArrowClockwise size={15} className="loading-icon"/>{update.message}</p>}
              <div className="section-actions"><button type="button" data-testid="check-rclone-updates" disabled={busy || pending} onClick={checkUpdates}>{environment.available ? <ArrowClockwise size={16}/> : <DownloadSimple size={16}/>}<span>{busy ? t('processing') : environment.available ? t('checkForUpdates') : t('downloadRclone')}</span></button><button type="button" className="text-button" disabled={busy} onClick={() => act(() => window.rclone.openExternal('https://rclone.org/downloads/'))}>{t('openDownloads')}<ArrowSquareOut size={14}/></button></div>
            </div>
          </section>
          <section className="settings-section"><h3>{t('connections')}</h3><p className="section-hint">{t('configureHint')}</p>
            <div className="section-actions"><button type="button" className="primary" disabled={busy || pending || !environment.available} onClick={() => act(async () => { await onFlush(); await onConfigure(); setNotice(t('remoteSetupOpened')); })}><TerminalWindow size={17}/>{t('configLabel')}</button></div>
            <details className="advanced-options"><summary>{t('configPath')}</summary><div className="advanced-content"><code className="config-path">{environment.configPath || settings.configPath || t('defaultConfig')}</code><div className="section-actions"><button type="button" disabled={busy} onClick={chooseConfig}><FolderOpen size={16}/>{t('browse')}</button>{settings.configPath && <button type="button" className="text-button" disabled={busy} onClick={() => act(() => onSave({configPath: ''}))}>{t('resetConfig')}</button>}</div>
              <Field label={t('configPassword')} hint={t('unlockHint')}><div className="input-action"><input type="password" autoComplete="off" value={password} disabled={busy} onChange={event => setPassword(event.target.value)}/><button type="button" disabled={busy || !password || pending} onClick={() => act(async () => { try { await onFlush(); await window.rclone.unlockConfig(password); await onReload(); setNotice(t('unlocked')); } finally { setPassword(''); } })}><Key size={15}/>{t('unlock')}</button></div></Field>
            </div></details>
          </section>
          <section className="settings-section startup-settings"><div className="section-heading"><h3>{t('initialLocations')}</h3><InfoTooltip label={t('initialLocations')} text={t(settings.savedWorkspace ? 'workspaceStartupHint' : 'initialLocationsHint')}/>{settings.savedWorkspace && <span className="role-tag">{t('workspaceSaved')}</span>}</div>
            <div className="startup-location-editors">{(['left','right'] as const).map(side => <EndpointEditor key={side} value={startupLocation(side)} label={t(side)} locations={locations} remotes={remotes} home={home} t={t} disabled={busy} onChange={value => setStartup(side, value)} onError={setError}/>)}</div>
            <div className="section-actions"><button type="button" disabled={busy || !currentLocationsValid} onClick={() => act(async () => { await onSave(settings.savedWorkspace ? {savedWorkspace: {...settings.savedWorkspace, ...currentLocations}} : {initialLocations: currentLocations}); setNotice(t('settingsSaved')); })}>{t('saveInitialLocations')}</button>{(settings.savedWorkspace || Object.keys(settings.initialLocations).length > 0) && <button type="button" className="text-button" disabled={busy} onClick={() => act(async () => { await onSave({savedWorkspace: null, initialLocations: {}}); setNotice(t('settingsSaved')); })}>{t(settings.savedWorkspace ? 'forgetWorkspace' : 'resetInitialLocations')}</button>}</div>
          </section>
          <section className="settings-section"><h3>{t('settingsTasks')}</h3><Field label={t('maxConcurrentJobs')} hint={t('jobLimitHint')}><div className="concurrent-job-limit"><select aria-label={t('limitJobs')} value={settings.maxConcurrentJobs === 0 ? 'unlimited' : 'limited'} onChange={event => patch({maxConcurrentJobs: event.target.value === 'unlimited' ? 0 : 2})}><option value="unlimited">{t('unlimitedJobs')}</option><option value="limited">{t('limitJobs')}</option></select>{settings.maxConcurrentJobs > 0 && <CommittedInput label={t('maxConcurrentJobs')} type="number" min={1} max={128} value={String(settings.maxConcurrentJobs)} onCommit={value => patch({maxConcurrentJobs: Number(value)})}/>}</div></Field><p className="section-hint">{t('settingsTransferDefault')}</p><Field label={t('defaultRcloneOptions')} hint={t('defaultRcloneOptionsHint')}><CommittedInput multiline label={t('defaultRcloneOptions')} value={settings.defaultRcloneOptions.join('\n')} onCommit={value => patch({defaultRcloneOptions: lines(value)})} placeholder="--buffer-size=16M"/></Field></section>
          <section className="settings-section"><h3>{t('streamPlayer')}</h3><p className="section-hint">{t('streamPlayerHint')}</p>{settings.streamPlayerPath && <code className="config-path">{settings.streamPlayerPath}</code>}<div className="section-actions"><button type="button" disabled={busy} onClick={choosePlayer}>{t('choosePlayer')}</button></div><Field label={t('playerArguments')} hint={t('playerArgumentsHint')}><CommittedInput multiline label={t('playerArguments')} value={settings.streamPlayerArguments.join('\n')} onCommit={value => patch({streamPlayerArguments: lines(value)})} placeholder="-"/></Field></section>
        </>}
        {tab === 'appearance' && <>
          <section className="settings-section interface-scale-section"><div className="section-heading"><h3 id="interface-scale-title">{t('interfaceScale')}</h3><InfoTooltip label={t('interfaceScale')} text={t('interfaceScaleHint')}/></div><div className="interface-scale-picker" role="radiogroup" aria-labelledby="interface-scale-title">{INTERFACE_SCALES.map(scale => <label key={scale} className={settings.interfaceScale === scale ? 'selected' : ''}><input type="radio" name="interface-scale" value={scale} checked={settings.interfaceScale === scale} onChange={() => patch({interfaceScale: scale})}/><span>{scale}%</span>{scale === 100 && <small>{t('defaultScale')}</small>}</label>)}</div><p className="section-hint">{t('interfaceScaleSummary')}</p></section>
          <section className="settings-section"><h3>{t('theme')}</h3><div className="theme-picker" role="group" aria-label={t('chooseTheme')}>{themes.map(theme => <button type="button" key={theme.value} className={`theme-option swatch-${theme.value}`} aria-pressed={settings.theme === theme.value} onClick={() => patch({theme: theme.value})}><span className="theme-preview" aria-hidden="true"><i className="theme-bar"/><i className="theme-panel"/><i className="theme-action"/><i className="theme-panel"/></span><span>{t(theme.label)}{settings.theme === theme.value && <Check size={16} weight="bold"/>}</span></button>)}</div></section>
          <section className="settings-section"><h3>{t('language')}</h3><Field label={t('menuLanguage')} hint={t('systemLanguageHint')}><select value={settings.language} onChange={event => patch({language: event.target.value as AppSettings['language']})}><option value="system">{t('systemLanguage')}</option><option value="zh-TW">繁體中文</option><option value="en">English</option><option value="ja">日本語</option></select></Field></section>
          <section className="settings-section"><h3>{t('fileListAppearance')}</h3><div className="checkbox-stack">{(['showHiddenFiles','showFolderIcons','showFileIcons','alternatingRows'] as const).map(key => <label className="checkbox-field" key={key}><input type="checkbox" checked={settings[key]} onChange={event => patch({[key]: event.target.checked})}/>{t(key === 'showHiddenFiles' ? 'showHidden' : key)}</label>)}</div></section>
          <section className="settings-section"><h3>{t('backgroundBehavior')}</h3><div className="checkbox-stack">{(['showStatusItem','notifyOnCompletion'] as const).map(key => <label className="checkbox-field" key={key}><input type="checkbox" checked={settings[key]} onChange={event => patch({[key]: event.target.checked})}/>{t(key)}</label>)}</div></section>
        </>}
        {tab === 'network' && <><section className="settings-section"><h3>{t('connectionPrefs')}</h3>
          <fieldset className="proxy-modes"><legend>{t('proxyMode')}</legend><label><input type="radio" name="proxy-mode" checked={settings.proxyMode === 'system'} onChange={() => patch({proxyMode: 'system'})}/>{t('proxySystem')}</label><label><input type="radio" name="proxy-mode" checked={settings.proxyMode === 'manual'} onChange={() => patch({proxyMode: 'manual'})}/>{t('proxyManual')}</label></fieldset>
          {settings.proxyMode === 'manual' && <><Field label={t('httpProxy')} hint={t('httpProxyHint')}><CommittedInput label={t('httpProxy')} value={settings.httpProxy} onCommit={value => patch({httpProxy: value.trim()})} placeholder="http://127.0.0.1:8080"/></Field><Field label={t('httpsProxy')}><CommittedInput label={t('httpsProxy')} value={settings.httpsProxy} onCommit={value => patch({httpsProxy: value.trim()})} placeholder="http://127.0.0.1:8080"/></Field><Field label={t('noProxy')} hint={t('noProxyHint')}><CommittedInput label={t('noProxy')} value={settings.noProxy} onCommit={value => patch({noProxy: value.trim()})} placeholder="localhost,127.0.0.1,.local"/></Field></>}
          <p className="section-hint">{t('proxySavedHint')}</p></section>
          <section className="settings-section network-options-section"><h3>{t('rcloneConnections')}</h3><p className="section-hint">{t('rcloneConnectionsHint')}</p>
            <Field label={t('bindMode')} hint={t('bindHint')}><select value={customBind ? 'address' : settings.networkOptions.bindMode} onChange={event => { const value = event.target.value as NetworkOptions['bindMode']; setCustomBind(value === 'address'); if (value !== 'address' || settings.networkOptions.bindAddress) setNetwork('bindMode', value); }}><option value="auto">{t('bindAuto')}</option><option value="ipv4">{t('bindIPv4')}</option><option value="ipv6">{t('bindIPv6')}</option><option value="address">{t('bindCustom')}</option></select></Field>
            {customBind && <Field label={t('bindAddress')} hint={t('bindHint')}><CommittedInput label={t('bindAddress')} value={settings.networkOptions.bindAddress} placeholder="192.168.1.20" onCommit={value => { if (value.trim()) patch({networkOptions: {bindMode: 'address', bindAddress: value.trim()}}); else setError(t('bindPending')); }}/>{settings.networkOptions.bindMode !== 'address' && <span className="field-hint bind-pending">{t('bindPending')}</span>}</Field>}
            <div className="form-grid"><Field label={t('connectTimeout')} hint={t('networkTimeoutHint')}><CommittedInput label={t('connectTimeout')} value={settings.networkOptions.connectTimeout} onCommit={value => setNetwork('connectTimeout', value.trim())} placeholder="1m"/></Field><Field label={t('ioTimeout')} hint={t('networkTimeoutHint')}><CommittedInput label={t('ioTimeout')} value={settings.networkOptions.ioTimeout} onCommit={value => setNetwork('ioTimeout', value.trim())} placeholder="5m"/></Field><Field label={t('tpsLimit')} hint={t('tpsHint')}><CommittedInput label={t('tpsLimit')} type="number" min={0} max={1000000} step="any" value={String(settings.networkOptions.tpsLimit)} onCommit={value => setNetwork('tpsLimit', Number(value))}/></Field><Field label={t('tpsBurst')} hint={t('tpsBurstHint')}><CommittedInput label={t('tpsBurst')} type="number" min={1} max={1000000} value={String(settings.networkOptions.tpsBurst)} onCommit={value => setNetwork('tpsBurst', Number(value))}/></Field></div>
            <Field label={t('userAgent')} hint={t('userAgentHint')}><CommittedInput label={t('userAgent')} value={settings.networkOptions.userAgent} onCommit={value => setNetwork('userAgent', value)}/></Field>
            <Checkbox checked={settings.networkOptions.disableHTTP2} onChange={value => setNetwork('disableHTTP2', value)} hint={t('disableHTTP2Hint')}>{t('disableHTTP2')}</Checkbox>
          </section></>}

      </div>
    </div>
    <footer className="dialog-footer"><span className="autosave-note" role="status">{pending ? <><ArrowClockwise size={13} className="loading-icon"/>{t('savingSettings')}</> : <><Check size={13}/>{t('autosaveHint')}</>}</span><span className="spacer"/><button type="button" onClick={onClose}>{t('close')}</button></footer>
  </Dialog>;
}

function lines(value: string) { return value.split(/\r?\n/).map(line => line.trim()).filter(Boolean); }

function CommittedInput({value, onCommit, placeholder, label, multiline = false, type = 'text', min, max, step = 1}: {label: string; value: string; onCommit(value: string): void; placeholder?: string; multiline?: boolean; type?: 'text'|'number'; min?: number; max?: number; step?: number|'any'}) {
  const [text, setText] = useState(value);
  const cancelled = useRef(false);
  useEffect(() => setText(value), [value]);
  const props = {
    'aria-label': label, value: text, placeholder, spellCheck: false,
    onChange: (event: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement>) => setText(event.target.value),
    onBlur: (event: React.FocusEvent<HTMLInputElement | HTMLTextAreaElement>) => { if (!event.currentTarget.validity.valid) { event.currentTarget.reportValidity(); setText(value); return; } if (cancelled.current) { cancelled.current = false; return; } if (text !== value) onCommit(text); },
    onKeyDown: (event: React.KeyboardEvent<HTMLInputElement | HTMLTextAreaElement>) => {
      if (event.key === 'Enter' && (!multiline || event.metaKey || event.ctrlKey)) { event.preventDefault(); event.currentTarget.blur(); }
      if (event.key === 'Escape') { event.preventDefault(); event.stopPropagation(); cancelled.current = true; setText(value); event.currentTarget.blur(); }
    },
  };
  return multiline ? <textarea rows={3} {...props}/> : <input {...props} type={type} min={min} max={max} step={step} required={type === 'number'}/>;
}
