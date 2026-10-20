import { useEffect, useState } from 'react';
import { CaretDown, Cloud, FolderOpen, HardDrives } from '@phosphor-icons/react';
import type { Endpoint, LocalLocation, RemoteInfo } from '../shared/types';
import type { Translate } from './i18n';
import { Field, IconButton } from './components';
import { endpointEqual, errorMessage } from './utils';

export function localLocationName(location: LocalLocation, t: Translate): string {
  const labels = {home: 'homeFolder', desktop: 'desktopFolder', documents: 'documentsFolder', downloads: 'downloadsFolder', pictures: 'picturesFolder', music: 'musicFolder', movies: 'moviesFolder', volumes: 'volumesFolder'} as const;
  return location.id === 'volumes' ? t('volumesFolder') : location.kind === 'volume' ? location.name : t(labels[location.kind]);
}

export function LocationPicker({ endpoint, locations, remotes, label, disabled = false, remoteAvailable = true, t, onChange, remotePath }: {
  endpoint: Endpoint; locations: LocalLocation[]; remotes: RemoteInfo[]; label: string; disabled?: boolean; remoteAvailable?: boolean; t: Translate;
  onChange(endpoint: Endpoint): void; remotePath?(name: string): string;
}) {
  const current = !endpoint.remote && locations.find(location => location.path === endpoint.path);
  const value = endpoint.remote || (current ? `@local:${current.id}` : '');
  const local = locations.filter(location => location.group !== 'network');
  const networkVolumes = locations.filter(location => location.group === 'network');
  const groups = (['network','cloud','other'] as const).map(group => ({group, items: remotes.filter(remote => (remote.group || (['smb','sftp','ftp'].includes(remote.type) ? 'network' : 'other')) === group)}));
  const places = (list: LocalLocation[]) => list.map(location => <option key={location.id} value={`@local:${location.id}`}>{localLocationName(location, t)}</option>);
  return <div className="location-select">{endpoint.remote ? <Cloud size={18}/> : <HardDrives size={18}/>}<select aria-label={label} value={value} disabled={disabled} onChange={event => {
    const next = event.target.value;
    if (next.startsWith('@local:')) { const location = locations.find(item => `@local:${item.id}` === next); if (location) onChange({remote: null, path: location.path}); }
    else if (next) onChange({remote: next, path: remotePath?.(next) || ''});
  }}>
    <optgroup label={t('localPlaces')}>
      {!current && !endpoint.remote && <option value="">{t('currentLocalFolder')}</option>}
      {places(local)}
    </optgroup>
    {groups.map(({group, items}) => (items.length > 0 || group === 'network' && networkVolumes.length > 0) && <optgroup key={group} label={t(group === 'network' ? 'networkPlaces' : group === 'cloud' ? 'cloudPlaces' : 'otherPlaces')}>
      {group === 'network' && places(networkVolumes)}
      {items.map(remote => <option key={remote.name} value={remote.name} disabled={!remoteAvailable}>{remote.name} · {remote.type}</option>)}
    </optgroup>)}
    {endpoint.remote && !remotes.some(remote => remote.name === endpoint.remote) && <optgroup label={t('otherPlaces')}><option value={endpoint.remote}>{endpoint.remote}</option></optgroup>}
  </select><CaretDown size={12} className="select-caret"/></div>;
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
