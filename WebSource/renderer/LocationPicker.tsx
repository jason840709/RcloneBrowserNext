import { useEffect, useId, useLayoutEffect, useRef, useState, type KeyboardEvent } from 'react';
import { createPortal } from 'react-dom';
import { CaretDown, Check, Cloud, FolderOpen, HardDrives, MagnifyingGlass } from '@phosphor-icons/react';
import type { Endpoint, LocalLocation, RemoteInfo } from '../shared/types';
import type { Translate } from './i18n';
import { Field, IconButton } from './components';
import { endpointEqual, errorMessage } from './utils';

export function localLocationName(location: LocalLocation, t: Translate): string {
  const labels = {home: 'homeFolder', desktop: 'desktopFolder', documents: 'documentsFolder', downloads: 'downloadsFolder', pictures: 'picturesFolder', music: 'musicFolder', movies: 'moviesFolder', volumes: 'volumesFolder'} as const;
  return location.id === 'volumes' ? t('volumesFolder') : location.kind === 'volume' ? location.name : t(labels[location.kind]);
}

type PlaceOption = {value: string; name: string; endpoint: Endpoint; disabled?: boolean};

export function LocationPicker({ endpoint, locations, remotes, label, disabled = false, remoteAvailable = true, t, onChange, remotePath, compact = false }: {
  endpoint: Endpoint; locations: LocalLocation[]; remotes: RemoteInfo[]; label: string; disabled?: boolean; remoteAvailable?: boolean; t: Translate;
  compact?: boolean; onChange(endpoint: Endpoint): void; remotePath?(name: string): string;
}) {
  const [open, setOpen] = useState(false), [query, setQuery] = useState('');
  const [active, setActive] = useState('');
  const [position, setPosition] = useState({left: 0, top: 0, width: 280, maxHeight: 400});
  const trigger = useRef<HTMLButtonElement>(null), popup = useRef<HTMLDivElement>(null), search = useRef<HTMLInputElement>(null), list = useRef<HTMLDivElement>(null);
  const id = useId(), listId = `${id}-places`;
  const container = trigger.current?.closest('dialog') || document.body;
  const current = !endpoint.remote && locations.find(location => endpointEqual(endpoint, {remote: null, path: location.path}));
  const value = endpoint.remote || (current ? `@local:${current.id}` : '');
  const place = (location: LocalLocation): PlaceOption => ({value: `@local:${location.id}`, name: localLocationName(location, t), endpoint: {remote: null, path: location.path}});
  const remote = (item: RemoteInfo): PlaceOption => ({value: item.name, name: `${item.name} · ${item.type}`, endpoint: {remote: item.name, path: remotePath?.(item.name) || ''}, disabled: !remoteAvailable});
  const groups = [
    {label: t('localPlaces'), items: [...(!current && !endpoint.remote ? [{value: '', name: t('currentLocalFolder'), endpoint}] : []), ...locations.filter(location => location.group !== 'network').map(place)]},
    ...(['network', 'cloud', 'other'] as const).map(group => ({label: t(group === 'network' ? 'networkPlaces' : group === 'cloud' ? 'cloudPlaces' : 'otherPlaces'), items: [
      ...(group === 'network' ? locations.filter(location => location.group === 'network').map(place) : []),
      ...remotes.filter(item => (item.group || (['smb','sftp','ftp'].includes(item.type) ? 'network' : 'other')) === group).map(remote),
      ...(group === 'other' && endpoint.remote && !remotes.some(item => item.name === endpoint.remote) ? [{value: endpoint.remote, name: endpoint.remote, endpoint, disabled: !remoteAvailable}] : []),
    ]})),
  ];
  const options = groups.flatMap(group => group.items);
  const selectedName = options.find(option => option.value === value)?.name || endpoint.remote || t('currentLocalFolder');
  const filtered = groups.map(group => ({...group, items: group.items.filter(option => `${option.name} ${option.endpoint.path}`.toLocaleLowerCase().includes(query.trim().toLocaleLowerCase()))})).filter(group => group.items.length);
  const available = filtered.flatMap(group => group.items).filter(option => !option.disabled);
  const activeIndex = available.findIndex(option => option.value === active);
  const activeId = activeIndex < 0 ? undefined : `${id}-option-${options.findIndex(option => option.value === active)}`;
  const close = (focus = false) => { setOpen(false); if (focus) trigger.current?.focus({preventScroll: true}); };
  const show = (edge?: 'first' | 'last') => {
    if (disabled) return;
    setQuery('');
    const enabled = options.filter(option => !option.disabled);
    setActive(edge === 'first' ? enabled[0]?.value || '' : edge === 'last' ? enabled.at(-1)?.value || '' : enabled.find(option => option.value === value)?.value || enabled[0]?.value || '');
    setOpen(true);
  };
  const choose = (option: PlaceOption) => {
    if (option.disabled) return;
    close(true);
    if (!endpointEqual(endpoint, option.endpoint)) onChange(option.endpoint);
  };
  useLayoutEffect(() => {
    if (!open || !trigger.current) return;
    const positionBelow = () => {
      if (!trigger.current) return;
      const anchor = trigger.current.getBoundingClientRect();
      const inDialog = container !== document.body;
      const surface = inDialog ? container.getBoundingClientRect() : {left: 0, top: 0, right: innerWidth, bottom: innerHeight};
      const margin = 8, top = anchor.bottom + 6;
      const width = Math.min(Math.max(280, compact ? 0 : anchor.width), Math.min(innerWidth, surface.right) - Math.max(0, surface.left) - 2 * margin);
      const left = Math.max(surface.left + margin, Math.min(anchor.left, surface.right - width - margin));
      // A selected item may scroll inside the list; it never moves the popup above its trigger.
      setPosition({left: left - (inDialog ? surface.left + container.clientLeft : 0), top: top - (inDialog ? surface.top + container.clientTop : 0), width, maxHeight: Math.max(0, Math.min(420, Math.min(innerHeight, surface.bottom) - top - margin))});
    };
    positionBelow(); search.current?.focus({preventScroll: true});
    const scroll = (event: Event) => { if (!popup.current?.contains(event.target as Node)) positionBelow(); };
    window.addEventListener('resize', positionBelow); document.addEventListener('scroll', scroll, true);
    return () => { window.removeEventListener('resize', positionBelow); document.removeEventListener('scroll', scroll, true); };
  }, [open, container, compact]);
  useLayoutEffect(() => {
    if (!open || !list.current || !activeId) return;
    const option = document.getElementById(activeId);
    if (!option) return;
    const box = list.current.getBoundingClientRect(), item = option.getBoundingClientRect();
    if (item.top < box.top) list.current.scrollTop -= box.top - item.top;
    else if (item.bottom > box.bottom) list.current.scrollTop += item.bottom - box.bottom;
  }, [open, activeId, query, position.maxHeight]);
  useEffect(() => {
    if (!open) return;
    const outside = (event: Event) => { if (!trigger.current?.contains(event.target as Node) && !popup.current?.contains(event.target as Node)) close(); };
    document.addEventListener('pointerdown', outside);
    document.addEventListener('focusin', outside);
    return () => { document.removeEventListener('pointerdown', outside); document.removeEventListener('focusin', outside); };
  }, [open]);
  useEffect(() => { if (disabled) close(); }, [disabled]);
  useEffect(() => { setOpen(false); }, [endpoint.remote, endpoint.path]);
  const keyDown = (event: KeyboardEvent<HTMLInputElement>) => {
    event.stopPropagation();
    if (event.nativeEvent.isComposing || event.keyCode === 229) return;
    if (event.key === 'Escape') { event.preventDefault(); close(true); }
    else if (event.key === 'Tab') close(true);
    else if (event.key === 'Enter') { event.preventDefault(); if (available[activeIndex]) choose(available[activeIndex]); }
    else if (['ArrowDown', 'ArrowUp'].includes(event.key) || event.altKey && ['Home', 'End'].includes(event.key)) {
      event.preventDefault();
      if (!available.length) return;
      const next = event.key === 'Home' ? 0 : event.key === 'End' ? available.length - 1 : event.key === 'ArrowDown' ? (activeIndex + 1) % available.length : (activeIndex - 1 + available.length) % available.length;
      setActive(available[next].value);
    }
  };
  return <div className={`location-select ${compact ? 'location-select-compact' : ''}`}>
    <button ref={trigger} type="button" className="location-trigger" aria-label={label} title={`${label}: ${selectedName}`} aria-haspopup="listbox" aria-expanded={open} aria-controls={open ? listId : undefined} disabled={disabled} onClick={() => open ? close() : show()} onKeyDown={event => {
      if (['ArrowDown','ArrowUp','Home','End'].includes(event.key)) { event.preventDefault(); event.stopPropagation(); show(event.key === 'Home' ? 'first' : event.key === 'End' ? 'last' : undefined); }
    }}>{endpoint.remote ? <Cloud size={18}/> : <HardDrives size={18}/>}<span className="location-trigger-label">{selectedName}</span><CaretDown size={12} className="select-caret"/></button>
    {open && createPortal(<div ref={popup} className="location-popup" style={{position: container === document.body ? 'fixed' : 'absolute', ...position}} onPointerDown={event => event.stopPropagation()}>
      <div className="location-search"><MagnifyingGlass size={16}/><input ref={search} role="combobox" aria-label={`${label} ${t('searchLocations')}`} aria-controls={listId} aria-expanded="true" aria-autocomplete="list" aria-activedescendant={activeId} value={query} placeholder={t('searchLocations')} spellCheck={false} onChange={event => {setQuery(event.target.value); const text = event.target.value.trim().toLocaleLowerCase(); setActive(options.find(option => !option.disabled && `${option.name} ${option.endpoint.path}`.toLocaleLowerCase().includes(text))?.value || '');}} onKeyDown={keyDown}/></div>
      <div ref={list} id={listId} role="listbox" aria-label={label} className="location-options">
        {filtered.map((group, groupIndex) => <div role="group" aria-labelledby={`${id}-group-${groupIndex}`} key={group.label} className="location-group"><div id={`${id}-group-${groupIndex}`} className="location-group-label">{group.label}</div>{group.items.map(option => <div key={option.value} id={`${id}-option-${options.findIndex(item => item.value === option.value)}`} role="option" aria-selected={value === option.value} aria-disabled={option.disabled || undefined} data-value={option.value} data-active={active === option.value} className="location-option" title={option.name} onPointerMove={() => {if (!option.disabled) setActive(option.value);}} onPointerDown={event => event.preventDefault()} onClick={() => choose(option)}><span className="location-check">{value === option.value && <Check size={15} weight="bold"/>}</span>{option.endpoint.remote ? <Cloud size={16}/> : <HardDrives size={16}/>}<span>{option.name}</span></div>)}</div>)}
        {!filtered.length && <p className="location-no-results" role="status">{t('noMatches')}</p>}
      </div>
    </div>, container)}
  </div>;
}

export function EndpointEditor({ value, label, locations, remotes, home, t, disabled = false, onChange, onError }: {
  value: Endpoint; label: string; locations: LocalLocation[]; remotes: RemoteInfo[]; home: string; t: Translate; disabled?: boolean; onChange(value: Endpoint): void; onError(message: string): void;
}) {
  const [path, setPath] = useState(value.path);
  useEffect(() => setPath(value.path), [value.path, value.remote]);
  const commit = () => { const next = {...value, path: value.remote && path === '/' ? '' : path}; if (!endpointEqual(value, next)) onChange(next); };
  const choose = async () => { try { const selected = await window.rclone.chooseFolder(value.remote ? home : path || home); if (selected) onChange({remote: null, path: selected}); } catch (error) { onError(errorMessage(error)); } };
  return <div className="endpoint-editor"><Field label={label}><LocationPicker endpoint={value} locations={locations} remotes={remotes} label={`${label} ${t('location')}`} disabled={disabled} t={t} onChange={onChange}/></Field><div className="endpoint-path-row"><input aria-label={`${label} ${t('path')}`} value={path} placeholder={value.remote ? '/' : home} required={!value.remote} disabled={disabled} spellCheck={false} onChange={event => setPath(event.target.value)} onBlur={commit} onKeyDown={event => { if (event.key === 'Enter') { event.preventDefault(); commit(); } if (event.key === 'Escape') { event.preventDefault(); event.stopPropagation(); setPath(value.path); } }}/><IconButton title={`${label} ${t('chooseFolder')}`} onClick={() => void choose()} disabled={disabled}><FolderOpen size={18}/></IconButton></div></div>;
}
