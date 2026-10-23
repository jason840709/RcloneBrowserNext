import type { Endpoint, FileEntry } from '../shared/types';

export interface FileRow extends FileEntry { rowKey: string }

// Remote directories can contain distinct objects with the same name and path.
// Assign each occurrence a display identity before filtering or sorting, without
// changing the native entries or treating a display key as an operation target.
export function fileRows(endpoint: Endpoint, entries: readonly FileEntry[]): FileRow[] {
  const occurrences = new Map<string, number>();
  return entries.map(entry => {
    const identity = JSON.stringify([entry.path, entry.name, entry.isDir]);
    const occurrence = occurrences.get(identity) ?? 0;
    occurrences.set(identity, occurrence + 1);
    return { ...entry, rowKey: JSON.stringify([endpoint.remote, endpoint.path, entry.path, entry.name, entry.isDir, occurrence]) };
  });
}
