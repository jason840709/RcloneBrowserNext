import {DEFAULT_OPTIONS, type BuiltinPresetID, type Endpoint, type LocalLocation, type RemoteInfo, type TransferOptions} from '../shared/types';

export const BUILTIN_PRESETS: BuiltinPresetID[] = ['local-nas', 'nas-cloud', 'local-cloud'];
export const MAC_EXCLUDES = ['.DS_Store', '._*', '.Spotlight-V100/**', '.Trashes/**', '.fseventsd/**', '.TemporaryItems/**'];
export const presetLabel = (id: BuiltinPresetID) => id === 'local-nas' ? 'presetLocalNAS' : id === 'nas-cloud' ? 'presetNASCloud' : 'presetLocalCloud';
export const presetSummary = (id: BuiltinPresetID) => id === 'local-cloud' ? 'presetCloudSummary' : 'presetNASSummary';
export function presetOptions(id: BuiltinPresetID): TransferOptions {
  return {...structuredClone(DEFAULT_OPTIONS), transfers: id === 'local-cloud' ? 4 : 1, checkers: id === 'local-cloud' ? 8 : 10,
    comparison: 'default', localHashPolicy: 'none', maxDelete: -1, deleteMode: 'during', exclude: [...MAC_EXCLUDES], extraArgs: id === 'local-nas' ? ['--multi-thread-streams=0'] : []};
}
function endpointKind(endpoint: Endpoint, remotes: RemoteInfo[], locations: LocalLocation[]) {
  if (endpoint.remote) return remotes.find(remote => remote.name === endpoint.remote)?.group || 'other';
  return locations.some(location => location.group === 'network' && (endpoint.path === location.path || endpoint.path.startsWith(`${location.path}/`))) ? 'network' : 'local';
}
export function recommendedPreset(source: Endpoint, destination: Endpoint, remotes: RemoteInfo[], locations: LocalLocation[]): BuiltinPresetID | null {
  const from = endpointKind(source, remotes, locations), to = endpointKind(destination, remotes, locations);
  if (from === 'local' && to === 'network') return 'local-nas';
  if (from === 'network' && to === 'cloud') return 'nas-cloud';
  if (from === 'local' && to === 'cloud') return 'local-cloud';
  return null;
}
