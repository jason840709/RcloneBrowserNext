import {DEFAULT_OPTIONS, type BuiltinPresetID, type Endpoint, type LocalLocation, type RemoteInfo, type TransferOptions} from '../shared/types';

export const BUILTIN_PRESETS: BuiltinPresetID[] = ['local-local', 'local-nas', 'local-cloud', 'nas-cloud', 'cloud-cloud', 'cloud-local'];
export const MAC_EXCLUDES = ['.DS_Store', '._*', '.Spotlight-V100/**', '.Trashes/**', '.fseventsd/**', '.TemporaryItems/**'];
export const presetLabel = (id: BuiltinPresetID) => ({'local-nas':'presetLocalNAS','nas-cloud':'presetNASCloud','local-cloud':'presetLocalCloud','local-local':'presetLocalLocal','cloud-cloud':'presetCloudCloud','cloud-local':'presetCloudLocal'} as const)[id];
export const presetWritesLocal = (id: BuiltinPresetID) => ['local-local','local-nas','cloud-local'].includes(id);
export const presetSummary = (id: BuiltinPresetID) => presetWritesLocal(id) ? 'presetNASSummary' : 'presetCloudSummary';
export function presetOptions(id: BuiltinPresetID): TransferOptions {
  return {...structuredClone(DEFAULT_OPTIONS), transfers: presetWritesLocal(id) ? 1 : 7, checkers: 10,
    comparison: 'default', localHashPolicy: 'none', maxDelete: -1, deleteMode: 'during', exclude: [...MAC_EXCLUDES], extraArgs: presetWritesLocal(id) ? ['--multi-thread-streams=0'] : []};
}
function endpointKind(endpoint: Endpoint, remotes: RemoteInfo[], locations: LocalLocation[]) {
  if (endpoint.remote) return remotes.find(remote => remote.name === endpoint.remote)?.group || 'other';
  return locations.some(location => location.group === 'network' && (endpoint.path === location.path || endpoint.path.startsWith(`${location.path}/`))) ? 'network' : 'local';
}
export function recommendedPreset(source: Endpoint, destination: Endpoint, remotes: RemoteInfo[], locations: LocalLocation[]): BuiltinPresetID | null {
  const from = endpointKind(source, remotes, locations), to = endpointKind(destination, remotes, locations);
  if (from === 'local' && to === 'local') return 'local-local';
  if (from === 'local' && to === 'network') return 'local-nas';
  if (from === 'network' && to === 'cloud') return 'nas-cloud';
  if (from === 'local' && to === 'cloud') return 'local-cloud';
  if (from === 'cloud' && to === 'cloud') return 'cloud-cloud';
  if (from === 'cloud' && (to === 'local' || to === 'network')) return 'cloud-local';
  return null;
}
