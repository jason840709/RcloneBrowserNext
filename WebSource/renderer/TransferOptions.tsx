import { useId, useRef, useState, type PropsWithChildren } from 'react';
import { HardDrives, ArrowRight, ArrowLeft, X, Folder, File as FileIcon } from '@phosphor-icons/react';
import { DEFAULT_OPTIONS, type TransferMode, type TransferOptions as Options, type TransferRequest, type Endpoint, type FileEntry, type Selection, type LocalLocation, type RemoteInfo, type BuiltinPresetID } from '../shared/types';
import type { Translate } from './i18n';
import { Checkbox, Dialog, Field, Notice, IconButton, InfoTooltip, FloatingNotice } from './components';
import { endpointEqual, errorMessage } from './utils';
import {recommendedPreset, presetLabel} from './presets';
import { EndpointEditor } from './LocationPicker';

export interface TaskEditorConfig { name: string; id?: string; request: TransferRequest; validationError?: string; locations: LocalLocation[]; remotes: RemoteInfo[]; home: string; onSave(name: string, request: TransferRequest, id?: string): Promise<void> }

export default function TransferOptionsDialog({ options, mode, defaults, onSave, onSaveDefaults, onClose, t, task, recommendation, hiddenPresets = [], onRestorePresets }: {
  options: Options; mode: TransferMode; defaults: Options; onSave(options: Options, mode: TransferMode): void;
  onSaveDefaults(options: Options): Promise<void>; onClose(): void; t: Translate; task?: TaskEditorConfig; recommendation?: BuiltinPresetID | null; hiddenPresets?: BuiltinPresetID[]; onRestorePresets?(): Promise<void>;
}) {
  const [draft, setDraft] = useState<Options>(() => ({...structuredClone(DEFAULT_OPTIONS), ...structuredClone(options)}));
  const [draftMode, setDraftMode] = useState(mode);
  const [tab, setTab] = useState<'locations'|'general'|'filters'|'advanced'>(task ? 'locations' : 'general');
  const uid = useId();
  const fid = (name: string) => `${uid}-${name}`;
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
  // Edits are protected: clicking the backdrop nudges the sheet instead of discarding them.
  const [edited, setEdited] = useState(false);
  const tabMotion = useRef<{tab: string; direction: 'none'|'forward'|'back'}>({tab, direction: 'none'});
  if (tabMotion.current.tab !== tab) {
    const tabOrder = ['locations', 'general', 'filters', 'advanced'];
    tabMotion.current = {tab, direction: tabOrder.indexOf(tab) > tabOrder.indexOf(tabMotion.current.tab) ? 'forward' : 'back'};
  }
  const paneDirection = tabMotion.current.direction;
  const numberInput = (key: 'transfers' | 'checkers' | 'retries' | 'maxDelete' | 'maxDepth' | 'lowLevelRetries', min: number, max: number) => <input id={fid(key)} className="number-field" type="number" min={min} max={max} step={1} required value={draft[key]} onChange={event => set(key, Number.isNaN(event.target.valueAsNumber) ? min : event.target.valueAsNumber)}/>;
  const textInput = (key: 'bandwidth'|'modifyWindow'|'minSize'|'maxSize'|'minAge'|'maxAge'|'connectTimeout'|'ioTimeout'|'retrySleep', placeholder?: string) => <input id={fid(key)} aria-label={t(key)} className="short-field" value={draft[key]} placeholder={placeholder} onChange={event => set(key, event.target.value)} spellCheck={false}/>;
  const check = (key: 'updateOnly'|'skipExisting'|'deleteExcluded'|'createEmptyDirs'|'oneFileSystem'|'noUpdateModtime'|'preserveMetadata'|'driveSharedWithMe'|'checkFirst'|'noTraverse'|'fastList'|'ignoreChecksum', label: string, help: string, disabled = false) => <label className="checkbox-field" title={help}><input type="checkbox" aria-label={label} checked={draft[key]} disabled={disabled} onChange={event => set(key, event.target.checked)}/><span>{label}</span></label>;
  const result = (): Options => ({...draft, exclude: exclude.split(/\r?\n/).filter(Boolean), include: include.split(/\r?\n/).filter(Boolean), extraArgs: extraArgs.split(/\r?\n/).map(line => line.trim()).filter(Boolean)});
  const reset = (value: Options) => { setDraft(structuredClone(value)); setExclude(value.exclude.join('\n')); setInclude(value.include.join('\n')); setExtraArgs(value.extraArgs.join('\n')); setNotice(''); setError(''); };
  const selectMode = (value: TransferMode) => { if (value === 'move' && draft.updateOnly) setNotice(t('moveNewerHint')); setDraftMode(value); setDraft(old => ({...old, ...(value === 'sync' ? {noTraverse: false} : {deleteExcluded: false}), ...(value === 'move' ? {updateOnly: false} : {})})); };
  const comparison = draft.localHashPolicy === 'none' && draft.comparison === 'default' ? 'nas' : draft.comparison;
  const comparisonSummary = comparison === 'nas' ? 'comparisonNASSummary' : comparison === 'checksum' ? 'comparisonChecksumSummary' : comparison === 'checksum-only' ? 'comparisonChecksumOnlySummary' : comparison === 'size' ? 'comparisonSizeSummary' : comparison === 'modtime' ? 'comparisonModtimeSummary' : comparison === 'none' ? 'comparisonNoneSummary' : 'comparisonDefaultSummary';
  const comparisonHint = comparison === 'nas' ? 'comparisonNASHint' : comparison === 'checksum' ? 'comparisonChecksumHint' : comparison === 'checksum-only' ? 'comparisonChecksumOnlyHint' : comparison === 'size' ? 'comparisonSizeHint' : comparison === 'modtime' ? 'comparisonModtimeHint' : comparison === 'none' ? 'comparisonNoneHint' : 'comparisonDefaultHint';
  const source = direction === 'lr' ? left : right;
  const destination = direction === 'lr' ? right : left;
  const advice = task ? recommendedPreset(source, destination, task.remotes, task.locations) : recommendation;
  const restore = async () => {if (!onRestorePresets) return; setBusy(true); try {await onRestorePresets(); setNotice(t('presetsRestored'));} catch (reason) {setError(errorMessage(reason));} finally {setBusy(false);}};
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
    if (draftMode === 'sync' && selection.some(item => !item.isDir)) { setError(t('syncSelection')); setTab('locations'); return; }
    if (draftMode === 'sync' && selection.length > 0 && draft.deleteExcluded) { setError(t('syncSelectionDeleteExcluded')); setTab('general'); return; }
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
  const tabs: {key: 'locations'|'general'|'filters'|'advanced'; label: 'locationsTab'|'generalTab'|'filtersTab'|'advancedTab'}[] = [{key: 'locations', label: 'locationsTab'}, {key: 'general', label: 'generalTab'}, {key: 'filters', label: 'filtersTab'}, {key: 'advanced', label: 'advancedTab'}];
  // A plain Mac form: labels on the left, controls on the right, no running commentary.
  // The three tabs switch the content below them; the operation is an ordinary popup.
  // Explanations live in hover help on each label.
  return <Dialog title={task ? t(task.id ? 'editingTask' : 'saveTask') : t('options')} t={t} onClose={onClose} className={`options-dialog ${task ? 'task-editor-dialog' : ''}`} guarded={edited}><form onChange={() => setEdited(true)} onSubmit={event => { event.preventDefault(); void submit(); }}>
    <nav className="options-tabs" aria-label={t('options')}>{tabs.filter(item => task || item.key !== 'locations').map(item => <button type="button" key={item.key} aria-pressed={tab === item.key} onClick={() => setTab(item.key)}>{t(item.label)}</button>)}</nav>
    <div className="dialog-body options-content">
      {error && <Notice kind="error">{error}</Notice>}<FloatingNotice message={notice} onClose={() => setNotice('')}/>
      {task && tab === 'locations' && <div className="form-rows options-pane" data-direction={paneDirection}>
        <Row label={t('taskName')} id={fid('name')}><input id={fid('name')} value={taskName} autoFocus required disabled={busy} onChange={event => setTaskName(event.target.value)}/></Row>
        <Row label={t('left')}><EndpointEditor value={left} label={`${t('left')} · ${t(direction === 'lr' ? 'source' : 'destination')}`} locations={task.locations} remotes={task.remotes} home={task.home} t={t} disabled={busy} onChange={value => changeEndpoint('left', value)} onError={setError}/></Row>
        <Row label={t('right')}><EndpointEditor value={right} label={`${t('right')} · ${t(direction === 'rl' ? 'source' : 'destination')}`} locations={task.locations} remotes={task.remotes} home={task.home} t={t} disabled={busy} onChange={value => changeEndpoint('right', value)} onError={setError}/></Row>
        <Row label={t('direction')}><div className="direction-picker task-direction" data-direction={direction}><button type="button" aria-label={t('leftToRight')} aria-pressed={direction === 'lr'} className={direction === 'lr' ? 'selected' : ''} onClick={() => changeDirection('lr')}><ArrowRight size={16} weight="bold"/></button><button type="button" aria-label={t('rightToLeft')} aria-pressed={direction === 'rl'} className={direction === 'rl' ? 'selected' : ''} onClick={() => changeDirection('rl')}><ArrowLeft size={16} weight="bold"/></button></div></Row>
        <Row label={t('selectionEditor')} help={t('selectionHint')} top>
          <div className="task-selection-summary"><span>{selection.length ? `${t('selected')} ${selection.length} ${t('items')}` : t('wholeFolder')}</span><span className="spacer"/>{selection.length > 0 && <button type="button" className="text-button" onClick={() => setSelection([])}>{t('clearSelection')}</button>}<button type="button" disabled={selectionLoading || busy} onClick={() => void browseSelection()}>{selectionLoading ? t('loadingFolder') : t('browseSelection')}</button></div>
          {draftMode === 'sync' && selection.some(item => !item.isDir) && <Notice kind="warning">{t('syncSelection')}</Notice>}{draftMode === 'sync' && selection.length > 0 && draft.deleteExcluded && <Notice kind="warning">{t('syncSelectionDeleteExcluded')}</Notice>}
          {selectionError && <Notice kind="error">{selectionError}</Notice>}
          {sourceEntries ? <div className="task-selection-list">{sourceEntries.map(entry => <Checkbox key={entry.name} checked={selection.some(item => item.name === entry.name)} disabled={draftMode === 'sync' && !entry.isDir && !selection.some(item => item.name === entry.name)} onChange={checked => setSelection(old => checked ? [...old.filter(item => item.name !== entry.name), {name: entry.name, isDir: entry.isDir}] : old.filter(item => item.name !== entry.name))}><span className="selection-item-label">{entry.isDir ? <Folder size={16}/> : <FileIcon size={16}/>}<span>{entry.name}</span></span></Checkbox>)}</div> : selection.length > 0 && <ul className="selected-task-items">{selection.map(item => <li key={item.name}>{item.isDir ? <Folder size={16}/> : <FileIcon size={16}/>}<span>{item.name}</span><IconButton title={`${t('removeSelectionItem')} ${item.name}`} onClick={() => setSelection(old => old.filter(entry => entry.name !== item.name))}><X size={12}/></IconButton></li>)}</ul>}
        </Row>
      </div>}
      {tab === 'general' && <div className="form-rows options-pane" data-direction={paneDirection}>
        <Row label={t('operation')} id={fid('mode')} help={t(draftMode === 'sync' ? 'syncDetail' : draftMode === 'move' ? 'moveDetail' : 'copyDetail')}><select id={fid('mode')} data-testid="transfer-mode" value={draftMode} onChange={event => selectMode(event.target.value as TransferMode)}>{(['copy','sync','move'] as const).map(value => <option key={value} value={value}>{t(value)}</option>)}</select></Row>
        <Row label={t('comparison')} id={fid('comparison')} help={t(comparisonHint)}><select id={fid('comparison')} value={comparison} data-testid="transfer-comparison" onChange={event => {
          const value = event.target.value;
          setDraft(old => ({...old, comparison: value === 'nas' ? 'default' : value as Options['comparison'], localHashPolicy: value === 'nas' ? 'none' : 'default', ...(value === 'nas' ? {ignoreChecksum: false} : {}), ...(value === 'none' ? {skipExisting: false, updateOnly: false} : {})}));
        }}><option value="nas">{t('comparisonNAS')}</option><option value="default">{t('comparisonDefault')}</option><option value="checksum">{t('comparisonChecksum')}</option><option value="modtime">{t('comparisonModtime')}</option><option value="size">{t('comparisonSize')}</option><option value="checksum-only">{t('comparisonChecksumOnly')}</option><option value="none">{t('comparisonNone')}</option></select></Row>
        <Row label={t('skipFiles')} top><div className="check-column">{check('skipExisting', t('skipExistingShort'), t('skipExistingHint'), draft.comparison === 'none')}{check('updateOnly', t('updateOnlyShort'), draftMode === 'move' ? t('moveNewerHint') : t('updateOnlyHint'), draft.comparison === 'none' || (draftMode === 'move' && !draft.updateOnly))}</div></Row>
        {draftMode === 'sync' && (draft.skipExisting || draft.updateOnly) && <Row label=""><Notice kind="warning">{t('syncOverridesWarning')}</Notice></Row>}
        {draftMode === 'sync' && <>
          <div className="form-separator" role="separator"/>
          <Row label={t('deleteMode')} id={fid('deleteMode')} help={t('deleteModeHint')}><select id={fid('deleteMode')} value={draft.deleteMode} onChange={event => set('deleteMode', event.target.value as Options['deleteMode'])}><option value="before">{t('deleteBefore')}</option><option value="during">{t('deleteDuring')}</option><option value="after">{t('deleteAfter')}</option></select></Row>
          <Row label={t('maxDelete')} help={t('maxDeleteHint')}><div className="inline-controls"><label className="checkbox-field"><input type="checkbox" aria-label={t('unlimitedJobs')} checked={draft.maxDelete === -1} onChange={event => set('maxDelete', event.target.checked ? -1 : 100)}/><span>{t('unlimitedJobs')}</span></label>{draft.maxDelete !== -1 && numberInput('maxDelete', 0, 100000)}</div></Row>
          <Row label=""><div className="check-column">{check('deleteExcluded', t('deleteExcluded'), t('deleteExcludedHint'))}</div></Row>
        </>}
        <div className="form-separator" role="separator"/>
        <Row label={t('transfers')} id={fid('transfers')} help={t('transfersHint')}><div className="inline-controls">{numberInput('transfers', 1, 64)}<span className="inline-pair" title={t('checkersHint')}><label className="inline-label" htmlFor={fid('checkers')}>{t('checkers')}</label>{numberInput('checkers', 1, 128)}</span></div></Row>
        <Row label={t('bandwidth')} id={fid('bandwidth')} help={t('bandwidthHint')}><div className="inline-controls">{textInput('bandwidth', t('unlimitedJobs'))}<span className="unit-hint">{t('bandwidthExample')}</span></div></Row>
      </div>}
      {tab === 'filters' && <div className="form-rows options-pane" data-direction={paneDirection}>
        <Row label={t('exclude')} id={fid('exclude')} help={t('patternsHint')} top><textarea id={fid('exclude')} rows={5} value={exclude} onChange={event => setExclude(event.target.value)} spellCheck={false} placeholder={'*.tmp\n/cache/**'}/></Row>
        <Row label={t('include')} id={fid('include')} help={t('patternsHint')} top><textarea id={fid('include')} rows={3} value={include} onChange={event => setInclude(event.target.value)} spellCheck={false}/></Row>
        <div className="form-separator" role="separator"/>
        <Row label={t('fileSizeRange')} help={t('fileSizeHint')}><div className="inline-controls"><span className="inline-label">{t('atLeast')}</span>{textInput('minSize', '100k')}<span className="inline-label">{t('atMost')}</span>{textInput('maxSize', '2G')}</div></Row>
        <Row label={t('fileAgeRange')} help={t('ageHint')}><div className="inline-controls"><span className="inline-label">{t('atLeast')}</span>{textInput('minAge', '1h')}<span className="inline-label">{t('atMost')}</span>{textInput('maxAge', '7d')}</div></Row>
        <Row label={t('maxDepth')} id={fid('maxDepth')} help={t('maxDepthHint')}>{numberInput('maxDepth', -1, 100000)}</Row>
      </div>}
      {tab === 'advanced' && <div className="form-rows options-pane" data-direction={paneDirection}>
        <Row label={t('symlinkMode')} id={fid('symlinks')} help={t('symlinkHint')}><select id={fid('symlinks')} data-testid="transfer-symlinks" value={draft.symlinkMode||'skip'} onChange={event=>set('symlinkMode',event.target.value as Options['symlinkMode'])}><option value="skip">{t('symlinkSkip')}</option><option value="preserve">{t('symlinkPreserve')}</option></select></Row>
        <Row label={t('behavior')} top><div className="check-column">{check('createEmptyDirs', t('createEmpty'), t('createEmptyHint'))}{check('noUpdateModtime', t('noUpdateModtime'), t('noUpdateModtimeHint'))}{check('preserveMetadata', t('preserveMetadata'), t('preserveMetadataHint'))}{check('oneFileSystem', t('oneFileSystem'), t('oneFileSystemHint'))}{check('driveSharedWithMe', t('sharedWithMe'), t('sharedWithMeHint'))}</div></Row>
        <Row label={t('modifyWindow')} id={fid('modifyWindow')} help={t('modifyWindowHint')}>{textInput('modifyWindow', t('automaticShort'))}</Row>
        <div className="form-separator" role="separator"/>
        <Row label={t('performance')} top><div className="check-column">{check('checkFirst', t('checkFirst'), t('checkFirstHint'))}{check('noTraverse', t('noTraverse'), t('noTraverseHint'), draftMode === 'sync')}{check('fastList', t('fastList'), t('fastListHint'))}{check('ignoreChecksum', t('ignoreChecksum'), t('ignoreChecksumHint'))}</div></Row>
        <Row label={t('retries')} id={fid('retries')} help={t('retriesHint')}><div className="inline-controls">{numberInput('retries', 1, 100)}<span className="inline-pair" title={t('lowLevelRetriesHint')}><label className="inline-label" htmlFor={fid('lowLevelRetries')}>{t('lowLevelRetries')}</label>{numberInput('lowLevelRetries', 1, 100)}</span></div></Row>
        <Row label={t('retrySleep')} id={fid('retrySleep')} help={t('retrySleepHint')}>{textInput('retrySleep', '10s')}</Row>
        <Row label={t('connectTimeout')} id={fid('connectTimeout')} help={`${t('networkTimeoutHint')} ${t('inheritNetworkHint')}`}><div className="inline-controls">{textInput('connectTimeout', t('inheritNetwork'))}<label className="inline-label" htmlFor={fid('ioTimeout')}>{t('ioTimeout')}</label>{textInput('ioTimeout', t('inheritNetwork'))}</div></Row>
        <Row label={t('extraArgs')} id={fid('extraArgs')} help={t('extraArgsHint')} top><textarea id={fid('extraArgs')} rows={3} value={extraArgs} onChange={event => setExtraArgs(event.target.value)} spellCheck={false} placeholder="--buffer-size=16M"/></Row>
        {onRestorePresets && hiddenPresets.length > 0 && <Row label=""><button type="button" className="text-button" disabled={busy} onClick={() => void restore()}>{t('restorePresets')}</button></Row>}
      </div>}
    </div><footer className="dialog-footer"><button type="button" className="text-button" onClick={() => reset(defaults)}>{t('resetOptions')}</button><button type="button" className="text-button" onClick={() => void saveDefault()} disabled={busy}>{t('saveDefaults')}</button><span className="spacer"/>{task?.id && <Checkbox checked={saveCopy} onChange={setSaveCopy}>{t('saveAsNew')}</Checkbox>}<button type="button" onClick={onClose}>{t('cancel')}</button><button type="submit" className="primary" disabled={busy}>{t(task ? 'save' : 'apply')}</button></footer>
  </form></Dialog>;
}

function Row({label, id, help, top = false, children}: PropsWithChildren<{label: string; id?: string; help?: string; top?: boolean}>) {
  // The hint covers the whole row, label and controls, not only the label text.
  return <div className={`form-row ${top ? 'form-row-top' : ''}`} title={help}>{id ? <label className="form-row-label" htmlFor={id}>{label}</label> : <span className="form-row-label">{label}</span>}<div className="form-row-control">{children}</div></div>;
}
