import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, type KeyboardEvent, type MouseEvent, type PointerEvent } from 'react';
import { TableVirtuoso, type TableComponents, type TableVirtuosoHandle } from 'react-virtuoso';
import { ArrowLeft, ArrowRight, ArrowUp, ArrowClockwise, Folder, FolderOpen, FolderPlus, HardDrives, Cloud, MagnifyingGlass,
  Eye, EyeSlash, CaretDown, CaretUp, File as FileIcon, FileText, FileImage, FileZip, PencilSimple, Trash, ChartBar, X, Plus } from '@phosphor-icons/react';
import type { FileEntry, ResolvedLanguage, RemoteInfo, LocalLocation, PaneColumnWidths, Settings } from '../shared/types';
import type { BrowserState } from './useBrowser';
import type { Translate } from './i18n';
import { childEndpoint, endpointEqual, endpointName, endpointText, errorMessage, formatBytes, formatDate, parentEndpoint } from './utils';
import PaneMenu from './PaneMenu';
import { LocationPicker } from './LocationPicker';
import type { ToolAction } from './Tools';
import { EmptyState, IconButton, Notice } from './components';

export type FileAction = 'newFolder' | 'rename' | 'remove' | 'size';
interface PaneContext {
  disabled: boolean;
  selected: Set<string>;
  checkWidth: number;
  widths: PaneColumnWidths;
  focused: string;
  onSelect(item: FileEntry, event: MouseEvent): void;
  onOpen(item: FileEntry): void;
  onKey(event: KeyboardEvent, item: FileEntry, index: number): void;
  onFocus(item: FileEntry): void;
}
const tableComponents: TableComponents<FileEntry, PaneContext> = {
  Table: ({ context, children, ...props }) => <table {...props} className="file-table" style={{width: '100%', minWidth: (context?.checkWidth || 14) + (context?.widths.name || 180) + (context?.widths.size || 86) + (context?.widths.modified || 164)}}><colgroup><col style={{width: context?.checkWidth || 14}}/><col style={{width: context?.widths.name}}/><col style={{width: context?.widths.size}}/><col style={{width: context?.widths.modified}}/><col className="row-fill"/></colgroup>{children}</table>,
  TableRow: ({ item, context, ...props }) => <tr {...props} data-row-parity={Number(props['data-index']) % 2} data-selected={context?.selected.has(item.name) || undefined}
    tabIndex={!context?.disabled && context?.focused === item.name ? 0 : -1} aria-selected={context?.selected.has(item.name)} aria-disabled={context?.disabled || undefined}
    onFocus={() => context?.onFocus(item)}
    onClick={event => context?.onSelect(item, event)}
    onDoubleClick={() => context?.onOpen(item)}
    onKeyDown={event => context?.onKey(event, item, Number(props['data-index']))}/>,
};

function EntryIcon({ entry }: {entry: FileEntry}) {
  if (entry.isDir) return <Folder className="folder-icon" size={19} weight="duotone"/>;
  const extension = entry.name.toLowerCase().split('.').at(-1) || '';
  if (['jpg', 'jpeg', 'png', 'heic', 'webp', 'tif', 'tiff', 'svg', 'gif'].includes(extension)) return <FileImage size={18} className="file-icon"/>;
  if (['zip', 'gz', '7z', 'rar', 'tar', 'bz2', 'xz'].includes(extension)) return <FileZip size={18} className="file-icon"/>;
  if (['txt', 'md', 'pdf', 'doc', 'docx', 'tex', 'csv'].includes(extension)) return <FileText size={18} className="file-icon"/>;
  return <FileIcon size={18} className="file-icon"/>;
}

export default function BrowserPane({ side, browser, remotes, locations, home, platform, t, language, active, isSource, disabled, remoteAvailable, onActivate, onFileAction, onError, columnWidths, onColumnWidths, preferences, onToolAction }:
  {side: 'left' | 'right'; browser: BrowserState; remotes: RemoteInfo[]; locations: LocalLocation[]; home: string; platform: string; t: Translate; language: ResolvedLanguage;
    active: boolean; isSource: boolean; disabled: boolean; remoteAvailable: boolean; onActivate(): void; onFileAction(action: FileAction): void; onError(message: string): void; columnWidths?: PaneColumnWidths; onColumnWidths(widths: PaneColumnWidths): void; preferences: Settings; onToolAction(action: ToolAction): void}) {
  const { endpoint, entries, selection, loading, error } = browser;
  const openingName = browser.pendingEndpoint ? browser.pendingEndpoint.remote ? browser.pendingEndpoint.path.replace(/\/+$/, '').split('/').at(-1) || browser.pendingEndpoint.remote : endpointName(browser.pendingEndpoint) : '';
  const loadingLabel = browser.cancelling ? t('cancellingFolder') : openingName ? t('openingFolder').replace('{name}', openingName) : t('loadingFolder');
  const fileSelection = isSource ? selection : browser.focusedEntry ? [browser.focusedEntry] : [];
  const checkWidth = isSource ? 36 : 14;
  useEffect(() => { if (!isSource) browser.clearSelections(); }, [isSource, browser.clearSelections]);
  const navigationDisabled = disabled || browser.cancelling || Boolean(endpoint.remote && !remoteAvailable);
  const listingDisabled = navigationDisabled || loading || !browser.hasListing;
  const [query, setQuery] = useState('');
  const [showHidden, setShowHidden] = useState(preferences.showHiddenFiles);
  useEffect(() => setShowHidden(preferences.showHiddenFiles), [preferences.showHiddenFiles]);
  const [sort, setSort] = useState<{key: 'name'|'size'|'modified'; ascending: boolean}>({ key: 'name', ascending: true });
  const [focused, setFocused] = useState('');
  const [pathDraft, setPathDraft] = useState<string | null>(null);
  const sectionRef = useRef<HTMLElement>(null);
  const pathRef = useRef<HTMLInputElement>(null);
  const [paneWidth, setPaneWidth] = useState(450);
  const [dragWidths, setDragWidths] = useState<PaneColumnWidths | null>(null);
  const dragging = useRef<{column: keyof PaneColumnWidths; startX: number; widths: PaneColumnWidths; pointerId: number; latest: PaneColumnWidths} | null>(null);
  const widths: PaneColumnWidths = dragWidths || columnWidths || {name: Math.max(120, paneWidth - 16 - checkWidth - 82 - 158), size: 82, modified: 158};
  useEffect(() => {
    const element = sectionRef.current;
    if (!element) return;
    const observer = new ResizeObserver(entries => setPaneWidth(Math.floor(entries[0].contentRect.width)));
    observer.observe(element);
    return () => observer.disconnect();
  }, []);
  useEffect(() => { if (!dragging.current) setDragWidths(null); }, [columnWidths]);
  const columnLimits = {name: [120,1600], size: [76,400], modified: [150,500]} as const;
  const clampWidth = (key: keyof PaneColumnWidths, width: number) => Math.round(Math.max(columnLimits[key][0], Math.min(columnLimits[key][1], width)));
  const commitWidths = (value: PaneColumnWidths) => { setDragWidths(value); onColumnWidths(value); };
  const resetWidths = () => commitWidths({name: Math.max(120, paneWidth - 16 - checkWidth - 82 - 158), size: 82, modified: 158});
  const onResizeStart = (event: PointerEvent<HTMLButtonElement>, column: keyof PaneColumnWidths) => {
    if (dragging.current || event.button !== 0) return;
    event.preventDefault(); event.stopPropagation();
    event.currentTarget.setPointerCapture(event.pointerId);
    dragging.current = {column, startX: event.clientX, widths: {...widths}, pointerId: event.pointerId, latest: {...widths}};
  };
  const onResizeMove = (event: PointerEvent<HTMLButtonElement>) => {
    const drag = dragging.current;
    if (!drag || drag.pointerId !== event.pointerId) return;
    const next = {...drag.widths, [drag.column]: clampWidth(drag.column, drag.widths[drag.column] + event.clientX - drag.startX)};
    drag.latest = next; setDragWidths(next);
  };
  const onResizeEnd = (event: PointerEvent<HTMLButtonElement>) => {
    const drag = dragging.current;
    if (!drag || drag.pointerId !== event.pointerId) return;
    dragging.current = null; if (event.currentTarget.hasPointerCapture(event.pointerId)) event.currentTarget.releasePointerCapture(event.pointerId);
    commitWidths(drag.latest);
  };
  const resizeHandle = (key: keyof PaneColumnWidths, label: string) => <button type="button" className={`column-resizer ${key === 'modified' ? 'column-resizer-last' : ''}`} aria-label={`${label} ${t('resizeColumn')}`} title={t('resizeColumnHint')} data-testid={`${side}-resize-${key}`} onPointerDown={event => onResizeStart(event, key)} onPointerMove={onResizeMove} onPointerUp={onResizeEnd} onPointerCancel={onResizeEnd} onDoubleClick={resetWidths} onKeyDown={event => {
    if (event.key === 'ArrowLeft' || event.key === 'ArrowRight') { event.preventDefault(); event.stopPropagation(); commitWidths({...widths, [key]: clampWidth(key, widths[key] + (event.key === 'ArrowRight' ? 8 : -8))}); }
    if (event.key === 'Home') { event.preventDefault(); resetWidths(); }
  }}/>;
  const virtuoso = useRef<TableVirtuosoHandle>(null);
  const anchor = useRef<number | null>(null);
  const rememberedPaths = useRef<Record<string, string>>({});
  rememberedPaths.current[endpoint.remote || ''] = endpoint.path;
  useLayoutEffect(() => { setPathDraft(null); setQuery(''); setFocused(''); anchor.current = null; }, [endpoint.remote, endpoint.path, browser.activeTab]);
  useLayoutEffect(() => { if (!browser.pathDirty) setPathDraft(null); }, [browser.pathDirty]);
  const selected = useMemo(() => new Set(isSource ? selection.map(item => item.name) : []), [selection, isSource]);
  const filtered = useMemo(() => entries.filter(entry => (showHidden || !entry.name.startsWith('.')) && entry.name.toLocaleLowerCase().includes(query.toLocaleLowerCase()))
    .sort((a, b) => {
      if (a.isDir !== b.isDir) return a.isDir ? -1 : 1;
      const primary = sort.key === 'size' ? a.size - b.size : sort.key === 'modified' ? Date.parse(a.modified) - Date.parse(b.modified) : a.name.localeCompare(b.name, language, {numeric: true, sensitivity: 'base'});
      const diff = Number.isFinite(primary) && primary !== 0 ? primary : a.name.localeCompare(b.name, language, {numeric: true});
      return sort.ascending ? diff : -diff;
    }), [entries, query, showHidden, sort, language]);
  const visibleNames = useMemo(() => new Set(filtered.map(item => item.name)), [filtered]);
  const allSelected = useMemo(() => filtered.length > 0 && selected.size > 0 && filtered.every(item => selected.has(item.name)), [filtered, selected]);
  const someSelected = useMemo(() => selected.size > 0 && filtered.some(item => selected.has(item.name)), [filtered, selected]);
  const hiddenSelection = useMemo(() => selection.some(item => !visibleNames.has(item.name)), [selection, visibleNames]);
  const navigate = useCallback((target: typeof endpoint) => {
    setPathDraft(null); browser.navigate(target);
  }, [browser.navigate]);
  const cancelRead = async () => {
    await browser.cancelLoading();
    requestAnimationFrame(() => {
      const row = sectionRef.current?.querySelector<HTMLElement>('.file-table tbody tr[tabindex="0"]');
      (row || pathRef.current)?.focus();
    });
  };
  const toggle = (item: FileEntry) => { if (isSource && !listingDisabled) browser.setSelection(selected.has(item.name) ? selection.filter(x => x.name !== item.name) : [...selection, { name: item.name, isDir: item.isDir }]); };
  const selectVisible = () => {
    if (!isSource || listingDisabled) return;
    const remaining = selection.filter(item => !visibleNames.has(item.name));
    browser.setSelection(allSelected ? remaining : [...remaining, ...filtered.map(item => ({name: item.name, isDir: item.isDir}))]);
  };
  const focusIndex = (index: number) => {
    const next = Math.min(filtered.length - 1, Math.max(0, index));
    if (!filtered[next]) return;
    setFocused(filtered[next].name);
    virtuoso.current?.scrollIntoView({index: next, behavior: 'auto', done: () => sectionRef.current?.querySelector<HTMLElement>(`tr[data-index="${next}"]`)?.focus()});
  };
  const context: PaneContext = {
    disabled: listingDisabled, selected, widths, checkWidth, focused: visibleNames.has(focused) ? focused : filtered[0]?.name || '', onFocus: item => { if (!listingDisabled) { setFocused(item.name); browser.setFocusedEntry({name:item.name,isDir:item.isDir}); } },
    onOpen: item => { if (item.isDir && !listingDisabled) navigate(childEndpoint(endpoint, item.name)); },
    onSelect: (item, event) => {
      if (listingDisabled || (event.target as HTMLElement).closest('input,button')) return;
      setFocused(item.name);browser.setFocusedEntry({name:item.name,isDir:item.isDir});
      if (!isSource) return;
      const index = filtered.findIndex(x => x.name === item.name);
      if (event.shiftKey && anchor.current !== null) {
        const start = Math.min(anchor.current, index), end = Math.max(anchor.current, index);
        browser.setSelection(filtered.slice(start, end + 1).map(x => ({name: x.name, isDir: x.isDir})));
      } else if (event.metaKey || event.ctrlKey) toggle(item);
      else browser.setSelection([{name: item.name, isDir: item.isDir}]);
      if (!event.shiftKey) anchor.current = index;
      setFocused(item.name);
    },
    onKey: (event, item, index) => {
      if (listingDisabled || event.target instanceof HTMLInputElement) return;
      if (event.key === 'ArrowDown' || event.key === 'ArrowUp') { event.preventDefault(); focusIndex(index + (event.key === 'ArrowDown' ? 1 : -1)); }
      if (event.key === ' ') { event.preventDefault(); toggle(item); }
      if (event.key === 'Enter' && item.isDir && !navigationDisabled) { event.preventDefault(); navigate(childEndpoint(endpoint, item.name)); }
    },
  };
  const sortBy = (key: typeof sort.key) => setSort(old => ({key, ascending: old.key === key ? !old.ascending : true}));
  const sortHeader = (key: typeof sort.key, label: string) => <button type="button" className="sort-button" onClick={() => sortBy(key)}>{label}{sort.key === key && (sort.ascending ? <CaretUp size={10}/> : <CaretDown size={10}/>)}</button>;
  const chooseLocal = async () => {
    try { const path = await window.rclone.chooseFolder(endpoint.remote ? home : endpoint.path); if (path) navigate({remote: null, path}); }
    catch (reason) { onError(errorMessage(reason)); }
  };
  const onKeyDown = (event: KeyboardEvent<HTMLElement>) => {
    if (navigationDisabled) return;
    const modifier = event.metaKey || event.ctrlKey;
    if (modifier && event.key.toLowerCase() === 'l') { event.preventDefault(); pathRef.current?.focus(); pathRef.current?.select(); }
    if ((modifier && event.key.toLowerCase() === 'r') || event.key === 'F5') { event.preventDefault(); browser.reload(); return; }
    if (event.key === 'Escape' && loading && pathDraft === null) { event.preventDefault(); event.stopPropagation(); void cancelRead(); return; }
    const editing = (event.target as HTMLElement).closest('input,textarea,select');
    if (editing) return;
    if (event.key === 'Escape' && loading) { event.preventDefault(); event.stopPropagation(); void cancelRead(); return; }
    if (modifier && event.key.toLowerCase() === 'a') { event.preventDefault(); if (isSource && !listingDisabled) browser.setSelection(filtered.map(item => ({name: item.name, isDir: item.isDir}))); }
    if ((modifier && event.key === 'ArrowUp') || event.key === 'Backspace') { event.preventDefault(); event.stopPropagation(); setPathDraft(null); browser.up(); }
  };

  return <section ref={sectionRef} className={`browser-pane ${active ? 'pane-active' : ''} ${preferences.alternatingRows ? 'striped-rows' : ''} ${isSource ? 'source-pane' : 'destination-pane'}`} aria-label={`${t(side)} ${t('files')}`} data-testid={`${side}-pane`} data-pane-side={side}
    onFocusCapture={onActivate} onPointerDown={onActivate} onKeyDownCapture={onKeyDown}>
    <header className="pane-heading"><span className="pane-side">{t(side)}</span><span className={`role-tag ${isSource ? 'source-tag' : ''}`}>{t(isSource ? 'source' : 'destination')}</span></header>
    <div className="pane-tabs" role="tablist" aria-label={`${t(side)} ${t('locationTabs')}`}>{browser.tabs.map(tab => <div key={tab.id} className={`pane-tab ${tab.id === browser.activeTab ? 'active' : ''}`}><button type="button" role="tab" aria-selected={tab.id === browser.activeTab} title={endpointText(tab.endpoint)} onClick={() => browser.switchTab(tab.id)} onKeyDown={event => { if (event.key === 'ArrowLeft' || event.key === 'ArrowRight') { event.preventDefault(); const index = browser.tabs.findIndex(item => item.id === tab.id); const next = browser.tabs[(index + (event.key === 'ArrowRight' ? 1 : browser.tabs.length - 1)) % browser.tabs.length]; browser.switchTab(next.id); requestAnimationFrame(() => sectionRef.current?.querySelector<HTMLButtonElement>('[role="tab"][aria-selected="true"]')?.focus()); } }}>{tab.endpoint.remote ? <Cloud size={13}/> : <HardDrives size={13}/>}<span>{endpointName(tab.endpoint)}</span></button>{browser.tabs.length > 1 && <button type="button" className="tab-close" aria-label={`${t('closeTab')} ${endpointName(tab.endpoint)}`} onClick={() => browser.closeTab(tab.id)}><X size={11}/></button>}</div>)}<IconButton title={t('newTab')} disabled={browser.tabs.length >= 12 || !browser.hasListing || browser.cancelling} onClick={browser.newTab}><Plus size={15}/></IconButton></div>
    <div className="path-toolbar">
      <LocationPicker compact endpoint={endpoint} locations={locations} remotes={remotes} label={`${t(side)} ${t('location')}`} disabled={disabled} remoteAvailable={remoteAvailable} t={t} onChange={navigate} remotePath={name => rememberedPaths.current[name] || ''}/>
      <IconButton title={t('back')} disabled={!browser.canBack || navigationDisabled} onClick={() => { setPathDraft(null); browser.back(); }}><ArrowLeft size={17}/></IconButton>
      <IconButton title={t('forward')} disabled={!browser.canForward || navigationDisabled} onClick={() => { setPathDraft(null); browser.forward(); }}><ArrowRight size={17}/></IconButton>
      <IconButton title={t('up')} disabled={navigationDisabled || endpointEqual(endpoint, parentEndpoint(endpoint))} onClick={() => { setPathDraft(null); browser.up(); }}><ArrowUp size={17}/></IconButton>
      <form className="path-form" onSubmit={event => { event.preventDefault(); if (navigationDisabled) return; const raw = pathDraft ?? endpoint.path; if (!endpoint.remote && !raw.trim()) return; navigate({ ...endpoint, path: raw }); }}>
        {endpoint.remote && <span className="path-endpoint-name" title={endpoint.remote}>{endpoint.remote}:</span>}
        <input ref={pathRef} aria-label={`${t(side)} ${t('path')}`} spellCheck={false} value={pathDraft ?? (endpoint.path || '/')} onChange={event => { setPathDraft(event.target.value); browser.setPathDirty(event.target.value !== endpoint.path); }} onKeyDown={event => { if (event.key === 'Escape') { event.preventDefault(); setPathDraft(null); browser.setPathDirty(false); } }} disabled={navigationDisabled}/>
        <button type="submit" className="path-go" title={t('go')} aria-label={t('go')} disabled={navigationDisabled}><CaretDown className="rotate-left" size={13}/></button>
      </form>
      <IconButton title={t('refresh')} className={loading ? 'loading-icon' : ''} onClick={browser.reload} disabled={navigationDisabled || loading}><ArrowClockwise size={18}/></IconButton>
    </div>
    <div className="file-toolbar">
      <div className="search-field"><MagnifyingGlass size={15}/><input aria-label={`${t(side)} ${t('search')}`} placeholder={t('search')} value={query} onChange={event => setQuery(event.target.value)} spellCheck={false}/>{query && <button type="button" onClick={() => setQuery('')} aria-label={t('clearSelection')}><X size={12}/></button>}</div>
      {!endpoint.remote && <IconButton title={t('chooseFolder')} onClick={chooseLocal} disabled={disabled}><FolderOpen size={18}/></IconButton>}
      <IconButton title={t('newFolder')} onClick={() => onFileAction('newFolder')} disabled={listingDisabled || browser.pathDirty}><FolderPlus size={18}/></IconButton>
      <PaneMenu t={t} remote={Boolean(endpoint.remote)} canMount={platform === 'darwin'} selectedCount={fileSelection.length} selectedDirectory={fileSelection[0]?.isDir || false} disabled={listingDisabled || browser.pathDirty} onAction={onToolAction} onResetColumns={resetWidths}/>
      <IconButton title={t(showHidden ? 'hideHidden' : 'showHidden')} aria-pressed={showHidden} onClick={() => setShowHidden(!showHidden)}>{showHidden ? <Eye size={18}/> : <EyeSlash size={18}/>}</IconButton>
    </div>
    {isSource && browser.missingSelection && <Notice kind="warning">{t('missingSelection')} <button type="button" className="text-button" onClick={() => browser.setSelection([])}>{t('clearSelection')}</button></Notice>}
    {error && browser.hasListing && <Notice kind="error">{t('cannotBrowse')}: {error} <button type="button" className="text-button" onClick={browser.retry}>{t('retry')}</button></Notice>}
    <span className="sr-only" role="status">{loading ? loadingLabel : ''}</span>
    <div className="file-list" data-empty={!filtered.length || undefined} aria-busy={loading}
      onDragStartCapture={event => { if (listingDisabled) { event.preventDefault(); event.stopPropagation(); } }}
      onContextMenuCapture={event => { if (listingDisabled) { event.preventDefault(); event.stopPropagation(); } }}>
      {!browser.hasListing || filtered.length === 0 ?
        <div className="file-empty-scroller">{error && !browser.hasListing ?
          <EmptyState compact kind="error" icon={endpoint.remote ? <Cloud size={30}/> : <FolderOpen size={30}/>} title={t('cannotBrowse')} action={<button type="button" onClick={browser.retry}>{t('retry')}</button>}>{error}</EmptyState> : !browser.hasListing ? null :
          <EmptyState compact icon={query ? <MagnifyingGlass size={32}/> : <FolderOpen size={34} weight="duotone"/>} title={t(query || entries.length > 0 ? 'noMatches' : 'emptyFolder')}>{(query || entries.length > 0) ? t('noMatchesHint') : null}</EmptyState>}
        </div> :
        <TableVirtuoso ref={virtuoso} data={filtered} components={tableComponents} context={context} fixedItemHeight={37} overscan={200} onScroll={event => { const element = event.currentTarget as HTMLElement; element.closest<HTMLElement>('.file-list')?.style.setProperty('--stripe-offset', `${33 - element.scrollTop % 74}px`); }}
          computeItemKey={(_index, item) => item.name}
          fixedHeaderContent={() => <tr><th scope="col" className="check-cell" aria-hidden={!isSource || undefined}>{isSource && <input type="checkbox" aria-label={`${t(side)} ${t('selectAll')}`} checked={allSelected} disabled={listingDisabled} ref={element => { if (element) element.indeterminate = someSelected && !allSelected; }} onChange={selectVisible}/>}</th><th scope="col" aria-sort={sort.key === 'name' ? sort.ascending ? 'ascending' : 'descending' : 'none'}>{sortHeader('name', t('name'))}{resizeHandle('name', t('name'))}</th><th scope="col" className="numeric" aria-sort={sort.key === 'size' ? sort.ascending ? 'ascending' : 'descending' : 'none'}>{sortHeader('size', t('size'))}{resizeHandle('size', t('size'))}</th><th scope="col" aria-sort={sort.key === 'modified' ? sort.ascending ? 'ascending' : 'descending' : 'none'}>{sortHeader('modified', t('modified'))}{resizeHandle('modified', t('modified'))}</th><th scope="col" className="row-fill" aria-label=""/></tr>}
          itemContent={(_index, entry) => <><td className="check-cell" aria-hidden={!isSource || undefined}>{isSource && <input type="checkbox" aria-label={`${t('selected')} ${entry.name}`} checked={selected.has(entry.name)} disabled={listingDisabled} onChange={() => toggle(entry)} onClick={event => event.stopPropagation()}/>}</td><td><div className="file-name" title={entry.name}>{(entry.isDir ? preferences.showFolderIcons : preferences.showFileIcons) && <EntryIcon entry={entry}/>}<span>{entry.name}</span>{entry.isLink && <span className="link-marker">↗</span>}</div></td><td className="numeric muted">{entry.isDir ? '—' : formatBytes(entry.size)}</td><td className="date-cell muted" title={formatDate(entry.modified, language)}>{formatDate(entry.modified, language)}</td><td className="row-fill" aria-hidden="true"/></>}/>
      }
      {loading && <div className="folder-loading-overlay"><button type="button" className="folder-load-cancel" aria-label={t(browser.cancelling ? 'cancellingFolder' : 'cancelLoadingFolder')} aria-describedby={`${side}-folder-read-label`} title={t(browser.cancelling ? 'cancellingFolder' : 'cancelLoadingFolder')} disabled={browser.cancelling} onClick={() => void cancelRead()}><span className="folder-loading-ring" aria-hidden="true"/><X className="folder-loading-cross" size={13} weight="bold" aria-hidden="true"/></button><span className="folder-loading-label" id={`${side}-folder-read-label`} title={browser.pendingEndpoint ? endpointText(browser.pendingEndpoint) : undefined}>{loadingLabel}</span></div>}
    </div>
    <footer className="pane-footer">
      <div className="selection-summary" title={hiddenSelection ? t('hiddenSelection') : endpointText(endpoint)}><span>{filtered.length.toLocaleString()} {t('items')}</span>{isSource && selection.length > 0 && <><span className="dot-separator">·</span><button type="button" className="text-button" onClick={() => browser.setSelection([])} title={t('clearSelection')}>{t('selected')} {selection.length}{hiddenSelection ? ' *' : ''}<X size={11}/></button></>}</div>
      <div className="pane-file-actions"><IconButton title={t('rename')} disabled={listingDisabled || browser.pathDirty || fileSelection.length !== 1 || (isSource && browser.missingSelection)} onClick={() => onFileAction('rename')}><PencilSimple size={15}/></IconButton><IconButton title={t('remove')} disabled={listingDisabled || browser.pathDirty || fileSelection.length === 0 || (isSource && browser.missingSelection)} onClick={() => onFileAction('remove')}><Trash size={15}/></IconButton><IconButton title={t('folderSize')} disabled={listingDisabled || browser.pathDirty} onClick={() => onFileAction('size')}><ChartBar size={15}/></IconButton></div>
    </footer>
  </section>;
}
