import { useState } from 'react';
import { HardDrives, ArrowRight, ArrowLeft, X, Folder, File as FileIcon } from '@phosphor-icons/react';
import { DEFAULT_OPTIONS, type TransferMode, type TransferOptions as Options, type TransferRequest, type Endpoint, type FileEntry, type Selection, type LocalLocation, type RemoteInfo } from '../shared/types';
import type { Translate } from './i18n';
import { Checkbox, Dialog, Field, Notice, IconButton, InfoTooltip } from './components';
import { endpointEqual, errorMessage } from './utils';
import { EndpointEditor } from './LocationPicker';

export interface TaskEditorConfig { name: string; id?: string; request: TransferRequest; validationError?: string; locations: LocalLocation[]; remotes: RemoteInfo[]; home: string; onSave(name: string, request: TransferRequest, id?: string): Promise<void> }

export default function TransferOptionsDialog({ options, mode, defaults, onSave, onSaveDefaults, onClose, t, task }: {
  options: Options; mode: TransferMode; defaults: Options; onSave(options: Options, mode: TransferMode): void;
  onSaveDefaults(options: Options): Promise<void>; onClose(): void; t: Translate; task?: TaskEditorConfig;
}) {
  const [draft, setDraft] = useState<Options>(() => ({...structuredClone(DEFAULT_OPTIONS), ...structuredClone(options)}));
  const [draftMode, setDraftMode] = useState(mode);
  const [tab, setTab] = useState<'locations'|'comparison'|'transfer'|'filters'>(task ? 'locations' : 'comparison');
  const [taskName, setTaskName] = useState(task?.name || '');
  const [saveCopy, setSaveCopy] = useState(false);
  const [direction, setDirection] = useState<'lr'|'rl'>(task?.request.direction || 'lr');
  const [left, setLeft] = useState<Endpoint>(task?.request.direction === 'rl' ? task.request.destination : task?.request.source || {remote: null, path: ''});
  const [right, setRight] = useState<Endpoint>(task?.request.direction === 'rl' ? task.request.source : task?.request.destination || {remote: null, path: ''});
  const [selection, setSelection] = useState<Selection[]>(task?.request.selection || []);
  const [sourceEntries, setSourceEntries] = useState<FileEntry[] | null>(null);
  const [selectionLoading, setSelectionLoading] = useState(false);
  const [selectionError, setSelectionError] = useState('');
  const [exclude, setExclude] = useState(options.exclude.join('\n'));
  const [include, setInclude] = useState(options.include.join('\n'));
  const [extraArgs, setExtraArgs] = useState(options.extraArgs.join('\n'));
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(task?.validationError || '');
  const [notice, setNotice] = useState('');
  const set = <K extends keyof Options>(key: K, value: Options[K]) => setDraft(old => ({...old, [key]: value}));
  const numberInput = (key: 'transfers' | 'checkers' | 'retries' | 'maxDelete' | 'maxDepth' | 'lowLevelRetries', min: number, max: number) => <input type="number" min={min} max={max} step={1} required value={draft[key]} onChange={event => set(key, Number.isNaN(event.target.valueAsNumber) ? min : event.target.valueAsNumber)}/>;
  const textInput = (key: 'bandwidth'|'modifyWindow'|'minSize'|'maxSize'|'minAge'|'maxAge'|'connectTimeout'|'ioTimeout'|'retrySleep', placeholder?: string) => <input value={draft[key]} placeholder={placeholder} onChange={event => set(key, event.target.value)} spellCheck={false}/>;
  const result = (): Options => ({...draft, exclude: exclude.split(/\r?\n/).filter(Boolean), include: include.split(/\r?\n/).filter(Boolean), extraArgs: extraArgs.split(/\r?\n/).map(line => line.trim()).filter(Boolean)});
  const reset = (value: Options) => { setDraft(structuredClone(value)); setExclude(value.exclude.join('\n')); setInclude(value.include.join('\n')); setExtraArgs(value.extraArgs.join('\n')); setNotice(''); setError(''); };
  const selectMode = (value: TransferMode) => { if (value === 'move' && draft.updateOnly) setNotice(t('moveNewerHint')); setDraftMode(value); setDraft(old => ({...old, ...(value === 'sync' ? {noTraverse: false} : {deleteExcluded: false}), ...(value === 'move' ? {updateOnly: false} : {})})); };
  const comparison = draft.localHashPolicy === 'none' && draft.comparison === 'default' ? 'nas' : draft.comparison;
  const comparisonHint = comparison === 'nas' ? 'comparisonNASHint' : comparison === 'checksum' ? 'comparisonChecksumHint' : comparison === 'checksum-only' ? 'comparisonChecksumOnlyHint' : comparison === 'size' ? 'comparisonSizeHint' : comparison === 'modtime' ? 'comparisonModtimeHint' : comparison === 'none' ? 'comparisonNoneHint' : 'comparisonDefaultHint';
  const source = direction === 'lr' ? left : right;
  const destination = direction === 'lr' ? right : left;
  const changeEndpoint = (side: 'left'|'right', value: Endpoint) => {
    const existing = side === 'left' ? left : right;
    if (endpointEqual(existing, value)) return;
    (side === 'left' ? setLeft : setRight)(value);
    if ((direction === 'lr' ? 'left' : 'right') === side) { setSelection([]); setSourceEntries(null); setSelectionError(''); if (selection.length) setNotice(t('selectionChangedSource')); }
  };
  const changeDirection = (value: 'lr'|'rl') => { if (value !== direction) { setDirection(value); setSelection([]); setSourceEntries(null); setSelectionError(''); if (selection.length) setNotice(t('selectionChangedSource')); } };
  const browseSelection = async () => { setSelectionLoading(true); setSelectionError(''); try { setSourceEntries(await window.rclone.list(source)); } catch (reason) { setSelectionError(errorMessage(reason)); } finally { setSelectionLoading(false); } };
  const submit = async () => {
    if (draftMode === 'move' && draft.updateOnly) { setError(t('moveNewerHint')); return; }
    if (!task) { onSave(result(), draftMode); return; }
    if (!taskName.trim()) { setError(t('nameRequired')); return; }
    if (endpointEqual(source, destination)) { setError(t('sameEndpoint')); return; }
    if ((!source.remote && !source.path.trim()) || (!destination.remote && !destination.path.trim())) { setError(t('selectLocation')); setTab('locations'); return; }
    if (draftMode === 'sync' && selection.length) { setError(t('syncSelection')); setTab('locations'); return; }
    setBusy(true); setError('');
    try { await task.onSave(taskName.trim(), {source, destination, direction, mode: draftMode, options: result(), selection, dryRun: false, label: taskName.trim()}, saveCopy ? undefined : task.id); }
    catch (reason) { setError(errorMessage(reason)); }
    finally { setBusy(false); }
  };
  const saveDefault = async () => {
    setBusy(true); setError(''); setNotice('');
    try { await onSaveDefaults(result()); setNotice(t('defaultsSaved')); } catch (reason) { setError(errorMessage(reason)); }
    finally { setBusy(false); }
  };
  return <Dialog title={task ? t(task.id ? 'editingTask' : 'saveTask') : t('options')} t={t} onClose={onClose} className={`options-dialog ${task ? 'task-editor-dialog' : ''}`}><form onSubmit={event => { event.preventDefault(); void submit(); }}>
    {task && <div className="task-editor-title"><Field label={t('taskName')}><input value={taskName} autoFocus required disabled={busy} onChange={event => setTaskName(event.target.value)}/></Field></div>}
    <div className="options-mode-bar"><span>{t('operation')}</span><div className="mode-picker" role="group" aria-label={t('operation')}>{(['copy','move','sync'] as const).map(value => <button type="button" key={value} aria-pressed={draftMode === value} onClick={() => selectMode(value)}>{t(value)}</button>)}</div><p className={draftMode === 'copy' ? '' : 'caution'}>{t(draftMode === 'copy' ? 'copyHint' : draftMode === 'sync' ? 'syncHint' : 'moveHint')}</p></div>
    <nav className="options-tabs" aria-label={t('options')}>{task && <button type="button" aria-pressed={tab === 'locations'} onClick={() => setTab('locations')}>{t('locationsTab')}</button>}{([{key: 'comparison', label: 'modeAndComparison'}, {key: 'transfer', label: 'transferPerformance'}, {key: 'filters', label: 'filtersTab'}] as const).map(item => <button type="button" key={item.key} aria-pressed={tab === item.key} onClick={() => setTab(item.key)}>{t(item.label)}</button>)}</nav>
    <div className="dialog-body options-content">
      {error && <Notice kind="error">{error}</Notice>}{notice && <Notice kind="success">{notice}</Notice>}
      {task && tab === 'locations' && <>
        <section className="settings-section task-locations-section"><div className="form-grid"><EndpointEditor value={left} label={`${t('left')} · ${t(direction === 'lr' ? 'source' : 'destination')}`} locations={task.locations} remotes={task.remotes} home={task.home} t={t} disabled={busy} onChange={value => changeEndpoint('left', value)} onError={setError}/><EndpointEditor value={right} label={`${t('right')} · ${t(direction === 'rl' ? 'source' : 'destination')}`} locations={task.locations} remotes={task.remotes} home={task.home} t={t} disabled={busy} onChange={value => changeEndpoint('right', value)} onError={setError}/></div><div className="task-direction-row"><span className="field-label">{t('direction')}</span><div className="direction-picker"><button type="button" aria-label={t('leftToRight')} aria-pressed={direction === 'lr'} className={direction === 'lr' ? 'selected' : ''} onClick={() => changeDirection('lr')}><span>{t('left')}</span><ArrowRight size={17}/><span>{t('right')}</span></button><button type="button" aria-label={t('rightToLeft')} aria-pressed={direction === 'rl'} className={direction === 'rl' ? 'selected' : ''} onClick={() => changeDirection('rl')}><span>{t('left')}</span><ArrowLeft size={17}/><span>{t('right')}</span></button></div></div></section>
        <section className="settings-section task-selection-section"><div className="section-heading"><h3>{t('selectionEditor')}</h3><InfoTooltip label={t('selectionEditor')} text={t('selectionHint')}/><span className="spacer"/><button type="button" disabled={selectionLoading || busy || draftMode === 'sync'} onClick={() => void browseSelection()}>{selectionLoading ? t('loadingFolder') : t('browseSelection')}</button></div>
          <div className="task-selection-summary"><span>{selection.length ? `${t('selected')} ${selection.length} ${t('items')}` : t('wholeFolder')}</span>{selection.length > 0 && <button type="button" className="text-button" onClick={() => setSelection([])}>{t('clearSelection')}</button>}</div>
          {draftMode === 'sync' && selection.length > 0 && <Notice kind="warning">{t('syncSelection')}</Notice>}
          {selectionError && <Notice kind="error">{selectionError}</Notice>}
          {sourceEntries ? <div className="task-selection-list">{sourceEntries.map(entry => <Checkbox key={entry.name} checked={selection.some(item => item.name === entry.name)} disabled={draftMode === 'sync'} onChange={checked => setSelection(old => checked ? [...old.filter(item => item.name !== entry.name), {name: entry.name, isDir: entry.isDir}] : old.filter(item => item.name !== entry.name))}><span className="selection-item-label">{entry.isDir ? <Folder size={17}/> : <FileIcon size={17}/>}<span>{entry.name}</span></span></Checkbox>)}</div> : selection.length > 0 && <ul className="selected-task-items">{selection.map(item => <li key={item.name}>{item.isDir ? <Folder size={17}/> : <FileIcon size={17}/>}<span>{item.name}</span><IconButton title={`${t('removeSelectionItem')} ${item.name}`} onClick={() => setSelection(old => old.filter(entry => entry.name !== item.name))}><X size={14}/></IconButton></li>)}</ul>}
        </section>
      </>}
      {tab === 'comparison' && <>
        <section className="settings-section"><Field className="comparison-field" label={t('comparison')} hint={t(comparisonHint)}><select value={comparison} data-testid="transfer-comparison" onChange={event => {
          const value = event.target.value;
          setDraft(old => ({...old, comparison: value === 'nas' ? 'default' : value as Options['comparison'], localHashPolicy: value === 'nas' ? 'none' : 'default', ...(value === 'nas' ? {ignoreChecksum: false, modifyWindow: ''} : {}), ...(value === 'none' ? {skipExisting: false, updateOnly: false} : {})}));
        }}><option value="default">{t('comparisonDefault')}</option><option value="checksum">{t('comparisonChecksum')}</option><option value="modtime">{t('comparisonModtime')}</option><option value="size">{t('comparisonSize')}</option><option value="checksum-only">{t('comparisonChecksumOnly')}</option><option value="none">{t('comparisonNone')}</option><option value="nas">{t('comparisonNAS')}</option></select></Field>
          {comparison === 'nas' && <div className="nas-choice"><HardDrives size={18}/><span>{t('nasLimitation')}</span></div>}
          <div className="checkbox-stack"><Checkbox checked={draft.updateOnly} disabled={draft.comparison === 'none' || (draftMode === 'move' && !draft.updateOnly)} hint={draftMode === 'move' ? t('moveNewerHint') : t('updateOnlyHint')} onChange={v => set('updateOnly', v)}>{t('updateOnly')}</Checkbox><Checkbox checked={draft.skipExisting} hint={t('skipExistingHint')} disabled={draft.comparison === 'none'} onChange={v => set('skipExisting', v)}>{t('skipExisting')}</Checkbox></div>
          <Field label={t('modifyWindow')} hint={t('modifyWindowHint')}>{textInput('modifyWindow', '1s')}</Field>
        </section>
        {draftMode === 'sync' && <section className="settings-section sync-settings"><h3>{t('sync')}</h3><div className="form-grid"><Field label={t('deleteMode')} hint={t('deleteModeHint')}><select value={draft.deleteMode} onChange={event => set('deleteMode', event.target.value as Options['deleteMode'])}><option value="before">{t('deleteBefore')}</option><option value="during">{t('deleteDuring')}</option><option value="after">{t('deleteAfter')}</option></select></Field><Field label={t('maxDelete')} hint={t('maxDeleteHint')}><div className="unlimited-number"><Checkbox checked={draft.maxDelete === -1} onChange={value => set('maxDelete', value ? -1 : 100)}>{t('unlimitedJobs')}</Checkbox>{draft.maxDelete !== -1 && numberInput('maxDelete', 0, 100000)}</div></Field></div><Checkbox checked={draft.deleteExcluded} onChange={v => set('deleteExcluded', v)} hint={t('deleteExcludedHint')}>{t('deleteExcluded')}</Checkbox></section>}
        <section className="settings-section"><h3>{t('behavior')}</h3><div className="checkbox-stack"><Checkbox checked={draft.createEmptyDirs} hint={t('createEmptyHint')} onChange={v => set('createEmptyDirs', v)}>{t('createEmpty')}</Checkbox><Checkbox checked={draft.oneFileSystem} hint={t('oneFileSystemHint')} onChange={v => set('oneFileSystem', v)}>{t('oneFileSystem')}</Checkbox><Checkbox checked={draft.noUpdateModtime} hint={t('noUpdateModtimeHint')} onChange={v => set('noUpdateModtime', v)}>{t('noUpdateModtime')}</Checkbox><Checkbox checked={draft.preserveMetadata} hint={t('preserveMetadataHint')} onChange={v => set('preserveMetadata', v)}>{t('preserveMetadata')}</Checkbox><Checkbox checked={draft.driveSharedWithMe} onChange={v => set('driveSharedWithMe', v)} hint={t('sharedWithMeHint')}>{t('sharedWithMe')}</Checkbox></div></section>
      </>}
      {tab === 'transfer' && <>
        <section className="settings-section"><h3>{t('performance')}</h3><div className="form-grid"><Field label={t('transfers')} hint={t('transfersHint')}>{numberInput('transfers', 1, 64)}</Field><Field label={t('checkers')} hint={t('checkersHint')}>{numberInput('checkers', 1, 128)}</Field><Field label={t('bandwidth')} hint={t('bandwidthHint')} className="span-two">{textInput('bandwidth', '10M')}</Field></div><div className="checkbox-stack"><Checkbox checked={draft.checkFirst} hint={t('checkFirstHint')} onChange={v => set('checkFirst', v)}>{t('checkFirst')}</Checkbox><Checkbox checked={draft.noTraverse} hint={t('noTraverseHint')} disabled={draftMode === 'sync'} onChange={v => set('noTraverse', v)}>{t('noTraverse')}</Checkbox><Checkbox checked={draft.fastList} hint={t('fastListHint')} onChange={v => set('fastList', v)}>{t('fastList')}</Checkbox></div></section>
        <section className="settings-section"><h3>{t('timeoutsAndRetries')}</h3><div className="form-grid"><Field label={t('connectTimeout')} hint={t('inheritNetworkHint')}>{textInput('connectTimeout', t('inheritNetwork'))}</Field><Field label={t('ioTimeout')} hint={t('inheritNetworkHint')}>{textInput('ioTimeout', t('inheritNetwork'))}</Field><Field label={t('retries')} hint={t('retriesHint')}>{numberInput('retries', 1, 100)}</Field><Field label={t('lowLevelRetries')} hint={t('lowLevelRetriesHint')}>{numberInput('lowLevelRetries', 1, 100)}</Field><Field label={t('retrySleep')} hint={t('durationHint')}>{textInput('retrySleep', '10s')}</Field></div></section>
        <section className="settings-section"><h3>{t('advancedOptions')}</h3><Checkbox checked={draft.ignoreChecksum} onChange={v => set('ignoreChecksum', v)} hint={t('ignoreChecksumHint')}>{t('ignoreChecksum')}</Checkbox><Field label={t('extraArgs')} hint={t('extraArgsHint')}><textarea rows={4} value={extraArgs} onChange={event => setExtraArgs(event.target.value)} spellCheck={false} placeholder="--buffer-size=16M"/></Field></section>
      </>}
      {tab === 'filters' && <>
        <section className="settings-section"><h3>{t('includeExclude')}</h3><InfoTooltip label={t('includeExclude')} text={t('patternsHint')}/><div className="form-grid"><Field label={t('exclude')}><textarea rows={5} value={exclude} onChange={event => setExclude(event.target.value)} spellCheck={false}/></Field><Field label={t('include')}><textarea rows={5} value={include} onChange={event => setInclude(event.target.value)} spellCheck={false}/></Field></div></section>
        <section className="settings-section"><h3>{t('sizeAndAge')}</h3><div className="form-grid"><Field label={t('minSize')} hint={t('fileSizeHint')}>{textInput('minSize', '100k')}</Field><Field label={t('maxSize')} hint={t('fileSizeHint')}>{textInput('maxSize', '2G')}</Field><Field label={t('minAge')} hint={t('ageHint')}>{textInput('minAge', '1h')}</Field><Field label={t('maxAge')} hint={t('ageHint')}>{textInput('maxAge', '7d')}</Field><Field label={t('maxDepth')} hint={t('maxDepthHint')}>{numberInput('maxDepth', -1, 100000)}</Field></div></section>
      </>}
    </div><footer className="dialog-footer"><button type="button" className="text-button" onClick={() => reset(defaults)}>{t('resetOptions')}</button><button type="button" className="text-button" onClick={() => void saveDefault()} disabled={busy}>{t('saveDefaults')}</button><span className="spacer"/><button type="button" onClick={onClose}>{t('cancel')}</button>{task?.id && <Checkbox checked={saveCopy} onChange={setSaveCopy}>{t('saveAsNew')}</Checkbox>}<button type="submit" className="primary" disabled={busy}>{t(task ? 'save' : 'apply')}</button></footer>
  </form></Dialog>;
}
