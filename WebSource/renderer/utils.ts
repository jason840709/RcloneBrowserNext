import type { Endpoint, Language } from '../shared/types';

export function endpointText(endpoint: Endpoint): string {
  return endpoint.remote ? `${endpoint.remote}:${endpoint.path}` : endpoint.path;
}
export function endpointName(endpoint: Endpoint): string {
  if (endpoint.remote) return endpoint.remote;
  return endpoint.path.split('/').filter(Boolean).at(-1) || '/';
}
export function endpointEqual(a: Endpoint, b: Endpoint): boolean {
  const normalize = (path: string) => path === '/' ? '/' : path.replace(/\/+$/, '');
  return a.remote === b.remote && normalize(a.path) === normalize(b.path);
}
export function childEndpoint(endpoint: Endpoint, name: string): Endpoint {
  const path = endpoint.path === '' && endpoint.remote ? name : `${endpoint.path.replace(/\/+$/, '')}/${name}`;
  return { ...endpoint, path };
}
export function parentEndpoint(endpoint: Endpoint): Endpoint {
  if (endpoint.path === '/') return {...endpoint};
  const path = endpoint.path.replace(/\/+$/, '');
  const slash = path.lastIndexOf('/');
  return { ...endpoint, path: slash > 0 ? path.slice(0, slash) : slash === 0 || !endpoint.remote ? '/' : '' };
}
export function formatBytes(value: number): string {
  if (!Number.isFinite(value) || value < 0) return '—';
  if (value === 0) return '0 B';
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB'];
  const index = Math.min(units.length - 1, Math.max(0, Math.floor(Math.log(value) / Math.log(1024))));
  const n = value / 1024 ** index;
  return `${n.toLocaleString('en', { maximumFractionDigits: index === 0 ? 0 : n >= 100 ? 0 : 1 })} ${units[index]}`;
}
export function formatDuration(seconds: number | null | undefined): string {
  if (seconds == null || !Number.isFinite(seconds) || seconds < 0) return '—';
  const whole = Math.floor(seconds);
  const hours = Math.floor(whole / 3600);
  const mins = Math.floor(whole % 3600 / 60);
  const secs = whole % 60;
  return hours > 0 ? `${hours}:${String(mins).padStart(2, '0')}:${String(secs).padStart(2, '0')}` : `${mins}:${String(secs).padStart(2, '0')}`;
}
export function formatDate(value: string, language: Language, _full = false): string {
  const date = new Date(value);
  if (!value || Number.isNaN(date.getTime())) return '—';
  return date.toLocaleString(language, {year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23'});
}
export function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message.replace(/^Error invoking remote method '[^']+': (?:Error: )?/, '') : String(error);
}
export function validName(name: string): boolean {
  return Boolean(name.trim()) && !/[\/\\\r\n\0]/.test(name) && name !== '.' && name !== '..';
}
